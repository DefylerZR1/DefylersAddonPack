if not DXMCore then return end

local Module = DXMCore:Module("DisenchantTracker")
local Const = DXMCore.Const()
Module.bootType = Const.BootType.PlayerEnteringWorld

local DISENCHANT_SPELL_ID = 13262
local target
local completed

local function now() return GetServerTime and GetServerTime() or time() end
local function itemID(link)
    local getter=C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
    return link and ((getter and tonumber((getter(link)))) or tonumber(link:match("item:(%d+)"))) or nil
end
local function marketData()
    DXMData = DXMData or {}
    DXMData.DisenchantSamples = DXMData.DisenchantSamples or {version=1,markets={}}
    DXMData.DisenchantSamples.markets = DXMData.DisenchantSamples.markets or {}
    local identity = DXMCore:MarketIdentity()
    local data = DXMData.DisenchantSamples.markets[identity.key]
    if not data then
        data={items={},totalAttempts=0,lastRecordedAt=0}
        DXMData.DisenchantSamples.markets[identity.key]=data
    end
    data.items=data.items or {}
    return data
end
local function remember(link)
    if not link then return end
    target={link=link,itemID=itemID(link),targetedAt=GetTime()}
end
local function containerLink(bag,slot)
    if C_Container and C_Container.GetContainerItemLink then return C_Container.GetContainerItemLink(bag,slot) end
    if GetContainerItemLink then return GetContainerItemLink(bag,slot) end
end
local function installHooks()
    if Module.hooksInstalled then return end
    Module.hooksInstalled=true
    if C_Container and C_Container.PickupContainerItem then
        hooksecurefunc(C_Container,"PickupContainerItem",function(bag,slot) remember(containerLink(bag,slot)) end)
    end
    if C_Container and C_Container.UseContainerItem then
        hooksecurefunc(C_Container,"UseContainerItem",function(bag,slot) remember(containerLink(bag,slot)) end)
    elseif UseContainerItem then
        hooksecurefunc("UseContainerItem",function(bag,slot) remember(containerLink(bag,slot)) end)
    end
    if PickupInventoryItem then
        hooksecurefunc("PickupInventoryItem",function(slot) remember(GetInventoryItemLink("player",slot)) end)
    end
    if SpellTargetItem then
        hooksecurefunc("SpellTargetItem",function(value)
            local _,link=C_Item.GetItemInfo(value); remember(link)
        end)
    end
    if UseItemByName then
        hooksecurefunc("UseItemByName",function(value)
            local _,link=C_Item.GetItemInfo(value); remember(link)
        end)
    end
end
local function record(outputs)
    if not completed or not completed.itemID or not next(outputs) then return end
    local data=marketData()
    local key=tostring(completed.itemID)
    local sample=data.items[key]
    if not sample then sample={itemID=completed.itemID,itemLink=completed.link,attempts=0,outputs={}};data.items[key]=sample end
    sample.itemLink=completed.link or sample.itemLink
    sample.attempts=(tonumber(sample.attempts) or 0)+1
    sample.lastRecordedAt=now()
    sample.outputs=sample.outputs or {}
    for outputID,quantity in pairs(outputs) do
        local output=sample.outputs[tostring(outputID)] or {itemID=outputID,total=0,events=0}
        output.total=(tonumber(output.total) or 0)+quantity
        output.events=(tonumber(output.events) or 0)+1
        sample.outputs[tostring(outputID)]=output
    end
    data.totalAttempts=(tonumber(data.totalAttempts) or 0)+1
    data.lastRecordedAt=sample.lastRecordedAt
    local ledgerRow
    if DXMLedger and DXMLedger.RecordDisenchant then
        ledgerRow=DXMLedger:RecordDisenchant(completed.itemID,completed.link,outputs)
    end
    if DXMDDQ and DXMDDQ.RecordDisenchantResult then
        pcall(DXMDDQ.RecordDisenchantResult,ledgerRow,outputs)
    end
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(("|cffffd100DXM:|r Recorded disenchant #%d for %s."):format(sample.attempts,sample.itemLink or ("item "..sample.itemID)))
    end
end

local events=CreateFrame("Frame")
for _,event in ipairs({"PLAYER_ENTERING_WORLD","UNIT_SPELLCAST_SUCCEEDED","UNIT_SPELLCAST_FAILED","UNIT_SPELLCAST_INTERRUPTED","LOOT_OPENED","LOOT_CLOSED"}) do events:RegisterEvent(event) end
events:SetScript("OnEvent",function(_,event,...)
    if event=="PLAYER_ENTERING_WORLD" then
        installHooks()
    elseif event=="UNIT_SPELLCAST_SUCCEEDED" then
        local unit,castGUID,spellID=...
        spellID=tonumber(spellID)
        if unit=="player" and spellID==DISENCHANT_SPELL_ID and target and GetTime()-(target.targetedAt or 0)<10 then
            completed=target
            completed.completedAt=GetTime()
            target=nil
        end
    elseif event=="UNIT_SPELLCAST_FAILED" or event=="UNIT_SPELLCAST_INTERRUPTED" then
        local unit,castGUID,spellID=...
        if unit=="player" and tonumber(spellID)==DISENCHANT_SPELL_ID then target=nil;completed=nil end
    elseif event=="LOOT_OPENED" then
        if not completed or GetTime()-(completed.completedAt or 0)>10 then return end
        local outputs={}
        for slot=1,(GetNumLootItems and GetNumLootItems() or 0) do
            if not GetLootSlotType or GetLootSlotType(slot)==LOOT_SLOT_ITEM then
                local link=GetLootSlotLink and GetLootSlotLink(slot)
                local id=itemID(link)
                if id then
                    local _,_,quantity=GetLootSlotInfo(slot)
                    outputs[id]=(outputs[id] or 0)+math.max(1,tonumber(quantity) or 1)
                end
            end
        end
        record(outputs)
        completed=nil
    elseif event=="LOOT_CLOSED" then
        if completed and GetTime()-(completed.completedAt or 0)>10 then completed=nil end
    end
end)

DXMSalvageObservations={
    Get=function(sourceItemID)
        local data=marketData()
        return data.items[tostring(tonumber(sourceItemID) or "")]
    end,
    Summary=function()
        local data=marketData()
        local itemTypes=0
        for _ in pairs(data.items) do itemTypes=itemTypes+1 end
        return tonumber(data.totalAttempts) or 0,itemTypes,tonumber(data.lastRecordedAt) or 0
    end,
}
