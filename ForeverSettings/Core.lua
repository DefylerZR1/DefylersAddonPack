local _, FS = ...

FS.VERSION = "0.1.8"
FS.PAGE_SIZE = 11

FS.categories = {
    { id = "rendering", name = "Rendering" },
    { id = "world", name = "World detail" },
    { id = "effects", name = "Effects" },
}

FS.settings = {
    { category="rendering", cvar="RenderScale", label="Render scale", min=.5, max=3, step=.05, format="percent", reload=true,
      help="Experimental above 200%. The client may clamp, ignore, or reject the value." },
    { category="rendering", cvar="graphicsQuality", raid="RAIDgraphicsQuality", label="Overall quality", min=1, max=10, step=1 },
    { category="rendering", cvar="ffxAntiAliasingMode", label="Anti-aliasing mode", min=0, max=8, step=1, reload=true },
    { category="rendering", cvar="MSAAQuality", label="MSAA quality", min=0, max=8, step=1, reload=true },
    { category="rendering", cvar="shadowMode", raid="RAIDshadowMode", label="Shadow mode", min=0, max=6, step=1 },
    { category="rendering", cvar="shadowTextureSize", raid="RAIDshadowTextureSize", label="Shadow texture size", min=512, max=8192, step=256, reload=true },
    { category="rendering", cvar="graphicsLightMode", raid="raidGraphicsLightMode", label="Lighting mode", min=0, max=4, step=1 },
    { category="rendering", cvar="giQuality", raid="RAIDgiQuality", label="Global illumination (safe)", min=2, max=2, step=1,
      help="Locked to the confirmed-stable value 2. Other persisted values can prevent the client from entering the world." },

    { category="world", cvar="farclip", raid="RAIDfarclip", label="View distance", min=500, max=20000, step=100 },
    { category="world", cvar="horizonStart", raid="RAIDhorizonStart", label="Horizon start", min=0, max=10000, step=100 },
    { category="world", cvar="horizonClip", raid="RAIDhorizonClip", label="Horizon clip", min=500, max=20000, step=100 },
    { category="world", cvar="groundEffectDist", raid="RAIDgroundEffectDist", label="Ground-effect distance", min=40, max=1000, step=10 },
    { category="world", cvar="groundEffectDensity", raid="RAIDgroundEffectDensity", label="Ground-effect density", min=16, max=256, step=1 },
    { category="world", cvar="terrainLodDist", raid="RAIDterrainLodDist", label="Terrain LOD distance", min=100, max=2000, step=25 },
    { category="world", cvar="wmoLodDist", raid="RAIDwmoLodDist", label="Building LOD distance", min=100, max=1200, step=25 },
    { category="world", cvar="doodadLodScale", raid="RAIDdoodadLodScale", label="Doodad LOD scale", min=50, max=300, step=5 },
    { category="world", cvar="lodObjectFadeScale", raid="RAIDlodObjectFadeScale", label="Object fade scale", min=50, max=300, step=5 },
    { category="world", cvar="lodObjectCullSize", raid="RAIDlodObjectCullSize", label="Object cull size", min=1, max=64, step=1 },
    { category="world", cvar="entityShadowFadeScale", raid="RAIDentityShadowFadeScale", label="Entity-shadow distance", min=10, max=250, step=5 },

    { category="effects", cvar="SSAO", raid="RAIDSSAO", label="Ambient occlusion", min=0, max=5, step=1 },
    { category="effects", cvar="volumeFogLevel", raid="RAIDVolumeFogLevel", label="Volumetric fog", min=0, max=5, step=1 },
    { category="effects", cvar="sunShafts", raid="RAIDsunShafts", label="Sun shafts", min=0, max=3, step=1 },
    { category="effects", cvar="waterDetail", raid="RAIDWaterDetail", label="Water detail", min=0, max=4, step=1 },
    { category="effects", cvar="graphicsSpellDensity", raid="raidGraphicsSpellDensity", label="Spell density", min=0, max=5, step=1 },
    { category="effects", cvar="graphicsParticleDensity", raid="raidGraphicsParticleDensity", label="Particle density", min=0, max=5, step=1 },
    { category="effects", cvar="graphicsComputeEffects", raid="raidGraphicsComputeEffects", label="Compute effects", min=0, max=5, step=1 },
    { category="effects", cvar="graphicsDepthEffects", raid="raidGraphicsDepthEffects", label="Depth effects", min=0, max=5, step=1 },
    { category="effects", cvar="graphicsPBRLiquidDetail", raid="raidGraphicsPBRLiquidDetail", label="PBR liquid detail", min=0, max=4, step=1 },
}

FS.toggleSettings = {
    { cvar="volumeFog", label="Enable fog" },
}

-- Changing these values while the world renderer is starting can crash the
-- 1.60.1 client inside its lighting engine. Keep them visible for readback,
-- but never write them from addon code.
local UNSAFE_LIGHTING_CVARS = {
    giQuality=true, RAIDgiQuality=true,
    graphicsLightMode=true, raidGraphicsLightMode=true,
}

local function SanitizeStoredLightingProfile()
    for _, field in ipairs({"profile", "initialSnapshot"}) do
        local values=ForeverSettingsDB and ForeverSettingsDB[field]
        if type(values)=="table" then
            values.giQuality=2
            values.RAIDgiQuality=2
            -- Never replay an old addon-selected lighting mode.
            values.graphicsLightMode=nil
            values.raidGraphicsLightMode=nil
        end
    end
    if ForeverSettingsDB then ForeverSettingsDB.lightingSafetyVersion=1 end
