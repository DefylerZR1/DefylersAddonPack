if not DXMCore or not DXMExchange then return end

local Module = DXMCore:Module("VendorFinder", "Scanner")
local Const = DXMCore.Const()
local PAGE_SIZE = 9

local results = {}
local resultsByKey = {}
local pending = {}
local lastItems
local pageOffset = 0
local scanRequested = false
local scanWaiting = false
local scanDestination = "vendor"
local statusText
local countText
local rows = {}
local sortHeaders = {}
local sortKey = "profit"
local sortAscending = false
local previousButton
local nextButton
local updateRows
local quantityQueue = {}
local quantityPending
local quantityGeneration = 0
local requestNextQuantity
local minimumProfit = 0
local minimumROI = 0
local buyQueueButton
local queueableResults = {}
local vendorPage

DXMConfig = DXMConfig or {}

local function money(value)
    value = math.max(0, math.floor(tonumber(value) or 0))
    local gold = math.floor(value / 10000)
    local silver = math.floor((value % 10000) / 100)
    local copper = value % 100
    local parts = {}
    if gold > 0 then table.insert(parts, gold .. "g") end
    if silver > 0 then table.insert(parts, silver .. "s") end
    if copper > 0 or #parts == 0 then table.insert(parts, copper .. "c") end
    return table.concat(parts, " ")
end

local function parseMoney(text)
    text = tostring(text or ""):lower():gsub(",", "")
    if text:match("^%s*$") then return 0 end
    local gold = tonumber(text:match("([%d%.]+)%s*g")) or 0
    local silver = tonumber(text:match("([%d%.]+)%s*s")) or 0
    local copper = tonumber(text:match("([%d%.]+)%s*c")) or 0
    if gold == 0 and silver == 0 and copper == 0 then copper = tonumber(text:match("[%d%.]+")) or 0 end
    return math.max(0, math.floor(gold * 10000 + silver * 100 + copper + 0.5))
end

local function parseROI(text)
    return math.max(0, tonumber(tostring(text or ""):match("[%d%.]+")) or 0)
end

local function resultKey(item)
    return item.id or DXMCore:ItemKeyKey(item.itemKey)
end

local function updateSortHeaders()
    for key, entry in pairs(sortHeaders) do
        local marker = ""
        if key == sortKey then marker = sortAscending and " ^" or " v" end
        entry.Label:SetText(entry.label .. marker)
    end
end

local function sortResults()
    table.sort(results, function(a, b)
        local valueA = tonumber(a[sortKey]) or 0
        local valueB = tonumber(b[sortKey]) or 0
        if valueA == valueB then return (a.name or "") < (b.name or "") end
        if sortAscending then return valueA < valueB end
        return valueA > valueB
    end)
    updateSortHeaders()
end

local function setStatus(message)
    if statusText then statusText:SetText(message) end
end

local function showTooltip(row)
    local result = row.result
    if not result then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if result.link then
        GameTooltip:SetHyperlink(result.link)
    elseif GameTooltip.SetItemByID then
        GameTooltip:SetItemByID(result.itemID)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("AH buyout", money(result.buyout), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Vendor value", money(result.vendor), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Profit per item", money(result.profit), 0.2, 1, 0.2, 1, 1, 1)
    GameTooltip:AddDoubleLine("Quantity at price", result.quantityAtPrice and tostring(result.quantityAtPrice) or "Loading...", 1, 0.82, 0, 1, 1, 1)
    if result.totalProfit then GameTooltip:AddDoubleLine("Profit if all sell", money(result.totalProfit), 0.2, 1, 0.2, 1, 1, 1) end
    GameTooltip:Show()
end

local function openResult(result)
    if not result or not AuctionHouseFrame or not result.browseResult then return end
    AuctionHouseFrame:SelectBrowseResult(result.browseResult)
end

local function purchaseError(message)
    if UIErrorsFrame and UIErrorsFrame.AddMessage then
        UIErrorsFrame:AddMessage(message, 1, 0.2, 0.2)
    else
        print(message)
    end
end

local pendingPurchase
local activePurchase
local unavailableAuctions = {}
local purchaseQueue
local purchaseQueueIndex = 0
local advancePurchaseQueue
local cursorBuyDialogPendingUntil = 0
local cursorBuyDialogTargetX
local cursorBuyDialogTargetY
local cursorBuyDialogGeneration = 0

local function stopPurchaseQueue(message)
    purchaseQueue = nil
    purchaseQueueIndex = 0
    pendingPurchase = nil
    activePurchase = nil
    if message then setStatus(message) end
    if updateRows then updateRows() end
end

local function findDialogAcceptButton(dialog, preferred)
    if preferred then return preferred end
    if dialog.GetButton1 then
        local button = dialog:GetButton1()
        if button then return button end
    end
    if dialog.button1 then return dialog.button1 end
    if dialog.Button1 then return dialog.Button1 end
    if dialog.buttons and dialog.buttons[1] then return dialog.buttons[1] end
    if dialog.Buttons and dialog.Buttons[1] then return dialog.Buttons[1] end
    local name = dialog.GetName and dialog:GetName()
    if name and _G[name .. "Button1"] then return _G[name .. "Button1"] end

    local leftmost
    local leftmostX
    if dialog.GetChildren then
        local children = { dialog:GetChildren() }
        for _, child in ipairs(children) do
            if child and child.IsObjectType and child:IsObjectType("Button") and child:IsShown() then
                local text = child.GetText and child:GetText()
                if text == ACCEPT or text == YES then return child end
                local childX = child:GetCenter()
                if childX and (not leftmostX or childX < leftmostX) then
                    leftmost = child
                    leftmostX = childX
                end
            end
        end
    end
    return leftmost
end

