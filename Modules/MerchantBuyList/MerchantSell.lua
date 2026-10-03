if not DXMCore then return end

local Module = DXMCore:Module("MerchantSell")
Module.bootType = DXMCore.Const().BootType.PlayerEnteringWorld
DXMConfig = DXMConfig or {}
if DXMConfig.merchantSellProfitable == nil then DXMConfig.merchantSellProfitable = true end
if DXMConfig.merchantSellJunk == nil then DXMConfig.merchantSellJunk = true end
if DXMConfig.merchantSellAll == nil then DXMConfig.merchantSellAll = false end
-- Reset the unsafe pre-protection choice once. The user can deliberately re-enable it.
if tonumber(DXMConfig.merchantSellSafetyVersion) ~= 2 then
    DXMConfig.merchantSellAll = false
    DXMConfig.merchantSellSafetyVersion = 2
end

local PROFESSION_TOOLS = {
    [2901]=true, [5956]=true, [6217]=true, [6218]=true, [6219]=true, [6256]=true, [6338]=true, [6339]=true,
    [7005]=true, [9149]=true, [10498]=true, [11128]=true, [11130]=true, [11144]=true, [11145]=true, [15846]=true,
    [16206]=true, [16207]=true, [20815]=true, [20824]=true, [22461]=true, [22462]=true, [22463]=true, [25843]=true, [25844]=true, [25845]=true,
    [39505]=true, [40772]=true, [41745]=true, [44452]=true,
}

-- These categories are never eligible for the vendor queue, including when
-- "Vendor all" is enabled. Numeric IDs keep the rules independent of locale.
local PROTECTED_CONSUMABLE_SUBCLASSES = {
    [1]=true, -- Potions
    [2]=true, -- Elixirs
    [3]=true, -- Flasks
    [5]=true, -- Food & Drink
}
local PROTECTED_TRADE_GOODS_SUBCLASSES = {
    [7]=true, -- Metal & Stone (ore, bars, and ingots)
    [9]=true, -- Herbs
}

local function categoryProtected(classID, subclassID)
    classID, subclassID = tonumber(classID), tonumber(subclassID)
    if classID == 0 and PROTECTED_CONSUMABLE_SUBCLASSES[subclassID] then return true end
    if classID == 7 and PROTECTED_TRADE_GOODS_SUBCLASSES[subclassID] then return true end
    return false
end

local panel, tab, status, summary, sellButton, stopButton
local rows = {}
local candidates = {}
local sellQueue
local queueIndex = 0
local pending
local generation = 0
local ROWS = 12
local nativeWidth, nativeHeight
local specialtyProtected = 0

local protectedItemIDs = {}

local function refreshProtectedItems()
    wipe(protectedItemIDs)
    for itemID in pairs(PROFESSION_TOOLS) do protectedItemIDs[itemID] = true end
    for key, entry in pairs(DXMShoppingList and DXMShoppingList.items or {}) do
        local itemID = tonumber(entry.itemID or key)
        if itemID and (tonumber(entry.needed) or 0) > 0 then protectedItemIDs[itemID] = true end
    end
    if C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs and C_EquipmentSet.GetItemIDs then
        for _, setID in ipairs(C_EquipmentSet.GetEquipmentSetIDs() or {}) do
            for _, itemID in pairs(C_EquipmentSet.GetItemIDs(setID) or {}) do
                itemID = tonumber(itemID)
                if itemID and itemID > 0 then protectedItemIDs[itemID] = true end
            end
        end
    end
end
local function money(value)
    value = math.max(0, math.floor(tonumber(value) or 0))
    local gold = math.floor(value / 10000)
    local silver = math.floor(value / 100) % 100
    local copper = value % 100
    if gold > 0 then return ("%dg %02ds %02dc"):format(gold, silver, copper) end
    if silver > 0 then return ("%ds %02dc"):format(silver, copper) end
    return copper .. "c"
end

local function itemSuffix(link)
    return DXMLedgerAccounting and DXMLedgerAccounting.Suffix and DXMLedgerAccounting.Suffix(link)
