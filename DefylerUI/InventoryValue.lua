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

local summary={total=0,auction=0,vendor=0,disenchant=0,missing=0,pending=0,fallback=0,units=0}
local queued,priceRefreshRegistered=false,false
local listeners={}

DefylerUIInventoryValue={}
function DefylerUIInventoryValue.GetSummary() return summary end
function DefylerUIInventoryValue.FormatMoney(value) return money(value) end
function DefylerUIInventoryValue.RegisterRefresh(callback)
    if type(callback)=="function" then listeners[#listeners+1]=callback end
end

local function refresh()
    queued=false
    summary=estimate()
    for _,callback in ipairs(listeners) do pcall(callback,summary) end
end
local function schedule()
    if queued then return end
    queued=true
    C_Timer.After(.2,refresh)
end
local function registerPriceRefresh()
    if priceRefreshRegistered or not DXMPriceSummary or not DXMPriceSummary.RegisterRefresh then return end
    DXMPriceSummary.RegisterRefresh(schedule)
    priceRefreshRegistered=true
end
local events=CreateFrame("Frame")
for _,event in ipairs({"PLAYER_LOGIN","ADDON_LOADED","BAG_UPDATE_DELAYED","GET_ITEM_INFO_RECEIVED"}) do events:RegisterEvent(event) end
events:SetScript("OnEvent",function(_,event)
    registerPriceRefresh()
    if event~="GET_ITEM_INFO_RECEIVED" or summary.pending>0 then schedule() end
end)
