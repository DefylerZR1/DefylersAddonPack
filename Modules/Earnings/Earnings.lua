if not DXMCore or not DXMExchange then return end

local Module = DXMCore:Module("Earnings")
local Const = DXMCore.Const()
local DAYS_SHOWN = 14
local chartRefresh

local function dayKey(timestamp)
    return date("%Y-%m-%d", tonumber(timestamp) or GetServerTime())
end

local function money(value)
    value = math.floor(tonumber(value) or 0)
    local prefix = value < 0 and "-" or ""
    value = math.abs(value)
    local gold = math.floor(value / 10000)
    local silver = math.floor((value % 10000) / 100)
    local copper = value % 100
    if gold > 0 then return prefix .. ("%dg %02ds"):format(gold, silver) end
    if silver > 0 then return prefix .. ("%ds %02dc"):format(silver, copper) end
    return prefix .. copper .. "c"
end

local function ledgerRows()
    return DXMLedger and DXMLedger.GetTransactions and DXMLedger:GetTransactions() or {}
end

local function saleProceeds(row)
    if row.saleProceeds ~= nil then return math.max(0, tonumber(row.saleProceeds) or 0) end
    return math.max(0, (tonumber(row.total) or 0) - (tonumber(row.deposit) or 0))
end

local function buildLedgerSnapshot(nowValue)
    nowValue = tonumber(nowValue) or GetServerTime()
    local snapshot = {
        daily = {}, items = {}, auctionEarned = 0, auctionSpent = 0,
        tradeEarned = 0, tradeSpent = 0,
    }
    local cutoff = nowValue - (DAYS_SHOWN - 1) * 86400
    local function dailyEntry(timestamp)
        timestamp = tonumber(timestamp) or nowValue
        if timestamp < cutoff or timestamp > nowValue + 86400 then return end
        local key = dayKey(timestamp)
        local day = snapshot.daily[key]
        if not day then
            day = {income = 0, spending = 0, auctionIncome = 0, auctionSpending = 0,
                tradeIncome = 0, tradeSpending = 0, proceeds = 0, sales = 0, items = 0}
            snapshot.daily[key] = day
        end
        return day
    end
    for _, row in ipairs(ledgerRows()) do
        local total = math.max(0, tonumber(row.total) or 0)
        local day = dailyEntry(row.timestamp)
        if row.kind == "purchase" and (row.source == nil or row.source == "auction") then
            snapshot.auctionSpent = snapshot.auctionSpent + total
            if day then day.auctionSpending = day.auctionSpending + total; day.spending = day.spending + total end
        elseif row.kind == "posting" then
            local deposit = math.max(0, tonumber(row.deposit) or 0)
            snapshot.auctionSpent = snapshot.auctionSpent + deposit
            if day then day.auctionSpending = day.auctionSpending + deposit; day.spending = day.spending + deposit end
        elseif row.kind == "trade" and row.status == "received" then
            snapshot.tradeEarned = snapshot.tradeEarned + total
            if day then day.tradeIncome = day.tradeIncome + total; day.income = day.income + total end
        elseif row.kind == "trade" and row.status == "spent" then
            snapshot.tradeSpent = snapshot.tradeSpent + total
            if day then day.tradeSpending = day.tradeSpending + total; day.spending = day.spending + total end
        elseif row.kind == "mail" and row.status == "sold" and row.collected then
            snapshot.auctionEarned = snapshot.auctionEarned + total
            if day then
                local quantity = math.max(1, math.floor(tonumber(row.quantity) or 1))
                local proceeds = saleProceeds(row)
                day.auctionIncome = day.auctionIncome + total
                day.income = day.income + total
                day.proceeds = day.proceeds + proceeds
                day.sales = day.sales + 1
                day.items = day.items + quantity
                local itemID = tonumber(row.itemID)
                if itemID then
                    local item = snapshot.items[itemID] or {
                        itemID = itemID, name = row.name, quantity = 0, proceeds = 0,
                        sales = 0, knownCost = 0, knownProfit = 0, knownQuantity = 0,
                    }
                    item.name = row.name or item.name
                    item.quantity = item.quantity + quantity
                    item.proceeds = item.proceeds + proceeds
                    item.sales = item.sales + 1
                    if row.profit ~= nil and row.costBasis ~= nil then
                        item.knownCost = item.knownCost + math.max(0, tonumber(row.costBasis) or 0)
                        item.knownProfit = item.knownProfit + (tonumber(row.profit) or 0)
                        item.knownQuantity = item.knownQuantity + quantity
                    end
                    snapshot.items[itemID] = item
                end
            end
        end
    end
    return snapshot
