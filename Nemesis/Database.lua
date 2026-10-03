local N = Nemesis

local function isSecret(value)
    return issecretvalue and issecretvalue(value)
end

local defaults = {
    schemaVersion = 1,
    settings = {
        enabled = true, markersEnabled = true, soundsEnabled = true, messagesEnabled = true,
        defaultMarker = 8, markerSize = 38, markerOffsetX = 0, markerOffsetY = 18,
        markerColor = {r=1, g=.12, b=.12, a=1}, alertCooldown = 30,
        encounterReset = 120, soundChannel = "Master", pulse = true,
        promptPoint = "BOTTOM", promptX = 0, promptY = 165,
    },
    entries = {}, window = {point="CENTER", relativePoint="CENTER", x=0, y=0},
}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function normalizePart(value)
    return trim(value):lower():gsub("[%s']", ""):gsub("[^%w%-]", "")
end

function N:SplitCharacter(text, realmOverride)
    text = trim(text)
    local name, realm = text:match("^([^%-]+)%-(.+)$")
    name = trim(name or text)
    realm = trim(realmOverride or realm or (GetRealmName and GetRealmName()) or "")
    if name == "" then return end
    local key = normalizePart(name) .. "|" .. normalizePart(realm)
    return name, realm, key
end

function N:UnitIdentity(unit)
    local exists = UnitExists(unit)
    if isSecret(exists) or not exists then return end
    if UnitIsUnit then
        local isPlayer = UnitIsUnit(unit, "player")
        if isSecret(isPlayer) or isPlayer then return end
    end
    local name, realm
    if UnitFullName then name, realm = UnitFullName(unit) end
    if isSecret(name) or isSecret(realm) then return end
    if not name or name == "" then name = UnitName(unit) end
    if isSecret(name) then return end
    if not name then return end
    realm = realm and realm ~= "" and realm or (GetRealmName and GetRealmName()) or ""
    local _, _, key = self:SplitCharacter(name, realm)
    return name, realm, key
end

function N:InitializeDB()
    NemesisDB = type(NemesisDB) == "table" and NemesisDB or {}
    self.CopyDefaults(defaults, NemesisDB)
    self.db = NemesisDB
    self:EnsureEntryOrder()
end

function N:GetEntryByUnit(unit)
    local name, realm, key = self:UnitIdentity(unit)
    if not key then return end
    local entry = self.db.entries[key]
    if not entry then
        local wanted = {normalizePart(name), normalizePart(realm)}
        local found, foundKey
        for _, wantedName in ipairs(wanted) do
            if wantedName ~= "" then
                for candidateKey, candidate in pairs(self.db.entries) do
                    if candidateKey:match("^([^|]+)") == wantedName then
                        if found and foundKey ~= candidateKey then return end
                        found, foundKey = candidate, candidateKey
                    end
                end
                if found then break end
            end
        end
        entry, key = found, foundKey or key
    end
    if entry and entry.enabled ~= false then
        local currentRealm = (GetRealmName and GetRealmName()) or ""
        if name and realm and realm ~= "" and normalizePart(realm) ~= normalizePart(currentRealm) then
            entry.displayName = trim(name .. " " .. realm)
        elseif name and name ~= "" then
            entry.displayName = trim(name)
        end
        return entry, key, name, realm
    end
end

function N:EnsureEntryOrder()
    local used, unordered = {}, {}
    for key, entry in pairs(self.db.entries) do
        local slot = math.floor(tonumber(entry.order) or 0)
        if slot > 0 and not used[slot] then entry.order=slot; used[slot]=true else unordered[#unordered+1]={key=key,entry=entry} end
        entry.guid = nil
        entry.kills = math.max(0, math.floor(tonumber(entry.kills) or 0))
        entry.deaths = math.max(0, math.floor(tonumber(entry.deaths) or 0))
    end
    table.sort(unordered,function(a,b) return (a.entry.name or ""):lower() < (b.entry.name or ""):lower() end)
    local slot=1
    for _,item in ipairs(unordered) do while used[slot] do slot=slot+1 end; item.entry.order=slot; used[slot]=true end
end

function N:NextAvailableSlot()
    local used={}
    for _,entry in pairs(self.db.entries) do local slot=tonumber(entry.order); if slot and slot>0 then used[slot]=true end end
    local slot=1; while used[slot] do slot=slot+1 end; return slot
end

function N:AddEntry(text, realm)
    local name, normalizedRealm, key = self:SplitCharacter(text, realm)
    if not key then return nil, "Enter a character name." end
    if name:find("[/:\\]") or name:find("https?", 1, true) then return nil, "That character name is not valid." end
    local entry = self.db.entries[key]
    if not entry then
        local c = self.db.settings.markerColor
        entry = {
            name=name, realm=normalizedRealm, enabled=true, marker=self.db.settings.defaultMarker,
            markerColor={r=c.r,g=c.g,b=c.b,a=c.a}, sound=true, notes="", encounters=0, kills=0, deaths=0, order=self:NextAvailableSlot(),
            firstSeen=0, lastSeen=0, lastZone="", guid=nil,
        }
        self.db.entries[key] = entry
    else
        entry.name, entry.realm, entry.enabled = name, normalizedRealm, true
    end
    if self.RefreshUI then self:RefreshUI(key) end
    self:EnableRuntimeEvents()
    self:ReconcileUnits()
    return entry, key
end

function N:RemoveEntry(key)
    if self.db.entries[key] then
        self.db.entries[key] = nil
        self.acknowledgedKeys[key] = nil
        for unit, state in pairs(self.activeUnits) do if state.key == key then self:RemoveUnit(unit) end end
        if self.RefreshUI then self:RefreshUI() end
        return true
    end
end

function N:MoveEntry(key, delta)
    local entry=self.db.entries[key]
    if not entry then return end
    local list=self:SortedEntries("")
    local index
    for i,item in ipairs(list) do if item.key==key then index=i; break end end
    local target=index and list[index+(delta or 0)]
    if target then entry.order,target.entry.order=target.entry.order,entry.order; if self.RefreshUI then self:RefreshUI(key) end end
end

function N:GetEntryByCombatant(name)
    if not name or isSecret(name) then return end
    local clean=name:match("^[^|]+") or name
    local _,_,key=self:SplitCharacter(clean)
    local entry=key and self.db.entries[key]
    if entry then return entry,key end
    local short=clean:match("^([^%-]+)")
    if short then
        local normalized=short:lower():gsub("[%s']",""):gsub("[^%w%-]","")
        local found,foundKey
        for candidateKey,candidate in pairs(self.db.entries) do
            if candidateKey:match("^([^|]+)")==normalized then if found then return end; found,foundKey=candidate,candidateKey end
        end
        return found,foundKey
    end
end

function N:SortedEntries(filter)
    local list = {}
    filter = trim(filter):lower()
    for key, entry in pairs(self.db.entries) do
        local label = entry.displayName or entry.name or ""
        if filter == "" or label:lower():find(filter, 1, true) then
            list[#list+1] = {key=key, entry=entry, label=label}
        end
    end
    table.sort(list, function(a,b) local ao,bo=tonumber(a.entry.order) or 999999,tonumber(b.entry.order) or 999999; if ao~=bo then return ao<bo end; return a.label:lower()<b.label:lower() end)
    return list
end
