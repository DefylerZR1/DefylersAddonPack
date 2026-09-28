if not DXMCore then return end

local Module = DXMCore:Module("Ledger")
local Const = DXMCore.Const()
Module.bootType = Const.BootType.PlayerEnteringWorld

local Ledger = DXMLedger or {}
DXMLedger = Ledger
local refreshers = {}
local pendingPurchase
local pendingPost
local lastPosting
local lastMoney
local sequence = 0
local restoredMarkets = setmetatable({}, {__mode = "k"})

local function now() return GetServerTime and GetServerTime() or time() end
local function character()
    local name, realm = UnitFullName("player")
    return (name or UnitName("player") or "Unknown") .. "-" .. (realm or GetRealmName() or "Unknown")
end
local function market()
    local history = DXMLedgerHistory:Get()
    local identity = DXMCore:MarketIdentity()
    local data = history.markets[identity.key]
    if not data then
        data = {transactions = {}, lots = {}, mailSigs = {}, owned = {}, nextID = 1}
        history.markets[identity.key] = data
    end
    data.transactions = data.transactions or {}
    data.lots = data.lots or {}
    data.startedAt = data.startedAt or now()
    data.mailSigs = data.mailSigs or {}
    data.owned = data.owned or {}
    data.nextID = tonumber(data.nextID) or 1
    if not restoredMarkets[data] then
        -- SavedVariables serializes shared table references as separate copies.
        -- Reconnect the mail index to the canonical rows after every reload.
        local signatures = {}
        for _, row in ipairs(data.transactions) do
            data.nextID = math.max(data.nextID, (tonumber(row.id) or 0) + 1)
            DXMLedgerAccounting.UpdateSale(row)
            if row.mailType and row.mailSig then
                local key = row.mailType .. ":" .. row.mailSig
                local saved = data.mailSigs[key]
                if type(saved) == "table" and saved.collected and not row.collected then
                    for field, value in pairs(saved) do row[field] = value end
                end
                signatures[key] = row
            end
        end
        local owners = {}
        for _, row in ipairs(data.transactions) do owners[row.id] = row.character end
        for _, lot in ipairs(data.lots) do lot.character = lot.character or owners[lot.transactionID] end
        data.mailSigs = signatures
        restoredMarkets[data] = true
    end
    return data, identity
end
local function itemName(itemID, link, fallback)
    local name = link and C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(link)
    if not name and itemID and C_Item and C_Item.GetItemInfo then name = C_Item.GetItemInfo(itemID) end
    return name or fallback or (itemID and ("Item " .. itemID)) or "Unknown item"
end
local function notify()
    for callback in pairs(refreshers) do pcall(callback) end
