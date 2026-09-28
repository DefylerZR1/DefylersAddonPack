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

function Module:DisplayTooltip(kind, tooltip, tip, ...)
    if DXMConfig and DXMConfig.showTooltips == false then return end
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
        local salvage = DXMSalvage.Value(itemKey.itemID)
        if salvage then tooltip:AddLine("Salvage value", "|cff20ff20" .. money(salvage) .. "|r") end
    end
    if IsShiftKeyDown() then
        if prices.excluded and prices.excluded>0 then tooltip:AddLine(("Excluded %d listings above 200%% of fair average"):format(prices.excluded)) end
        tooltip:AddLine(("Observed minimum prices: %d samples / 7d, %d / 24h"):format(prices.count7, prices.count24))
        tooltip:AddLine("Latest source: " .. (prices.source or "none"))
    end
    tooltip:ClearFrame(tip)
end
