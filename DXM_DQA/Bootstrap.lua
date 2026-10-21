-- Keep the user-facing entry point independent from optional marker APIs.
-- This file loads last, so a failure in an earlier module cannot make /dqa
-- disappear without an explanation.
SLASH_DQA1 = "/dqa"
SlashCmdList["DQA"] = function(input)
    local command = type(input) == "string" and input:lower():match("^%s*(%S*)") or ""
    if command == "on" and DQA_SetObjectiveMarkersEnabled then
        DQA_SetObjectiveMarkersEnabled(true)
        print("|cffc9a4f4DQA:|r objective markers enabled.")
        return
    elseif command == "off" and DQA_SetObjectiveMarkersEnabled then
        DQA_SetObjectiveMarkersEnabled(false)
        print("|cffc9a4f4DQA:|r objective markers disabled.")
        return
    end
    if type(DQA_OpenSettings) == "function" then
        DQA_OpenSettings()
    else
        print("|cffff5555DQA:|r settings module did not load. Check Lua errors for DXM_DQA/Settings.lua.")
    end
end

