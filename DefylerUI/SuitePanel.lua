local panel
local statusText
local windowControls
local damageMeter
local scaleSlider
local scaleValue
local moduleRows = {}
local RefreshModuleRows

local GOLD = {1, .82, .2}
local VIOLET = {.78, .64, .96}
local MUTED = {.56, .58, .64}

local function TakePanelPositionOwnership(frame)
    if frame.SetUserPlaced then frame:SetUserPlaced(false) end
    if frame.SetDontSavePosition then frame:SetDontSavePosition(true) end
end

local function SavePanelPosition(frame)
    local left, top = frame:GetLeft(), frame:GetTop()
    local scale = frame:GetEffectiveScale()
    if not left or not top or not scale or scale <= 0 then return end
    DefylerUIDB = type(DefylerUIDB) == "table" and DefylerUIDB or {}
    DefylerUIDB.suitePanelPosition = {left = left * scale, top = top * scale}
    if DefylerUI_SaveSuiteSettings then DefylerUI_SaveSuiteSettings() end
end

local function RestorePanelPosition(frame)
    local position = type(DefylerUIDB) == "table" and DefylerUIDB.suitePanelPosition
    local scale = frame:GetEffectiveScale()
    if type(position) ~= "table" or type(position.left) ~= "number" or type(position.top) ~= "number"
        or not scale or scale <= 0 then return end
    TakePanelPositionOwnership(frame)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", position.left / scale, position.top / scale)
end

local function AddText(parent, template, text)
    local label = parent:CreateFontString(nil, "OVERLAY", template)
    label:SetText(text or "")
    label:SetJustifyH("LEFT")
    return label
end

local function AddButton(parent, text, width, click)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width or 92, 24)
    button:SetText(text)
    button:SetScript("OnClick", click)
    return button
end

local function Loaded(name)
    if C_AddOns and C_AddOns.IsAddOnLoaded then return C_AddOns.IsAddOnLoaded(name) end
    if IsAddOnLoaded then return IsAddOnLoaded(name) end
    return false
end

local function AddOnVersion(name)
    local getter = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    return getter and getter(name, "Version") or nil
end

local function SetStatus(message, errorState)
    if not statusText then return end
    statusText:SetText(message or "")
    statusText:SetTextColor(errorState and 1 or .70, errorState and .35 or .76, errorState and .28 or .86)
end

local function CloseAndRun(callback)
    panel:Hide()
    callback()
end

local function OpenDXMPage(pageKey, label)
    if not (DXMExchange and DXMExchange.Open) then
        SetStatus((label or "DXM") .. " is not loaded.", true)
        return
    end
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
        SetStatus("Open the Auction House first, then open " .. (label or "DXM") .. ".", true)
        return
    end
    CloseAndRun(function() DXMExchange:Open(pageKey) end)
end

local function OpenForeverSettings()
    if SlashCmdList and SlashCmdList.FOREVERSETTINGS then
        CloseAndRun(function() SlashCmdList.FOREVERSETTINGS("") end)
    else
        SetStatus("Forever Settings is not loaded.", true)
    end
end

local function OpenDamageMeterSettings()
    if DDM_OpenOptions then
        panel:Hide()
        local success, message = DDM_OpenOptions()
        if success == false then
            panel:Show()
            SetStatus(message or "Damage Meter options are unavailable.", true)
        end
    elseif SlashCmdList and SlashCmdList.DEFYLERDAMAGEMETER then
        CloseAndRun(function() SlashCmdList.DEFYLERDAMAGEMETER("options") end)
    else
        SetStatus("Defyler Damage Meter is not loaded.", true)
    end
end

local function OpenDDQ()
    if DXMDDQ and DXMDDQ.Show then
        CloseAndRun(DXMDDQ.Show)
    elseif SlashCmdList and SlashCmdList.DXMDDQ then
        CloseAndRun(function() SlashCmdList.DXMDDQ("") end)
    else
        SetStatus("Defyler's Disenchant Queue is not loaded.", true)
    end
end

local function ToggleDQA()
    if not (SlashCmdList and SlashCmdList.DQA) then
        SetStatus("Defyler's Quest Assistance is not loaded.", true)
        return
    end
    DQADB = type(DQADB) == "table" and DQADB or {}
    SlashCmdList.DQA(DQADB.enabled == false and "on" or "off")
    SetStatus("Quest Assistance " .. (DQADB.enabled == false and "disabled." or "enabled."))
    RefreshModuleRows()
end

