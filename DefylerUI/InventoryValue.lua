-- Read-only inventory estimate. Never modify native bag routing or item buttons.
local function positive(value)
    value=tonumber(value)
    return value and value>0 and value or nil
end
local function itemValue(auctionable, prices, vendor, salvage)
    if auctionable and prices then
        local price=positive(prices.latest) or positive(prices.average24) or positive(prices.average7)
        if price then return price,"auction" end
    end
    vendor=math.max(0,tonumber(vendor) or 0)
    salvage=positive(salvage) or 0
    return math.max(vendor,salvage),salvage>vendor and "disenchant" or "vendor"
end
local function money(value)
    value=math.floor((tonumber(value) or 0)+.5)
    return ("%dg %02ds %02dc"):format(math.floor(value/10000),math.floor(value/100)%100,value%100)
end
local function estimate()
    local result={total=0,auction=0,vendor=0,disenchant=0,missing=0,pending=0,fallback=0,units=0}
    local cache={}
    for bag=0,(Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag or 5) do
        for slot=1,(C_Container.GetContainerNumSlots(bag) or 0) do
            local item=C_Container.GetContainerItemInfo(bag,slot)
            if item and item.itemID then
                local count=tonumber(item.stackCount) or 1
                result.units=result.units+count
                local name,_,_,_,_,_,_,_,_,_,vendor=C_Item.GetItemInfo(item.hyperlink or item.itemID)
                if not name then
                    result.pending=result.pending+count
                else
                    local location=ItemLocation:CreateFromBagAndSlot(bag,slot)
                    local ok,auctionable=pcall(C_AuctionHouse.IsSellItemValid,location,false)
                    -- If eligibility cannot be checked, do not assume auctionability.
                    auctionable=ok and auctionable==true
                    local key=C_AuctionHouse.GetItemKeyFromItem(location)
                    local identity=key and DXMCore and DXMCore:ItemKeyKey(key)
                    local cacheKey=tostring(identity or item.hyperlink or item.itemID)..":"..tostring(auctionable)
                    local entry=cache[cacheKey]
                    if not entry then
                        local prices=auctionable and key and DXMPriceSummary and DXMPriceSummary.Get(key) or nil
                        local salvage=DXMSalvage and DXMSalvage.Value(item.itemID) or nil
                        local value,kind=itemValue(auctionable,prices,vendor,salvage)
                        entry={value=value,kind=kind,missingAuction=auctionable and kind~="auction",eligibilityUnknown=not ok}
                        cache[cacheKey]=entry
                    end
                    local value=entry.value*count
                    result.total=result.total+value
                    result[entry.kind]=result[entry.kind]+value
                    if entry.missingAuction or entry.eligibilityUnknown then result.fallback=result.fallback+count end
                    if entry.value==0 then result.missing=result.missing+count end
                end
            end
        end
    end
    return result
end

local footer,label,summary,queued
local function tooltip()
    if not footer or not summary then return end
    GameTooltip:SetOwner(footer,"ANCHOR_TOPLEFT")
    GameTooltip:AddLine("Estimated inventory value",1,.82,0)
    GameTooltip:AddDoubleLine("Auction estimate",money(summary.auction),1,1,1,1,1,1)
    GameTooltip:AddDoubleLine("Vendor fallback",money(summary.vendor),1,1,1,1,1,1)
    GameTooltip:AddDoubleLine("Disenchant fallback",money(summary.disenchant),1,1,1,1,1,1)
    GameTooltip:AddLine("Backpack, carried bags and reagent bag. Excludes equipped items, bank and wallet.",.75,.75,.75,true)
    GameTooltip:AddLine("Auction values use latest filtered DXM unit prices, then 24-hour/7-day averages. Gross estimates before fees; not guaranteed sale proceeds.",.75,.75,.75,true)
    GameTooltip:AddLine("Non-auctionable items use the higher vendor or estimated disenchant value. Disenchant value assumes the item can be disenchanted and suitable skill is available.",.75,.75,.75,true)
    if summary.fallback>0 then GameTooltip:AddLine(summary.fallback.." units lack auction pricing or confirmed eligibility; fallback used.",1,.65,.2,true) end
    if summary.missing>0 then GameTooltip:AddLine(summary.missing.." units have no positive value estimate.",1,.65,.2,true) end
    if summary.pending>0 then GameTooltip:AddLine(summary.pending.." units are waiting for item data.",1,.65,.2,true) end
    GameTooltip:Show()
end
local function layoutFooter()
    local bag=ContainerFrameCombinedBags
    -- MoneyFrame spans the full row; the native coin controls occupy its right side.
    footer:ClearAllPoints()
    footer:SetPoint("LEFT",bag.MoneyFrame,"LEFT",6,0)
    footer:SetWidth(math.max(1,bag.MoneyFrame:GetWidth()-186))
    footer:SetFrameLevel(bag.MoneyFrame:GetFrameLevel()+2)
end
local function refresh()
    queued=false
    if not footer or not footer:IsShown() then return end
    layoutFooter()
    summary=estimate()
    local incomplete=summary.missing+summary.pending+summary.fallback>0
    label:SetText("Estimated inventory value: |cffffffff"..money(summary.total)..(incomplete and " *" or "").."|r")
    if footer:IsMouseOver() then tooltip() end
end
local function schedule()
    if queued or not footer or not footer:IsShown() then return end
    queued=true
    C_Timer.After(.2,refresh)
end
local function attach()
    if footer or (InCombatLockdown and InCombatLockdown()) then return end
    local bag=ContainerFrameCombinedBags
    if not bag or not bag.MoneyFrame then return end
    footer=CreateFrame("Frame",nil,bag)
    footer:SetHeight(18)
    layoutFooter()
    footer:EnableMouse(true)
    label=footer:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    label:SetAllPoints();label:SetJustifyH("LEFT");label:SetWordWrap(false)
    footer:SetScript("OnEnter",tooltip)
    footer:SetScript("OnLeave",function() GameTooltip:Hide() end)
    footer:SetScript("OnShow",function() layoutFooter();schedule() end)
    bag.MoneyFrame:HookScript("OnSizeChanged",function() layoutFooter() end)
    local elapsed=0
    footer:SetScript("OnUpdate",function(_,delta)
        elapsed=elapsed+delta
        if elapsed>=10 then elapsed=0;schedule() end
    end)
    schedule()
end
local events=CreateFrame("Frame")
for _,event in ipairs({"PLAYER_LOGIN","ADDON_LOADED","PLAYER_REGEN_ENABLED","BAG_UPDATE_DELAYED","GET_ITEM_INFO_RECEIVED"}) do events:RegisterEvent(event) end
events:SetScript("OnEvent",function(_,event)
    attach()
    if event~="GET_ITEM_INFO_RECEIVED" or (summary and summary.pending>0) then schedule() end
end)