local function positionDialogButtonAtCursor(dialog, preferredButton)
    if not dialog or not dialog:IsShown() or not cursorBuyDialogTargetX or not cursorBuyDialogTargetY then return false end
    local button = findDialogAcceptButton(dialog, preferredButton)
    if not button then return false end
    local uiScale = UIParent:GetEffectiveScale()
    local dialogScale = dialog:GetEffectiveScale()
    local buttonScale = button:GetEffectiveScale()
    if not uiScale or uiScale <= 0 or not dialogScale or dialogScale <= 0 or not buttonScale or buttonScale <= 0 then return false end
    local dialogX, dialogY = dialog:GetCenter()
    local buttonX, buttonY = button:GetCenter()
    if not dialogX or not dialogY or not buttonX or not buttonY then return false end

    -- Convert every measurement to physical screen pixels before calculating the
    -- translation. Popup/button scales can differ from UIParent's scale.
    local targetDialogX = ((dialogX * dialogScale) + cursorBuyDialogTargetX - (buttonX * buttonScale)) / uiScale
    local targetDialogY = ((dialogY * dialogScale) + cursorBuyDialogTargetY - (buttonY * buttonScale)) / uiScale
    dialog:SetClampedToScreen(true)
    dialog:ClearAllPoints()
    dialog:SetPoint("CENTER", UIParent, "BOTTOMLEFT", targetDialogX, targetDialogY)
    return true
end

local function positionBuyoutPopup(popup)
    if not popup or not popup:IsShown() or popup.which ~= "BUYOUT_AUCTION" then return end
    local accept = popup.GetButton1 and popup:GetButton1() or popup.button1 or _G[popup:GetName() .. "Button1"]
    local cancel = popup.GetButton2 and popup:GetButton2() or popup.button2 or _G[popup:GetName() .. "Button2"]
    if cancel and not cancel.DXMPurchaseQueueCancelHooked then
        cancel.DXMPurchaseQueueCancelHooked = true
        cancel:HookScript("OnClick", function()
            activePurchase = nil
            if purchaseQueue then stopPurchaseQueue("Purchase queue canceled.") end
        end)
    end
    positionDialogButtonAtCursor(popup, accept)
end

local function positionBuyoutPopupAtCursor()
    for index = 1, (STATICPOPUP_NUMDIALOGS or 4) do
        local popup = _G["StaticPopup" .. index]
        if popup and popup:IsShown() and popup.which == "BUYOUT_AUCTION" then
            positionBuyoutPopup(popup)
            return
        end
    end
end

local function scheduleCursorBuyDialogPosition(generation)
    local delays = { 0, .01, .03, .06, .12 }
    for _, delay in ipairs(delays) do
        C_Timer.After(delay, function()
            if generation ~= cursorBuyDialogGeneration or GetTime() > cursorBuyDialogPendingUntil then return end
            local dialog = AuctionHouseFrame and AuctionHouseFrame.BuyDialog
            if dialog and dialog:IsShown() then
                positionDialogButtonAtCursor(dialog, dialog.BuyNowButton)
            end
            positionBuyoutPopupAtCursor()
        end)
    end
end

local function hookBuyoutPopups()
    for index = 1, (STATICPOPUP_NUMDIALOGS or 4) do
        local popup = _G["StaticPopup" .. index]
        if popup and not popup.DXMCursorPositionHooked then
            popup.DXMCursorPositionHooked = true
            if hooksecurefunc and popup.Resize then
                hooksecurefunc(popup, "Resize", function(self)
                    if GetTime() <= cursorBuyDialogPendingUntil then positionBuyoutPopup(self) end
                end)
            end
        end
    end
end

local function armCursorBuyDialog()
    cursorBuyDialogTargetX, cursorBuyDialogTargetY = GetCursorPosition()
    if not cursorBuyDialogTargetX or not cursorBuyDialogTargetY then return end
    cursorBuyDialogGeneration = cursorBuyDialogGeneration + 1
    local generation = cursorBuyDialogGeneration
    cursorBuyDialogPendingUntil = GetTime() + 10
    hookBuyoutPopups()
    local dialog = AuctionHouseFrame and AuctionHouseFrame.BuyDialog
    if dialog and not dialog.DXMCursorPositionHooked then
        dialog.DXMCursorPositionHooked = true
        dialog:HookScript("OnShow", function(self)
            if GetTime() <= cursorBuyDialogPendingUntil then
                positionDialogButtonAtCursor(self, self.BuyNowButton)
                scheduleCursorBuyDialogPosition(cursorBuyDialogGeneration)
            end
        end)
        if dialog.CancelButton then
            dialog.CancelButton:HookScript("OnClick", function()
                activePurchase = nil
                if purchaseQueue then stopPurchaseQueue("Purchase queue canceled.") end
            end)
        end
    end
    scheduleCursorBuyDialogPosition(generation)
end

local function skipQueuedPurchase(message)
    if not purchaseQueue then return false end
    pendingPurchase = nil
    purchaseQueueIndex = purchaseQueueIndex + 1
    if message then setStatus(message) end
    C_Timer.After(.10, advancePurchaseQueue)
    return true
end

local function invalidateScannedTier(result)
    if DXMSalvage and DXMSalvage.MarkUnavailable then
        DXMSalvage.MarkUnavailable(result and result.itemKey, result and result.buyout)
    end
end