end

local function recordSale(mailType, mail)
    if (mailType ~= "Sold" and mailType ~= "Invoice") or type(mail) ~= "table" then return end
    if not mail.collected then return end
    local proceeds = math.max(0, math.floor(tonumber(mail.money) or 0))
    local quantity = math.max(1, math.floor(tonumber(mail.itemQuantity) or 1))
    if proceeds <= 0 then return end
    local itemID = mail.itemLink and GetItemInfoInstant and select(1, GetItemInfoInstant(mail.itemLink))
    itemID = tonumber(mail.itemID) or tonumber(itemID)
    local timestamp = (tonumber(mail.arrivalPoint) or 0) * 5
    if timestamp <= 0 then timestamp = GetServerTime() end

    if itemID then
        if DXMQueueSaleObservation then
            DXMQueueSaleObservation(itemID, quantity, proceeds, tonumber(mail.costBasis) or 0, timestamp, mail.sig)
        end
    end
    if chartRefresh then chartRefresh() end
end

local moneyTracker = CreateFrame("Frame")
local lastMoney
local contextExpires = 0
local tradeArmed = false
for _, event in ipairs({
    "PLAYER_ENTERING_WORLD", "PLAYER_MONEY", "TRADE_SHOW", "TRADE_ACCEPT_UPDATE", "TRADE_CLOSED",
}) do moneyTracker:RegisterEvent(event) end
moneyTracker:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        lastMoney = GetMoney()
    elseif event == "TRADE_SHOW" then
        contextExpires, tradeArmed = 0, false
    elseif event == "TRADE_ACCEPT_UPDATE" then
        local playerAccepted, targetAccepted = ...
        tradeArmed = playerAccepted == 1 and targetAccepted == 1
    elseif event == "TRADE_CLOSED" then
        if tradeArmed then
            contextExpires = GetTime() + 3
        else
            contextExpires = 0
        end
        tradeArmed = false
    elseif event == "PLAYER_MONEY" then
        local current = GetMoney()
        if lastMoney and contextExpires > 0 and GetTime() <= contextExpires then
            local delta = current - lastMoney
            if delta ~= 0 and DXMLedger and DXMLedger.RecordTrade then
                DXMLedger:RecordTrade(delta)
                contextExpires = 0
            end
        end
        lastMoney = current
    end
    if contextExpires > 0 and GetTime() > contextExpires then
        contextExpires = 0
    end