end

local function GetInfo(name)
    if not C_CVar or not C_CVar.GetCVarInfo then return nil end
    local result = { pcall(C_CVar.GetCVarInfo, name) }
    if not result[1] then return nil end
    return result[2], result[3], result[6], result[7], result[8]
end

function FS:GetValue(name)
    local getter = C_CVar and C_CVar.GetCVar or GetCVar
    local success, value = pcall(getter, name)
    if not success then return nil, nil end
    return value and tonumber(value), value
end

function FS:GetAvailability(name)
    if UNSAFE_LIGHTING_CVARS[name] then
        return false, "Locked: crashes the 1.60.1 lighting engine"
    end
    local value, defaultValue, locked, secure, readOnly = GetInfo(name)
    if value == nil then return false, "Unavailable in this client" end
    if locked then return false, "Locked by the client" end
    if secure then return false, "Secure CVar" end
    if readOnly then return false, "Read-only CVar" end
    return true, nil, defaultValue
end

function FS:SetValue(name, value)
    if UNSAFE_LIGHTING_CVARS[name] then return false, "Unsafe lighting CVar" end
    local available, reason = self:GetAvailability(name)
    if not available then return false, reason end
    local callWorked, success = pcall(C_CVar.SetCVar, name, tostring(value))
    local actual = self:GetValue(name)
    if not callWorked or not success then return false, "Client rejected the value", actual end
    if actual == nil then return false, "No value returned after applying" end
    local requested = tonumber(value)
    if requested and math.abs(actual - requested) > .0001 then
        return true, string.format("Clamped to %s", tostring(actual)), actual
    end
    return true, "Applied", actual
end

function FS:ReadProfile()
    local profile = {}
    for _, setting in ipairs(self.settings) do
        local value = self:GetValue(setting.cvar)
        if value ~= nil then profile[setting.cvar] = value end
        if setting.raid then
            local raidValue = self:GetValue(setting.raid)
            if raidValue ~= nil then profile[setting.raid] = raidValue end
        end
    end
    for _, setting in ipairs(self.toggleSettings) do
        local value = self:GetValue(setting.cvar)
        if value ~= nil then profile[setting.cvar] = value end
    end
    return profile
end

function FS:EnsureProfile()
    if type(ForeverSettingsDB.profile) ~= "table" then
        ForeverSettingsDB.profile = {}
        local source = type(ForeverSettingsDB.initialSnapshot) == "table"
            and ForeverSettingsDB.initialSnapshot or self:ReadProfile()
        for name, value in pairs(source) do ForeverSettingsDB.profile[name] = value end
    end
    for _, setting in ipairs(self.settings) do
        if ForeverSettingsDB.profile[setting.cvar] == nil then
            local value = self:GetValue(setting.cvar)
            if value ~= nil then ForeverSettingsDB.profile[setting.cvar] = value end
        end
        if setting.raid and ForeverSettingsDB.profile[setting.raid] == nil then
            local value = self:GetValue(setting.raid)
            if value ~= nil then ForeverSettingsDB.profile[setting.raid] = value end
        end
    end
    for _, setting in ipairs(self.toggleSettings) do
        if ForeverSettingsDB.profile[setting.cvar] == nil then
            local value = self:GetValue(setting.cvar)
            if value ~= nil then ForeverSettingsDB.profile[setting.cvar] = value end
        end
    end
end

function FS:SaveProfile()
    ForeverSettingsDB.profile = self:ReadProfile()
    ForeverSettingsDB.profileSavedAt = date("%Y-%m-%d %H:%M:%S")
end

function FS:RestoreProfile()
    local profile = ForeverSettingsDB.profile
    if type(profile) ~= "table" then return 0, 0 end
    local applied, failed = 0, 0
    for name, value in pairs(profile) do
        local current = self:GetValue(name)
        if current == nil or math.abs(current - value) > .0001 then
            local success = self:SetValue(name, value)
            if success then applied = applied + 1 else failed = failed + 1 end
        end
    end
    return applied, failed
end

function FS:ApplySavedProfile()
    self:EnsureProfile()
    local applied, failed = self:RestoreProfile()
    if self.window then self:RefreshRows() end
    return applied, failed
end

function ForeverSettings_ApplySavedProfile()
    return FS:ApplySavedProfile()
end

local initialized = false

local function Initialize()
    if initialized then return end
    ForeverSettingsDB = type(ForeverSettingsDB) == "table" and ForeverSettingsDB or {}
    SanitizeStoredLightingProfile()
    if ForeverSettingsDB.linkRaid == nil then ForeverSettingsDB.linkRaid = true end
    if not ForeverSettingsDB.initialSnapshot then ForeverSettingsDB.initialSnapshot = FS:ReadProfile() end
    FS:EnsureProfile()
    FS:CreateWindow()
    SLASH_FOREVERSETTINGS1 = "/fsettings"
    SLASH_FOREVERSETTINGS2 = "/foreversettings"
    SlashCmdList.FOREVERSETTINGS = function() FS:Toggle() end
    initialized = true
    print("|cffe6bd74Forever Settings|r loaded. Type |cffffffff/fsettings|r to open.")
end

local events = CreateFrame("Frame")
events:RegisterEvent("VARIABLES_LOADED")
events:SetScript("OnEvent", Initialize)