end

local function questProtected(info)
    return info and (info.isQuestItem == true or (tonumber(info.questID) or 0) > 0) or false
end
local function itemInfo(bag, slot)
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info or not info.itemID or info.isLocked or info.isBound then return end
    if protectedItemIDs[tonumber(info.itemID)] then return end
    local quest = C_Container.GetContainerItemQuestInfo and C_Container.GetContainerItemQuestInfo(bag, slot)
    if questProtected(quest) then return end
    local name, link, quality, _, _, _, _, _, _, icon, sellPrice, classID, subclassID = C_Item.GetItemInfo(info.hyperlink or info.itemID)
    -- Fail closed while item data is uncached. A later bag/item event will scan
    -- it again after the client has loaded authoritative category information.
    if not name or quality == nil or classID == nil or subclassID == nil then
        if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(info.itemID) end
        return
    end
    if categoryProtected(classID, subclassID) then return end
    sellPrice = tonumber(sellPrice) or 0
    local quantity = math.max(1, math.floor(tonumber(info.stackCount) or 1))
    if sellPrice <= 0 then return end
    return {
        bag=bag, slot=slot, itemID=tonumber(info.itemID), name=name or ("Item " .. info.itemID),
        link=link or info.hyperlink, icon=info.iconFileID or icon or 134400,
        quality=tonumber(quality) or 1, quantity=quantity, vendorUnit=sellPrice,
        vendorTotal=sellPrice * quantity,
    }
end

local function classify(entry)
    if DXMConfig.merchantSellAll then entry.reason = "Vendor all"; return true end
    if entry.quality == 0 then
        if DXMConfig.merchantSellJunk then entry.reason = "Gray item"; return true end
        return false
    end
    if not DXMConfig.merchantSellProfitable or not DXMLedger or not DXMLedger.PreviewCost then return false end
    local cost, matched = DXMLedger:PreviewCost(entry.itemID, entry.quantity, nil, nil, itemSuffix(entry.link))
    if matched == entry.quantity and tonumber(cost) and entry.vendorTotal > cost then
        entry.cost = cost
        entry.profit = entry.vendorTotal - cost
        entry.reason = "DXM profit " .. money(entry.profit)
        return true
    end
    return false
end

local function isSpecialtyBag(bag, family)
    bag = tonumber(bag)
    if not bag or bag == 0 then return false end
    local reagentBag = Enum and Enum.BagIndex and tonumber(Enum.BagIndex.ReagentBag)
    return (reagentBag and bag == reagentBag) or (tonumber(family) or 0) ~= 0
end
local function scanCandidates()
    refreshProtectedItems()
    wipe(candidates)
    specialtyProtected = 0
    local lastBag = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag or NUM_BAG_SLOTS or 4
    for bag = 0, lastBag do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        local _, family = C_Container.GetContainerNumFreeSlots(bag)
        local specialtyBag = isSpecialtyBag(bag, family)
        for slot = 1, slots do
            if specialtyBag then
                if C_Container.GetContainerItemInfo(bag, slot) then specialtyProtected = specialtyProtected + 1 end
            else
                local entry = itemInfo(bag, slot)
                if entry and classify(entry) then candidates[#candidates + 1] = entry end
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.reason ~= b.reason then return a.reason < b.reason end
        if a.name ~= b.name then return a.name < b.name end
        if a.bag ~= b.bag then return a.bag < b.bag end
        return a.slot < b.slot
    end)
end

local function queueActive()
    return sellQueue ~= nil
end

