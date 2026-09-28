local panel
local statusText
local windowControls
local damageMeter
local scaleSlider
local scaleValue

local function TakePanelPositionOwnership(frame)
    if frame.SetUserPlaced then frame:SetUserPlaced(false) end
    if frame.SetDontSavePosition then frame:SetDontSavePosition(true) end
end

local function SavePanelPosition(frame)
    local left, top = frame:GetLeft(), frame:GetTop()
    local scale = frame:GetEffectiveScale()
    if not left or not top or not scale or scale <= 0 then return end
    DefylerUIDB = type(DefylerUIDB) == "table" and DefylerUIDB or {}
    DefylerUIDB.suitePanelPosition = {
        left = left * scale,
        top = top * scale,
    }
    if DefylerUI_SaveSuiteSettings then DefylerUI_SaveSuiteSettings() end
end

local function RestorePanelPosition(frame)
    local position = type(DefylerUIDB) == "table" and DefylerUIDB.suitePanelPosition
    local scale = frame:GetEffectiveScale()
    if type(position) ~= "table"
        or type(position.left) ~= "number"
        or type(position.top) ~= "number"
        or not scale
        or scale <= 0 then
        return
    end
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
    button:SetSize(width or 150, 26)
    button:SetText(text)
    button:SetScript("OnClick", click)
    return button
end

local function Loaded(name)
    if C_AddOns and C_AddOns.IsAddOnLoaded then return C_AddOns.IsAddOnLoaded(name) end
    if IsAddOnLoaded then return IsAddOnLoaded(name) end
    return false
end

local function SetStatus(message, errorState)
    if not statusText then return end
    statusText:SetText(message or "")
    statusText:SetTextColor(errorState and 1 or .72, errorState and .35 or .82, errorState and .28 or .92)
end

local function OpenForeverSettings()
    if SlashCmdList and SlashCmdList.FOREVERSETTINGS then
        panel:Hide()
        SlashCmdList.FOREVERSETTINGS("")
    else
        SetStatus("Forever Settings is not loaded.", true)
    end
end

local function OpenDXMSettings()
    if not (DXMExchange and DXMExchange.Open) then
        SetStatus("DXM is not loaded.", true)
    elseif not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
        SetStatus("Open the Auction House first, then use DXM Configuration.", true)
    else
        panel:Hide()
        DXMExchange:Open("config")
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
        panel:Hide()
        SlashCmdList.DEFYLERDAMAGEMETER("options")
    else
        SetStatus("Defyler Damage Meter is not loaded.", true)
    end
end

local function Refresh()
    if not panel then return end
    panel:SetScale(1 / UIParent:GetEffectiveScale())
    RestorePanelPosition(panel)
    if DefylerUI_AreWindowControlsEnabled then
        windowControls:SetChecked(DefylerUI_AreWindowControlsEnabled())
    end

    local damageLoaded = Loaded("DefylerDamageMeter") and type(DDM_IsEnabled) == "function"
    damageMeter:SetEnabled(damageLoaded)
    damageMeter.Text:SetTextColor(damageLoaded and 1 or .5, damageLoaded and .82 or .5, damageLoaded and .2 or .5)
    damageMeter:SetChecked(damageLoaded and DDM_IsEnabled() or false)

    local scale = DefylerUI_GetGlobalScale and DefylerUI_GetGlobalScale() or UIParent:GetScale()
    scaleSlider:SetValue(scale)
    scaleValue:SetText(string.format("%.2f", scale))

    local foreverState = Loaded("ForeverSettings") and "|cff40ff40Loaded|r" or "|cffff5050Unavailable|r"
    local dxmState = Loaded("DXM") and "|cff40ff40Loaded|r" or "|cffff5050Unavailable|r"
    local ddmState = damageLoaded and (DDM_IsEnabled() and "|cff40ff40On|r" or "|cffffd100Off|r") or "|cffff5050Unavailable|r"
    SetStatus("Forever Settings: " .. foreverState .. "     DXM: " .. dxmState .. "     Damage Meter: " .. ddmState)
end

