local ADDON_NAME = ...
local DISENCHANT_SPELL_ID = 13262
local currentCandidate
local lootOpen = false
local refreshPending = false
local disenchantPending = false
local pendingGeneration = 0
local lootFrameSuppressed = false
local status
local sessionSummary
local sessionDetail
local session = {items=0, materialValue=0, knownCost=0, knownProfit=0, complete=0, incomplete=0}

-- DXM_Salvager stored its settings in a differently named SavedVariables file.
-- The installer copies that file once so this bridge can retain existing state.
DXMDDQDB = DXMDDQDB or DXMSalvagerDB or {}
DXMSalvagerDB = nil

local function containerSlots(bag)
    if C_Container and C_Container.GetContainerNumSlots then return C_Container.GetContainerNumSlots(bag) or 0 end
    return GetContainerNumSlots and GetContainerNumSlots(bag) or 0
end

local function containerInfo(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if not info then return end
        local itemID = info.itemID or (C_Container.GetContainerItemID and C_Container.GetContainerItemID(bag, slot))
        return info.hyperlink or (C_Container.GetContainerItemLink and C_Container.GetContainerItemLink(bag, slot)), info.stackCount or 1, info.isLocked, itemID, info.quality, info.iconFileID
    end
    if not GetContainerItemInfo then return end
    local icon, count, locked, quality, _, _, link = GetContainerItemInfo(bag, slot)
    local itemID = GetContainerItemID and GetContainerItemID(bag, slot)
    return link or (GetContainerItemLink and GetContainerItemLink(bag, slot)), count or 1, locked, itemID, quality, icon
end

local function bagItemCanDisenchant(link, itemID, containerQuality, containerIcon)
    local query = link or itemID
    if not query then return false end

    local instant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
    local resolvedID, itemType, itemSubType, equipLoc, instantIcon, classID
    if instant then
        resolvedID, itemType, itemSubType, equipLoc, instantIcon, classID = instant(query)
    end
    itemID = tonumber(itemID) or tonumber(resolvedID)

    local getter = C_Item and C_Item.GetItemInfo or GetItemInfo
    local name, canonicalLink, quality, level, _, fullItemType, fullItemSubType, maxStack, fullEquipLoc, icon, vendor, fullClassID
    if getter then
        name, canonicalLink, quality, level, _, fullItemType, fullItemSubType, maxStack, fullEquipLoc, icon, vendor, fullClassID = getter(query)
        if not name and itemID and query ~= itemID then
            name, canonicalLink, quality, level, _, fullItemType, fullItemSubType, maxStack, fullEquipLoc, icon, vendor, fullClassID = getter(itemID)
        end
    end

    quality = tonumber(quality) or tonumber(containerQuality)
    classID = tonumber(fullClassID) or tonumber(classID)
    equipLoc = fullEquipLoc or equipLoc
    if quality ~= 2 and quality ~= 3 and quality ~= 4 then return false end
    if classID ~= 2 and classID ~= 4 then return false end
    if not equipLoc or equipLoc == "" then return false end
    if (tonumber(maxStack) or 1) > 1 then return false end

    return true, {
        itemID = itemID,
        name = name or canonicalLink or link or (itemID and ("Item " .. itemID)) or "Unknown item",
        link = canonicalLink or link,
        quality = quality,
        level = tonumber(level) or 0,
        itemType = fullItemType or itemType,
        itemSubType = fullItemSubType or itemSubType,
        maxStack = tonumber(maxStack) or 1,
        equipLoc = equipLoc,
        icon = icon or instantIcon or containerIcon,
        vendor = tonumber(vendor) or 0,
        classID = classID,
    }
end

local function findCandidate()
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, containerSlots(bag) do
            local link, count, locked, itemID, quality, icon = containerInfo(bag, slot)
            if (link or itemID) and not locked and (tonumber(count) or 1) == 1 then
                local eligible, info
                if DXMSalvage and DXMSalvage.CanDisenchant then
                    eligible, info = DXMSalvage.CanDisenchant(link or itemID)
                end
                if not eligible then
                    eligible, info = bagItemCanDisenchant(link, itemID, quality, icon)
                end
                if eligible then
                    return {bag=bag,slot=slot,link=link or (info and info.link),info=info}
                end
            end
        end
    end
end

local function spellName()
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(DISENCHANT_SPELL_ID) end
    if GetSpellInfo then return (GetSpellInfo(DISENCHANT_SPELL_ID)) end
end

local function knowsDisenchant()
    if IsPlayerSpell then return IsPlayerSpell(DISENCHANT_SPELL_ID) == true end
    if IsSpellKnown then return IsSpellKnown(DISENCHANT_SPELL_ID) == true end
    return false
end

local function money(value, signed)
    value = math.floor(tonumber(value) or 0)
    local sign = value < 0 and "-" or (signed and value > 0 and "+" or "")
    value = math.abs(value)
    local gold = math.floor(value / 10000)
    local silver = math.floor((value % 10000) / 100)
    local copper = value % 100
    local parts = {}
    if gold > 0 then parts[#parts + 1] = gold .. "g" end
    if silver > 0 then parts[#parts + 1] = silver .. "s" end
    if copper > 0 or #parts == 0 then parts[#parts + 1] = copper .. "c" end
    return sign .. table.concat(parts, " ")
end

local function refreshSessionDisplay()
    if not sessionSummary then return end
    sessionSummary:SetText(("Disenchanted: %d    Materials: %s    Known cost: %s    P&L: %s"):format(
        session.items, money(session.materialValue), money(session.knownCost), money(session.knownProfit, true)))
    if session.knownProfit > 0 then
        sessionSummary:SetTextColor(.2, 1, .2)
    elseif session.knownProfit < 0 then
        sessionSummary:SetTextColor(1, .25, .25)
    else
        sessionSummary:SetTextColor(1, 1, 1)
    end
    sessionDetail:SetText(session.incomplete > 0
        and ("%d result%s excluded from P&L because cost or material value is unknown."):format(session.incomplete, session.incomplete == 1 and "" or "s")
        or "Actual materials at current DXM value minus matched FIFO purchase cost.")
end

local function materialValue(itemID)
    local value = DXMSalvage and DXMSalvage.MaterialValue and DXMSalvage.MaterialValue(itemID)
    if tonumber(value) and value > 0 then return tonumber(value) end
    local vendor = C_Item and C_Item.GetItemInfo and select(11, C_Item.GetItemInfo(itemID))
    if tonumber(vendor) and vendor > 0 then return tonumber(vendor) end
end

local function recordSessionResult(row, outputs)
    local totalValue, complete = 0, true
    for itemID, quantity in pairs(outputs or {}) do
        local value = materialValue(itemID)
        quantity = math.max(1, math.floor(tonumber(quantity) or 1))
        if value then totalValue = totalValue + value * quantity else complete = false end
    end
    local cost = row and tonumber(row.costBasis)
    session.items = session.items + 1
    session.materialValue = session.materialValue + totalValue
    if cost and complete then
        session.complete = session.complete + 1
        session.knownCost = session.knownCost + cost
        session.knownProfit = session.knownProfit + totalValue - cost
    else
        session.incomplete = session.incomplete + 1
    end
    refreshSessionDisplay()
end

local function restoreLootFrame()
    if not lootFrameSuppressed or not LootFrame then return end
    LootFrame:SetAlpha(1)
    LootFrame:EnableMouse(true)
    lootFrameSuppressed = false
end

local function collectDisenchantLoot()
    if not disenchantPending then return false end
    disenchantPending = false
    if LootFrame then
        lootFrameSuppressed = true
        LootFrame:SetAlpha(0)
        LootFrame:EnableMouse(false)
    end
    local count = GetNumLootItems and GetNumLootItems() or 0
    for slot = 1, count do
        if LootSlot then LootSlot(slot) end
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(.5, function()
            if lootOpen then
                restoreLootFrame()
                status:SetText("Some materials could not be looted. Make room in your bags and collect them.")
            end
        end)
    end
    return true
end

local frame = CreateFrame("Frame", "DXMDDQFrame", UIParent, "BasicFrameTemplateWithInset")
frame:SetSize(390, 154)
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function(self)
    if not self.openedFromProfession then self:StartMoving() end
end)
frame:SetScript("OnDragStop", function(self)
    if self.openedFromProfession then return end
    self:StopMovingOrSizing()
    local point, _, relativePoint, x, y = self:GetPoint(1)
    DXMDDQDB.point, DXMDDQDB.relativePoint = point, relativePoint
    DXMDDQDB.x, DXMDDQDB.y = x, y
end)
if frame.TitleText then frame.TitleText:SetText("DDQ") end

local embeddedTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
embeddedTitle:SetPoint("TOPLEFT", 22, -18)
embeddedTitle:SetText("DDQ - Defyler's Disenchant Queue")
embeddedTitle:Hide()

local icon = CreateFrame("Button", nil, frame)
icon:SetSize(42, 42)
icon:SetPoint("TOPLEFT", 18, -42)
icon.texture = icon:CreateTexture(nil, "ARTWORK")
icon.texture:SetAllPoints()
icon.texture:SetTexture("Interface\\Icons\\INV_Enchant_Disenchant")
icon:SetScript("OnEnter", function(self)
    if not currentCandidate then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(currentCandidate.link)
    GameTooltip:Show()
end)
icon:SetScript("OnLeave", function() GameTooltip:Hide() end)

local nextLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
nextLabel:SetPoint("TOPLEFT", icon, "TOPRIGHT", 12, 0)
nextLabel:SetText("Next item")

local itemName = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
itemName:SetPoint("TOPLEFT", nextLabel, "BOTTOMLEFT", 0, -7)
itemName:SetPoint("RIGHT", frame, "RIGHT", -18, 0)
itemName:SetJustifyH("LEFT")
itemName:SetWordWrap(false)

status = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
status:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 0, -12)
status:SetPoint("RIGHT", frame, "RIGHT", -18, 0)
status:SetJustifyH("LEFT")

local action = CreateFrame("Button", "DXMDDQActionButton", frame, "SecureActionButtonTemplate,UIPanelButtonTemplate")
action:SetSize(150, 28)
action:SetPoint("BOTTOMRIGHT", -18, 14)
action:RegisterForClicks("LeftButtonUp")
action:SetAttribute("useOnKeyDown", false)
action:SetText("Disenchant")

local sessionPanel = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
sessionPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 24, -220)
sessionPanel:SetPoint("RIGHT", frame, "RIGHT", -24, 0)
sessionPanel:SetHeight(82)
sessionPanel:Hide()
local sessionTitle = sessionPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
sessionTitle:SetPoint("TOPLEFT", 14, -12)
sessionTitle:SetText("Session P&L")
local sessionSince = sessionPanel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
sessionSince:SetPoint("LEFT", sessionTitle, "RIGHT", 8, 0)
sessionSince:SetText("since reload")
sessionSummary = sessionPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
sessionSummary:SetPoint("TOPLEFT", sessionTitle, "BOTTOMLEFT", 0, -10)
sessionSummary:SetPoint("RIGHT", sessionPanel, "RIGHT", -14, 0)
sessionSummary:SetJustifyH("LEFT")
sessionDetail = sessionPanel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
sessionDetail:SetPoint("TOPLEFT", sessionSummary, "BOTTOMLEFT", 0, -7)
sessionDetail:SetPoint("RIGHT", sessionPanel, "RIGHT", -14, 0)
sessionDetail:SetJustifyH("LEFT")
refreshSessionDisplay()

