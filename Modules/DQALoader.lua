-- DQA is a companion addon, but Forever can skip standalone enabled addons
-- after a crash-safe startup. DXM is already resident, so load DQA from here
-- and keep its user-facing command available even when the companion is not.
local loader=CreateFrame("Frame")
local attempted=false

local function loadDQA(report)
    if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("DXM_DQA") then return true end
    if IsAddOnLoaded and IsAddOnLoaded("DXM_DQA") then return true end
    local load=C_AddOns and C_AddOns.LoadAddOn or LoadAddOn
    if type(load)~="function" then
        if report then print("|cffff5555DQA:|r addon loader API is unavailable.") end
        return false
    end
    local ok,loaded,reason=pcall(load,"DXM_DQA")
    local success=ok and (loaded==true or loaded==1)
    if not success and report then
        print(("|cffff5555DQA:|r failed to load DXM_DQA (%s)."):format(tostring(reason or loaded or "unknown reason")))
    end
    return success
end

loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent",function()
    if attempted then return end
    attempted=true
    loadDQA(true)
end)

SLASH_DQA1="/dqa"
SlashCmdList["DQA"]=function()
    if not loadDQA(true) then return end
    if type(DQA_OpenSettings)=="function" then
        DQA_OpenSettings()
    else
        print("|cffff5555DQA:|r loaded, but its settings module is unavailable.")
    end
end

