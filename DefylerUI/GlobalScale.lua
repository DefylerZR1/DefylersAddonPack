local MIN, MAX = .25, 1.50
local EPSILON = .0001
local DRIFT_CHECK_SECONDS = 2
local events = CreateFrame("Frame")
local panel, pending, queued
local startupGeneration = 0
local driftElapsed = 0
local applyingScale = false
local variablesReady = false
local preloadDatabase = {}
local function DB()
    if not variablesReady then return preloadDatabase end
    DefylerUIDB = type(DefylerUIDB) == "table" and DefylerUIDB or {}
    return DefylerUIDB
end
local function Valid(value)
    return type(value) == "number" and value == value and value >= MIN and value <= MAX
end
local function SavedScaleMismatch()
    local value = DB().globalScale
    return Valid(value) and math.abs(UIParent:GetScale() - value) > EPSILON
end
local function ApplySaved()
    local value = DB().globalScale
    if not Valid(value) then return end
    local changed = math.abs(UIParent:GetScale() - value) > EPSILON
    if not changed then
        pending = nil
        if panel then panel:SetScale(1/UIParent:GetEffectiveScale()) end
        return
    end
    if InCombatLockdown() then pending = true; return end
    pending = nil
    applyingScale = true
    UIParent:SetScale(value)
    applyingScale = false
    if panel then panel:SetScale(1/UIParent:GetEffectiveScale()) end
    if DefylerUI_ReflowAfterGlobalScale then
        DefylerUI_ReflowAfterGlobalScale()
    end
end
local function Schedule()
    if queued then return end
    queued = true
    C_Timer.After(0, function() queued = nil; ApplySaved() end)
end
local function ScheduleStartup()
    startupGeneration = startupGeneration + 1
    local generation = startupGeneration
    for _, delay in ipairs({0, .1, .5, 1, 2, 4, 8}) do
        C_Timer.After(delay, function()
            if generation == startupGeneration then ApplySaved() end
        end)
    end
end
local function Set(value)
    if not Valid(value) then
        print("DUI global scale: enter a number from 0.25 to 1.50.")
        return false
    end
    if InCombatLockdown() then
        print("DUI: finish combat before changing global UI scale.")
        return false
    end
    DB().globalScale = value
    if DefylerUI_SaveSuiteSettings then DefylerUI_SaveSuiteSettings() end
    ApplySaved()
    print(string.format("DUI global scale: %.2f. /dui scale reset restores the client default.", value))
    return true
end
local function Reset()
    if InCombatLockdown() then print("DUI: finish combat before resetting UI scale."); return end
    DB().globalScale = nil
    if DefylerUI_SaveSuiteSettings then DefylerUI_SaveSuiteSettings() end
    pending = nil
    ReloadUI()
end
local function ShowPanel()
    if not panel then
        panel = CreateFrame("Frame", "DefylerUIGlobalScalePanel", UIParent, "BackdropTemplate")
        panel:SetSize(360, 175)
        panel:SetPoint("CENTER")
        panel:SetFrameStrata("DIALOG")
        panel:SetClampedToScreen(true)
        panel:SetBackdrop({bgFile="Interface\\Tooltips\\UI-Tooltip-Background",edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",tile=true,tileSize=16,edgeSize=16,insets={left=4,right=4,top=4,bottom=4}})
        panel:SetBackdropColor(.05,.05,.05,.98)
        local title=panel:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
        title:SetPoint("TOP",0,-16); title:SetText("Global UI scale")
        local slider=CreateFrame("Slider", "DefylerUIGlobalScaleSlider", panel, "OptionsSliderTemplate")
        panel.slider=slider
        slider:SetPoint("TOP",0,-63); slider:SetSize(290,20)
        slider:SetMinMaxValues(MIN,MAX); slider:SetValueStep(.01); slider:SetObeyStepOnDrag(true)
        slider.Low:SetText("0.25")
        slider.High:SetText("1.50")
        slider:SetScript("OnValueChanged",function(self,value)
            self.Text:SetText(string.format("%.2f",value))
        end)
        local note=panel:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        note:SetPoint("TOP",0,-101); note:SetText("Changes the whole UI. Reset reloads the interface.")
        local function Button(text,x,fn)
            local b=CreateFrame("Button",nil,panel,"UIPanelButtonTemplate")
            b:SetSize(98,24); b:SetPoint("BOTTOMLEFT",x,18); b:SetText(text); b:SetScript("OnClick",fn)
        end
        Button("Apply",22,function() Set(math.floor(slider:GetValue()*100+.5)/100) end)
        Button("Reset",131,Reset)
        Button("Close",240,function() panel:Hide() end)
        UISpecialFrames[#UISpecialFrames+1]="DefylerUIGlobalScalePanel"
    end
    -- Keep the settings dialog readable even at very small world-UI scales.
    panel:SetScale(1/UIParent:GetEffectiveScale())
    panel.slider:SetValue(DB().globalScale or UIParent:GetScale())
    panel:Show()
end
function DefylerUI_RestoreGlobalScale()
    ApplySaved()
end
function DefylerUI_GetGlobalScale()
    return DB().globalScale or UIParent:GetScale()
end
function DefylerUI_SetGlobalScale(value)
    return Set(tonumber(value))
end
function DefylerUI_ResetGlobalScale()
    Reset()
end
function DefylerUI_ScaleCommand(argument)
    argument=(argument or ""):lower():match("^%s*(.-)%s*$")
    if argument=="reset" then Reset()
    elseif argument=="" then ShowPanel()
    else Set(tonumber(argument)) end
end
SLASH_DEFYLERUISCALE1="/duiscale"
SlashCmdList.DEFYLERUISCALE=DefylerUI_ScaleCommand
for _,event in ipairs({"VARIABLES_LOADED","PLAYER_LOGIN","PLAYER_ENTERING_WORLD","LOADING_SCREEN_DISABLED","DISPLAY_SIZE_CHANGED","UI_SCALE_CHANGED","PLAYER_REGEN_ENABLED"}) do events:RegisterEvent(event) end
events:SetScript("OnEvent",function(_,event)
    if event=="VARIABLES_LOADED" then
        variablesReady=true
        ScheduleStartup()
        return
    end
    if not variablesReady then return end
    if event=="PLAYER_LOGIN" or event=="PLAYER_ENTERING_WORLD" or event=="LOADING_SCREEN_DISABLED" or event=="DISPLAY_SIZE_CHANGED" then
        ScheduleStartup()
    elseif event=="UI_SCALE_CHANGED" then
        -- UIParent:SetScale can emit this event. Ignore our own write and the
        -- matching follow-up event so it cannot create a restore loop.
        if applyingScale or not SavedScaleMismatch() then return end
        Schedule()
    elseif event=="PLAYER_REGEN_ENABLED" and pending then
        Schedule()
    end
end)
events:SetScript("OnUpdate", function(_, delta)
    if not variablesReady then return end
    driftElapsed = driftElapsed + delta
    if driftElapsed < DRIFT_CHECK_SECONDS then return end
    driftElapsed = 0
    -- Some client layout restores bypass UI_SCALE_CHANGED. Check rarely and
    -- only write when the live scale has actually drifted from the saved one.
    if SavedScaleMismatch() then ApplySaved() end
end)