local function clearAction(message)
    currentCandidate = nil
    icon.texture:SetTexture("Interface\\Icons\\INV_Enchant_Disenchant")
    itemName:SetTextColor(.65, .65, .65)
    itemName:SetText("No eligible item found")
    status:SetText(message or "Add an uncommon, rare, or epic weapon or armor item to your bags.")
    if not InCombatLockdown or not InCombatLockdown() then
        action:SetAttribute("type", nil)
        action:SetAttribute("spell", nil)
        action:SetAttribute("target-bag", nil)
        action:SetAttribute("target-slot", nil)
        action:SetAttribute("macrotext", nil)
    end
    action:Disable()
end

local function applyCandidate(candidate)
    if not candidate then clearAction(); return end
    local name = candidate.info and candidate.info.name or candidate.link
    local quality = candidate.info and candidate.info.quality or 1
    local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    currentCandidate = candidate
    icon.texture:SetTexture((candidate.info and candidate.info.icon) or "Interface\\Icons\\INV_Enchant_Disenchant")
    if color then itemName:SetTextColor(color.r, color.g, color.b) else itemName:SetTextColor(1, 1, 1) end
    itemName:SetText(name or candidate.link)
    status:SetText(("Bag %d, slot %d. One click processes this item."):format(candidate.bag, candidate.slot))
    action:SetAttribute("macrotext", nil)
    action:SetAttribute("type", "spell")
    action:SetAttribute("spell", DISENCHANT_SPELL_ID)
    action:SetAttribute("target-bag", candidate.bag)
    action:SetAttribute("target-slot", candidate.slot)
    action:Enable()
