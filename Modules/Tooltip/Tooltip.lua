if not DXMCore then return end

local Module = DXMCore:Module("Tooltip")
local Const = DXMCore:Const()
Module.bootType = Const.BootType.PlayerEnteringWorld

function Module:Boot(hook)
    hook(Const.DisplayTooltip, Module.DisplayTooltip)
end

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

local function getItemKey(tip, additional, link)
    local itemKey
    if additional.event == "SetItemKey" then
        itemKey = C_AuctionHouse.MakeItemKey(additional.eventItemID, additional.eventItemLevel or 0, additional.eventItemSuffix or additional.EventItemSuffix or 0, 0)
    elseif additional.event == "SetBagItem" then
        local location = ItemLocation:CreateFromBagAndSlot(additional.eventContainer, additional.eventIndex)
        itemKey = C_AuctionHouse.GetItemKeyFromItem(location)
    elseif additional.event == "SetInventoryItem" and additional.eventUnit == "player" then
        local location = ItemLocation:CreateFromEquipmentSlot(additional.eventIndex)
        itemKey = C_AuctionHouse.GetItemKeyFromItem(location)
    elseif tip.GetOwner then
        local owner = tip:GetOwner()
        if owner and owner.GetItemKey then
            itemKey = owner:GetItemKey()
        elseif owner and owner.GetItemLocation then
            local location = owner:GetItemLocation()
            if location then itemKey = C_AuctionHouse.GetItemKeyFromItem(location) end
        end
    end
    if not itemKey and link then itemKey = DXMCore:ItemKeyFromLink(link) end
    return itemKey
end

local function addNativeLine(tip, left, right)
    tip:AddDoubleLine(left, right, 0.25, 0.8, 1, 1, 1, 1)
end

local function displayNativeTooltip(tip, data)
    if not tip or not data then return end
    local link = data.hyperlink
    if not link and tip.GetItem then
        local _, itemLink = tip:GetItem()
        link = itemLink
    end
    -- Bag and equipment tooltips can expose an ItemLocation through their
    -- owner. Prefer that Auction House key because Classic item links carry
    -- the raw random-property suffix while AH history uses its normalized
    -- suffix identity.
    local itemKey = getItemKey(tip, {}, link)
    if not itemKey then return end
    local key = DXMCore:ItemKeyKey(itemKey)
    if not key then return end

    local prices = DXMPriceSummary.Get(itemKey)
    local function value(price)
        return price and ("|cff20ff20" .. money(price) .. "|r") or "No data"
    end
    local age = ""
    if prices.capturedAt then
        local seconds = math.max(0, GetServerTime() - prices.capturedAt)
        age = seconds < 60 and "just now" or seconds < 3600 and (math.floor(seconds / 60) .. "m ago")
            or seconds < 86400 and (math.floor(seconds / 3600) .. "h ago") or (math.floor(seconds / 86400) .. "d ago")
    end

    addNativeLine(tip, "7-day average / unit", value(prices.average7))
    addNativeLine(tip, "24-hour average / unit", value(prices.average24))
    addNativeLine(tip, "Latest / unit" .. (age ~= "" and (" (" .. age .. ")") or ""), value(prices.latest))
    if DXMSalvage and itemKey.itemID then
        local canDisenchant = DXMSalvage.CanDisenchant and DXMSalvage.CanDisenchant(itemKey.itemID)
        if canDisenchant then
            local salvage, _, missing = DXMSalvage.Value(itemKey.itemID, true)
            local salvageText = salvage and ("|cff20ff20" .. money(salvage) .. "|r")
                or ("|cffaaaaaa" .. (missing or "No material price data") .. "|r")
            addNativeLine(tip, "Salvager value / unit", salvageText)
        end
    end
    if IsShiftKeyDown() then
        if prices.excluded and prices.excluded > 0 then
            tip:AddLine(("Excluded %d listings above 200%% of fair average"):format(prices.excluded), 0.25, 0.8, 1)
        end
        tip:AddLine(("Observed minimum prices: %d samples / 7d, %d / 24h"):format(prices.count7, prices.count24), 0.25, 0.8, 1)
        tip:AddLine("Latest source: " .. (prices.source or "none"), 0.25, 0.8, 1)
    end
end

function Module:DisplayTooltip(kind, tooltip, tip, ...)
    if DXMConfig and DXMConfig.showTooltips == false then return end
    local mode, nativeData = ...
    if kind == "item" and mode == "native" then
        displayNativeTooltip(tip, nativeData)
        return
    end
    local link, quantity
    if kind == "item" then
        _, quantity, _, link = ...
    elseif kind == "battlepet" then
        link, quantity = ...
    else
        return
    end

    tooltip:SetFrame(tip)
    local itemKey = getItemKey(tip, tooltip:GetExtra(), link)
    if not itemKey then tooltip:ClearFrame(tip) return end
    local key = DXMCore:ItemKeyKey(itemKey)
    if not key then tooltip:ClearFrame(tip) return end

    local prices = DXMPriceSummary.Get(itemKey)
    local function value(price)
        return price and ("|cff20ff20" .. money(price) .. "|r") or "No data"
    end
    local age = ""
    if prices.capturedAt then
        local seconds = math.max(0, GetServerTime() - prices.capturedAt)
        age = seconds < 60 and "just now" or seconds < 3600 and (math.floor(seconds / 60) .. "m ago")
            or seconds < 86400 and (math.floor(seconds / 3600) .. "h ago") or (math.floor(seconds / 86400) .. "d ago")
    end

    tooltip:SetColor(0.25, 0.8, 1)
    tooltip:SetMoneyAsText(true)
    tooltip:SetEmbed(true)
    tooltip:AddLine("7-day average / unit", value(prices.average7))
    tooltip:AddLine("24-hour average / unit", value(prices.average24))
    tooltip:AddLine("Latest / unit" .. (age ~= "" and (" (" .. age .. ")") or ""), value(prices.latest))
    if DXMSalvage and itemKey.itemID then
        local canDisenchant = DXMSalvage.CanDisenchant and DXMSalvage.CanDisenchant(itemKey.itemID)
        if canDisenchant then
            local salvage, _, missing = DXMSalvage.Value(itemKey.itemID, true)
            local salvageText = salvage and ("|cff20ff20" .. money(salvage) .. "|r")
                or ("|cffaaaaaa" .. (missing or "No material price data") .. "|r")
            tooltip:AddLine("Salvager value / unit", salvageText)
        end
    end
    if IsShiftKeyDown() then
        if prices.excluded and prices.excluded>0 then tooltip:AddLine(("Excluded %d listings above 200%% of fair average"):format(prices.excluded)) end
        tooltip:AddLine(("Observed minimum prices: %d samples / 7d, %d / 24h"):format(prices.count7, prices.count24))
        tooltip:AddLine("Latest source: " .. (prices.source or "none"))
    end
    tooltip:ClearFrame(tip)
end
