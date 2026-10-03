local N = Nemesis

function N:ObserveUnit(unit, hasNameplate)
    if not self.db or not self.db.settings.enabled then return end
    local entry, key, name, realm = self:GetEntryByUnit(unit)
    if not entry then
        if hasNameplate then self:RemoveUnit(unit) end
        return
    end
    self:ShowMarkerPrompt(unit, entry, key)
    self:TriggerEncounter(entry, key, name, realm)
end

function N:ReconcileUnits()
    if not self.db or not self.db.settings.enabled then return end
    for _, unit in ipairs({"target", "focus", "mouseover"}) do self:ObserveUnit(unit, false) end
    for index=1, 40 do
        local unit = "nameplate" .. index
        if UnitExists(unit) then self:ObserveUnit(unit, true) end
    end
    for index=1, 4 do if UnitExists("party"..index) then self:ObserveUnit("party"..index, false) end end
    for index=1, 40 do if UnitExists("raid"..index) then self:ObserveUnit("raid"..index, false) end end
    local now = self:Now()
    for key, state in pairs(self.activeKeys) do
        local entry = self.db.entries[key]
        if not entry or now - (tonumber(entry.lastSeen) or 0) > 1 then self:RemoveUnit(state.unit) end
    end
end