end

local function refresh()
    refreshPending = false
    if InCombatLockdown and InCombatLockdown() then
        refreshPending = true
        status:SetText("DDQ will refresh after combat.")
        action:Disable()
        return
    end
    if lootOpen then clearAction("Loot the enchanting materials to continue."); return end
    if not knowsDisenchant() then clearAction("This character does not know Disenchant."); return end
    if not spellName() then clearAction("Disenchant spell data is still loading."); return end
    applyCandidate(findCandidate())
end

action:SetScript("PostClick", function()
    if currentCandidate then
        disenchantPending = true
        pendingGeneration = pendingGeneration + 1
        local generation = pendingGeneration
        C_Timer.After(10, function()
            if generation == pendingGeneration then disenchantPending = false end
        end)
        status:SetText("Disenchanting. The next item will load after your bags update.")
        action:Disable()
    end
end)

frame:SetScript("OnShow", function()
    DXMDDQDB.shown = true
    refresh()
end)
frame:SetScript("OnHide", function()
    DXMDDQDB.shown = false
    if _G.DXMDDQProfessionTab and PanelTemplates_DeselectTab then
        PanelTemplates_DeselectTab(_G.DXMDDQProfessionTab)
    end
    frame.openedFromProfession = false
end)

local ENCHANTING_SKILL_LINE_ID = 333
local professionTab
local suspendedDefylerGeometry
local outerChromeKeys = {
    "TopLeftCorner", "TopRightCorner", "TopBorder",
    "BotLeftCorner", "BotRightCorner", "BottomBorder",
    "LeftBorder", "RightBorder", "Bg", "TitleBg",
    "TopTileStreaks", "TitleText", "CloseButton",
}