end
local function append(kind, fields)
    local data, identity = market()
    local id = data.nextID
    data.nextID = id + 1
    sequence = sequence + 1
    local row = fields or {}
    row.id, row.kind = id, kind
    row.timestamp = tonumber(row.timestamp) or now()
    row.character = row.character or character()
    row.market = identity.key
    row.quantity = math.max(1, math.floor(tonumber(row.quantity) or 1))
    row.total = math.max(0, math.floor(tonumber(row.total) or 0))
    row.sequence = sequence
    data.transactions[#data.transactions + 1] = row
    notify()
    return row
end

function Ledger:RegisterRefresh(callback)
    if type(callback) == "function" then refreshers[callback] = true end
end

local function addPurchaseLot(row)
    if not row.itemID or row.total <= 0 then return end
    local data = market()
    data.lots[#data.lots + 1] = {
        transactionID = row.id, character = row.character, itemID = row.itemID, itemKey = row.itemKey,
        name = row.name, acquiredAt = row.timestamp, quantity = row.quantity,
        remaining = row.quantity, totalCost = row.total,
        remainingCost = row.total, source = row.source or "auction",
    }
end

function Ledger:RecordPurchase(fields)
    fields.status = "purchased"
    fields.source = fields.source or "auction"
    local row = append("purchase", fields)
    addPurchaseLot(row)
    return row
end

local function consumeCost(itemID, quantity, timestamp, owner, suffix)
    timestamp, owner = timestamp or now(), owner or character()
    local data = market()
    local needed, cost, matched = quantity, 0, 0
    for _, lot in ipairs(data.lots) do
        if needed <= 0 then break end
        if tonumber(lot.itemID) == tonumber(itemID) and (tonumber(lot.remaining) or 0) > 0
            and (not lot.character or lot.character == owner) and (tonumber(lot.acquiredAt) or 0) <= timestamp + 5
            and (suffix==nil or (lot.itemKey and (tonumber(lot.itemKey.itemSuffix) or 0)==suffix)
                or (suffix==0 and not lot.itemKey)) then
            local available = tonumber(lot.remaining) or 0
            local take = math.min(needed, available)
            local lotCost = tonumber(lot.remainingCost) or 0
            local assigned = take == available and lotCost or math.floor(lotCost * take / available + 0.5)
            lot.remaining = available - take
            lot.remainingCost = math.max(0, lotCost - assigned)
            if lot.costKnown ~= false then cost, matched = cost + assigned, matched + take end
            needed = needed - take
        end
    end
    return cost, matched, quantity - matched
end

local function assignSaleCost(row)
    if row.status ~= "sold" or not row.collected then return end
    if row.itemID and not row.costAssigned then
        row.costBasis, row.costQuantity, row.unmatchedQuantity = consumeCost(row.itemID, row.quantity, row.timestamp, row.character, DXMLedgerAccounting.Suffix(row.itemLink))
        row.costAssigned = true
    end
    DXMLedgerAccounting.UpdateSale(row)
end

function Ledger:ReconcileHistory()
    local data = market()
    for _, row in ipairs(data.transactions) do
        if row.kind == "mail" and row.status == "sold" then
            row.itemID = DXMLedgerAccounting.ResolveItem(data, row.name, row.itemLink, row.itemID)
            assignSaleCost(row)
        end
    end
end

function Ledger:RecordDisenchant(sourceItemID, sourceLink, outputs)
    local ids, units = {}, 0
    for id, quantity in pairs(outputs or {}) do
        id, quantity = tonumber(id), math.floor(tonumber(quantity) or 0)
        if id and quantity > 0 then ids[#ids+1] = {id=id,quantity=quantity}; units=units+quantity end
    end
    if units == 0 then return end
    table.sort(ids,function(a,b) return a.id<b.id end)
    local cost, matched = consumeCost(sourceItemID,1,nil,nil,DXMLedgerAccounting.Suffix(sourceLink))
    local row = append("disenchant",{itemID=sourceItemID,itemLink=sourceLink,
        name=itemName(sourceItemID,sourceLink),quantity=1,total=0,status="disenchanted",
        costBasis=matched==1 and cost or nil,confidence=matched==1 and "FIFO input; cost split by output units" or "unknown input cost",outputs=ids})
    local data, remainingCost, remainingUnits = market(), cost, units
    for _, output in ipairs(ids) do
        local assigned = output.quantity==remainingUnits and remainingCost or math.floor(remainingCost*output.quantity/remainingUnits)
        data.lots[#data.lots+1]={transactionID=row.id,character=row.character,itemID=output.id,
            name=itemName(output.id),acquiredAt=row.timestamp,quantity=output.quantity,remaining=output.quantity,
            totalCost=assigned,remainingCost=assigned,costKnown=matched==1,source="disenchant"}
        remainingCost,remainingUnits=remainingCost-assigned,remainingUnits-output.quantity
    end
    notify()
    return row
end

function Ledger:RecordMail(mailType, mail)
    if type(mail) ~= "table" then return end
    local data = market()
    local sig = mail.sig or mail.earningsSig
    local key = sig and (mailType .. ":" .. sig)
    local existing = key and data.mailSigs[key]
    local timestamp = (tonumber(mail.arrivalPoint) or 0) * 5
    if timestamp <= 0 then timestamp = now() end
    local quantity = math.max(1,math.floor(tonumber(mail.itemQuantity) or 1))
    -- Join an old header-only observation to its new invoice receipt once.
    if not existing and mailType == "Sold" then
        for _, row in ipairs(data.transactions) do
            if row.kind=="mail" and row.status=="sold" and not row.collected and not row.receiptID
                and row.character==character() and row.name==mail.itemName
                and row.quantity==quantity and row.total==(tonumber(mail.money) or 0)
                and math.abs((row.timestamp or 0)-timestamp)<=10 then
                existing=row; row.mailType=mailType; row.mailSig=sig; break
            end
        end
    end
    if existing then
        existing.itemID = DXMLedgerAccounting.ResolveItem(data, existing.name, mail.itemLink, existing.itemID or mail.itemID)
        existing.receiptID = mail.receiptID or existing.receiptID
        if mail.collected and not existing.collected then
            existing.collected=true
            existing.total=tonumber(mail.money) or existing.total or 0
            existing.deposit=tonumber(mail.deposit) or existing.deposit or 0
            existing.fee=tonumber(mail.consignment) or existing.fee or 0
        end
        assignSaleCost(existing)
        if key then data.mailSigs[key]=existing end
        mail.costBasis,mail.itemID=existing.costBasis,existing.itemID
        notify(); return existing
    end
    local id = DXMLedgerAccounting.ResolveItem(data,mail.itemName,mail.itemLink,mail.itemID)
    local status = ({Sold="sold",Invoice="pending",Expired="expired",Removed="canceled",Won="won",Outbid="outbid"})[mailType] or "mail"
    local fields={status=status,timestamp=timestamp,character=character(),itemID=id,itemLink=mail.itemLink,
        name=mail.itemName or itemName(id,mail.itemLink,mail.subject),quantity=quantity,
        total=tonumber(mail.money) or 0,deposit=tonumber(mail.deposit) or 0,fee=tonumber(mail.consignment) or 0,
        collected=mail.collected and true or false,confidence=id and "matched" or "mail only",
        mailType=mailType,mailSig=sig,receiptID=mail.receiptID}
    local matchedPost
    if status=="sold" or status=="expired" or status=="canceled" then
        for _, post in ipairs(data.transactions) do
            local sameItem=id and tonumber(post.itemID)==id
            local sameName=not id and post.name==fields.name
            if post.kind=="posting" and post.status=="posted" and (sameItem or sameName)
                and post.character==fields.character and (post.timestamp or 0)<=timestamp+10 then
                matchedPost=post; fields.postingID=post.id; fields.itemLink=fields.itemLink or post.itemLink
                post.closedQuantity=(post.closedQuantity or 0)+quantity
                if post.closedQuantity >= (post.quantity or 1) then post.status=status;post.closedAt=timestamp end
                if fields.deposit<=0 and status~="sold" then fields.deposit=tonumber(post.deposit) or 0 end
                break
            end
        end
    end
    assignSaleCost(fields)
    if (status=="expired" or status=="canceled") and fields.deposit>0 then
        fields.profit=-fields.deposit; fields.confidence=matchedPost and "matched post" or fields.confidence
    end
    local row=append("mail",fields)
    if key then data.mailSigs[key]=row end
    mail.costBasis,mail.itemID=row.costBasis,row.itemID
    return row
end

local function locationLink(location)
    if not location then return nil end
    if C_Item and C_Item.GetItemLink then
        local ok, link = pcall(C_Item.GetItemLink, location)
        if ok then return link end
    end
end
local function locationID(location)
    if not location then return nil end
    if C_Item and C_Item.GetItemID then
        local ok, id = pcall(C_Item.GetItemID, location)
        if ok then return tonumber(id) end
    end
end

local function recordPendingPurchase(delta)
    local pending = pendingPurchase
    if not pending or delta >= 0 then return end
    if pending.expiresAt and GetTime() > pending.expiresAt then pendingPurchase = nil; return end
    local spent = -delta
    if spent <= 0 then return end
    pending.total = spent
    Ledger:RecordPurchase(pending)
    pendingPurchase = nil
end

local function snapshotOwned()
    if not C_AuctionHouse or not C_AuctionHouse.GetNumOwnedAuctions or not C_AuctionHouse.GetOwnedAuctionInfo then return end
    local data = market()
    local current = {}
    for index = 1, (tonumber(C_AuctionHouse.GetNumOwnedAuctions()) or 0) do
        local info = C_AuctionHouse.GetOwnedAuctionInfo(index)
        if info and info.auctionID then
            local auctionID = tostring(info.auctionID)
            local itemKey = info.itemKey
            local itemID = itemKey and tonumber(itemKey.itemID)
            current[auctionID] = true
            local owned = data.owned[auctionID] or {}
            owned.auctionID, owned.itemID, owned.itemKey = info.auctionID, itemID, itemKey
            owned.name = itemName(itemID, info.itemLink, owned.name)
            owned.quantity = tonumber(info.quantity) or owned.quantity or 1
            owned.buyoutAmount = tonumber(info.buyoutAmount) or owned.buyoutAmount or 0
            owned.bidAmount = tonumber(info.bidAmount) or owned.bidAmount or 0
            owned.timeLeftSeconds = tonumber(info.timeLeftSeconds) or 0
            owned.lastSeen = now()
            owned.status = "active"
            data.owned[auctionID] = owned
        end
    end
    for auctionID, owned in pairs(data.owned) do
        if owned.status == "active" and not current[auctionID] then
            owned.status, owned.closedAt = "awaiting mail", now()
        end
    end
    notify()
end

local events = CreateFrame("Frame")
for _, event in ipairs({"PLAYER_ENTERING_WORLD", "PLAYER_MONEY", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "AUCTION_HOUSE_AUCTION_CREATED", "OWNED_AUCTIONS_UPDATED"}) do events:RegisterEvent(event) end
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_ENTERING_WORLD" then
        Ledger:ReconcileHistory()
        lastMoney = GetMoney()
    elseif event == "PLAYER_MONEY" then
        local current = GetMoney()
        if lastMoney then
            local delta = current - lastMoney
            if pendingPurchase then
                recordPendingPurchase(delta)
            elseif delta < 0 and pendingPost then
                pendingPost.deposit = (tonumber(pendingPost.deposit) or 0) - delta
            elseif delta < 0 and lastPosting and GetTime() <= (lastPosting.depositExpires or 0) then
                lastPosting.deposit = (tonumber(lastPosting.deposit) or 0) - delta
                notify()
            end
        end
        lastMoney = current
    elseif event == "AUCTION_HOUSE_SHOW" then
        lastMoney = GetMoney()
        C_Timer.After(0, snapshotOwned)
    elseif event == "AUCTION_HOUSE_CLOSED" then
        pendingPurchase, pendingPost = nil, nil
    elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
        if pendingPost then
            pendingPost.status = "posted"
            lastPosting = append("posting", pendingPost)
            lastPosting.depositExpires = GetTime() + 3
            pendingPost = nil
        end
        C_Timer.After(0.1, snapshotOwned)
    elseif event == "OWNED_AUCTIONS_UPDATED" then
        C_Timer.After(0, snapshotOwned)
    end
end)

local hookedAuctionFrame
local function hookAuctionFrame()
    if hookedAuctionFrame or not AuctionHouseFrame then return end
    hookedAuctionFrame = true
    if AuctionHouseFrame.StartItemBuyout then
        hooksecurefunc(AuctionHouseFrame, "StartItemBuyout", function(_, auctionID, buyout)
            local info = C_AuctionHouse and C_AuctionHouse.GetAuctionInfoByID and C_AuctionHouse.GetAuctionInfoByID(auctionID)
            local itemKey = info and info.itemKey
            local id = itemKey and tonumber(itemKey.itemID)
            pendingPurchase = {auctionID=auctionID, itemID=id, itemKey=itemKey, name=itemName(id, info and info.itemLink), quantity=tonumber(info and info.quantity) or 1, quotedTotal=tonumber(buyout) or 0, confidence="exact auction", expiresAt=GetTime()+30}
        end)
    end
    if AuctionHouseFrame.StartCommoditiesPurchase then
        hooksecurefunc(AuctionHouseFrame, "StartCommoditiesPurchase", function(_, itemID, quantity, unitPrice, totalPrice)
            pendingPurchase = {itemID=tonumber(itemID), name=itemName(itemID), quantity=tonumber(quantity) or 1, unitPrice=tonumber(unitPrice) or 0, quotedTotal=tonumber(totalPrice) or 0, confidence="commodity quote", expiresAt=GetTime()+30}
        end)
    end
end

local function hookPostingFrames()
    local itemFrame = AuctionHouseFrame and AuctionHouseFrame.ItemSellFrame
    local commodityFrame = AuctionHouseFrame and AuctionHouseFrame.CommoditiesSellFrame
    if itemFrame and itemFrame.StartPost and not itemFrame.DXMLedgerHooked then
        itemFrame.DXMLedgerHooked = true
        hooksecurefunc(itemFrame, "StartPost", function(_, location, duration, quantity, bid, buyout)
            local id, link = locationID(location), locationLink(location)
            pendingPost = {itemID=id, itemLink=link, name=itemName(id, link), quantity=quantity, duration=duration, bid=bid, unitPrice=buyout, total=(tonumber(buyout) or 0) * (tonumber(quantity) or 1), confidence="post request"}
        end)
    end
    if commodityFrame and commodityFrame.StartPost and not commodityFrame.DXMLedgerHooked then
        commodityFrame.DXMLedgerHooked = true
        hooksecurefunc(commodityFrame, "StartPost", function(_, location, duration, quantity, unitPrice)
            local id, link = locationID(location), locationLink(location)
            pendingPost = {itemID=id, itemLink=link, name=itemName(id, link), quantity=quantity, duration=duration, unitPrice=unitPrice, total=(tonumber(unitPrice) or 0) * (tonumber(quantity) or 1), confidence="post request"}
        end)
    end
end

function Module:Boot(hook)
    hook(Const.AuctionHouseOpened, Module.AuctionHouseOpened)
end
function Module:AuctionHouseOpened()
    hookAuctionFrame()
    hookPostingFrames()
    snapshotOwned()
end

local function money(value, signed)
    value = math.floor(tonumber(value) or 0)
    local prefix = ""
    if signed and value > 0 then prefix = "+" elseif value < 0 then prefix, value = "-", -value end
    local gold, silver, copper = math.floor(value / 10000), math.floor((value % 10000) / 100), value % 100
    if gold > 0 then return prefix .. ("%dg %02ds %02dc"):format(gold, silver, copper) end
    if silver > 0 then return prefix .. ("%ds %02dc"):format(silver, copper) end
    return prefix .. copper .. "c"
end
local function transactionRows()
    local data = market()
    local rows = {}
    for _, row in ipairs(data.transactions) do rows[#rows + 1] = row end
    return rows
end

local function buildLedger(parent, compact)
    local view = CreateFrame("Frame", nil, parent)
    view:SetAllPoints(parent)
    local summary = view:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    summary:SetPoint("TOPLEFT", 8, -8); summary:SetPoint("TOPRIGHT", -8, -8)
    summary:SetHeight(compact and 100 or 68); summary:SetJustifyH("LEFT"); summary:SetJustifyV("TOP")
    local filter = CreateFrame("Frame", nil, view)
    filter:SetPoint("TOPLEFT", 8, compact and -112 or -80); filter:SetPoint("TOPRIGHT", -8, compact and -112 or -80); filter:SetHeight(56)
    local search = CreateFrame("EditBox", nil, filter, "InputBoxTemplate")
    search:SetPoint("TOPLEFT", 4, 0); search:SetPoint("TOPRIGHT", -4, 0); search:SetHeight(22)
    search:SetAutoFocus(false); search:SetTextInsets(6,6,0,0)
    local searchHint = search:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
    searchHint:SetPoint("LEFT",8,0); searchHint:SetText("Search item or character")
    local statusButton = CreateFrame("Button",nil,filter,"UIPanelButtonTemplate")
    statusButton:SetSize(115,22); statusButton:SetPoint("TOPLEFT",0,-30)
    local rangeButton = CreateFrame("Button",nil,filter,"UIPanelButtonTemplate")
    rangeButton:SetSize(96,22); rangeButton:SetPoint("LEFT",statusButton,"RIGHT",8,0)
    local status = CreateFrame("Frame", nil, view)
    status:SetPoint("TOPLEFT", filter, "BOTTOMLEFT", 0, -4)
    status:SetPoint("TOPRIGHT", filter, "BOTTOMRIGHT", -22, -4); status:SetHeight(25)
    local headerBG = status:CreateTexture(nil, "BACKGROUND")
    headerBG:SetAllPoints(); headerBG:SetColorTexture(0.20,0.13,0.02,.92)
    local columns = compact and {
        {"Date","timestamp",0,.17},{"Item","name",.17,.45},{"Status","status",.45,.61},
        {"Qty","quantity",.61,.69},{"Money","total",.69,.85},{"Profit","profit",.85,1},
    } or {
        {"Date","timestamp",0,.12},{"Item","name",.12,.33},{"Type","kind",.33,.42},
        {"Status","status",.42,.52},{"Qty","quantity",.52,.58},{"Spent/Proceeds","total",.58,.73},
        {"Cost","costBasis",.73,.84},{"Profit","profit",.84,.94},{"ROI","roi",.94,1},
    }
    local sortKey, ascending = "timestamp", false
    local statusFilters, statusIndex = {"all","sold","purchased","posted","expired","canceled"}, 1
    local ranges, rangeIndex = {{"All time",0},{"7 days",7},{"30 days",30},{"90 days",90}}, 1
    local headers, rows, list = {}, {}, {}
    local rowHeight = compact and 34 or 30
    local countText = view:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    countText:SetPoint("BOTTOMLEFT",8,6); countText:SetPoint("BOTTOMRIGHT",-8,6); countText:SetHeight(16)
    local scroll = CreateFrame("ScrollFrame",nil,view,"UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",status,"BOTTOMLEFT",0,-2)
    scroll:SetPoint("BOTTOMRIGHT",view,"BOTTOMRIGHT",-30,26)
    local content = CreateFrame("Frame",nil,scroll)
    content:SetSize(1,1); scroll:SetScrollChild(content)
    local refresh, render
    local function place(region, owner, col)
        region:ClearAllPoints()
        region:SetPoint("TOPLEFT",owner,"TOPLEFT",owner:GetWidth()*col[3]+2,0)
        region:SetPoint("BOTTOMRIGHT",owner,"TOPLEFT",owner:GetWidth()*col[4]-2,-owner:GetHeight())
    end
    for _, col in ipairs(columns) do
        local button = CreateFrame("Button",nil,status)
        button.Label = button:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        button.Label:SetAllPoints(); button.Label:SetJustifyH("LEFT"); button.Label:SetWordWrap(false)
        button:SetScript("OnClick",function()
            if sortKey == col[2] then ascending = not ascending
            else sortKey,ascending = col[2],(col[2]=="name" or col[2]=="status" or col[2]=="kind") end
            scroll:SetVerticalScroll(0); refresh()
        end)
        headers[#headers+1] = {button=button,col=col}
    end
    local function createRow()
        local row = CreateFrame("Frame",nil,content)
        row:SetHeight(rowHeight); row:EnableMouse(true)
        local bg=row:CreateTexture(nil,"BACKGROUND"); bg:SetAllPoints(); row.bg=bg
        row.fields={}
        for _,col in ipairs(columns) do
            local label=row:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
            label:SetJustifyH((col[2]=="name" or col[2]=="timestamp") and "LEFT" or "RIGHT")
            if col[2]=="name" then label:SetJustifyH("LEFT") end
            label:SetWordWrap(col[2]=="name"); row.fields[col[2]]=label
        end
        row:SetScript("OnEnter",function(self)
            local data=self.data; if not data then return end
            GameTooltip:SetOwner(self,"ANCHOR_RIGHT"); GameTooltip:SetText(data.name or "Unknown item")
            GameTooltip:AddLine(data.character or "",1,1,1)
            GameTooltip:AddLine(date("%Y-%m-%d %H:%M",data.timestamp),1,1,1)
            GameTooltip:AddLine((data.kind or "").." / "..(data.status or ""),1,1,1)
            GameTooltip:AddLine("Amount: "..money(data.total),1,1,1)
            local costLabel=(data.unmatchedQuantity or 0)>0 and "Matched cost: " or "Cost: "
            local knownCost=data.costBasis~=nil and ((data.costQuantity or 0)>0 or not data.costAssigned)
            GameTooltip:AddLine(costLabel..(knownCost and money(data.costBasis) or "Unknown"),1,1,1)
            if (data.unmatchedQuantity or 0)>0 then GameTooltip:AddLine(("Missing cost for %d units"):format(data.unmatchedQuantity),1,.82,0) end
            GameTooltip:AddLine("Profit: "..(data.profit~=nil and money(data.profit,true) or "Unknown"),1,1,1)
            if data.deposit and data.deposit>0 then GameTooltip:AddLine("Deposit: "..money(data.deposit),1,1,1) end
            GameTooltip:AddLine(data.confidence or "",.8,.8,.8); GameTooltip:Show()
        end)
        row:SetScript("OnLeave",function() GameTooltip:Hide() end)
        rows[#rows+1]=row
        return row
    end
    render=function()
        local width,height=scroll:GetWidth(),scroll:GetHeight()
        if width<=0 or height<=0 then return end
        content:SetWidth(width)
        local first=math.floor((scroll:GetVerticalScroll() or 0)/rowHeight)
        local visible=math.ceil(height/rowHeight)+1
        for index=1,math.max(visible,#rows) do
            local row=rows[index]
            local data=index<=visible and list[first+index] or nil
            if data and not row then row=createRow() end
            if row then
                row.data=data; row:SetShown(data~=nil)
                if data then
                    row:ClearAllPoints(); row:SetPoint("TOPLEFT",0,-(first+index-1)*rowHeight); row:SetWidth(width)
                    local shade=(first+index)%2==0 and .10 or .035; row.bg:SetColorTexture(shade,shade,shade,.92)
                    local function amount(value,signed)
                        if value==nil then return "--" end
                        local text=money(value,signed)
                        return compact and text:gsub(" ","") or text
                    end
                    local values={timestamp=date("%m/%d\n%H:%M",data.timestamp),name=data.name or "Unknown",
                        kind=data.kind or "",status=data.status or "",quantity=tostring(data.quantity or 0),
                        total=amount(data.total),costBasis=(data.unmatchedQuantity or 0)>0 and ((data.costQuantity or 0)>0 and (amount(data.costBasis).."*") or "--") or amount(data.costBasis),profit=amount(data.profit,true),
                        roi=data.roi~=nil and ("%.0f%%"):format(data.roi) or "--"}
                    for _,col in ipairs(columns) do
                        local label=row.fields[col[2]]; place(label,row,col); label:SetText(values[col[2]] or "")
                    end
                end
            end
        end
        for _,h in ipairs(headers) do place(h.button,status,h.col) end
        countText:SetText(#list>0 and ("%d-%d of %d records"):format(first+1,math.min(first+math.ceil(height/rowHeight),#list),#list) or "No transactions recorded yet")
    end
    refresh=function()
        list={}
        local needle=search:GetText():lower():gsub("^%s+",""):gsub("%s+$","")
        searchHint:SetShown(needle=="" and not search:HasFocus())
        local days=ranges[rangeIndex][2]; local cutoff=days>0 and now()-days*86400 or 0
        for _,row in ipairs(transactionRows()) do
            local text=((row.name or "").." "..(row.character or "")):lower()
            if (statusFilters[statusIndex]=="all" or row.status==statusFilters[statusIndex])
                and (needle=="" or text:find(needle,1,true)) and (tonumber(row.timestamp) or 0)>=cutoff then
                list[#list+1]=row
            end
        end
        table.sort(list,function(a,b)
            local av,bv=a[sortKey],b[sortKey]
            if av==bv then
                if ascending then return (a.id or 0)<(b.id or 0) end
                return (a.id or 0)>(b.id or 0)
            end
            if av==nil then return false elseif bv==nil then return true end
            if ascending then return av<bv end
            return av>bv
        end)
        local totals=DXMLedgerAccounting.Summary(list)
        local profitText=totals.known>0 and money(totals.profit,true) or "Unknown"
        if totals.unknown>0 then profitText=profitText..(" (%d sales missing costs)"):format(totals.unknown) end
        summary:SetText(("Recorded purchases %s   Collected sales %s\nRecorded AH cash flow %s (after deposits)\nMatched profit %s\n%d records since %s; this market, all characters. Earlier activity may be missing."):format(
            money(totals.spent),money(totals.received),money(totals.cashFlow,true),profitText,#list,
            totals.since and date("%m/%d %H:%M",totals.since) or "--"))
        if compact then
            summary:SetText(("Purchases %s / Collected %s\nRecorded cash flow %s\nMatched profit %s\n%d sales missing costs\nRecorded since %s; older activity may be missing."):format(
                money(totals.spent),money(totals.received),money(totals.cashFlow,true),
                totals.known>0 and money(totals.profit,true) or "Unknown",totals.unknown,
                totals.since and date("%m/%d",totals.since) or "--"))
        end
        for _,h in ipairs(headers) do h.button.Label:SetText(h.col[1]..(sortKey==h.col[2] and (ascending and " ^" or " v") or "")) end
        statusButton:SetText("Status: "..statusFilters[statusIndex]); rangeButton:SetText(ranges[rangeIndex][1])
        local height=math.max(1,scroll:GetHeight())
        content:SetHeight(math.max(height,#list*rowHeight))
        scroll:SetVerticalScroll(math.min(scroll:GetVerticalScroll() or 0,math.max(0,#list*rowHeight-height)))
        render()
    end
    search:SetScript("OnTextChanged",function() scroll:SetVerticalScroll(0); refresh() end)
    search:SetScript("OnEditFocusGained",function() searchHint:Hide() end)
    search:SetScript("OnEditFocusLost",function() searchHint:SetShown(search:GetText()=="") end)
    search:SetScript("OnEscapePressed",function(self) self:ClearFocus() end)
    statusButton:SetScript("OnClick",function() statusIndex=statusIndex%#statusFilters+1; scroll:SetVerticalScroll(0); refresh() end)
    rangeButton:SetScript("OnClick",function() rangeIndex=rangeIndex%#ranges+1; scroll:SetVerticalScroll(0); refresh() end)
    scroll:HookScript("OnVerticalScroll",render)
    scroll:HookScript("OnSizeChanged",function() refresh() end)
    Ledger:RegisterRefresh(function() if view:IsShown() then refresh() end end)
    view:SetScript("OnShow",refresh)
    refresh()
    return view
end

local function buildAHPage(page)
    local host=CreateFrame("Frame",nil,page,"InsetFrameTemplate")
    host:SetPoint("TOPLEFT",page.Description,"BOTTOMLEFT",0,-14); host:SetPoint("BOTTOMRIGHT",page,"BOTTOMRIGHT",-12,12)
    buildLedger(host,false)
end
if DXMExchange then DXMExchange:RegisterPageBuilder("ledger",buildAHPage) end

local characterTab, characterPanel
local CHARACTER_LEDGER_FRAME = "DXMCharacterLedgerFrame"
local CHARACTER_LEDGER_ICON = "Interface\\AddOns\\DXM\\Media\\defylers_ledger_icon.png"

local function ensureCharacterLedger()
    if characterTab or not CharacterFrame or not CharacterFrame.ModeTabs or not CharacterFrame.ModeTabs.Tabs then return end

    characterPanel = CreateFrame("Frame", CHARACTER_LEDGER_FRAME, CharacterFrame, "InsetFrameTemplate")
    characterPanel:SetPoint("TOPLEFT", CharacterFrame, "TOPLEFT", 8, -54)
    characterPanel:SetPoint("BOTTOMRIGHT", CharacterFrame, "BOTTOMRIGHT", -8, 8)
    characterPanel:SetFrameLevel(CharacterFrame:GetFrameLevel() + 20)
    if characterPanel.Bg then characterPanel.Bg:SetColorTexture(.015, .012, .02, .98) end
    characterPanel:Hide()
    buildLedger(characterPanel, false)

    local nativePaneState
    characterPanel:SetScript("OnShow", function()
        nativePaneState = {}
        for _, nativePane in ipairs({CharacterFrame.LeftPaneHost, CharacterFrame.RightPaneHost, CharacterFrame.RightPaneToggleButton}) do
            if nativePane then
                nativePaneState[#nativePaneState + 1] = {frame = nativePane, shown = nativePane:IsShown()}
                nativePane:Hide()
            end
        end
        if CharacterFrame.SetTitle then CharacterFrame:SetTitle("DXM Ledger") end
    end)
    characterPanel:SetScript("OnHide", function()
        for _, state in ipairs(nativePaneState or {}) do state.frame:SetShown(state.shown) end
        nativePaneState = nil
    end)

    local tabs = CharacterFrame.ModeTabs.Tabs
    characterTab = CreateFrame("Frame", "DXMCharacterLedgerTab", CharacterFrame.ModeTabs, "CharacterFrameModeSideTabTemplate")
    characterTab:SetID(#tabs + 1)
    characterTab.tooltipText = "DXM Ledger"
    characterTab.iconTexture = CHARACTER_LEDGER_ICON
    characterTab.Icon:SetTexture(CHARACTER_LEDGER_ICON)
    characterTab:SetCustomOnMouseUpHandler(function(tab, button, upInside)
        if button ~= "LeftButton" or not upInside then return end
        for _, modeTab in ipairs(tabs) do
            modeTab:SetChecked(false)
            local nativeFrame = modeTab.frameName and _G[modeTab.frameName]
            if nativeFrame then nativeFrame:Hide() end
        end
        tab:SetChecked(true)
        characterPanel:Show()
    end)
    local anchor = tabs[#tabs]
    characterTab:SetPoint("TOPLEFT", anchor or CharacterFrame.ModeTabs, anchor and "BOTTOMLEFT" or "TOPLEFT", 0, anchor and -2 or 0)

    hooksecurefunc(CharacterFrame, "ShowSubFrame", function()
        characterPanel:Hide()
        characterTab:SetChecked(false)
    end)
end

local characterInit = CreateFrame("Frame")
characterInit:RegisterEvent("PLAYER_LOGIN")
characterInit:SetScript("OnEvent", function() C_Timer.After(0, ensureCharacterLedger) end)

local mailTab, mailPanel
local function ensureMailTab()
    if mailTab or not MailFrame or not MailFrameTab2 then return end
    mailPanel=CreateFrame("Frame","DXMMailLedgerFrame",MailFrame,"InsetFrameTemplate")
    mailPanel.FocusGamepad=function() end; mailPanel.UnfocusGamepad=function() end
    mailPanel:SetPoint("TOPLEFT",MailFrame,"TOPLEFT",8,-58); mailPanel:SetPoint("BOTTOMRIGHT",MailFrame,"BOTTOMRIGHT",-8,32); mailPanel:Hide()
    buildLedger(mailPanel,true)
    mailTab=CreateFrame("Button","MailFrameTab3",MailFrame,"FriendsFrameTabTemplate")
    mailTab:SetID(3); mailTab:SetText("DXM"); mailTab:SetPoint("LEFT",MailFrameTab2,"RIGHT",-8,0)
    PanelTemplates_SetNumTabs(MailFrame,3)
    mailTab:SetScript("OnClick",function()
        PanelTemplates_SetTab(MailFrame,3)
        if MailFrame.activeSubFrame then MailFrame.activeSubFrame:Hide() end
        MailFrame.activeSubFrame=mailPanel; SetSendMailShowing(false); ButtonFrameTemplate_HideButtonBar(MailFrame); MailFrame:SetTitle("DXM Mail Ledger"); mailPanel:Show()
    end)
    hooksecurefunc("MailFrameTab_OnClick",function(_,tabID) if tabID~=3 and mailPanel then mailPanel:Hide() end end)
end
local mailInit=CreateFrame("Frame")
mailInit:RegisterEvent("MAIL_SHOW")
mailInit:SetScript("OnEvent",function() ensureMailTab() end)
