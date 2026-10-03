if not DXMCore or not DXMExchange then return end

local Module = DXMCore:Module("SellQueue", "Scanner")
DXMConfig = DXMConfig or {}
if DXMConfig.sellPriceMode ~= "market7" and DXMConfig.sellPriceMode ~= "market24"
    and DXMConfig.sellPriceMode ~= "undercut" then
    DXMConfig.sellPriceMode = "market7"
end

local page
local modeButtons = {}
local queue = {}
local queueIndex = 0
local queryGeneration = 0
local pendingQuery
local awaitingPost
local currentPrice
local currentPriceSource
local icon
local itemName
local itemDetail
local priceText
local queueText
local statusText
local previewRows = {}
local listButton
local skipButton
local cancelButton

local MODE_LABELS = {
    market7 = "7 Day Market",
    market24 = "24 Hour Market",
    undercut = "1c Undercut",
}

local function money(value)
    value = math.max(0, math.floor((tonumber(value) or 0) + .5))
    local gold = math.floor(value / 10000)
    local silver = math.floor(value / 100) % 100
    local copper = value % 100
    if gold > 0 then return ("%dg %02ds %02dc"):format(gold, silver, copper) end
    if silver > 0 then return ("%ds %02dc"):format(silver, copper) end
    return copper .. "c"
end

local function choosePrice(mode, summary, livePrice)
    if mode == "market7" then return summary and tonumber(summary.average7), "7-day market average" end
    if mode == "market24" then return summary and tonumber(summary.average24), "24-hour market average" end
    livePrice = tonumber(livePrice)
    if mode == "undercut" and livePrice and livePrice > 0 then
        return math.max(1, math.floor(livePrice) - 1), "current lowest minus 1c"
    end
end

local function locationFor(entry)
    if not entry or not entry.bag or not entry.slot then return end
    return ItemLocation:CreateFromBagAndSlot(entry.bag, entry.slot)
end

local function liveEntryLocation(entry)
    if not entry then return end
    for _, position in ipairs(entry.locations or {entry}) do
        local info = C_Container.GetContainerItemInfo(position.bag, position.slot)
        if info and tonumber(info.itemID) == entry.itemID and not info.isLocked then
            entry.bag, entry.slot = position.bag, position.slot
            return locationFor(entry), info
        end
    end
end

local function setStatus(message, red)
    if not statusText then return end
    statusText:SetText(message or "")
    statusText:SetTextColor(red and 1 or .68, red and .28 or .70, red and .24 or .78)
end

local function updateModeButtons()
    for key, button in pairs(modeButtons) do
        local selected = DXMConfig.sellPriceMode == key
        button.DXMBackground:SetColorTexture(selected and .165 or .071, selected and .122 or .082, selected and .231 or .133, 1)
        button.DXMAccent:SetShown(selected)
        button.DXMLabel:SetTextColor(selected and .788 or .933, selected and .643 or .918, selected and .957 or .961)
    end
end

local function updateActions()
    local entry = queue[queueIndex]
    local ready = entry and currentPrice and currentPrice > 0 and not pendingQuery and not awaitingPost
    listButton:SetEnabled(ready == true)
    skipButton:SetEnabled(entry ~= nil and not awaitingPost)
    cancelButton:SetEnabled(true)
end

local function refreshPreview()
    if not page then return end
    for rowIndex, row in ipairs(previewRows) do
        local entry = queue[queueIndex + rowIndex]
        if entry then
            row:SetText(("%d. %s  x%d"):format(queueIndex + rowIndex, entry.name or ("Item " .. entry.itemID), entry.quantity or 1))
            row:Show()
        else
            row:SetText("")
            row:Hide()
        end
    end
end

local function clearCurrent(message)
    currentPrice, currentPriceSource = nil, nil
    pendingQuery = nil
    awaitingPost = nil
    if icon then icon:SetTexture(nil) end
    if itemName then itemName:SetText("No sellable bag items") end
    if itemDetail then itemDetail:SetText("") end
    if priceText then priceText:SetText("No listing price") end
    if queueText then queueText:SetText("Queue complete") end
    setStatus(message or "No auctionable items were found in your carried bags.")
    refreshPreview()
    updateActions()
end

local function lowestLivePrice(entry)
    local lowest
    if entry.isCommodity then
        for index = 1, (C_AuctionHouse.GetNumCommoditySearchResults(entry.itemID) or 0) do
            local row = C_AuctionHouse.GetCommoditySearchResultInfo(entry.itemID, index)
            local value = row and tonumber(row.unitPrice)
            if value and value > 0 and (not lowest or value < lowest) then lowest = value end
        end
    else
        for index = 1, (C_AuctionHouse.GetNumItemSearchResults(entry.itemKey) or 0) do
            local row = C_AuctionHouse.GetItemSearchResultInfo(entry.itemKey, index)
            local total = row and tonumber(row.buyoutAmount)
            local quantity = math.max(1, tonumber(row and row.quantity) or 1)
            local value = total and total > 0 and math.floor(total / quantity) or nil
            if value and value > 0 and (not lowest or value < lowest) then lowest = value end
        end
    end
    return lowest
