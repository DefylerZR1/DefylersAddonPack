-- Use Blizzard's combined-bag mode without replacing its secure routing or
-- initializing native pooled item buttons from addon code. The reagent bag
-- remains a native separate container on clients that exclude it from the grid.
local ready = false
local function initialize()
    if ready or (InCombatLockdown and InCombatLockdown()) then return end
    if not ContainerFrameCombinedBags or not GetCVarBool or not SetCVar then return end
    if not GetCVarBool("combinedBags") then SetCVar("combinedBags", 1) end
    ready = true
end
local events = CreateFrame("Frame")
for _, event in ipairs({"PLAYER_LOGIN", "ADDON_LOADED", "PLAYER_REGEN_ENABLED"}) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", initialize)

SLASH_DUIONEBAG1 = "/duibags"
SlashCmdList.DUIONEBAG = function()
    initialize()
    print("Defyler UI bags: Blizzard combined bags; native item controls. Reagent bag uses its native window.")
end