local MODULES = {
    {addon = "DefylerUI", name = "Defyler UI", action = "Current", current = true},
    {addon = "DefylerDamageMeter", name = "Damage Meter", action = "Settings", open = OpenDamageMeterSettings},
    {addon = "DXM", name = "DXM Exchange", action = "Settings", open = function() OpenDXMPage("config", "DXM settings") end},
    {addon = "DXM_DDQ", name = "Disenchant Queue", action = "Open", open = OpenDDQ},
    {addon = "DXM_DQA", name = "Quest Assistance", action = "Toggle", open = ToggleDQA},
    {addon = "DXM_DealFinder", name = "Deal Finder", action = "Open", open = function() OpenDXMPage("deals", "Deal Finder") end},
    {addon = "DXM_Stats_OverTime", name = "Market History", action = "Open", open = function() OpenDXMPage("valuation", "Market History") end},
    {addon = "DXM_SharedData", name = "DXM Network", action = "Open", open = function() OpenDXMPage("network", "DXM Network") end},
    {addon = "DXM_Valuer", name = "DXM Valuer", action = "Open", open = function() OpenDXMPage("valuation", "DXM Valuer") end},
    {addon = "ForeverSettings", name = "Forever Controls", action = "Settings", open = OpenForeverSettings},
}

RefreshModuleRows = function()
    for _, row in ipairs(moduleRows) do
        local definition = row.Definition
        local isLoaded = Loaded(definition.addon)
        local version = AddOnVersion(definition.addon)
        local state = isLoaded and "Loaded" or "Unavailable"
        if definition.addon == "DXM_DQA" and isLoaded and type(DQADB) == "table" then
            state = DQADB.enabled == false and "Off" or "On"
            row.Action:SetText(DQADB.enabled == false and "Enable" or "Disable")
        else
            row.Action:SetText(definition.action)
        end
        row.State:SetText((version and ("v" .. version .. "  ") or "") .. state)
        row.State:SetTextColor(isLoaded and .45 or .65, isLoaded and .82 or .36, isLoaded and .56 or .36)
        row.Action:SetEnabled(isLoaded and not definition.current and definition.open ~= nil)
    end
end

