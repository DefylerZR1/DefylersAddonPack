local N = Nemesis

local function mine(flags)
    local affiliation=_G.COMBATLOG_OBJECT_AFFILIATION_MINE
    return affiliation and flags and bit and bit.band(flags,affiliation)~=0
end

function N:OnCombatLogEvent()
    if not self.db then return end
    local _,subevent,_,_,sourceName,sourceFlags,_,_,destName,destFlags=CombatLogGetCurrentEventInfo()
    if subevent~="PARTY_KILL" then return end
    local entry,key
    if mine(sourceFlags) and not mine(destFlags) then
        entry,key=self:GetEntryByCombatant(destName)
        if entry then entry.kills=(tonumber(entry.kills) or 0)+1; entry.lastSeen=self:Now(); entry.lastZone=self:Zone(); self:Print(("You defeated %s. Rivalry: %d-%d."):format(entry.name,entry.kills,entry.deaths or 0)) end
    elseif mine(destFlags) and not mine(sourceFlags) then
        entry,key=self:GetEntryByCombatant(sourceName)
        if entry then entry.deaths=(tonumber(entry.deaths) or 0)+1; entry.lastSeen=self:Now(); entry.lastZone=self:Zone(); self:Print(("%s defeated you. Rivalry: %d-%d."):format(entry.name,entry.kills or 0,entry.deaths)) end
    end
    if entry and self.RefreshUI then self:RefreshUI(key) end
end