local function setEmbeddedLayer(page, professionsFrame)
    local strata = professionsFrame:GetFrameStrata() or "MEDIUM"
    local pageLevel = professionsFrame:GetFrameLevel() + 1
    page:SetFrameStrata(strata)
    page:SetFrameLevel(pageLevel)

    local chromeLevel = pageLevel + 20
    for _, key in ipairs({"NineSlice", "TitleContainer", "PortraitContainer", "CloseButton"}) do
        local region = professionsFrame[key]
        if region and region.SetFrameStrata then region:SetFrameStrata(strata) end
        if region and region.SetFrameLevel then region:SetFrameLevel(chromeLevel) end
    end
    if professionsFrame.ProfessionsOverviewTab then
        professionsFrame.ProfessionsOverviewTab:SetFrameLevel(chromeLevel + 1)
    end
    for _, nativeTab in ipairs(professionsFrame.rightProfessionTabs or {}) do
        nativeTab:SetFrameLevel(chromeLevel + 1)
    end
end

local function suspendDefylerGeometry()
    local frames = _G.DefylerUIDB and _G.DefylerUIDB.frames
    if not frames then return end
    if frames.DXMDDQFrame then
        suspendedDefylerGeometry = frames.DXMDDQFrame
        frames.DXMDDQFrame = nil
    end
end

local function restoreDefylerGeometry()
    local frames = _G.DefylerUIDB and _G.DefylerUIDB.frames
    if frames and suspendedDefylerGeometry and not frames.DXMDDQFrame then
        frames.DXMDDQFrame = suspendedDefylerGeometry
    end
    suspendedDefylerGeometry = nil
end

local function hasEnchantingProfession()
    if GetProfessions and GetProfessionInfo then
        local profession1, profession2 = GetProfessions()
        for professionSlot = 1, 2 do
            local professionIndex = professionSlot == 1 and profession1 or profession2
            if professionIndex then
                local _, _, _, _, _, _, skillLineID = GetProfessionInfo(professionIndex)
                if tonumber(skillLineID) == ENCHANTING_SKILL_LINE_ID then return true end
            end
        end
    end
    return knowsDisenchant()
end

local function setOuterChromeShown(shown)
    for _, key in ipairs(outerChromeKeys) do
        local region = frame[key]
        if region then region:SetShown(shown) end
    end
end

local function hideProfessionPages(professionsFrame)
    for _, page in ipairs(professionsFrame.Pages or {}) do page:Hide() end
    if professionsFrame.BookPage then professionsFrame.BookPage:Hide() end
    if professionsFrame.CraftingPage then professionsFrame.CraftingPage:Hide() end
end

