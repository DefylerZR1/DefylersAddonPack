Nemesis = Nemesis or {}
local N = Nemesis

N.VERSION = "0.3.27"
N.MEDIA = "Interface\\AddOns\\Nemesis\\Media\\"
N.markerNames = {
    "Bullseye", "Triple Ring", "Crosshair", "Four Arrows", "Vertical Scope",
    "Segment Lock", "Precision Cross", "Target Arrow", "Broken Ring", "Marked X",
    "Target Star", "North Marker", "Hardpoint", "Corner Scope", "Tracking Arrows",
    "Confirmed Target", "Cardinal Target", "Six Point Scope", "Dual Arc", "Threat Lock",
}
N.activeUnits = {}
N.activeKeys = {}
N.acknowledgedKeys = {}
N.lastAlerts = {}
N.sessionSeen = {}

local function copyDefaults(source, target)
    for key, value in pairs(source) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then target[key] = {} end
            copyDefaults(value, target[key])
        elseif target[key] == nil then target[key] = value end
    end
end
N.CopyDefaults = copyDefaults

function N:Print(message)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffff3333Nemesis:|r " .. tostring(message)) end
end

function N:Now()
    return GetServerTime and GetServerTime() or time()
end

function N:Zone()
    return GetRealZoneText and GetRealZoneText() or GetZoneText and GetZoneText() or ""
end

function N:MarkerPath(index)
    return self.MEDIA .. ("Markers\\marker_%02d.tga"):format(math.max(1, math.min(20, tonumber(index) or 1)))
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")

function N:EnableRuntimeEvents()
    if self.runtimeEventsEnabled then return end
    self.runtimeEventsEnabled = true
    local elapsed = 0
    events:SetScript("OnUpdate", function(_, delta)
        elapsed = elapsed + delta
        if elapsed < 0.25 then return end
        elapsed = 0
        N:ReconcileUnits()
    end)
end

events:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" and (...) == "Nemesis" then
        N:InitializeDB()
        N:RegisterCommands()
        if next(N.db.entries) then N:EnableRuntimeEvents() end
    end
end)