local function refreshRows(message)
    if not panel then return end
    if not queueActive() then scanCandidates() end
    local list = queueActive() and sellQueue or candidates
    local total, units = 0, 0
    for _, entry in ipairs(list or {}) do
        total = total + (entry.vendorTotal or 0)
        units = units + (entry.quantity or 0)
    end
    for index, row in ipairs(rows) do
        local entry = list and list[index]
        row.entry = entry
        if entry then
            row.Icon:SetTexture(entry.icon)
            row.Name:SetText(entry.link or entry.name)
            row.Quantity:SetText(entry.quantity)
            row.Reason:SetText(entry.reason)
            row.Value:SetText(money(entry.vendorTotal))
            row:Show()
        else
            row:Hide()
        end
    end
    summary:SetText(("%d stacks / %d items    Vendor value %s    %d specialty-bag stacks protected"):format(#(list or {}), units, money(total), specialtyProtected))
    status:SetText(message or (#list == 0 and "No items match the enabled safe-selling rules." or
        "Review the queue, then sell every matching stack automatically. Profession tools are always protected."))
    sellButton:SetText(queueActive() and "Selling..." or ("Sell Queue (" .. #list .. ")"))
    sellButton:SetEnabled(not queueActive() and #list > 0)
    stopButton:SetEnabled(queueActive())
end

local function stopQueue(message)
    generation = generation + 1
    sellQueue, pending = nil, nil
    queueIndex = 0
    refreshRows(message or "Selling stopped.")
end

local sellNext

local function confirmPending()
    if not pending then return end
    local item = C_Container.GetContainerItemInfo(pending.entry.bag, pending.entry.slot)
    local remaining = item and tonumber(item.itemID) == pending.entry.itemID and (tonumber(item.stackCount) or 0) or 0
    local sold = math.max(0, pending.before - remaining)
    if sold <= 0 then return end
    local entry = pending.entry
    if DXMLedger and DXMLedger.RecordVendorSale then
        DXMLedger:RecordVendorSale({
            itemID=entry.itemID, itemLink=entry.link, name=entry.name, quantity=sold,
            total=sold * entry.vendorUnit,
        })
    end
    pending = nil
    queueIndex = queueIndex + 1
    C_Timer.After(.08, sellNext)
end

sellNext = function()
    if not sellQueue or pending then return end
    if not MerchantFrame or not MerchantFrame:IsShown() or not panel or not panel:IsShown() then
        stopQueue("Selling stopped because the merchant or DXM SELL tab closed.")
        return
    end
    local entry = sellQueue[queueIndex]
    if not entry then
        local count = #sellQueue
        sellQueue, pending = nil, nil
        queueIndex = 0
        refreshRows(("Sold %d queued stacks."):format(count))
        return
    end
    local current = itemInfo(entry.bag, entry.slot)
    if not current or current.itemID ~= entry.itemID or not classify(current) then
        queueIndex = queueIndex + 1
        C_Timer.After(0, sellNext)
        return
    end
    entry.quantity, entry.vendorTotal, entry.cost, entry.profit, entry.reason = current.quantity, current.vendorTotal, current.cost, current.profit, current.reason
    pending = {entry=entry, before=current.quantity, generation=generation}
    status:SetText(("Selling %d/%d: %s x%d"):format(queueIndex, #sellQueue, entry.name, entry.quantity))
    local ok, err = pcall(C_Container.UseContainerItem, entry.bag, entry.slot)
    if not ok then
        pending = nil
        stopQueue("Selling stopped: " .. tostring(err or "merchant rejected the item"))
        return
    end
    local token = generation
    C_Timer.After(1.5, function()
        if sellQueue and pending and pending.generation == token then
            confirmPending()
            if pending and pending.generation == token then
                stopQueue("Selling stopped because the current stack did not leave the bag.")
            end
        end
    end)
end

local function startQueue()
    if queueActive() then return end
    scanCandidates()
    if #candidates == 0 then refreshRows(); return end
    sellQueue = {}
    for _, entry in ipairs(candidates) do sellQueue[#sellQueue + 1] = entry end
    queueIndex = 1
    generation = generation + 1
    refreshRows()
    sellNext()
end

local function makeCheck(parent, label, key, anchor)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetSize(22, 22)
    check:SetPoint("LEFT", anchor, "RIGHT", 16, 0)
    check:SetChecked(DXMConfig[key] == true)
    local text = check:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    text:SetPoint("LEFT", check, "RIGHT", 2, 0)
    text:SetText(label)
    check:SetScript("OnClick", function(self)
        DXMConfig[key] = self:GetChecked() == true
        if queueActive() then stopQueue("Queue stopped because a selling rule changed.") else refreshRows() end
    end)
    return text
end

local function makeRow(previous, index)
    local row = CreateFrame("Frame", nil, panel)
    row:SetHeight(29); row:SetPoint("LEFT", 8, 0); row:SetPoint("RIGHT", -8, 0); row:SetPoint("TOP", previous, "BOTTOM")
    local bg = row:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); local shade=index%2==0 and .09 or .025; bg:SetColorTexture(shade,shade,shade,.96)
    local line = row:CreateTexture(nil, "BORDER"); line:SetPoint("BOTTOMLEFT"); line:SetPoint("BOTTOMRIGHT"); line:SetHeight(1); line:SetColorTexture(.31,.27,.19,.72)
    row.Icon = row:CreateTexture(nil, "ARTWORK"); row.Icon:SetSize(24,24); row.Icon:SetPoint("LEFT",2,0)
    row.Name = row:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); row.Name:SetPoint("LEFT",30,0); row.Name:SetPoint("RIGHT",-270,0); row.Name:SetJustifyH("LEFT")
    row.Quantity = row:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); row.Quantity:SetPoint("RIGHT",-235,0); row.Quantity:SetWidth(30)
    row.Reason = row:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); row.Reason:SetPoint("RIGHT",-94,0); row.Reason:SetWidth(132); row.Reason:SetJustifyH("RIGHT")
    row.Value = row:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); row.Value:SetPoint("RIGHT",-5,0); row.Value:SetWidth(84); row.Value:SetJustifyH("RIGHT")
    return row
end

local function expandMerchant()
    if not MerchantFrame then return end
    if not nativeWidth then nativeWidth, nativeHeight = MerchantFrame:GetSize() end
    MerchantFrame:SetSize(math.max(tonumber(nativeWidth) or 0, 720), math.max(tonumber(nativeHeight) or 0, 650))
end

local function restoreMerchant()
    if MerchantFrame and nativeWidth and nativeHeight then MerchantFrame:SetSize(nativeWidth, nativeHeight) end
end
local function raisePanel()
    if not panel then return end
    local parent = panel:GetParent()
    panel:SetFrameStrata("DIALOG")
    panel:SetFrameLevel(math.max((parent and parent:GetFrameLevel() or 0) + 200, 500))
    if panel.Raise then panel:Raise() end
end

local function createPanel()
    if panel or not MerchantFrame or not MerchantFrameTab2 then return end
    local craftingTab = _G.DXMMerchantTab
    if not craftingTab then return end
    tab = CreateFrame("Button", "DXMMerchantSellTab", MerchantFrame, "PanelTabButtonTemplate")
    tab:SetID(4); tab:SetText("DXM SELL"); tab:SetPoint("LEFT", craftingTab, "RIGHT", -16, 0)
    if PanelTemplates_SetNumTabs then PanelTemplates_SetNumTabs(MerchantFrame, 4) end
    if PanelTemplates_TabResize then PanelTemplates_TabResize(tab, 0) end

    panel = DXMTheme:CreatePanel(MerchantFrame, "DXMMerchantSellFrame")
    panel:SetPoint("TOPLEFT",6,-58); panel:SetPoint("BOTTOMRIGHT",-6,35)
    panel:SetToplevel(true); panel:SetScript("OnShow", function() expandMerchant(); raisePanel(); refreshRows() end); raisePanel(); panel:EnableMouse(true)
    panel:SetScript("OnHide", function() if queueActive() then stopQueue("Selling stopped.") end; restoreMerchant() end)
    local fill=panel:CreateTexture(nil,"BACKGROUND"); fill:SetPoint("TOPLEFT",4,-4); fill:SetPoint("BOTTOMRIGHT",-4,4); fill:SetColorTexture(.025,.025,.025,1)
    local title=panel:CreateFontString(nil,"ARTWORK","GameFontNormalLarge"); title:SetPoint("TOPLEFT",14,-12); title:SetText("DXM Safe Vendor Queue")
    summary=panel:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); summary:SetPoint("TOPLEFT",title,"BOTTOMLEFT",0,-6)
    local ruleLabel=panel:CreateFontString(nil,"ARTWORK","GameFontNormalSmall"); ruleLabel:SetPoint("TOPLEFT",summary,"BOTTOMLEFT",0,-8); ruleLabel:SetText("Include")
    local first = makeCheck(panel, "Profitable DXM purchases", "merchantSellProfitable", ruleLabel)
    local second = makeCheck(panel, "Gray items", "merchantSellJunk", first)
    makeCheck(panel, "Vendor all", "merchantSellAll", second)

    local header=CreateFrame("Frame",nil,panel); header:SetPoint("TOPLEFT",8,-79); header:SetPoint("TOPRIGHT",-8,-79); header:SetHeight(22)
    local hbg=header:CreateTexture(nil,"BACKGROUND"); hbg:SetAllPoints(); hbg:SetColorTexture(.16,.12,.05,.95)
    local label=header:CreateFontString(nil,"ARTWORK","GameFontNormalSmall"); label:SetPoint("LEFT",8,0); label:SetText("Item")
    for _,spec in ipairs({{"Qty",-235,30},{"Why",-94,132},{"Vendor",-5,84}}) do local text=header:CreateFontString(nil,"ARTWORK","GameFontNormalSmall"); text:SetPoint("RIGHT",spec[2],0); text:SetWidth(spec[3]); text:SetText(spec[1]); text:SetJustifyH("RIGHT") end
    local previous=header
    for index=1,ROWS do rows[index]=makeRow(previous,index); previous=rows[index] end

    status=panel:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); status:SetPoint("BOTTOMLEFT",10,42); status:SetPoint("RIGHT",-10,0); status:SetJustifyH("LEFT")
    sellButton=DXMTheme:CreateButton(panel); sellButton:SetSize(126,23); sellButton:SetPoint("BOTTOMLEFT",10,10); sellButton:SetText("Sell Queue"); sellButton:SetScript("OnClick",startQueue)
    stopButton=DXMTheme:CreateButton(panel); stopButton:SetSize(72,23); stopButton:SetPoint("LEFT",sellButton,"RIGHT",5,0); stopButton:SetText("Stop"); stopButton:SetScript("OnClick",function() stopQueue("Selling stopped.") end)
    local refresh=DXMTheme:CreateButton(panel); refresh:SetSize(76,23); refresh:SetPoint("LEFT",stopButton,"RIGHT",5,0); refresh:SetText("Refresh"); refresh:SetScript("OnClick",function() if not queueActive() then refreshRows() end end)

    tab:SetScript("OnClick",function()
        MerchantFrame.selectedTab=4
        if PanelTemplates_SetTab then PanelTemplates_SetTab(MerchantFrame,4) end
        if _G.DXMMerchantCraftingFrame then _G.DXMMerchantCraftingFrame:Hide() end
        panel:Show(); raisePanel(); refreshRows()
    end)
    MerchantFrameTab1:HookScript("OnClick",function() panel:Hide() end)
    MerchantFrameTab2:HookScript("OnClick",function() panel:Hide() end)
    craftingTab:HookScript("OnClick",function() panel:Hide() end)
    panel:Hide()
end

local events=CreateFrame("Frame")
for _,event in ipairs({"ADDON_LOADED","MERCHANT_SHOW","MERCHANT_CLOSED","BAG_UPDATE_DELAYED"}) do events:RegisterEvent(event) end
events:SetScript("OnEvent",function(_,event)
    if event=="ADDON_LOADED" then createPanel(); return end
    if event=="MERCHANT_SHOW" then createPanel(); if panel then panel:Hide() end
    elseif event=="MERCHANT_CLOSED" then if panel then panel:Hide() end
    elseif event=="BAG_UPDATE_DELAYED" then
        if pending then confirmPending()
        elseif panel and panel:IsShown() and not queueActive() then refreshRows() end
    end
end)

function Module:Boot()
    createPanel()
end