end

local prepareCurrent

local function finishLiveQuery(entry)
    if not pendingQuery or pendingQuery.entry ~= entry then return end
    pendingQuery = nil
    local lowest = lowestLivePrice(entry)
    currentPrice, currentPriceSource = choosePrice("undercut", nil, lowest)
    if currentPrice then
        priceText:SetText(("%s per unit  |cff888888(%s)|r"):format(money(currentPrice), currentPriceSource))
        setStatus("Ready. List posts the full quantity shown, then advances after Blizzard confirms it.")
    else
        priceText:SetText("No current listing to undercut")
        setStatus("No current listing was found. Choose a market-average option or Skip.", true)
    end
    updateActions()
end

prepareCurrent = function()
    queryGeneration = queryGeneration + 1
    pendingQuery = nil
    currentPrice, currentPriceSource = nil, nil
    local entry = queue[queueIndex]
    if not entry then
        clearCurrent(#queue > 0 and "Listing queue complete." or nil)
        return
    end

    local location, bagInfo = liveEntryLocation(entry)
    if not location or not bagInfo then
        queueIndex = queueIndex + 1
        prepareCurrent()
        return
    end

    icon:SetTexture(entry.icon or 134400)
    itemName:SetText(entry.link or entry.name or ("Item " .. entry.itemID))
    itemDetail:SetText(("Quantity: %d    %s    Bag %d, slot %d"):format(entry.quantity or 1,
        entry.isCommodity and "Commodity" or "Item", entry.bag, entry.slot))
    queueText:SetText(("Listing queue %d of %d"):format(queueIndex, #queue))
    refreshPreview()

    local mode = DXMConfig.sellPriceMode
    if mode == "undercut" then
        priceText:SetText("Loading current lowest price...")
        setStatus("Loading one live quote for this item...")
        local generation = queryGeneration
        pendingQuery = {entry = entry, generation = generation}
        local context = entry.isCommodity and AuctionHouseSearchContext.SellCommodities or AuctionHouseSearchContext.SellItems
        AuctionHouseFrame:QueryItem(context, entry.itemKey)
        C_Timer.After(5, function()
            if pendingQuery and pendingQuery.generation == generation then
                pendingQuery = nil
                priceText:SetText("Live price request timed out")
                setStatus("The Auction House did not return a quote. Select this option again to retry.", true)
                updateActions()
            end
        end)
    else
        local summary = DXMPriceSummary and DXMPriceSummary.Get(entry.itemKey)
        currentPrice, currentPriceSource = choosePrice(mode, summary)
        if currentPrice and currentPrice > 0 then
            priceText:SetText(("%s per unit  |cff888888(%s)|r"):format(money(currentPrice), currentPriceSource))
            setStatus("Ready. List posts the full quantity shown, then advances after Blizzard confirms it.")
        else
            priceText:SetText("No " .. (MODE_LABELS[mode] or "selected") .. " data")
            setStatus("This item has no price for the selected strategy. Choose another option or Skip.", true)
        end
    end
    updateActions()
end

local function addBagEntry(entries, commodities, bag, slot, info)
    if not info or not info.itemID or info.isLocked then return end
    local location = ItemLocation:CreateFromBagAndSlot(bag, slot)
    local ok, valid = pcall(C_AuctionHouse.IsSellItemValid, location, false)
    if not ok or valid ~= true then return end
    local itemKey = C_AuctionHouse.GetItemKeyFromItem(location)
    local keyInfo = itemKey and C_AuctionHouse.GetItemKeyInfo(itemKey)
    if not itemKey or not keyInfo then return end
    local itemID = tonumber(info.itemID)
    local name, link, _, _, _, _, _, _, _, iconFile = C_Item.GetItemInfo(info.hyperlink or itemID)
    local quantity = math.max(1, tonumber(info.stackCount) or 1)
    if keyInfo.isCommodity then
        local entry = commodities[itemID]
        if not entry then
            entry = {itemID=itemID, itemKey=itemKey, isCommodity=true, quantity=0,
                bag=bag, slot=slot, name=name, link=link or info.hyperlink, icon=info.iconFileID or iconFile, locations={}}
            commodities[itemID] = entry
            entries[#entries + 1] = entry
        end
        entry.quantity = entry.quantity + quantity
        entry.locations[#entry.locations + 1] = {bag=bag,slot=slot}
    else
        entries[#entries + 1] = {itemID=itemID, itemKey=itemKey, isCommodity=false, quantity=quantity,
            bag=bag, slot=slot, name=name, link=link or info.hyperlink, icon=info.iconFileID or iconFile,
            locations={{bag=bag,slot=slot}}}
    end
end

local function buildQueue()
    queryGeneration = queryGeneration + 1
    pendingQuery, awaitingPost = nil, nil
    wipe(queue)
    local commodities = {}
    local lastBag = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag or NUM_BAG_SLOTS or 4
    for bag = 0, lastBag do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            addBagEntry(queue, commodities, bag, slot, C_Container.GetContainerItemInfo(bag, slot))
        end
    end
    table.sort(queue, function(a, b)
        local an, bn = tostring(a.name or ""), tostring(b.name or "")
        if an ~= bn then return an < bn end
        if a.itemID ~= b.itemID then return a.itemID < b.itemID end
        if a.bag ~= b.bag then return a.bag < b.bag end
        return a.slot < b.slot
    end)
    queueIndex = 1
    prepareCurrent()
end

local function selectMode(mode)
    if mode ~= "market7" and mode ~= "market24" and mode ~= "undercut" then return end
    DXMConfig.sellPriceMode = mode
    updateModeButtons()
    prepareCurrent()
end

local function postCurrent()
    local entry = queue[queueIndex]
    if not entry or not currentPrice or currentPrice <= 0 or pendingQuery or awaitingPost then return end
    local location = liveEntryLocation(entry)
    if not location then
        setStatus("That bag item moved or disappeared. Skipping it.", true)
        queueIndex = queueIndex + 1
        prepareCurrent()
        return
    end
    local duration = Enum and Enum.AuctionHouseDuration and Enum.AuctionHouseDuration.Medium or 2
    awaitingPost = {entry=entry, index=queueIndex}
    updateActions()
    setStatus("Submitting this listing to the Auction House...")
    local ok, err
    if entry.isCommodity then
        local frame = AuctionHouseFrame and AuctionHouseFrame.CommoditiesSellFrame
        ok, err = frame and frame.StartPost and pcall(frame.StartPost, frame, location, duration, entry.quantity, currentPrice)
    else
        local frame = AuctionHouseFrame and AuctionHouseFrame.ItemSellFrame
        ok, err = frame and frame.StartPost and pcall(frame.StartPost, frame, location, duration, entry.quantity, currentPrice, currentPrice)
    end
    if not ok then
        awaitingPost = nil
        setStatus("Listing failed to start: " .. tostring(err or "Blizzard sell frame unavailable"), true)
        updateActions()
    end
end

local function skipCurrent()
    if not queue[queueIndex] or awaitingPost then return end
    queryGeneration = queryGeneration + 1
    pendingQuery = nil
    queueIndex = queueIndex + 1
    prepareCurrent()
end

local function cancelQueue()
    queryGeneration = queryGeneration + 1
    pendingQuery, awaitingPost = nil, nil
    wipe(queue)
    queueIndex = 0
    if page and page:IsShown() then DXMExchange:SelectPage("overview") end
end

local events = CreateFrame("Frame")
for _, event in ipairs({"COMMODITY_SEARCH_RESULTS_RECEIVED", "COMMODITY_SEARCH_RESULTS_UPDATED",
    "ITEM_SEARCH_RESULTS_UPDATED", "AUCTION_HOUSE_AUCTION_CREATED", "AUCTION_HOUSE_SHOW_ERROR",
    "AUCTION_HOUSE_CLOSED"}) do events:RegisterEvent(event) end
events:SetScript("OnEvent", function(_, event, ...)
    if event == "AUCTION_HOUSE_CLOSED" then
        queryGeneration = queryGeneration + 1
        pendingQuery, awaitingPost = nil, nil
        wipe(queue)
        queueIndex = 0
        return
    end
    if event == "AUCTION_HOUSE_AUCTION_CREATED" and awaitingPost then
        local postedIndex = awaitingPost.index
        awaitingPost = nil
        if queueIndex == postedIndex then queueIndex = queueIndex + 1 end
        C_Timer.After(.10, prepareCurrent)
        return
    end
    if event == "AUCTION_HOUSE_SHOW_ERROR" and awaitingPost then
        local errorCode = ...
        awaitingPost = nil
        setStatus("Blizzard rejected this listing (error " .. tostring(errorCode or "unknown") .. "). You can retry or Skip.", true)
        updateActions()
        return
    end
    local request = pendingQuery
    if not request then return end
    local entry = request.entry
    if (event == "COMMODITY_SEARCH_RESULTS_RECEIVED" or event == "COMMODITY_SEARCH_RESULTS_UPDATED") and entry.isCommodity then
        local itemID = ...
        if not itemID or tonumber(itemID) == entry.itemID then finishLiveQuery(entry) end
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" and not entry.isCommodity then
        local itemKey = ...
        if not itemKey or DXMCore:ItemKeyKey(itemKey) == DXMCore:ItemKeyKey(entry.itemKey) then
            finishLiveQuery(entry)
        end
    end
end)

local function makeModeButton(parent, key, anchor)
    local button = DXMTheme:CreateButton(parent)
    button:SetSize(130, 24)
    button:SetText(MODE_LABELS[key])
    if anchor then button:SetPoint("LEFT", anchor, "RIGHT", 7, 0) end
    button:SetScript("OnClick", function() selectMode(key) end)
    modeButtons[key] = button
    return button
end

local function buildPage(parent)
    page = parent
    local strategy = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    strategy:SetPoint("TOPLEFT", page.Description, "BOTTOMLEFT", 0, -14)
    strategy:SetText("Listing price")
    local first = makeModeButton(page, "market7")
    first:SetPoint("LEFT", strategy, "RIGHT", 18, 0)
    local second = makeModeButton(page, "market24", first)
    makeModeButton(page, "undercut", second)

    local card = DXMTheme:CreatePanel(page)
    card:SetPoint("TOPLEFT", strategy, "BOTTOMLEFT", 0, -14)
    card:SetPoint("RIGHT", page, "RIGHT", -18, 0)
    card:SetHeight(156)
    icon = card:CreateTexture(nil, "ARTWORK")
    icon:SetSize(54, 54)
    icon:SetPoint("TOPLEFT", 14, -16)
    itemName = card:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    itemName:SetPoint("TOPLEFT", icon, "TOPRIGHT", 12, -1)
    itemName:SetPoint("RIGHT", card, "RIGHT", -14, 0)
    itemName:SetJustifyH("LEFT")
    itemDetail = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    itemDetail:SetPoint("TOPLEFT", itemName, "BOTTOMLEFT", 0, -7)
    itemDetail:SetPoint("RIGHT", card, "RIGHT", -14, 0)
    itemDetail:SetJustifyH("LEFT")
    priceText = card:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    priceText:SetPoint("TOPLEFT", itemDetail, "BOTTOMLEFT", 0, -10)
    priceText:SetPoint("RIGHT", card, "RIGHT", -14, 0)
    priceText:SetJustifyH("LEFT")
    queueText = card:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    queueText:SetPoint("BOTTOMLEFT", 14, 13)
    statusText = card:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    statusText:SetPoint("BOTTOMLEFT", queueText, "BOTTOMRIGHT", 20, 0)
    statusText:SetPoint("RIGHT", card, "RIGHT", -14, 0)
    statusText:SetJustifyH("LEFT")

    local actions = CreateFrame("Frame", nil, page)
    actions:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -10)
    actions:SetPoint("RIGHT", page, "RIGHT", -18, 0)
    actions:SetHeight(28)
    listButton = DXMTheme:CreateButton(actions); listButton:SetSize(110, 26); listButton:SetPoint("LEFT"); listButton:SetText("List")
    skipButton = DXMTheme:CreateButton(actions); skipButton:SetSize(110, 26); skipButton:SetPoint("LEFT", listButton, "RIGHT", 8, 0); skipButton:SetText("Skip")
    cancelButton = DXMTheme:CreateButton(actions); cancelButton:SetSize(110, 26); cancelButton:SetPoint("LEFT", skipButton, "RIGHT", 8, 0); cancelButton:SetText("Cancel")
    listButton:SetScript("OnClick", postCurrent)
    skipButton:SetScript("OnClick", skipCurrent)
    cancelButton:SetScript("OnClick", cancelQueue)

    local preview = DXMTheme:CreatePanel(page)
    preview:SetPoint("TOPLEFT", actions, "BOTTOMLEFT", 0, -10)
    preview:SetPoint("RIGHT", page, "RIGHT", -18, 0)
    preview:SetHeight(146)
    local previewTitle = preview:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    previewTitle:SetPoint("TOPLEFT", 12, -10)
    previewTitle:SetText("Next in queue")
    for rowIndex = 1, 5 do
        local row = preview:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row:SetPoint("TOPLEFT", previewTitle, "BOTTOMLEFT", 0, -8 - (rowIndex - 1) * 20)
        row:SetPoint("RIGHT", preview, "RIGHT", -12, 0)
        row:SetJustifyH("LEFT")
        previewRows[rowIndex] = row
    end

    page:SetScript("OnShow", function()
        updateModeButtons()
        C_Timer.After(0, function() if page and page:IsShown() then buildQueue() end end)
    end)
    page:SetScript("OnHide", function()
        queryGeneration = queryGeneration + 1
        pendingQuery, awaitingPost = nil, nil
        wipe(queue)
        queueIndex = 0
    end)
    updateModeButtons()
end

DXMExchange:RegisterPageBuilder("sell", buildPage)