local function finishCommodityPurchase(result)
    local itemID = result.itemKey.itemID
    local current = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, 1)
    local unitPrice = current and tonumber(current.unitPrice) or 0
    local purchaseLimit = tonumber(result.purchaseLimit) or tonumber(result.vendor) or 0
    local maximumBuyout = tonumber(result.maximumBuyout) or 0
    if unitPrice <= 0 then return false end
    if maximumBuyout > 0 and unitPrice > maximumBuyout then
        pendingPurchase = nil
        purchaseError(("DXM: purchase canceled. Live price %s exceeds the scanned price %s."):format(money(unitPrice), money(maximumBuyout)))
        local message=("Skipped: live price %s exceeds scanned price %s."):format(money(unitPrice), money(maximumBuyout))
        setStatus(message)
        skipQueuedPurchase(message)
        return true
    end
    if purchaseLimit <= 0 or unitPrice >= purchaseLimit then
        pendingPurchase = nil
        purchaseError("DXM: the current price is no longer profitable.")
        setStatus("Purchase canceled: current price is no longer profitable.")
        skipQueuedPurchase("Skipped an item that is no longer profitable.")
        return true
    end
    pendingPurchase = nil
    setStatus("Live quote loaded. Confirm the one-item purchase in Blizzard's dialog.")
    armCursorBuyDialog()
    AuctionHouseFrame:StartCommoditiesPurchase(itemID, 1, unitPrice, unitPrice)
    return true
end

