if not DXMCore or not DXMShopping then return end

local panel, status, withdraw
local bankOpen = false

local function bankBags()
    local bags = {}
    if C_Bank and C_Bank.FetchNumPurchasedBankTabs and Enum and Enum.BankType then
        local base = tonumber(NUM_TOTAL_EQUIPPED_BAG_SLOTS) or tonumber(NUM_BAG_SLOTS) or 4
        local count = C_Bank.FetchNumPurchasedBankTabs(Enum.BankType.Character) or 0
        for index = 1, count do bags[#bags + 1] = base + index end
    else
        if BANK_CONTAINER then bags[#bags + 1] = BANK_CONTAINER end
        local base = tonumber(NUM_BAG_SLOTS) or 4
        local count = GetNumBankSlots and GetNumBankSlots() or 0
        for index = 1, count do bags[#bags + 1] = base + index end
    end
    return bags
end

local function freeBagSlot()
    local last = tonumber(NUM_TOTAL_EQUIPPED_BAG_SLOTS) or tonumber(NUM_BAG_SLOTS) or 4
    for bag = 0, last do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            if not C_Container.GetContainerItemInfo(bag, slot) then return bag, slot end
        end
    end
end

local function queuedWithdrawals()
    local list, types, units = DXMShopping:GetRows(false), 0, 0
    for _, item in ipairs(list) do
        if item.withdraw and item.withdraw > 0 then types, units = types + 1, units + item.withdraw end
    end
    return list, types, units
end

local function refresh()
    if not panel then return end
    local _, types, units = queuedWithdrawals()
    if not bankOpen or units <= 0 then
        withdraw:SetEnabled(false)
        panel:Hide()
        return
    end
    status:SetText(("%d material types and %d units are available for the crafting queue."):format(types, units))
    withdraw:SetEnabled(true)
    panel:Show()
end

local function withdrawNeeded()
    if not bankOpen then return end
    local list = queuedWithdrawals()
    local moved, failed = 0, 0
    local containers = bankBags()
    for _, item in ipairs(list) do
        local need = item.withdraw or 0
        if need > 0 then
            for _, bag in ipairs(containers) do
                local slots = C_Container.GetContainerNumSlots(bag) or 0
                for slot = 1, slots do
                    if need <= 0 then break end
                    local itemID = C_Container.GetContainerItemID(bag, slot)
                    local info = itemID == item.itemID and C_Container.GetContainerItemInfo(bag, slot) or nil
                    local count = info and (tonumber(info.stackCount) or 0) or 0
                    if count > 0 and not info.isLocked then
                        local take = math.min(need, count)
                        if take == count then
                            C_Container.UseContainerItem(bag, slot)
                            moved, need = moved + take, need - take
                        else
                            local destBag, destSlot = freeBagSlot()
                            if not destBag then failed = failed + need; need = 0; break end
                            C_Container.SplitContainerItem(bag, slot, take)
                            C_Container.PickupContainerItem(destBag, destSlot)
                            if CursorHasItem and CursorHasItem() then
                                ClearCursor()
                                failed = failed + take
                            else
                                moved, need = moved + take, need - take
                            end
                        end
                    end
                end
                if need <= 0 then break end
            end
            failed = failed + math.max(0, need)
        end
    end
    status:SetText(("Moved %d queued material units%s."):format(moved, failed > 0 and ("; " .. failed .. " could not be moved") or ""))
    C_Timer.After(.25, function() DXMShopping:Refresh(); refresh() end)
end

local function createPanel()
    if panel or not BankFrame then return end
    panel = DXMTheme:CreatePanel(BankFrame, "DXMBankCraftingFrame")
    panel:SetSize(360, 145)
    panel:SetPoint("TOPLEFT", BankFrame, "TOPRIGHT", 6, 0)
    panel:SetFrameStrata("DIALOG")
    panel:SetFrameLevel(math.max(BankFrame:GetFrameLevel() + 200, 500))
    panel:SetToplevel(true)
    panel:EnableMouse(true)
    local fill = panel:CreateTexture(nil, "BACKGROUND")
    fill:SetPoint("TOPLEFT", 4, -4); fill:SetPoint("BOTTOMRIGHT", -4, 4); fill:SetColorTexture(.025, .025, .025, 1)
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16); title:SetText("DXM Crafting Bank")
    status = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    status:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12); status:SetPoint("RIGHT", -16, 0); status:SetJustifyH("LEFT"); status:SetJustifyV("TOP")
    withdraw = DXMTheme:CreateButton(panel)
    withdraw:SetSize(165, 26); withdraw:SetPoint("BOTTOMLEFT", 16, 14); withdraw:SetText("Withdraw Needed")
    withdraw:SetScript("OnClick", withdrawNeeded)
    local clear = DXMTheme:CreateButton(panel)
    clear:SetSize(90, 26); clear:SetPoint("LEFT", withdraw, "RIGHT", 8, 0); clear:SetText("Clear Queue")
    clear:SetScript("OnClick", function() DXMShopping:ClearAll(); refresh() end)
    panel:SetScript("OnShow", function() if panel.Raise then panel:Raise() end end)
    BankFrame:HookScript("OnHide", function()
        bankOpen = false
        panel:Hide()
    end)
    panel:Hide()
end

local events = CreateFrame("Frame")
for _, event in ipairs({"ADDON_LOADED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "BAG_UPDATE_DELAYED", "PLAYERBANKSLOTS_CHANGED", "PLAYERBANKBAGSLOTS_CHANGED"}) do
    pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event)
    if event == "ADDON_LOADED" then createPanel()
    elseif event == "BANKFRAME_OPENED" then bankOpen = true; createPanel(); refresh()
    elseif event == "BANKFRAME_CLOSED" then bankOpen = false; if panel then panel:Hide() end
    elseif bankOpen then C_Timer.After(0, refresh) end
end)