local function CreatePanel()
    panel = CreateFrame("Frame", "DefylerUISuitePanel", UIParent, "BackdropTemplate")
    panel:SetSize(570, 500)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("DIALOG")
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:SetMovable(true)
    TakePanelPositionOwnership(panel)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self)
        self:StartMoving()
        TakePanelPositionOwnership(self)
    end)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        TakePanelPositionOwnership(self)
        SavePanelPosition(self)
    end)
    panel:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = {left = 10, right = 10, top = 10, bottom = 10},
    })
    panel:SetBackdropColor(.025, .035, .055, .99)
    panel:SetBackdropBorderColor(.72, .50, .24, 1)

    -- Keep the controls readable even if a client build cannot resolve the backdrop texture.
    local backing = panel:CreateTexture(nil, "BACKGROUND")
    backing:SetPoint("TOPLEFT", 11, -11)
    backing:SetPoint("BOTTOMRIGHT", -11, 11)
    backing:SetColorTexture(.018, .024, .035, .97)

    local title = AddText(panel, "GameFontNormalLarge", "Defyler Suite Control")
    title:SetPoint("TOPLEFT", 24, -20)
    local subtitle = AddText(panel, "GameFontHighlightSmall", "One place for interface, graphics, market, and combat tools.")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -7)

    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -5, -5)

    local divider = panel:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(.82, .45, .12, .75)
    divider:SetPoint("TOPLEFT", 20, -70)
    divider:SetPoint("TOPRIGHT", -20, -70)
    divider:SetHeight(1)

    local controlsTitle = AddText(panel, "GameFontNormal", "DUI CONTROLS")
    controlsTitle:SetPoint("TOPLEFT", 26, -88)

    windowControls = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    windowControls:SetPoint("TOPLEFT", 24, -112)
    windowControls.Text:SetText("Show window move and resize controls")
    windowControls.Text:SetTextColor(1, .82, .2)
    windowControls:SetScript("OnClick", function(self)
        if DefylerUI_SetWindowControlsEnabled then
            DefylerUI_SetWindowControlsEnabled(self:GetChecked() and true or false)
            SetStatus("DUI window controls " .. (self:GetChecked() and "enabled." or "hidden."))
        end
    end)

    damageMeter = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    damageMeter:SetPoint("TOPLEFT", windowControls, "BOTTOMLEFT", 0, -8)
    damageMeter.Text:SetText("Enable Defyler Damage Meter")
    damageMeter.Text:SetTextColor(1, .82, .2)
    damageMeter:SetScript("OnClick", function(self)
        if not DDM_SetEnabled then self:SetChecked(false); SetStatus("Defyler Damage Meter is not loaded.", true); return end
        local success, message = DDM_SetEnabled(self:GetChecked() and true or false)
        if success == false then self:SetChecked(not self:GetChecked()); SetStatus(message or "Unable to change the damage meter.", true)
        else SetStatus("Defyler Damage Meter " .. (self:GetChecked() and "enabled." or "disabled.")) end
        Refresh()
    end)

    local scaleTitle = AddText(panel, "GameFontNormal", "GLOBAL UI SCALE")
    scaleTitle:SetPoint("TOPLEFT", 26, -190)
    scaleSlider = CreateFrame("Slider", "DefylerUISuiteScaleSlider", panel, "OptionsSliderTemplate")
    scaleSlider:SetPoint("TOPLEFT", 38, -226)
    scaleSlider:SetSize(350, 20)
    scaleSlider:SetMinMaxValues(.25, 1.50)
    scaleSlider:SetValueStep(.01)
    scaleSlider:SetObeyStepOnDrag(true)
    scaleSlider.Low:SetText("0.25")
    scaleSlider.High:SetText("1.50")
    scaleSlider.Text:SetText("")
    scaleValue = AddText(panel, "GameFontHighlight", "1.00")
    scaleValue:SetPoint("LEFT", scaleSlider, "RIGHT", 24, 0)
    scaleValue:SetWidth(45)
    scaleSlider:SetScript("OnValueChanged", function(_, value) scaleValue:SetText(string.format("%.2f", value)) end)

    local applyScale = AddButton(panel, "Apply Scale", 105, function()
        if DefylerUI_SetGlobalScale then
            DefylerUI_SetGlobalScale(math.floor(scaleSlider:GetValue() * 100 + .5) / 100)
            Refresh()
        end
    end)
    applyScale:SetPoint("TOPRIGHT", -24, -214)
    local resetScale = AddButton(panel, "Reset Scale", 105, function()
        if DefylerUI_ResetGlobalScale then DefylerUI_ResetGlobalScale() end
    end)
    resetScale:SetPoint("TOP", applyScale, "BOTTOM", 0, -8)

    local suiteTitle = AddText(panel, "GameFontNormal", "ADDON SETTINGS")
    suiteTitle:SetPoint("TOPLEFT", 26, -292)

    local forever = AddButton(panel, "Forever Controls", 158, OpenForeverSettings)
    forever:SetPoint("TOPLEFT", 26, -322)
    local dxm = AddButton(panel, "DXM Configuration", 158, OpenDXMSettings)
    dxm:SetPoint("LEFT", forever, "RIGHT", 20, 0)
    local ddm = AddButton(panel, "Damage Meter Options", 158, OpenDamageMeterSettings)
    ddm:SetPoint("LEFT", dxm, "RIGHT", 20, 0)

    local foreverNote = AddText(panel, "GameFontDisableSmall", "Extended graphics and world controls")
    foreverNote:SetPoint("TOP", forever, "BOTTOM", 0, -7)
    foreverNote:SetWidth(160)
    foreverNote:SetJustifyH("CENTER")
    local dxmNote = AddText(panel, "GameFontDisableSmall", "Available while the Auction House is open")
    dxmNote:SetPoint("TOP", dxm, "BOTTOM", 0, -7)
    dxmNote:SetWidth(160)
    dxmNote:SetJustifyH("CENTER")
    local ddmNote = AddText(panel, "GameFontDisableSmall", "Appearance, percentages, and reset controls")
    ddmNote:SetPoint("TOP", ddm, "BOTTOM", 0, -7)
    ddmNote:SetWidth(160)
    ddmNote:SetJustifyH("CENTER")

    local resetWindows = AddButton(panel, "Reset Window Positions", 175, function()
        if DefylerUI_ResetWindowPositions then DefylerUI_ResetWindowPositions() end
    end)
    resetWindows:SetPoint("BOTTOMLEFT", 24, 48)

    statusText = AddText(panel, "GameFontHighlightSmall", "")
    statusText:SetPoint("BOTTOMLEFT", 24, 18)
    statusText:SetPoint("BOTTOMRIGHT", -24, 18)
    statusText:SetJustifyH("LEFT")

    panel:SetScript("OnShow", function()
        Refresh()
    end)
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