local function finishItemPurchase(result)
    local bestAuction
    local count = C_AuctionHouse.GetNumItemSearchResults(result.itemKey) or 0
    for index = 1, count do
        local auction = C_AuctionHouse.GetItemSearchResultInfo(result.itemKey, index)
        local buyout = auction and tonumber(auction.buyoutAmount) or 0
        if buyout > 0 and (tonumber(auction.bidAmount) or 0)<=0
            and not unavailableAuctions[auction.auctionID]
            and not (DXMScanner and DXMScanner.IsPurchasedAuction and DXMScanner.IsPurchasedAuction(auction.auctionID))
            and (not bestAuction or buyout < bestAuction.buyoutAmount) then
            bestAuction = {auctionID = auction.auctionID, buyoutAmount = buyout}
        end
    end
    if not bestAuction then return false end
    local request = pendingPurchase
    pendingPurchase = nil
    local purchaseLimit = tonumber(result.purchaseLimit) or tonumber(result.vendor) or 0
    local maximumBuyout = tonumber(result.maximumBuyout) or 0
    if maximumBuyout > 0 and bestAuction.buyoutAmount > maximumBuyout then
        invalidateScannedTier(result)
        purchaseError(("DXM: purchase canceled. Live buyout %s exceeds the scanned cost %s."):format(money(bestAuction.buyoutAmount), money(maximumBuyout)))
        local message=("Skipped: live buyout %s exceeds scanned cost %s."):format(money(bestAuction.buyoutAmount), money(maximumBuyout))
        setStatus(message)
        skipQueuedPurchase(message)
    elseif purchaseLimit <= 0 or bestAuction.buyoutAmount >= purchaseLimit then
        invalidateScannedTier(result)
        purchaseError("DXM: the current buyout is no longer profitable.")
        setStatus("Purchase canceled: current buyout is no longer profitable.")
        skipQueuedPurchase("Skipped an item that is no longer profitable.")
    else
        setStatus(purchaseQueue and ("Queue %d/%d: confirm this purchase. Cancel stops the queue."):format(purchaseQueueIndex,#purchaseQueue)
            or "Current buyout loaded. Confirm the purchase in Blizzard's dialog.")
        activePurchase = {
            result = result,
            auctionID = bestAuction.auctionID,
            fromQueue = request and request.fromQueue == true,
            retryCount = request and tonumber(request.retryCount) or 0,
        }
        armCursorBuyDialog()
        AuctionHouseFrame:StartItemBuyout(bestAuction.auctionID, bestAuction.buyoutAmount)
    end
    return true
end

local purchaseEvents = CreateFrame("Frame")
purchaseEvents:RegisterEvent("COMMODITY_SEARCH_RESULTS_RECEIVED")
purchaseEvents:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
purchaseEvents:RegisterEvent("AUCTION_HOUSE_SHOW_ERROR")
purchaseEvents:RegisterEvent("AUCTION_HOUSE_CLOSED")
purchaseEvents:SetScript("OnEvent", function(_, event, ...)
    if event == "AUCTION_HOUSE_CLOSED" then
        if purchaseQueue then stopPurchaseQueue("Purchase queue stopped because the Auction House closed.") end
        return
    end
    if event == "AUCTION_HOUSE_SHOW_ERROR" then
        local errorCode = ...
        local itemNotFound = Enum and Enum.AuctionHouseError and Enum.AuctionHouseError.ItemNotFound or 4
        local itemNotAvailable = Enum and Enum.AuctionHouseError and Enum.AuctionHouseError.ItemNotAvailable or 25
        local failed = activePurchase
        activePurchase = nil
        if failed and (errorCode == itemNotFound or errorCode == itemNotAvailable) then
            unavailableAuctions[failed.auctionID] = true
            if (failed.retryCount or 0) >= 9 then
                if failed.fromQueue then skipQueuedPurchase("Too many competing purchases; advancing queue.")
                else setStatus("No stable auction remained at the scanned price.") end
                return
            end
            pendingPurchase = {
                result = failed.result,
                isCommodity = false,
                fromQueue = failed.fromQueue,
                retryCount = (failed.retryCount or 0) + 1,
            }
            setStatus("That auction sold. Loading the next available listing...")
            AuctionHouseFrame:QueryItem(AuctionHouseSearchContext.BuyItems, failed.result.itemKey)
        end
        return
    end
    local pendingData = pendingPurchase
    if pendingData then
        local result = pendingData.result
        if event == "COMMODITY_SEARCH_RESULTS_RECEIVED" and pendingData.isCommodity then
            local itemID = ...
            if not itemID or itemID == result.itemKey.itemID then finishCommodityPurchase(result) end
        elseif event == "ITEM_SEARCH_RESULTS_UPDATED" and not pendingData.isCommodity then
            local itemKey = ...
            if not itemKey or DXMCore:ItemKeyKey(itemKey) == DXMCore:ItemKeyKey(result.itemKey) then
                if C_AuctionHouse.HasFullItemSearchResults and not C_AuctionHouse.HasFullItemSearchResults(result.itemKey) then
                    if C_AuctionHouse.RequestMoreItemSearchResults then C_AuctionHouse.RequestMoreItemSearchResults(result.itemKey) end
                    return
                end
                local handled=finishItemPurchase(result)
                if not handled then
                    invalidateScannedTier(result)
                    if pendingData.fromQueue then
                        skipQueuedPurchase("No eligible auction remains; advancing queue.")
                    else
                        pendingPurchase = nil
                        purchaseError("DXM: no eligible auction remains at the scanned price.")
                        setStatus("No eligible auction remains at the scanned price.")
                    end
                end
            end
        end
    end

    local detail = quantityPending
    if not detail then return end
    local result = detail.result
    local matches = false
    if event == "COMMODITY_SEARCH_RESULTS_RECEIVED" and detail.isCommodity then
        local itemID = ...
        matches = not itemID or itemID == result.itemKey.itemID
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" and not detail.isCommodity then
        local itemKey = ...
        matches = not itemKey or DXMCore:ItemKeyKey(itemKey) == DXMCore:ItemKeyKey(result.itemKey)
    end
    if not matches then return end

    local quantity = 0
    if detail.isCommodity then
        local count = C_AuctionHouse.GetNumCommoditySearchResults(result.itemID) or 0
        for index = 1, count do
            local row = C_AuctionHouse.GetCommoditySearchResultInfo(result.itemID, index)
            if row and tonumber(row.unitPrice) == result.buyout then quantity = quantity + (tonumber(row.quantity) or 0) end
        end
    else
        local count = C_AuctionHouse.GetNumItemSearchResults(result.itemKey) or 0
        for index = 1, count do
            local row = C_AuctionHouse.GetItemSearchResultInfo(result.itemKey, index)
            if row and (tonumber(row.bidAmount) or 0)<=0
                and not (DXMScanner and DXMScanner.IsPurchasedAuction and DXMScanner.IsPurchasedAuction(row.auctionID))
                and tonumber(row.buyoutAmount) == result.buyout then quantity = quantity + math.max(1, tonumber(row.quantity) or 1) end
        end
    end
    result.quantityAtPrice = quantity
    result.totalProfit = result.profit * quantity
    quantityPending = nil
    sortResults()
    if updateRows then updateRows() end
    C_Timer.After(0.10, requestNextQuantity)
end)

local function buyResult(result, fromQueue)
    if not result or not result.itemKey or not AuctionHouseFrame then return end
    local purchaseLimit = tonumber(result.purchaseLimit) or tonumber(result.vendor) or 0
    if result.buyout <= 0 or purchaseLimit <= result.buyout then
        purchaseError("DXM: this listing is no longer profitable.")
        return
    end

    local itemKeyInfo = C_AuctionHouse.GetItemKeyInfo(result.itemKey)
    if not itemKeyInfo then
        purchaseError("DXM: item details are still loading. Right-click again.")
        return
    end

    GameTooltip:Hide()
    pendingPurchase = {result = result, isCommodity = itemKeyInfo.isCommodity, fromQueue = fromQueue == true}
    if itemKeyInfo.isCommodity then
        if finishCommodityPurchase(result) then return end
        setStatus("Loading the current commodity price...")
        AuctionHouseFrame:QueryItem(AuctionHouseSearchContext.BuyCommodities, result.itemKey)
    else
        if finishItemPurchase(result) then return end
        setStatus("Loading the current item auctions...")
        AuctionHouseFrame:QueryItem(AuctionHouseSearchContext.BuyItems, result.itemKey)
    end

    local request = pendingPurchase
    C_Timer.After(5, function()
        if pendingPurchase == request then
            if request.fromQueue then
                stopPurchaseQueue("Purchase queue stopped because current auction details timed out.")
            else
                pendingPurchase = nil
                purchaseError("DXM: current auction details did not load. Right-click again.")
                setStatus("Purchase request timed out; right-click the row to retry.")
            end
        end
    end)
end

advancePurchaseQueue = function()
    if not purchaseQueue or pendingPurchase then return end
    local result = purchaseQueue[purchaseQueueIndex]
    if not result then
        stopPurchaseQueue("Purchase queue complete.")
        return
    end
    buyResult(result, true)
end

local function buyQueue(entries)
    if pendingPurchase or purchaseQueue then
        purchaseError("DXM: a purchase or purchase queue is already active.")
        return
    end
    if not entries or #entries == 0 then
        purchaseError("DXM: no loaded filtered auctions are available to queue.")
        return
    end
    purchaseQueue = {}
    for _, result in ipairs(entries) do purchaseQueue[#purchaseQueue + 1] = result end
    purchaseQueueIndex = 1
    setStatus(("Purchase queue ready: %d confirmations. Cancel stops the queue."):format(#purchaseQueue))
    advancePurchaseQueue()
end

local function passesFilters(result, profitMinimum, roiMinimum)
    local unitProfit = tonumber(result and result.profit) or 0
    local roi = tonumber(result and result.roi) or 0
    return unitProfit >= (tonumber(profitMinimum) or 0)
        and roi >= (tonumber(roiMinimum) or 0)
        and (result.quantityAtPrice == nil or result.quantityAtPrice > 0)
end

updateRows = function()
    local visible = {}
    wipe(queueableResults)
    for _, result in ipairs(results) do
        if passesFilters(result, minimumProfit, minimumROI) then
            visible[#visible + 1] = result
            if tonumber(result.quantityAtPrice) and result.quantityAtPrice > 0 then
                queueableResults[#queueableResults + 1] = result
            end
        end
    end
    local total = #visible
    local maxOffset = math.max(0, total - PAGE_SIZE)
    pageOffset = math.max(0, math.min(pageOffset, maxOffset))

    for index, row in ipairs(rows) do
        local result = visible[pageOffset + index]
        row.result = result
        if result then
            row.Icon:SetTexture(result.icon or 134400)
            row.Name:SetText(result.name)
            local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[result.quality or 1]
            if color then row.Name:SetTextColor(color.r, color.g, color.b) else row.Name:SetTextColor(1, 1, 1) end
            row.Buyout:SetText(money(result.buyout))
            row.Vendor:SetText(money(result.vendor))
            row.Quantity:SetText(result.quantityAtPrice and tostring(result.quantityAtPrice) or "...")
            row.Profit:SetText(money(result.profit))
            row.TotalProfit:SetText(result.totalProfit and money(result.totalProfit) or "...")
            row.ROI:SetText(("%.0f%%"):format(result.roi))
            row:Show()
        else
            row:Hide()
        end
    end

    if countText then
        if total == 0 then
            if #results > 0 and (minimumProfit > 0 or minimumROI > 0) then
                countText:SetText(("No matches (%d below-vendor items before filters)."):format(#results))
            else
                countText:SetText("No below-vendor listings found yet.")
            end
        else
            local suffix = total < #results and (" (%d before filters)"):format(#results) or ""
            countText:SetText(("Showing %d-%d of %d matches%s"):format(pageOffset + 1, math.min(pageOffset + PAGE_SIZE, total), total, suffix))
        end
    end
    if previousButton then previousButton:SetEnabled(pageOffset > 0) end
    if nextButton then nextButton:SetEnabled(pageOffset < maxOffset) end
    if buyQueueButton then
        local count = #queueableResults
        buyQueueButton:SetText(count > 0 and ("Buy Queue (" .. count .. ")") or "Buy Queue")
        buyQueueButton:SetEnabled(count > 0 and not pendingPurchase and not purchaseQueue)
    end
end

local function addResult(item, name, link, quality, icon, vendor)
    local buyout = tonumber(item.itemData and item.itemData.minPrice) or 0
    vendor = tonumber(vendor) or 0
    if buyout <= 0 or vendor <= buyout then return end
    local key = resultKey(item)
    if resultsByKey[key] then return end

    local result = {
        key = key,
        itemKey = item.itemKey,
        itemID = item.itemKey and item.itemKey.itemID,
        name = name or (item.itemInfo and item.itemInfo.itemName) or ("Item " .. tostring(item.itemKey and item.itemKey.itemID or "?")),
        link = link,
        quality = quality or (item.itemInfo and item.itemInfo.quality) or 1,
        icon = icon or (item.itemInfo and item.itemInfo.iconFileID),
        buyout = buyout,
        vendor = vendor,
        profit = vendor - buyout,
        roi = (vendor - buyout) / buyout * 100,
        marketQuantity = tonumber(item.itemData and item.itemData.totalQuantity) or 0,
        quantityAtPrice = nil,
        totalProfit = nil,
        browseResult = item.itemData,
    }
    resultsByKey[key] = result
    table.insert(results, result)
end

local function resolveItemInfo(item)
    local itemID = item.itemKey and item.itemKey.itemID
    if not itemID then return false end

    local query = item.itemData and item.itemData.appearanceLink or itemID
    local name, link, quality, _, _, _, _, _, _, icon, appearanceVendor = C_Item.GetItemInfo(query)
    local baseName, baseLink, baseQuality, _, _, _, _, _, _, baseIcon, baseVendor
    if query == itemID then
        baseName, baseLink, baseQuality, baseIcon, baseVendor = name, link, quality, icon, appearanceVendor
    else
        baseName, baseLink, baseQuality, _, _, _, _, _, _, baseIcon, baseVendor = C_Item.GetItemInfo(itemID)
    end
    -- Browse appearance links frequently have a display name before their
    -- vendor value is available. The base item record owns the dependable
    -- sell price, so do not mark this item resolved until that record loads.
    if not baseName then return false end
    local vendor = tonumber(appearanceVendor) or 0
    if vendor <= 0 then vendor = tonumber(baseVendor) or 0 end
    return true, name or baseName, link or baseLink, quality or baseQuality, icon or baseIcon, vendor
end

local function evaluateItem(item)
    local resolved, name, link, quality, icon, vendor = resolveItemInfo(item)
    if not resolved then return false end
    addResult(item, name, link, quality, icon, vendor)
    return true
end

local function vendorPageVisible()
    if not vendorPage or not AuctionHouseFrame or not AuctionHouseFrame:IsShown() then return false end
    if vendorPage.IsVisible then return vendorPage:IsVisible() end
    return vendorPage:IsShown()
end

local function pauseQuantityLookup()
    quantityGeneration = quantityGeneration + 1
    quantityPending = nil
    wipe(quantityQueue)
end

local function resumeQuantityLookup()
    if not vendorPageVisible() then return end
    wipe(quantityQueue)
    for _, result in ipairs(results) do
        if result.quantityAtPrice == nil then quantityQueue[#quantityQueue + 1] = result end
    end
    if #quantityQueue > 0 then
        setStatus(("Loading exact quantities for %d below-vendor items..."):format(#quantityQueue))
        requestNextQuantity()
    end
end

requestNextQuantity = function()
    if not vendorPageVisible() then return end
    if quantityPending then return end
    if #quantityQueue == 0 then
        setStatus(("Scan complete: %d below-vendor items found; exact quantities loaded."):format(#results))
        return
    end
    if pendingPurchase then C_Timer.After(0.25, requestNextQuantity) return end
    if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
        C_Timer.After(0.25, requestNextQuantity)
        return
    end
    local result = table.remove(quantityQueue, 1)
    local keyInfo = C_AuctionHouse.GetItemKeyInfo(result.itemKey)
    if not keyInfo then table.insert(quantityQueue, result) C_Timer.After(0.10, requestNextQuantity) return end
    local generation = quantityGeneration
    quantityPending = {result=result, isCommodity=keyInfo.isCommodity, generation=generation}
    local context = keyInfo.isCommodity and AuctionHouseSearchContext.BuyCommodities or AuctionHouseSearchContext.BuyItems
    AuctionHouseFrame:QueryItem(context, result.itemKey)
    C_Timer.After(5, function()
        if quantityPending and quantityPending.result == result and quantityPending.generation == generation then
            quantityPending = nil
            C_Timer.After(0.10, requestNextQuantity)
        end
    end)
end

local function beginQuantityLookup()
    pauseQuantityLookup()
    for _, result in ipairs(results) do
        result.quantityAtPrice = nil
        result.totalProfit = nil
    end
    resumeQuantityLookup()
end

local function finishProcessing()
    sortResults()
    pageOffset = 0
    updateRows()
    local unresolved = 0
    for _ in pairs(pending) do unresolved = unresolved + 1 end
    setStatus(("Found %d below-vendor items%s."):format(#results, unresolved > 0 and (", " .. unresolved .. " item records still loading") or ""))
    beginQuantityLookup()
end

local function processItems(items)
    wipe(results)
    wipe(resultsByKey)
    wipe(pending)
    lastItems = items

    for _, item in ipairs(items or {}) do
        if not evaluateItem(item) then
            local itemID = item.itemKey and item.itemKey.itemID
            if itemID then
                pending[itemID] = pending[itemID] or {}
                table.insert(pending[itemID], item)
                if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
            end
        end
    end
    finishProcessing()
end

local itemEvent = CreateFrame("Frame")
itemEvent:RegisterEvent("GET_ITEM_INFO_RECEIVED")
itemEvent:SetScript("OnEvent", function(_, _, itemID, success)
    local waiting = pending[itemID]
    if not waiting then return end
    pending[itemID] = nil
    if success then
        local previousCount = #results
        for _, item in ipairs(waiting) do evaluateItem(item) end
        for index = previousCount + 1, #results do quantityQueue[#quantityQueue + 1] = results[index] end
        sortResults()
        updateRows()
        requestNextQuantity()
    end
end)

local function sendScanQuery(destination)
    if type(destination) == "string" then scanDestination = destination end
    if not AuctionHouseFrame or not C_AuctionHouse then return end
    if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
        if not scanWaiting then
            scanWaiting = true
            setStatus("Waiting for the Auction House query throttle...")
        end
        C_Timer.After(0.25, sendScanQuery)
        return
    end
    scanWaiting = false
    scanRequested = true
    setStatus("Scanning every Auction House browse result...")
    local sorts = AuctionHouseFrame.GetSortsForContext and AuctionHouseFrame:GetSortsForContext(AuctionHouseSearchContext.BrowseAll) or {}
    if not DXMScanner or not DXMScanner.RequestScan then
        setStatus("DXM Scanner is not ready. Close and reopen the Auction House.")
        return
    end
    DXMScanner.RequestScan()
    C_AuctionHouse.SendBrowseQuery({
        searchString = "",
        minLevel = 0,
        maxLevel = 0,
        filters = {},
        itemClassFilters = {},
        sorts = sorts,
    })
end

local function buildPage(page)
    vendorPage = page
    local scan = DXMTheme:CreateButton(page)
    scan:SetSize(150, 25)
    scan:SetPoint("TOPRIGHT", page, "TOPRIGHT", -8, -2)
    scan:SetText("Scan Auction House")
    scan:SetScript("OnClick", function() sendScanQuery("vendor") end)

    buyQueueButton = DXMTheme:CreateButton(page)
    buyQueueButton:SetSize(118, 25)
    buyQueueButton:SetPoint("RIGHT", scan, "LEFT", -8, 0)
    buyQueueButton:SetText("Buy Queue")
    buyQueueButton:SetEnabled(false)
    buyQueueButton:SetScript("OnClick", function()
        buyQueue(queueableResults)
        updateRows()
    end)

    statusText = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    statusText:SetPoint("TOPLEFT", page.Description, "BOTTOMLEFT", 0, -15)
    statusText:SetPoint("RIGHT", page, "RIGHT", -10, 0)
    statusText:SetJustifyH("LEFT")
    statusText:SetText("Press Scan Auction House to find guaranteed vendor-profit listings.")

    local note = page:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", statusText, "BOTTOMLEFT", 0, -4)
    note:SetText("One row per item key. Left-click opens the buy view; right-click starts Blizzard's buy confirmation.")

    local filters = CreateFrame("Frame", nil, page)
    filters:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -8)
    filters:SetPoint("RIGHT", page, "RIGHT", -8, 0)
    filters:SetHeight(28)

    local profitLabel = filters:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    profitLabel:SetPoint("LEFT", filters, "LEFT", 0, 0)
    profitLabel:SetText("Minimum profit")
    local profitInput = CreateFrame("EditBox", nil, filters, "InputBoxTemplate")
    profitInput:SetSize(105, 24)
    profitInput:SetPoint("LEFT", profitLabel, "RIGHT", 10, 0)
    profitInput:SetAutoFocus(false)
    profitInput:SetJustifyH("CENTER")
    profitInput:SetText(DXMConfig.vendorMinimumProfitText or "")

    local roiLabel = filters:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    roiLabel:SetPoint("LEFT", profitInput, "RIGHT", 24, 0)
    roiLabel:SetText("Minimum ROI")
    local roiInput = CreateFrame("EditBox", nil, filters, "InputBoxTemplate")
    roiInput:SetSize(70, 24)
    roiInput:SetPoint("LEFT", roiLabel, "RIGHT", 10, 0)
    roiInput:SetAutoFocus(false)
    roiInput:SetJustifyH("CENTER")
    roiInput:SetText(DXMConfig.vendorMinimumROIText or "")
    local percent = filters:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    percent:SetPoint("LEFT", roiInput, "RIGHT", 5, 0)
    percent:SetText("%")

    local hint = filters:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("LEFT", percent, "RIGHT", 18, 0)
    hint:SetText("Profit accepts 1g 25s 50c; blank = 0")

    local function applyFilters()
        DXMConfig.vendorMinimumProfitText = profitInput:GetText() or ""
        DXMConfig.vendorMinimumROIText = roiInput:GetText() or ""
        minimumProfit = parseMoney(DXMConfig.vendorMinimumProfitText)
        minimumROI = parseROI(DXMConfig.vendorMinimumROIText)
        pageOffset = 0
        updateRows()
    end
    profitInput:SetScript("OnEnterPressed", function(self) self:ClearFocus(); applyFilters() end)
    profitInput:SetScript("OnEditFocusLost", applyFilters)
    profitInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    roiInput:SetScript("OnEnterPressed", function(self) self:ClearFocus(); applyFilters() end)
    roiInput:SetScript("OnEditFocusLost", applyFilters)
    roiInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    minimumProfit = parseMoney(profitInput:GetText())
    minimumROI = parseROI(roiInput:GetText())

    local resultList = DXMTheme:CreatePanel(page)
    resultList:SetPoint("TOPLEFT", filters, "BOTTOMLEFT", -6, -7)
    resultList:SetPoint("RIGHT", page, "RIGHT", -8, 0)
    resultList:SetHeight(PAGE_SIZE * 25 + 42)

    local header = CreateFrame("Frame", nil, resultList)
    header:SetPoint("TOPLEFT", resultList, "TOPLEFT", 5, -5)
    header:SetPoint("TOPRIGHT", resultList, "TOPRIGHT", -5, -5)
    header:SetHeight(22)

    local headerBackground = header:CreateTexture(nil, "BACKGROUND")
    headerBackground:SetAllPoints()
    headerBackground:SetColorTexture(0.16, 0.12, 0.05, 0.9)

    local headerDivider = header:CreateTexture(nil, "BORDER")
    headerDivider:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0)
    headerDivider:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
    headerDivider:SetHeight(1)
    headerDivider:SetColorTexture(0.55, 0.42, 0.16, 0.9)

    local function addColumnDivider(owner)
        local divider = owner:CreateTexture(nil, "BORDER")
        divider:SetWidth(1)
        divider:SetColorTexture(0.35, 0.31, 0.23, 0.6)
        return divider
    end

    local function moveDivider(divider, owner, x)
        divider:ClearAllPoints()
        divider:SetPoint("TOPLEFT", owner, "TOPLEFT", x, 0)
        divider:SetPoint("BOTTOMLEFT", owner, "BOTTOMLEFT", x, 0)
    end

    local headerItem = header:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    headerItem:SetJustifyH("LEFT")
    headerItem:SetText("Item")

    local function sortHeader(label, key)
        local button = CreateFrame("Button", nil, header)
        button:SetHeight(21)
        button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        button.Label = button:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        button.Label:SetAllPoints()
        button.Label:SetJustifyH("CENTER")
        button:SetScript("OnClick", function()
            if sortKey == key then
                sortAscending = not sortAscending
            else
                sortKey = key
                sortAscending = key == "buyout"
            end
            sortResults()
            pageOffset = 0
            updateRows()
        end)
        sortHeaders[key] = {Button = button, Label = button.Label, label = label}
    end

    sortHeader("Buyout", "buyout")
    sortHeader("Vendor", "vendor")
    sortHeader("Qty", "quantityAtPrice")
    sortHeader("Unit Profit", "profit")
    sortHeader("Total Profit", "totalProfit")
    sortHeader("ROI", "roi")
    updateSortHeaders()
    header.ColumnDividers = {
        addColumnDivider(header),
        addColumnDivider(header),
        addColumnDivider(header),
        addColumnDivider(header),
        addColumnDivider(header),
        addColumnDivider(header),
    }

    local previousRow
    for index = 1, PAGE_SIZE do
        local row = CreateFrame("Button", nil, resultList)
        row:SetHeight(25)
        row:SetPoint("LEFT", header, "LEFT", 0, 0)
        row:SetPoint("RIGHT", header, "RIGHT", 0, 0)
        if previousRow then row:SetPoint("TOP", previousRow, "BOTTOM", 0, 0) else row:SetPoint("TOP", header, "BOTTOM", 0, 0) end
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        row.Background = row:CreateTexture(nil, "BACKGROUND")
        row.Background:SetAllPoints()
        if index % 2 == 0 then
            row.Background:SetColorTexture(0.10, 0.10, 0.10, 0.72)
        else
            row.Background:SetColorTexture(0.035, 0.035, 0.035, 0.72)
        end

        row.Divider = row:CreateTexture(nil, "BORDER")
        row.Divider:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
        row.Divider:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
        row.Divider:SetHeight(1)
        row.Divider:SetColorTexture(0.31, 0.27, 0.19, 0.72)
        row.ColumnDividers = {
            addColumnDivider(row),
            addColumnDivider(row),
            addColumnDivider(row),
            addColumnDivider(row),
            addColumnDivider(row),
            addColumnDivider(row),
        }

        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                buyResult(self.result)
            elseif IsModifiedClick and IsModifiedClick("CHATLINK") and self.result and self.result.link then
                ChatEdit_InsertLink(self.result.link)
            else
                openResult(self.result)
            end
        end)
        row:SetScript("OnEnter", showTooltip)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        row.Icon = row:CreateTexture(nil, "ARTWORK")
        row.Icon:SetSize(22, 22)
        row.Icon:SetPoint("LEFT", 2, 0)
        row.Name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.Name:SetJustifyH("LEFT")
        row.Buyout = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.Buyout:SetJustifyH("RIGHT")
        row.Vendor = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.Vendor:SetJustifyH("RIGHT")
        row.Quantity = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.Quantity:SetJustifyH("RIGHT")
        row.Profit = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.Profit:SetJustifyH("RIGHT")
        row.TotalProfit = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.TotalProfit:SetJustifyH("RIGHT")
        row.ROI = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.ROI:SetJustifyH("RIGHT")
        rows[index] = row
        previousRow = row
    end

    local function placeRegion(region, owner, left, right, insetLeft, insetRight)
        region:ClearAllPoints()
        region:SetPoint("LEFT", owner, "LEFT", left + (insetLeft or 0), 0)
        region:SetWidth(math.max(1, right - left - (insetLeft or 0) - (insetRight or 0)))
    end

    local function layoutColumns(width)
        width = math.max(1, tonumber(width) or 0)
        local boundaries = {
            math.floor(width * 0.34),
            math.floor(width * 0.47),
            math.floor(width * 0.59),
            math.floor(width * 0.66),
            math.floor(width * 0.78),
            math.floor(width * 0.93),
            width,
        }

        placeRegion(headerItem, header, 0, boundaries[1], 28, 5)
        local keys = {"buyout", "vendor", "quantityAtPrice", "profit", "totalProfit", "roi"}
        local left = boundaries[1]
        for index, key in ipairs(keys) do
            local right = boundaries[index + 1]
            placeRegion(sortHeaders[key].Button, header, left, right, 1, 1)
            moveDivider(header.ColumnDividers[index], header, left)
            left = right
        end

        for _, row in ipairs(rows) do
            placeRegion(row.Name, row, 0, boundaries[1], 28, 5)
            placeRegion(row.Buyout, row, boundaries[1], boundaries[2], 5, 5)
            placeRegion(row.Vendor, row, boundaries[2], boundaries[3], 5, 5)
            placeRegion(row.Quantity, row, boundaries[3], boundaries[4], 5, 5)
            placeRegion(row.Profit, row, boundaries[4], boundaries[5], 5, 5)
            placeRegion(row.TotalProfit, row, boundaries[5], boundaries[6], 5, 5)
            placeRegion(row.ROI, row, boundaries[6], boundaries[7], 5, 5)
            for index, divider in ipairs(row.ColumnDividers) do
                moveDivider(divider, row, boundaries[index])
            end
        end
    end

    header:SetScript("OnSizeChanged", function(_, width)
        if width and width > 0 then layoutColumns(width) end
    end)
    if header:GetWidth() > 0 then layoutColumns(header:GetWidth()) end
    C_Timer.After(0, function()
        if header and header:GetWidth() > 0 then layoutColumns(header:GetWidth()) end
    end)

    previousButton = DXMTheme:CreateButton(page)
    previousButton:SetSize(28, 22)
    previousButton:SetPoint("TOPLEFT", resultList, "BOTTOMLEFT", 4, -6)
    previousButton:SetText("<")
    previousButton:SetScript("OnClick", function() pageOffset = math.max(0, pageOffset - PAGE_SIZE) updateRows() end)

    nextButton = DXMTheme:CreateButton(page)
    nextButton:SetSize(28, 22)
    nextButton:SetPoint("LEFT", previousButton, "RIGHT", 5, 0)
    nextButton:SetText(">")
    nextButton:SetScript("OnClick", function() pageOffset = pageOffset + PAGE_SIZE updateRows() end)

    countText = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    countText:SetPoint("LEFT", nextButton, "RIGHT", 10, 0)
    countText:SetText("No scan results yet.")

    page:EnableMouseWheel(true)
    page:SetScript("OnMouseWheel", function(_, delta)
        if delta < 0 then pageOffset = pageOffset + PAGE_SIZE else pageOffset = pageOffset - PAGE_SIZE end
        updateRows()
    end)
    page:HookScript("OnShow", resumeQuantityLookup)
    page:HookScript("OnHide", pauseQuantityLookup)
    updateRows()
end

function Module:Boot(hook)
    hook(Const.ScannerItemsCompleted, Module.ScannerItemsCompleted)
    hook(Const.ScannerPurchaseCompleted, Module.ScannerPurchaseCompleted)
end

function Module:ScannerPurchaseCompleted()
    activePurchase = nil
    if not purchaseQueue then return end
    purchaseQueueIndex = purchaseQueueIndex + 1
    C_Timer.After(.15, advancePurchaseQueue)
end

function Module:ScannerItemsCompleted(items)
    processItems(items)
    if scanRequested then
        scanRequested = false
        local destination = scanDestination or "vendor"
        scanDestination = "vendor"
        DXMExchange:Open(destination)
    end
end

DXMVendorFinder = {
    StartScan = function(destination) sendScanQuery(destination) end,
    GetResults = function() return results end,
    FormatMoney = money,
    OpenResult = openResult,
    BuyResult = buyResult,
    BuyQueue = buyQueue,
    PurchaseActive = function() return pendingPurchase~=nil or purchaseQueue~=nil end,
}

DXMExchange:RegisterPageBuilder("vendor", buildPage)