local function CreateModuleRow(parent, definition, index)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetSize(296, 38)
    row:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
    row:SetBackdropColor(.055, .06, .09, .96)
    row:SetBackdropBorderColor(.22, .17, .28, 1)
    local column = (index - 1) % 2
    local line = math.floor((index - 1) / 2)
    row:SetPoint("TOPLEFT", 14 + column * 304, -24 - line * 42)
    local name = AddText(row, "GameFontNormal", definition.name)
    name:SetPoint("TOPLEFT", 10, -7)
    name:SetTextColor(unpack(GOLD))
    local state = AddText(row, "GameFontDisableSmall", "")
    state:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -2)
    state:SetWidth(190)
    local button = AddButton(row, definition.action, 78, definition.open or function() end)
    button:SetPoint("RIGHT", -7, 0)
    row.Definition = definition
    row.State = state
    row.Action = button
    moduleRows[#moduleRows + 1] = row
end

local function Refresh()
    if not panel then return end
    panel:SetScale(1)
    RestorePanelPosition(panel)
    if DefylerUI_AreWindowControlsEnabled then windowControls:SetChecked(DefylerUI_AreWindowControlsEnabled()) end
    local damageLoaded = Loaded("DefylerDamageMeter") and type(DDM_IsEnabled) == "function"
    damageMeter:SetEnabled(damageLoaded)
    damageMeter.Text:SetTextColor(damageLoaded and 1 or .5, damageLoaded and .82 or .5, damageLoaded and .2 or .5)
    damageMeter:SetChecked(damageLoaded and DDM_IsEnabled() or false)
    local scale = DefylerUI_GetGlobalScale and DefylerUI_GetGlobalScale() or UIParent:GetScale()
    scaleSlider:SetValue(scale)
    scaleValue:SetText(string.format("%.2f", scale))
    RefreshModuleRows()
end

local function CreatePanel()
    panel = CreateFrame("Frame", "DefylerUISuitePanel", UIParent, "BackdropTemplate")
    panel:SetSize(640, 410)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("DIALOG")
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:SetMovable(true)
    TakePanelPositionOwnership(panel)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self) self:StartMoving(); TakePanelPositionOwnership(self) end)
    panel:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); TakePanelPositionOwnership(self); SavePanelPosition(self) end)
    panel:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2,
        insets = {left = 1, right = 1, top = 1, bottom = 1}})
    panel:SetBackdropColor(.025, .03, .05, .99)
    panel:SetBackdropBorderColor(unpack(VIOLET))

    local header = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    header:SetPoint("TOPLEFT", 2, -2); header:SetPoint("TOPRIGHT", -2, -2); header:SetHeight(38)
    header:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8"})
    header:SetBackdropColor(.045, .05, .085, 1)
    local title = AddText(header, "GameFontNormalLarge", "Defyler Suite")
    title:SetPoint("LEFT", 14, 0); title:SetTextColor(unpack(VIOLET))
    local subtitle = AddText(header, "GameFontDisableSmall", "Controls and module settings")
    subtitle:SetPoint("LEFT", title, "RIGHT", 12, -1)
    local close = CreateFrame("Button", nil, header, "UIPanelCloseButton")
    close:SetPoint("RIGHT", -2, 0)

    local quick = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    quick:SetPoint("TOPLEFT", 12, -50); quick:SetPoint("TOPRIGHT", -12, -50); quick:SetHeight(76)
    quick:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
    quick:SetBackdropColor(.04, .045, .07, .95); quick:SetBackdropBorderColor(.22, .17, .28, 1)

    windowControls = CreateFrame("CheckButton", nil, quick, "UICheckButtonTemplate")
    windowControls:SetPoint("TOPLEFT", 8, -5)
    windowControls.Text:SetText("Window controls")
    windowControls.Text:SetTextColor(unpack(GOLD))
    windowControls:SetScript("OnClick", function(self)
        if DefylerUI_SetWindowControlsEnabled then
            DefylerUI_SetWindowControlsEnabled(self:GetChecked() and true or false)
            SetStatus("Window controls " .. (self:GetChecked() and "shown." or "hidden."))
        end
    end)

    damageMeter = CreateFrame("CheckButton", nil, quick, "UICheckButtonTemplate")
    damageMeter:SetPoint("TOPLEFT", 300, -5)
    damageMeter.Text:SetText("Damage Meter")
    damageMeter.Text:SetTextColor(unpack(GOLD))
    damageMeter:SetScript("OnClick", function(self)
        if not DDM_SetEnabled then self:SetChecked(false); SetStatus("Defyler Damage Meter is not loaded.", true); return end
        local success, message = DDM_SetEnabled(self:GetChecked() and true or false)
        if success == false then
            self:SetChecked(not self:GetChecked()); SetStatus(message or "Unable to change the Damage Meter.", true)
        else
            SetStatus("Damage Meter " .. (self:GetChecked() and "enabled." or "disabled."))
        end
        Refresh()
    end)

    local scaleLabel = AddText(quick, "GameFontHighlightSmall", "UI scale")
    scaleLabel:SetPoint("BOTTOMLEFT", 12, 13)
    scaleSlider = CreateFrame("Slider", "DefylerUISuiteScaleSlider", quick, "OptionsSliderTemplate")
    scaleSlider:SetPoint("LEFT", scaleLabel, "RIGHT", 15, 0)
    scaleSlider:SetSize(280, 16)
    scaleSlider:SetMinMaxValues(.25, 1.50); scaleSlider:SetValueStep(.01); scaleSlider:SetObeyStepOnDrag(true)
    scaleSlider.Low:SetText(""); scaleSlider.High:SetText(""); scaleSlider.Text:SetText("")
    scaleValue = AddText(quick, "GameFontHighlightSmall", "1.00")
    scaleValue:SetPoint("LEFT", scaleSlider, "RIGHT", 10, 0); scaleValue:SetWidth(36)
    scaleSlider:SetScript("OnValueChanged", function(_, value) scaleValue:SetText(string.format("%.2f", value)) end)
    local applyScale = AddButton(quick, "Apply", 66, function()
        if DefylerUI_SetGlobalScale then DefylerUI_SetGlobalScale(math.floor(scaleSlider:GetValue() * 100 + .5) / 100); Refresh() end
    end)
    applyScale:SetPoint("LEFT", scaleValue, "RIGHT", 4, 0)
    local resetScale = AddButton(quick, "Reset", 66, function()
        if DefylerUI_ResetGlobalScale then DefylerUI_ResetGlobalScale() end
    end)
    resetScale:SetPoint("LEFT", applyScale, "RIGHT", 5, 0)

    local moduleBox = CreateFrame("Frame", nil, panel)
    moduleBox:SetPoint("TOPLEFT", 0, -134); moduleBox:SetPoint("TOPRIGHT", 0, -134); moduleBox:SetHeight(255)
    local moduleTitle = AddText(moduleBox, "GameFontNormalSmall", "MODULES")
    moduleTitle:SetPoint("TOPLEFT", 16, 0); moduleTitle:SetTextColor(unpack(MUTED))
    for index, definition in ipairs(MODULES) do CreateModuleRow(moduleBox, definition, index) end

    local resetWindows = AddButton(panel, "Reset window positions", 154, function()
        if DefylerUI_ResetWindowPositions then DefylerUI_ResetWindowPositions() end
    end)
    resetWindows:SetPoint("BOTTOMLEFT", 14, 12)
    statusText = AddText(panel, "GameFontDisableSmall", "")
    statusText:SetPoint("LEFT", resetWindows, "RIGHT", 12, 0); statusText:SetPoint("RIGHT", -14, 0)
    statusText:SetJustifyH("LEFT")

    panel:SetScript("OnShow", Refresh)
    panel:Hide()
    UISpecialFrames[#UISpecialFrames + 1] = "DefylerUISuitePanel"
end

function DefylerUI_ToggleSuitePanel()
    if not panel then CreatePanel() end
    if panel:IsShown() then panel:Hide() else panel:Show() end
end

function DefylerUI_RefreshSuitePanel()
    if panel and panel:IsShown() then Refresh() end
end