end)
local function buildPage(page)
    local total = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    total:SetPoint("TOPLEFT", page.Description, "BOTTOMLEFT", 0, -18)

    local cashFlow = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    cashFlow:SetPoint("TOPLEFT", total, "BOTTOMLEFT", 0, -6)

    local chart = DXMTheme:CreatePanel(page)
    chart:SetPoint("TOPLEFT", cashFlow, "BOTTOMLEFT", 0, -10)
    chart:SetPoint("RIGHT", page, "RIGHT", -18, 0)
    chart:SetHeight(220)

    local baseline = chart:CreateTexture(nil, "BORDER")
    baseline:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", 14, 31)
    baseline:SetPoint("BOTTOMRIGHT", chart, "BOTTOMRIGHT", -14, 31)
    baseline:SetHeight(1)
    baseline:SetColorTexture(0.55, 0.43, 0.18, 0.9)

    local legend = chart:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    legend:SetPoint("TOPLEFT", chart, "TOPLEFT", 14, -8)
    legend:SetText("|cff26b84dIncome|r    |cffff5555Spending|r    Label = net")

    local bars = {}
    for index = 1, DAYS_SHOWN do
        local holder = CreateFrame("Frame", nil, chart)
        holder:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", 17 + (index - 1) * 46, 32)
        holder:SetSize(32, 165)
        local incomeBar = holder:CreateTexture(nil, "ARTWORK")
        incomeBar:SetPoint("BOTTOMRIGHT", holder, "BOTTOM", -1, 0)
        incomeBar:SetWidth(10)
        incomeBar:SetColorTexture(0.15, 0.72, 0.30, 0.88)
        local spendingBar = holder:CreateTexture(nil, "ARTWORK")
        spendingBar:SetPoint("BOTTOMLEFT", holder, "BOTTOM", 1, 0)
        spendingBar:SetWidth(10)
        spendingBar:SetColorTexture(1, 0.22, 0.22, 0.82)
        local amount = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        amount:SetPoint("BOTTOM", holder, "BOTTOM", 0, 2)
        local label = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOP", holder, "BOTTOM", 0, -4)
        holder:EnableMouse(true)
        holder:SetScript("OnEnter", function(self)
            if not self.entry then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.fullDate or "", 1, 0.82, 0)
            local net = (tonumber(self.entry.income) or 0) - (tonumber(self.entry.spending) or 0)
            GameTooltip:AddDoubleLine("Income", money(self.entry.income), 1, 1, 1, 0.2, 1, 0.2)
            GameTooltip:AddDoubleLine("Spending", money(self.entry.spending), 1, 1, 1, 1, 0.25, 0.25)
            GameTooltip:AddDoubleLine("Net", (net >= 0 and "+" or "") .. money(net), 1, 1, 1, net >= 0 and 0.2 or 1, net >= 0 and 1 or 0.25, net >= 0 and 0.2 or 0.25)
            GameTooltip:AddDoubleLine("Auction income", money(self.entry.auctionIncome), 1, 1, 1, 1, 1, 1)
            GameTooltip:AddDoubleLine("Auction spending", money(self.entry.auctionSpending), 1, 1, 1, 1, 1, 1)
            GameTooltip:AddDoubleLine("Sales", tostring(self.entry.sales or 0), 1, 1, 1, 1, 1, 1)
            GameTooltip:AddDoubleLine("Items sold", tostring(self.entry.items or 0), 1, 1, 1, 1, 1, 1)
            GameTooltip:Show()
        end)
        holder:SetScript("OnLeave", function() GameTooltip:Hide() end)
        bars[index] = {holder = holder, incomeBar = incomeBar, spendingBar = spendingBar, amount = amount, label = label}
    end

    local volumeTitle = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    volumeTitle:SetPoint("TOPLEFT", chart, "BOTTOMLEFT", 5, -16)
    volumeTitle:SetText("Top sellers by volume")
    local volumeLines = {}
    for index = 1, 6 do
        local line = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        line:SetPoint("TOPLEFT", volumeTitle, "BOTTOMLEFT", 0, -5 - (index - 1) * 18)
        line:SetWidth(280)
        line:SetJustifyH("LEFT")
        volumeLines[index] = line
    end

    local marginTitle = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    marginTitle:SetPoint("TOPLEFT", chart, "BOTTOMLEFT", 320, -16)
    marginTitle:SetText("Highest known profit margins")
    local marginLines = {}
    for index = 1, 6 do
        local line = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        line:SetPoint("TOPLEFT", marginTitle, "BOTTOMLEFT", 0, -5 - (index - 1) * 18)
        line:SetWidth(280)
        line:SetJustifyH("LEFT")
        marginLines[index] = line
    end

    local function layout(width)
        width = tonumber(width) or chart:GetWidth()
        if not width or width <= 40 then return end
        local innerWidth = width - 28
        local spacing = innerWidth / DAYS_SHOWN
        for index, display in ipairs(bars) do
            display.holder:ClearAllPoints()
            display.holder:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", 14 + (index - 1) * spacing, 32)
            display.holder:SetWidth(spacing)
            local barWidth = math.max(3, math.min(10, (spacing - 6) / 2))
            display.incomeBar:SetWidth(barWidth)
            display.spendingBar:SetWidth(barWidth)
        end
        local columnGap = 24
        local columnWidth = math.max(120, (width - columnGap - 10) / 2)
        volumeTitle:ClearAllPoints()
        volumeTitle:SetPoint("TOPLEFT", chart, "BOTTOMLEFT", 5, -16)
        marginTitle:ClearAllPoints()
        marginTitle:SetPoint("TOPLEFT", chart, "BOTTOMLEFT", 5 + columnWidth + columnGap, -16)
        for _, line in ipairs(volumeLines) do line:SetWidth(columnWidth) end
        for _, line in ipairs(marginLines) do line:SetWidth(columnWidth) end
    end
    chart:SetScript("OnSizeChanged", function(_, width) layout(width) end)
    C_Timer.After(0, function() layout(chart:GetWidth()) end)
    chartRefresh = function()
        local now = GetServerTime()
        local data = buildLedgerSnapshot(now)
        local maximum, totalIncome, totalSpending, totalSales, totalItems = 0, 0, 0, 0, 0
        local entries = {}
        for index = 1, DAYS_SHOWN do
            local timestamp = now - (DAYS_SHOWN - index) * 86400
            local entry = data.daily[dayKey(timestamp)] or {income = 0, spending = 0, proceeds = 0, sales = 0, items = 0}
            entries[index] = {timestamp = timestamp, entry = entry}
            maximum = math.max(maximum, tonumber(entry.income) or 0, tonumber(entry.spending) or 0)
            totalIncome = totalIncome + (tonumber(entry.income) or 0)
            totalSpending = totalSpending + (tonumber(entry.spending) or 0)
            totalSales = totalSales + (tonumber(entry.sales) or 0)
            totalItems = totalItems + (tonumber(entry.items) or 0)
        end
        local periodNet = totalIncome - totalSpending
        total:SetText(("Last 14 days: Net %s%s|r    Income |cff33ff33%s|r / Spending |cffff5555%s|r    %d sales (%d items)"):format(periodNet >= 0 and "|cff33ff33+" or "|cffff5555", money(periodNet), money(totalIncome), money(totalSpending), totalSales, totalItems))
        local earned = tonumber(data.auctionEarned) or 0
        local auctionSpent = tonumber(data.auctionSpent) or 0
        local tradeEarned = tonumber(data.tradeEarned) or 0
        local tradeSpent = tonumber(data.tradeSpent) or 0
        local net = earned + tradeEarned - auctionSpent - tradeSpent
        cashFlow:SetText(("All recorded: Auctions |cff33ff33+%s|r / |cffff5555-%s|r    Player trades |cff33ff33+%s|r / |cffff5555-%s|r    Net %s%s|r"):format(money(earned), money(auctionSpent), money(tradeEarned), money(tradeSpent), net >= 0 and "|cff33ff33+" or "|cffff5555", money(net)))
        for index, value in ipairs(entries) do
            local display = bars[index]
            local income = tonumber(value.entry.income) or 0
            local spending = tonumber(value.entry.spending) or 0
            local incomeHeight = maximum > 0 and math.floor(145 * income / maximum + 0.5) or 0
            local spendingHeight = maximum > 0 and math.floor(145 * spending / maximum + 0.5) or 0
            if income > 0 then incomeHeight = math.max(2, incomeHeight) end
            if spending > 0 then spendingHeight = math.max(2, spendingHeight) end
            display.incomeBar:SetHeight(incomeHeight)
            display.spendingBar:SetHeight(spendingHeight)
            local dailyNet = income - spending
            display.amount:ClearAllPoints()
            display.amount:SetPoint("BOTTOM", display.holder, "BOTTOM", 0, math.max(incomeHeight, spendingHeight) + 2)
            display.amount:SetText((income > 0 or spending > 0) and ((dailyNet >= 0 and "+" or "") .. money(dailyNet)) or "")
            display.amount:SetTextColor(dailyNet >= 0 and .2 or 1, dailyNet >= 0 and 1 or .3, dailyNet >= 0 and .2 or .3)
            display.label:SetText(date("%a", value.timestamp))
            display.holder.entry = value.entry
            display.holder.fullDate = date("%b %d, %Y", value.timestamp)
        end

        local volume, margins = {}, {}
        for _, item in pairs(data.items) do
            volume[#volume + 1] = item
            local knownCost = tonumber(item.knownCost) or 0
            local knownQuantity = tonumber(item.knownQuantity) or 0
            if knownCost > 0 and knownQuantity > 0 then
                item.margin = item.knownProfit / knownCost * 100
                margins[#margins + 1] = item
            end
        end
        table.sort(volume, function(a, b)
            if (a.quantity or 0) ~= (b.quantity or 0) then return (a.quantity or 0) > (b.quantity or 0) end
            return (a.proceeds or 0) > (b.proceeds or 0)
        end)
        table.sort(margins, function(a, b)
            if (a.margin or 0) ~= (b.margin or 0) then return (a.margin or 0) > (b.margin or 0) end
            return (a.knownProfit or 0) > (b.knownProfit or 0)
        end)
        for index = 1, 6 do
            local item = volume[index]
            volumeLines[index]:SetText(item and ("%d. %s - %d sold, %s"):format(index, item.name or ("Item " .. item.itemID), item.quantity or 0, money(item.proceeds)) or "")
            local margin = margins[index]
            marginLines[index]:SetText(margin and ("%d. %s - %.0f%%, %s profit"):format(index, margin.name or ("Item " .. margin.itemID), margin.margin, money(margin.knownProfit)) or (index == 1 and "Waiting for sales with a known cost basis." or ""))
        end
    end

    page:SetScript("OnShow", chartRefresh)
    if DXMLedger and DXMLedger.RegisterRefresh then DXMLedger:RegisterRefresh(chartRefresh) end
    chartRefresh()
end

function Module:Boot(hook)
    hook(Const.AuctionHouseMail, recordSale)
end

DXMEarnings = {RecordSale = recordSale, GetLedgerSnapshot = buildLedgerSnapshot, BuildPage = buildPage}
DXMExchange:RegisterPageBuilder("earnings", buildPage)
