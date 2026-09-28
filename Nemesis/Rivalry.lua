local N = Nemesis

local function mine(guid,flags)
    local playerGUID=UnitGUID("player")
    if guid and guid==playerGUID then return true end
    local affiliation=_G.COMBATLOG_OBJECT_AFFILIATION_MINE
    return affiliation and flags and bit and bit.band(flags,affiliation)~=0
end

function N:OnCombatLogEvent()
    if not self.db then return end
    local _,subevent,_,sourceGUID,sourceName,sourceFlags,_,destGUID,destName=CombatLogGetCurrentEventInfo()
    if subevent~="PARTY_KILL" then return end
    local playerGUID=UnitGUID("player")
    local entry,key
    if mine(sourceGUID,sourceFlags) and destGUID~=playerGUID then
        entry,key=self:GetEntryByCombatant(destName,destGUID)
        if entry then entry.kills=(tonumber(entry.kills) or 0)+1; entry.lastSeen=self:Now(); entry.lastZone=self:Zone(); self:Print(("You defeated %s. Rivalry: %d-%d."):format(entry.name,entry.kills,entry.deaths or 0)) end
    elseif destGUID==playerGUID then
        entry,key=self:GetEntryByCombatant(sourceName,sourceGUID)
        if entry then entry.deaths=(tonumber(entry.deaths) or 0)+1; entry.lastSeen=self:Now(); entry.lastZone=self:Zone(); self:Print(("%s defeated you. Rivalry: %d-%d."):format(entry.name,entry.kills or 0,entry.deaths)) end
    end
    if entry and self.RefreshUI then self:RefreshUI(key) end
end