local function restoreProfessionOverview(professionsFrame)
    if professionsFrame.SelectBookPage then
        professionsFrame:SelectBookPage()
    else
        if professionsFrame.BookPage then professionsFrame.BookPage:Show() end
        if professionsFrame.CraftingPage then professionsFrame.CraftingPage:Hide() end
    end
end

local function placeStandalone()
    restoreDefylerGeometry()
    frame:SetParent(UIParent)
    frame.openedFromProfession = false
    frame:SetMovable(true)
    frame:SetSize(390, 154)
    frame:SetFrameStrata("DIALOG")
    frame:ClearAllPoints()
    frame:SetPoint(DXMDDQDB.point or "CENTER", UIParent, DXMDDQDB.relativePoint or "CENTER", tonumber(DXMDDQDB.x) or 0, tonumber(DXMDDQDB.y) or 0)
    setOuterChromeShown(true)
    embeddedTitle:Hide()
    sessionPanel:Hide()
    if frame.DefylerUIResizeGrip then frame.DefylerUIResizeGrip:Show() end
    if frame.DefylerUITitleHandle then frame.DefylerUITitleHandle:Show() end
    if frame.InsetBg then
        frame.InsetBg:ClearAllPoints()
        frame.InsetBg:SetPoint("TOPLEFT", 4, -24)
        frame.InsetBg:SetPoint("BOTTOMRIGHT", -6, 4)
    end
    icon:ClearAllPoints()
    icon:SetPoint("TOPLEFT", 18, -42)
    action:ClearAllPoints()
    action:SetPoint("BOTTOMRIGHT", -18, 14)
end

local function showStandalone()
    placeStandalone()
    frame:Show()
end

local function placeInProfessions(professionsFrame)
    suspendDefylerGeometry()
    frame:SetParent(professionsFrame)
    frame.openedFromProfession = true
    frame:SetMovable(false)
    frame:SetScale(1)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", professionsFrame, "TOPLEFT", 3, -21)
    frame:SetPoint("BOTTOMRIGHT", professionsFrame, "BOTTOMRIGHT", -3, 3)
    setEmbeddedLayer(frame, professionsFrame)
    setOuterChromeShown(false)
    embeddedTitle:ClearAllPoints()
    embeddedTitle:SetPoint("TOPLEFT", frame, "TOPLEFT", 30, -48)
    embeddedTitle:Show()
    sessionPanel:Show()
    if frame.DefylerUIResizeGrip then frame.DefylerUIResizeGrip:Hide() end
    if frame.DefylerUITitleHandle then frame.DefylerUITitleHandle:Hide() end
    if frame.InsetBg then
        frame.InsetBg:ClearAllPoints()
        frame.InsetBg:SetAllPoints(frame)
    end
    icon:ClearAllPoints()
    icon:SetPoint("TOPLEFT", 30, -88)
    action:ClearAllPoints()
    action:SetPoint("TOPLEFT", frame, "TOPLEFT", 30, -178)
end

local function updateProfessionTab()
    if not professionTab then return end
    local enabled = hasEnchantingProfession()
    professionTab:SetEnabled(enabled)
    professionTab:SetAlpha(enabled and 1 or .45)
    if not enabled and frame.openedFromProfession then frame:Hide() end
end

