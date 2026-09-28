if not DXMCore or not DXMExchange then return end

local Module = DXMCore:Module("Earnings")
local Const = DXMCore.Const()
local DAYS_SHOWN = 14
local chartRefresh

local function marketData()
    DXMData = DXMData or {}
    DXMData.Earnings = DXMData.Earnings or {markets = {}}
    DXMData.Earnings.markets = DXMData.Earnings.markets or {}
    local identity = DXMCore:MarketIdentity()
    local data = DXMData.Earnings.markets[identity.key]
    if not data then
        data = {daily = {}, items = {}, totals = {}}
        DXMData.Earnings.markets[identity.key] = data
    end
    data.daily = data.daily or {}
    data.items = data.items or {}
    data.totals = data.totals or {}
    data.saleSigs = data.saleSigs or {}
    return data
end

local function dayKey(timestamp)
    return date("%Y-%m-%d", tonumber(timestamp) or GetServerTime())
end

local function money(value)
    value = math.max(0, math.floor(tonumber(value) or 0))
    local gold = math.floor(value / 10000)
    local silver = math.floor((value % 10000) / 100)
    local copper = value % 100
    if gold > 0 then return ("%dg %02ds"):format(gold, silver) end
    if silver > 0 then return ("%ds %02dc"):format(silver, copper) end
    return copper .. "c"
end

local function addCashFlow(category, amount, timestamp)
    amount = math.max(0, math.floor(tonumber(amount) or 0))
    if amount <= 0 then return end
    timestamp = tonumber(timestamp) or GetServerTime()
    local data = marketData()
    local key = dayKey(timestamp)
    local day = data.daily[key] or {proceeds = 0, sales = 0, items = 0}
    day[category] = (tonumber(day[category]) or 0) + amount
    data.daily[key] = day
    data.totals[category] = (tonumber(data.totals[category]) or 0) + amount
    if chartRefresh then chartRefresh() end
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

    local data = marketData()
    local saleSig = mail.earningsSig or mail.sig
    if saleSig and data.saleSigs[saleSig] then return end
    if saleSig then data.saleSigs[saleSig] = true end
    local key = dayKey(timestamp)
    local day = data.daily[key] or {proceeds = 0, sales = 0, items = 0}
    day.proceeds = (tonumber(day.proceeds) or 0) + proceeds
    day.auctionEarned = (tonumber(day.auctionEarned) or 0) + proceeds
    day.sales = (tonumber(day.sales) or 0) + 1
    day.items = (tonumber(day.items) or 0) + quantity
    data.daily[key] = day
    data.totals.auctionEarned = (tonumber(data.totals.auctionEarned) or 0) + proceeds

    if itemID then
        local item = data.items[itemID] or {name = mail.itemName, quantity = 0, proceeds = 0, sales = 0, knownCost = 0, knownQuantity = 0}
        item.name = mail.itemName or item.name
        item.quantity = (tonumber(item.quantity) or 0) + quantity
        item.proceeds = (tonumber(item.proceeds) or 0) + proceeds
        item.sales = (tonumber(item.sales) or 0) + 1
        item.lastSoldAt = math.max(tonumber(item.lastSoldAt) or 0, timestamp)
        data.items[itemID] = item
        if DXMQueueSaleObservation then
            DXMQueueSaleObservation(itemID, quantity, proceeds, tonumber(mail.costBasis) or 0, timestamp, mail.sig)
        end
    end
    if chartRefresh then chartRefresh() end
end

local moneyTracker = CreateFrame("Frame")
local lastMoney
local moneyContext
local contextExpires = 0
local tradeArmed = false
for _, event in ipairs({
    "PLAYER_ENTERING_WORLD", "PLAYER_MONEY", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
    "TRADE_SHOW", "TRADE_ACCEPT_UPDATE", "TRADE_CLOSED", "MAIL_SHOW", "MAIL_CLOSED",
}) do moneyTracker:RegisterEvent(event) end
moneyTracker:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        lastMoney = GetMoney()
    elseif event == "AUCTION_HOUSE_SHOW" then
        moneyContext, contextExpires = "auction", 0
    elseif event == "AUCTION_HOUSE_CLOSED" then
        if moneyContext == "auction" then moneyContext = nil end
    elseif event == "TRADE_SHOW" then
        moneyContext, contextExpires, tradeArmed = "trade", 0, false
    elseif event == "TRADE_ACCEPT_UPDATE" then
        local playerAccepted, targetAccepted = ...
        tradeArmed = playerAccepted == 1 and targetAccepted == 1
    elseif event == "TRADE_CLOSED" then
        if tradeArmed then
            moneyContext, contextExpires = "trade", GetTime() + 3
        else
            moneyContext, contextExpires = nil, 0
        end
        tradeArmed = false
    elseif event == "MAIL_SHOW" then
        moneyContext, contextExpires = "mail", 0
    elseif event == "MAIL_CLOSED" then
        if moneyContext == "mail" then moneyContext = nil end
    elseif event == "PLAYER_MONEY" then
        local current = GetMoney()
        if lastMoney then
            local delta = current - lastMoney
            if moneyContext == "auction" and delta < 0 then
                addCashFlow("auctionSpent", -delta)
            elseif moneyContext == "trade" and delta > 0 then
                addCashFlow("tradeEarned", delta)
                moneyContext = nil
            elseif moneyContext == "trade" and delta < 0 then
                addCashFlow("tradeSpent", -delta)
                moneyContext = nil
            end
        end
        lastMoney = current
    end
    if contextExpires > 0 and GetTime() > contextExpires then
        moneyContext, contextExpires = nil, 0
    end
