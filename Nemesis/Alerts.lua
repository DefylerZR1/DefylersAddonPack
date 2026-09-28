local N = Nemesis

function N:PlayAlert(entry)
    if not self.db.settings.soundsEnabled or entry.sound == false then return end
    local path = self.MEDIA .. "Sounds\\nemesis_alert.wav"
    pcall(PlaySoundFile, path, self.db.settings.soundChannel or "Master")
end

function N:ShowAlert(entry, name, realm)
    if not self.db.settings.messagesEnabled then return end
    local displayName = entry.displayName or entry.name or name or "Unknown"
    local message = ("NEMESIS DETECTED: %s"):format(displayName)
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, message, ChatTypeInfo and ChatTypeInfo["RAID_WARNING"] or {r=1,g=.1,b=.1})
    elseif UIErrorsFrame then UIErrorsFrame:AddMessage(message, 1, .1, .1, 1) end
    self:Print(message)
end

function N:TriggerEncounter(entry, key, name, realm, guid)
    local now = self:Now()
    local identity = guid or key
    local last = self.lastAlerts[identity] or 0
    local reset = tonumber(self.db.settings.encounterReset) or 120
    local previousSeen = tonumber(entry.lastSeen) or 0
    local newEncounter = not self.acknowledgedKeys[key] and (previousSeen == 0 or now - previousSeen >= reset)
    if newEncounter then
        entry.encounters = (tonumber(entry.encounters) or 0) + 1
    end
    if not entry.firstSeen or entry.firstSeen == 0 then entry.firstSeen = now end
    entry.lastSeen, entry.lastZone, entry.guid = now, self:Zone(), guid or entry.guid
    local cooldown = tonumber(entry.alertCooldown) or tonumber(self.db.settings.alertCooldown) or 30
    if newEncounter and now - last >= cooldown then
        self.lastAlerts[identity] = now
        self:PlayAlert(entry)
        self:ShowAlert(entry, name, realm)
    end
    if self.RefreshUI then self:RefreshUI() end
end

function N:TestAlert()
    local dummy = {name="Test Nemesis", realm="Current Realm", sound=true}
    self:PlayAlert(dummy)
    self:ShowAlert(dummy, dummy.name, dummy.realm)
end