local function ensureProfessionTab()
    local professionsFrame = _G.ProfessionsFrame
    if not professionsFrame then return end

    if not professionTab then
        professionTab = CreateFrame("Button", "DXMDDQProfessionTab", professionsFrame, "PanelTabButtonTemplate")
        professionTab:SetText("DDQ")
        professionTab:SetFrameStrata("DIALOG")
        professionTab:SetFrameLevel(math.max(professionsFrame:GetFrameLevel() + 210, 510))
        if PanelTemplates_TabResize then PanelTemplates_TabResize(professionTab, 12) end
        if PanelTemplates_DeselectTab then PanelTemplates_DeselectTab(professionTab) end
        professionTab:SetScript("OnClick", function()
            if not hasEnchantingProfession() then return end
            if frame:IsShown() and frame.openedFromProfession then
                frame:Hide()
                restoreProfessionOverview(professionsFrame)
                return
            end
            if _G.DXMProfessionProfitFrame then _G.DXMProfessionProfitFrame:Hide() end
            if _G.DXMProfessionTab and PanelTemplates_DeselectTab then PanelTemplates_DeselectTab(_G.DXMProfessionTab) end
            hideProfessionPages(professionsFrame)
            placeInProfessions(professionsFrame)
            frame:Show()
            if frame.Raise then frame:Raise() end
            if PanelTemplates_SelectTab then PanelTemplates_SelectTab(professionTab) end
        end)
        professionTab:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            if hasEnchantingProfession() then
                GameTooltip:SetText("DDQ - Defyler's Disenchant Queue")
                GameTooltip:AddLine("Disenchant the next eligible item in your bags.", 1, 1, 1, true)
            else
                GameTooltip:SetText("DDQ - Defyler's Disenchant Queue", 1, .82, 0)
                GameTooltip:AddLine("Requires the Enchanting profession.", 1, 1, 1, true)
            end
            GameTooltip:Show()
        end)
        professionTab:SetScript("OnLeave", function() GameTooltip:Hide() end)
        professionsFrame:HookScript("OnHide", function()
            if frame:GetParent() == professionsFrame then
                frame:Hide()
                restoreProfessionOverview(professionsFrame)
            end
        end)
        if EventRegistry and EventRegistry.RegisterCallback then
            EventRegistry:RegisterCallback("ProfessionsFrame.TabSet", function()
                if frame.openedFromProfession then frame:Hide() end
            end, professionTab)
        end
        if _G.DXMProfessionTab then
            _G.DXMProfessionTab:HookScript("OnClick", function()
                if frame.openedFromProfession then frame:Hide() end
            end)
        end
        local function leaveDDQPage()
            if frame.openedFromProfession then frame:Hide() end
        end
        if professionsFrame.ProfessionsOverviewTab then professionsFrame.ProfessionsOverviewTab:HookScript("OnMouseUp", leaveDDQPage) end
        for _, nativeTab in ipairs(professionsFrame.rightProfessionTabs or {}) do nativeTab:HookScript("OnMouseUp", leaveDDQPage) end
    end

    professionTab:ClearAllPoints()
    if _G.DXMProfessionTab then
        professionTab:SetPoint("LEFT", _G.DXMProfessionTab, "RIGHT", -8, 0)
    else
        professionTab:SetPoint("TOPLEFT", professionsFrame, "BOTTOMLEFT", 92, 4)
    end
    professionTab:Show()
    updateProfessionTab()
end

local events = CreateFrame("Frame")
for _, event in ipairs({"PLAYER_LOGIN", "ADDON_LOADED", "TRADE_SKILL_SHOW", "SKILL_LINES_CHANGED", "SPELLS_CHANGED", "BAG_UPDATE_DELAYED", "GET_ITEM_INFO_RECEIVED", "PLAYER_REGEN_ENABLED", "LOOT_OPENED", "LOOT_CLOSED", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED"}) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event, unit, _, spellID)
    if event == "PLAYER_LOGIN" then
        placeStandalone()
        frame:Hide()
        C_Timer.After(0, ensureProfessionTab)
        refresh()
    elseif event == "ADDON_LOADED" then
        if unit == "Blizzard_Professions" then C_Timer.After(0, ensureProfessionTab) end
    elseif event == "TRADE_SKILL_SHOW" or event == "SKILL_LINES_CHANGED" or event == "SPELLS_CHANGED" then
        C_Timer.After(0, function()
            ensureProfessionTab()
            updateProfessionTab()
            refresh()
        end)
    elseif event == "LOOT_OPENED" then
        lootOpen = true
        if collectDisenchantLoot() then
            status:SetText("Collecting disenchant materials...")
        else
            refresh()
        end
    elseif event == "LOOT_CLOSED" then
        lootOpen = false
        restoreLootFrame()
        C_Timer.After(0, refresh)
    elseif event == "PLAYER_REGEN_ENABLED" then
        if refreshPending then refresh() end
    elseif (event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED") and unit == "player" and tonumber(spellID) == DISENCHANT_SPELL_ID then
        disenchantPending = false
        pendingGeneration = pendingGeneration + 1
        C_Timer.After(0, refresh)
    else
        C_Timer.After(0, refresh)
    end
end)

SLASH_DXMDDQ1 = "/ddq"
SLASH_DXMDDQ2 = "/dxmddq"
SlashCmdList.DXMDDQ = function()
    if frame:IsShown() then frame:Hide() else showStandalone() end
end

DXMDDQ = {
    Refresh = refresh,
    Show = showStandalone,
    Hide = function() frame:Hide() end,
    FindCandidate = findCandidate,
    RecordDisenchantResult = recordSessionResult,
}