end)
local function buildPage(page)
    local total = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    total:SetPoint("TOPLEFT", page.Description, "BOTTOMLEFT", 0, -18)

    local cashFlow = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    cashFlow:SetPoint("TOPLEFT", total, "BOTTOMLEFT", 0, -6)

    local chart = CreateFrame("Frame", nil, page, "InsetFrameTemplate")
    chart:SetPoint("TOPLEFT", cashFlow, "BOTTOMLEFT", 0, -10)
    chart:SetPoint("RIGHT", page, "RIGHT", -18, 0)
    chart:SetHeight(220)

    local baseline = chart:CreateTexture(nil, "BORDER")
    baseline:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", 14, 31)
    baseline:SetPoint("BOTTOMRIGHT", chart, "BOTTOMRIGHT", -14, 31)
    baseline:SetHeight(1)
    baseline:SetColorTexture(0.55, 0.43, 0.18, 0.9)

    local bars = {}
    for index = 1, DAYS_SHOWN do
        local holder = CreateFrame("Frame", nil, chart)
        holder:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", 17 + (index - 1) * 46, 32)
        holder:SetSize(32, 165)
        local bar = holder:CreateTexture(nil, "ARTWORK")
        bar:SetPoint("BOTTOM", holder, "BOTTOM")
        bar:SetWidth(24)
        bar:SetColorTexture(0.15, 0.72, 0.30, 0.88)
        local amount = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        amount:SetPoint("BOTTOM", bar, "TOP", 0, 2)
        local label = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOP", holder, "BOTTOM", 0, -4)
        holder:EnableMouse(true)
        holder:SetScript("OnEnter", function(self)
            if not self.entry then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.fullDate or "", 1, 0.82, 0)
            GameTooltip:AddDoubleLine("Net proceeds", money(self.entry.proceeds), 1, 1, 1, 0.2, 1, 0.2)
            GameTooltip:AddDoubleLine("Sales", tostring(self.entry.sales or 0), 1, 1, 1, 1, 1, 1)
            GameTooltip:AddDoubleLine("Items sold", tostring(self.entry.items or 0), 1, 1, 1, 1, 1, 1)
            GameTooltip:Show()
        end)
        holder:SetScript("OnLeave", function() GameTooltip:Hide() end)
        bars[index] = {holder = holder, bar = bar, amount = amount, label = label}
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
            display.bar:SetWidth(math.max(6, math.min(24, spacing - 5)))
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
        local data = marketData()
        local now = GetServerTime()
        local maximum, totalProceeds, totalSales, totalItems = 0, 0, 0, 0
        local entries = {}
        for index = 1, DAYS_SHOWN do
            local timestamp = now - (DAYS_SHOWN - index) * 86400
            local entry = data.daily[dayKey(timestamp)] or {proceeds = 0, sales = 0, items = 0}
            entries[index] = {timestamp = timestamp, entry = entry}
            maximum = math.max(maximum, tonumber(entry.proceeds) or 0)
            totalProceeds = totalProceeds + (tonumber(entry.proceeds) or 0)
            totalSales = totalSales + (tonumber(entry.sales) or 0)
            totalItems = totalItems + (tonumber(entry.items) or 0)
        end
        total:SetText(("Last 14 days: |cff33ff33%s|r from %d sales (%d items)"):format(money(totalProceeds), totalSales, totalItems))
        local totals = data.totals or {}
        local earned = tonumber(totals.auctionEarned) or 0
        local auctionSpent = tonumber(totals.auctionSpent) or 0
        local tradeEarned = tonumber(totals.tradeEarned) or 0
        local tradeSpent = tonumber(totals.tradeSpent) or 0
        local net = earned + tradeEarned - auctionSpent - tradeSpent
        cashFlow:SetText(("Auctions: |cff33ff33+%s|r / |cffff5555-%s|r    Player trades: |cff33ff33+%s|r / |cffff5555-%s|r    Net: %s%s|r"):format(money(earned), money(auctionSpent), money(tradeEarned), money(tradeSpent), net >= 0 and "|cff33ff33+" or "|cffff5555-", money(math.abs(net))))
        for index, value in ipairs(entries) do
            local display = bars[index]
            local proceeds = tonumber(value.entry.proceeds) or 0
            local height = maximum > 0 and math.floor(150 * proceeds / maximum + 0.5) or 0
            if proceeds > 0 then height = math.max(2, height) end
            display.bar:SetHeight(height)
            display.amount:SetText(proceeds > 0 and money(proceeds) or "")
            display.label:SetText(date("%a", value.timestamp))
            display.holder.entry = value.entry
            display.holder.fullDate = date("%b %d, %Y", value.timestamp)
        end

        local volume, margins = {}, {}
        for itemID, item in pairs(data.items) do
            item.itemID = itemID
            volume[#volume + 1] = item
            local knownCost = tonumber(item.knownCost) or 0
            local knownQuantity = tonumber(item.knownQuantity) or 0
            if knownCost > 0 and knownQuantity > 0 then
                item.knownProfit = (tonumber(item.proceeds) or 0) - knownCost
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
    chartRefresh()
end

function Module:Boot(hook)
    hook(Const.AuctionHouseMail, recordSale)
end

DXMEarnings = {RecordSale = recordSale, AddCashFlow = addCashFlow, GetMarketData = marketData}
DXMExchange:RegisterPageBuilder("earnings", buildPage)