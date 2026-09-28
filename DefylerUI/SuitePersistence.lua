local addonName = ...
local restoreGeneration = 0
local variablesReady = false
local preloadMaster = { format = "Defyler Suite Settings", version = 1 }

local function CopyValue(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local copy = {}
    seen[value] = copy
    for key, entry in pairs(value) do
        copy[CopyValue(key, seen)] = CopyValue(entry, seen)
    end
    return copy
end

local function MasterDB()
    if not variablesReady then return preloadMaster end
    DefylerSuiteDB = type(DefylerSuiteDB) == "table" and DefylerSuiteDB or {}
    DefylerSuiteDB.format = "Defyler Suite Settings"
    DefylerSuiteDB.version = 1
    return DefylerSuiteDB
end

local function SnapshotSettings()
    local master = MasterDB()
    if type(DefylerUIDB) == "table" then
        master.dui = {
            enabled = DefylerUIDB.enabled ~= false,
            globalScale = DefylerUIDB.globalScale,
            minimapAngle = DefylerUIDB.minimapAngle,
            coordinateVersion = DefylerUIDB.coordinateVersion,
            frames = CopyValue(DefylerUIDB.frames or {}),
            suitePanelPosition = CopyValue(DefylerUIDB.suitePanelPosition),
        }
    end
    if type(ForeverSettingsDB) == "table" then
        master.forever = {
            linkRaid = ForeverSettingsDB.linkRaid,
            profile = CopyValue(ForeverSettingsDB.profile or {}),
            windowPosition = CopyValue(ForeverSettingsDB.windowPosition),
        }
    end
    if type(DDMDB) == "table" then
        master.damageMeter = { enabled = DDMDB.enabled ~= false }
    end
    master.initialized = true
    master.savedAt = time and time() or nil
end

local function RestoreDatabaseValues()
    local master = MasterDB()
    local dui = master.dui
    if type(dui) == "table" then
        DefylerUIDB = type(DefylerUIDB) == "table" and DefylerUIDB or {}
        DefylerUIDB.enabled = dui.enabled ~= false
        DefylerUIDB.globalScale = dui.globalScale
        DefylerUIDB.minimapAngle = dui.minimapAngle
        DefylerUIDB.coordinateVersion = dui.coordinateVersion
        DefylerUIDB.frames = CopyValue(dui.frames or {})
        if type(dui.suitePanelPosition) == "table" then
            DefylerUIDB.suitePanelPosition = CopyValue(dui.suitePanelPosition)
        end
    end
    local forever = master.forever
    if type(forever) == "table" and type(ForeverSettingsDB) == "table" then
        ForeverSettingsDB.linkRaid = forever.linkRaid
        ForeverSettingsDB.profile = CopyValue(forever.profile or {})
        if type(forever.windowPosition) == "table" then
            ForeverSettingsDB.windowPosition = CopyValue(forever.windowPosition)
        end
    end
    local damage = master.damageMeter
    if type(damage) == "table" and type(DDMDB) == "table" then
        DDMDB.enabled = damage.enabled ~= false
    end
end

local function ApplySettings()
    if DefylerUI_RefreshWindowControls then DefylerUI_RefreshWindowControls() end
    if DefylerUI_RestoreGlobalScale then DefylerUI_RestoreGlobalScale() end
    if DefylerUI_RestoreWindowPositions then DefylerUI_RestoreWindowPositions() end
    if ForeverSettings_ApplySavedProfile then ForeverSettings_ApplySavedProfile() end
    if DDM_SetEnabled and MasterDB().damageMeter then
        DDM_SetEnabled(MasterDB().damageMeter.enabled ~= false)
    end
end

local function ScheduleRestore()
    restoreGeneration = restoreGeneration + 1
    local generation = restoreGeneration
    for _, delay in ipairs({0, 0.1, 0.5, 1, 2}) do
        C_Timer.After(delay, function()
            if generation == restoreGeneration then ApplySettings() end
        end)
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("VARIABLES_LOADED")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_LOGOUT")
events:SetScript("OnEvent", function(_, event, loadedAddon)
    if event == "VARIABLES_LOADED" then
        variablesReady = true
        MasterDB()
        return
    end
    if not variablesReady then return end
    if event == "ADDON_LOADED" then
        if loadedAddon ~= addonName then return end
        MasterDB()
        return
    end
    if event == "PLAYER_LOGOUT" then
        SnapshotSettings()
        return
    end
    -- The addon's native SavedVariables are authoritative during normal login.
    -- Mirror them into the suite record instead of restoring an older suite
    -- snapshot over newly saved window positions and global scale.
    C_Timer.After(0, function()
        SnapshotSettings()
        ScheduleRestore()
    end)
end)

function DefylerUI_SaveSuiteSettings()
    SnapshotSettings()
end

function DefylerUI_RestoreSuiteSettings()
    if not MasterDB().initialized then SnapshotSettings() end
    RestoreDatabaseValues()
    ScheduleRestore()
end