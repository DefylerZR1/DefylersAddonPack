local addonName = ...

local controller = CreateFrame("Frame")
local styledEntries = setmetatable({}, {__mode = "k"})
local reportOverlays = setmetatable({}, {__mode = "k"})
local hooksInstalled
local settingsPanel
local placementRestorePending
local placementRestoreGeneration = 0
local placementHooksInstalled
local applyingPlacement
local userAdjustingPlacement
local placementWatchElapsed = 0
local placementWatchUntil = 0

local COLORS = {
    panel = {0.018, 0.028, 0.045, 0.96},
    header = {0.035, 0.055, 0.078, 0.98},
    border = {0.82, 0.45, 0.12, 1},
    borderDim = {0.34, 0.22, 0.10, 1},
    text = {0.94, 0.91, 0.82, 1},
    muted = {0.62, 0.67, 0.72, 1},
}

local function ShowReportNotice(message, red, green, blue)
    if UIErrorsFrame and UIErrorsFrame.AddMessage then
        UIErrorsFrame:AddMessage(message, red or 1, green or 0.82, blue or 0.20, 1)
    else
        print(message)
    end
end

local function ReportVisibleEntry(entry)
    if not entry or not entry.StatusBar then return end

    if not IsInGroup() then
        ShowReportNotice("DDM: Join a party before reporting a row.", 1, 0.25, 0.20)
        return
    end

    if InCombatLockdown() then
        ShowReportNotice("DDM: Report after combat ends.", 1, 0.75, 0.2)
        return
    end
    local text, reason = DDMBuildRowReport(entry, entry.DDMReportWindow)
    if not text then ShowReportNotice(reason, 1, 0.25, 0.20); return end
    local channel = IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and "INSTANCE_CHAT"
        or (IsInRaid() and "RAID" or "PARTY")
    C_ChatInfo.SendChatMessage(text, channel)
end

local function RefreshReportOverlays()
    local active = IsShiftKeyDown()
    for overlay in pairs(reportOverlays) do
        overlay:SetShown(active)
    end
end

local function InstallEntryReportOverlay(entry)
    if not entry then return end
    local overlay = entry.DDMReportOverlay
    if not overlay then
        -- While Shift is held, this invisible child receives the click before
        -- Blizzard's row button. With Shift released it ignores the mouse, so
        -- all normal Blizzard row behavior remains untouched and untainted.
        overlay = CreateFrame("Button", nil, entry)
        overlay:SetAllPoints(entry)
        overlay:EnableMouse(true)
        overlay:RegisterForClicks("LeftButtonDown")
        overlay:SetScript("OnClick", function(_, mouseButton)
            if mouseButton == "LeftButton" then ReportVisibleEntry(entry) end
        end)
        entry.DDMReportOverlay = overlay
        reportOverlays[overlay] = true
    end
    overlay:SetFrameLevel(entry:GetFrameLevel() + 20)
    overlay:SetShown(IsShiftKeyDown())
end

local DEFAULTS = {
    point = "CENTER", relativePoint = "CENTER", x = 330, y = -80,
    width = 330, height = 210, scale = 1, alpha = 0.95, enabled = true,
}

local function Clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function InitializeDatabase()
    DDMDB = DDMDB or {}
    for key, value in pairs(DEFAULTS) do
        if DDMDB[key] == nil then DDMDB[key] = value end
    end
end

local function ColorTexture(texture, color)
    if texture and texture.SetColorTexture then
        texture:SetColorTexture(color[1], color[2], color[3], color[4])
    end
end

local function AddBorder(frame, key, color)
    if frame[key] then return frame[key] end
    local border = {}
    for index = 1, 4 do
        border[index] = frame:CreateTexture(nil, "OVERLAY")
        border[index]:SetColorTexture(unpack(color or COLORS.border))
    end
    border[1]:SetPoint("TOPLEFT"); border[1]:SetPoint("TOPRIGHT"); border[1]:SetHeight(1)
    border[2]:SetPoint("BOTTOMLEFT"); border[2]:SetPoint("BOTTOMRIGHT"); border[2]:SetHeight(1)
    border[3]:SetPoint("TOPLEFT"); border[3]:SetPoint("BOTTOMLEFT"); border[3]:SetWidth(1)
    border[4]:SetPoint("TOPRIGHT"); border[4]:SetPoint("BOTTOMRIGHT"); border[4]:SetWidth(1)
    frame[key] = border
    return border
end

local function StyleEntry(entry, window)
    if not entry then return end
    if window then entry.DDMReportWindow = window end
    InstallEntryReportOverlay(entry)
    if not styledEntries[entry] then
        styledEntries[entry] = true
        if entry.Icon and entry.Icon.Icon then entry.Icon.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
    end
    local statusBar = entry.StatusBar
    if statusBar then
        statusBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        if statusBar.Background then ColorTexture(statusBar.Background, {0.012, 0.020, 0.032, 0.78}) end
        if statusBar.BackgroundEdge then statusBar.BackgroundEdge:SetAlpha(0) end
        if statusBar.Name then statusBar.Name:SetTextColor(unpack(COLORS.text)) end
        if statusBar.Value then statusBar.Value:SetTextColor(unpack(COLORS.text)) end
    end
end

local function SavePlacement()
    if not DamageMeter then return end
    local point, _, relativePoint, x, y = DamageMeter:GetPoint(1)
    if point then
        DDMDB.point, DDMDB.relativePoint = point, relativePoint
        DDMDB.x, DDMDB.y = math.floor((x or 0) + 0.5), math.floor((y or 0) + 0.5)
    end
    DDMDB.width = math.floor(DamageMeter:GetWidth() + 0.5)
    DDMDB.height = math.floor(DamageMeter:GetHeight() + 0.5)
    DDMDB.scale = Clamp(DamageMeter:GetScale() or 1, 0.60, 1.50)
    DDMDB.alpha = Clamp(DamageMeter:GetAlpha() or 1, 0.30, 1)
end

local function ApplyPlacement()
    if not DamageMeter or not DDMDB then return end
    applyingPlacement = true
    DamageMeter:SetMovable(true)
    DamageMeter:SetResizable(true)
    DamageMeter:SetClampedToScreen(true)
    if DamageMeter.SetResizeBounds then DamageMeter:SetResizeBounds(220, 120, 600, 400) end
    -- DamageMeter is an Edit Mode system. Use the original frame methods saved
    -- by Blizzard's mixin so restoring DDM's profile does not mark Edit Mode's
    -- default anchor dirty and trigger another layout pass over our placement.
    local setScale = DamageMeter.SetScaleBase or DamageMeter.SetScale
    local clearAllPoints = DamageMeter.ClearAllPointsBase or DamageMeter.ClearAllPoints
    local setPoint = DamageMeter.SetPointBase or DamageMeter.SetPoint
    setScale(DamageMeter, Clamp(DDMDB.scale, 0.60, 1.50))
    clearAllPoints(DamageMeter)
    setPoint(DamageMeter, DDMDB.point, UIParent, DDMDB.relativePoint, DDMDB.x, DDMDB.y)
    DamageMeter:SetSize(Clamp(DDMDB.width, 220, 600), Clamp(DDMDB.height, 120, 400))
    applyingPlacement = nil
end

local function PlacementMatchesProfile()
    if not DamageMeter or not DDMDB then return false end
    if math.abs((DamageMeter:GetScale() or 1) - Clamp(DDMDB.scale, 0.60, 1.50)) > 0.001 then return false end
    if math.abs((DamageMeter:GetWidth() or 0) - Clamp(DDMDB.width, 220, 600)) > 0.5 then return false end
    if math.abs((DamageMeter:GetHeight() or 0) - Clamp(DDMDB.height, 120, 400)) > 0.5 then return false end
    local point, relativeTo, relativePoint, x, y = DamageMeter:GetPoint(1)
    if point ~= DDMDB.point or relativePoint ~= DDMDB.relativePoint then return false end
    if relativeTo and relativeTo ~= UIParent then return false end
    return math.abs((x or 0) - DDMDB.x) <= 0.5 and math.abs((y or 0) - DDMDB.y) <= 0.5
end

local function StartPlacementWatch()
    placementWatchElapsed = 0
    placementWatchUntil = GetTime() + 15
end

local function QueuePlacementRestore()
    if placementRestorePending then return end
    placementRestorePending = true
    C_Timer.After(0, function()
        placementRestorePending = nil
        if not userAdjustingPlacement then ApplyPlacement() end
    end)
end

local function RestorePlacementThroughStartup()
    placementRestoreGeneration = placementRestoreGeneration + 1
    local generation = placementRestoreGeneration
    for _, delay in ipairs({0, 0.1, 0.5, 1, 2}) do
        C_Timer.After(delay, function()
            if generation == placementRestoreGeneration and not userAdjustingPlacement then ApplyPlacement() end
        end)
    end
end

local function BeginUserPlacementChange()
    userAdjustingPlacement = true
    -- Invalidate delayed startup restores that were queued before the drag.
    placementRestoreGeneration = placementRestoreGeneration + 1
end

local function EndUserPlacementChange()
    SavePlacement()
    userAdjustingPlacement = nil
end

local function InstallPlacementGuards()
    if placementHooksInstalled or not DamageMeter then return end
    placementHooksInstalled = true

    local function RestoreAfterBlizzardLayout()
        if not applyingPlacement and not userAdjustingPlacement then QueuePlacementRestore() end
    end

    -- Edit Mode can touch these methods after PLAYER_ENTERING_WORLD. Watching
    -- the actual frame catches every late layout pass, including ones that do
    -- not travel through EditModeDamageMeterSystemMixin:OnUpdateSystem.
    hooksecurefunc(DamageMeter, "SetPoint", RestoreAfterBlizzardLayout)
    hooksecurefunc(DamageMeter, "SetSize", RestoreAfterBlizzardLayout)
    hooksecurefunc(DamageMeter, "SetScale", RestoreAfterBlizzardLayout)
    DamageMeter:HookScript("OnShow", RestorePlacementThroughStartup)
end

local function ApplyMeterSettings()
    if not DamageMeter or not DDMDB then return end
    -- Frame APIs are presentation-only. Do not call Blizzard's meter mixin
    -- setters here: their Lua fields later interact with secret combat values.
    DamageMeter:SetAlpha(DDMDB.alpha)
end

local function MakeButton(parent, text, width, callback)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetSize(width or 92, 24)
    button:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
    button:SetBackdropColor(0.045, 0.070, 0.095, 1)
    button:SetBackdropBorderColor(unpack(COLORS.borderDim))
    button.Text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    button.Text:SetPoint("CENTER"); button.Text:SetText(text)
    button:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(unpack(COLORS.border)) end)
    button:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(unpack(COLORS.borderDim)) end)
    button:SetScript("OnClick", callback)
    return button
end

local function MakeSettingsButton(parent, callback)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(42, 42)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("CENTER")
    icon:SetAtlas("GM-icon-settings", false)
    icon:SetSize(35, 35)
    icon:SetVertexColor(0.90, 0.65, 0.25, 1)
    button.Icon = icon

    local glow = button:CreateTexture(nil, "HIGHLIGHT")
    glow:SetPoint("CENTER")
    glow:SetSize(42, 42)
    glow:SetTexture("Interface\\Buttons\\UI-Panel-Button-Highlight")
    glow:SetBlendMode("ADD")
    glow:SetAlpha(0.65)

    button:SetScript("OnMouseDown", function(self)
        self.Icon:SetPoint("CENTER", 1, -1)
        self.Icon:SetVertexColor(1, 0.82, 0.35, 1)
    end)
    button:SetScript("OnMouseUp", function(self)
        self.Icon:ClearAllPoints()
        self.Icon:SetPoint("CENTER")
        self.Icon:SetVertexColor(0.90, 0.65, 0.25, 1)
    end)
    button:SetScript("OnEnter", function(self)
        self.Icon:SetVertexColor(1, 0.82, 0.35, 1)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("DDM Settings")
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function(self)
        self.Icon:SetVertexColor(0.90, 0.65, 0.25, 1)
        GameTooltip:Hide()
    end)
    button:SetScript("OnClick", callback)
    return button
end

local function RefreshPanel()
    if not settingsPanel or not DDMDB then return end
    if settingsPanel.Percentages then settingsPanel.Percentages.Text:SetText(DDMPercentagesEnabled() and "Damage share: ON" or "Damage share: OFF") end
    settingsPanel.ScaleValue:SetText(string.format("%d%%", math.floor(DDMDB.scale * 100 + 0.5)))
    settingsPanel.OpacityValue:SetText(string.format("%d%%", math.floor(DDMDB.alpha * 100 + 0.5)))
end

local function AdjustScale(delta)
    DDMDB.scale = Clamp(DDMDB.scale + delta, 0.60, 1.50)
    if DamageMeter then DamageMeter:SetScale(DDMDB.scale) end
    SavePlacement(); RefreshPanel()
end

local function AdjustAlpha(delta)
    DDMDB.alpha = Clamp(DDMDB.alpha + delta, 0.30, 1)
    if DamageMeter then DamageMeter:SetAlpha(DDMDB.alpha) end
    RefreshPanel()
end

local function CreateSettingsPanel()
    if settingsPanel then return settingsPanel end
    local panel = CreateFrame("Frame", "DefylerDamageMeterSettings", UIParent, "BackdropTemplate")
    panel:SetSize(250, 198); panel:SetFrameStrata("DIALOG"); panel:SetClampedToScreen(true)
    panel:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
    panel:SetBackdropColor(unpack(COLORS.panel)); panel:SetBackdropBorderColor(unpack(COLORS.border)); panel:Hide()
    panel.Title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.Title:SetPoint("TOPLEFT", 12, -10); panel.Title:SetText("Defyler Damage Meter"); panel.Title:SetTextColor(unpack(COLORS.text))
    local close = MakeButton(panel, "X", 24, function() panel:Hide() end); close:SetPoint("TOPRIGHT", -8, -7)

    local function AddStepper(y, label, minusAction, plusAction, valueKey)
        local title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        title:SetPoint("TOPLEFT", 12, y); title:SetText(label)
        local minus = MakeButton(panel, "-", 28, minusAction); minus:SetPoint("TOPLEFT", 112, y + 5)
        local value = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        value:SetPoint("LEFT", minus, "RIGHT", 7, 0); value:SetWidth(45); value:SetJustifyH("CENTER"); panel[valueKey] = value
        local plus = MakeButton(panel, "+", 28, plusAction); plus:SetPoint("LEFT", value, "RIGHT", 7, 0)
    end

    AddStepper(-48, "Window scale", function() AdjustScale(-0.05) end, function() AdjustScale(0.05) end, "ScaleValue")
    AddStepper(-80, "Opacity", function() AdjustAlpha(-0.05) end, function() AdjustAlpha(0.05) end, "OpacityValue")

    panel.Percentages = MakeButton(panel, "Damage share", 226, function()
        DDMSetPercentages(not DDMPercentagesEnabled())
    end)
    panel.Percentages:SetPoint("TOPLEFT",12,-108)
    panel.Percentages:SetScript("OnEnter",function(self)
        GameTooltip:SetOwner(self,"ANCHOR_TOP"); GameTooltip:SetText("Total damage, DPS, and percentage"); GameTooltip:AddLine("Applies in a separate layout, then reloads the UI.",1,1,1); GameTooltip:Show()
    end)
    panel.Percentages:SetScript("OnLeave",GameTooltip_Hide)

    local resetData = MakeButton(panel, "Reset combat", 104, function()
        if C_DamageMeter and C_DamageMeter.ResetAllCombatSessions then C_DamageMeter.ResetAllCombatSessions() end
    end)
    resetData:SetPoint("TOPLEFT", 12, -147)
    local resetLayout = MakeButton(panel, "Reset layout", 112, function()
        for key, value in pairs(DEFAULTS) do DDMDB[key] = value end
        ApplyPlacement(); ApplyMeterSettings(); RefreshPanel()
    end)
    resetLayout:SetPoint("LEFT", resetData, "RIGHT", 10, 0)

    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOM", 0, 6); hint:SetText("Shift-left-click a row to report it to party")
    hint:SetTextColor(unpack(COLORS.muted))
    settingsPanel = panel; RefreshPanel(); return panel
end

local function ToggleSettings(window)
    local panel = CreateSettingsPanel()
    if panel:IsShown() then panel:Hide() else
        panel:ClearAllPoints(); panel:SetPoint("TOPLEFT", window, "TOPRIGHT", 6, 0); panel:Show(); RefreshPanel()
    end
end

local function AddWindowControls(window)
    if window.DDMControlsInstalled then return end
    window.DDMControlsInstalled = true
    window:HookScript("OnDragStart", function()
        if window == DamageMeter:GetPrimarySessionWindow() and not InCombatLockdown() then
            BeginUserPlacementChange()
            DamageMeter:StartMoving()
        end
    end)
    window:HookScript("OnDragStop", function()
        if window == DamageMeter:GetPrimarySessionWindow() then
            DamageMeter:StopMovingOrSizing()
            EndUserPlacementChange()
        end
    end)
    local resize = window.MinimizeContainer and window.MinimizeContainer.ResizeButton
    if resize then
        resize:SetAlpha(0.75)
        resize:HookScript("OnMouseDown", function(_, mouseButton)
            if mouseButton == "LeftButton" and window == DamageMeter:GetPrimarySessionWindow() and not InCombatLockdown() then
                BeginUserPlacementChange()
                DamageMeter:StartSizing("BOTTOMRIGHT")
            end
        end)
        resize:HookScript("OnMouseUp", function(_, mouseButton)
            if mouseButton == "LeftButton" and window == DamageMeter:GetPrimarySessionWindow() then
                DamageMeter:StopMovingOrSizing()
                EndUserPlacementChange()
            end
        end)
    end
    if window.SettingsDropdown then window.SettingsDropdown:Hide() end
    local menuButton = MakeSettingsButton(window, function() ToggleSettings(window) end)
    menuButton:SetFrameLevel(window:GetFrameLevel() + 20)
    menuButton:SetPoint("RIGHT", window.MinimizeButton, "LEFT", -4, -1)
    if window.SessionDropdown then
        window.SessionDropdown:ClearAllPoints()
        window.SessionDropdown:SetPoint("RIGHT", menuButton, "LEFT", -4, 1)
    end
    window.DDMMenuButton = menuButton
end

local function StyleWindow(window)
    if not window then return end
    if window.Header then ColorTexture(window.Header, COLORS.header) end
    if window.MinimizeContainer and window.MinimizeContainer.Background then
        ColorTexture(window.MinimizeContainer.Background, COLORS.panel); window.MinimizeContainer.Background:SetAlpha(1)
    end
    if window.SessionTimer then window.SessionTimer:SetTextColor(unpack(COLORS.muted)) end
    if window.DamageMeterTypeDropdown and window.DamageMeterTypeDropdown.TypeName then window.DamageMeterTypeDropdown.TypeName:SetTextColor(unpack(COLORS.text)) end
    if window.SessionDropdown and window.SessionDropdown.SessionName then window.SessionDropdown.SessionName:SetTextColor(unpack(COLORS.border)) end
    AddBorder(window, "DDMBorder", COLORS.border); AddWindowControls(window)
    local scrollBox = window.MinimizeContainer and window.MinimizeContainer.ScrollBox
    if scrollBox and ScrollUtil and ScrollUtil.AddAcquiredFrameCallback and not window.DDMEntryCallbackInstalled then
        window.DDMEntryCallbackInstalled = true
        -- Damage-meter rows are virtualized and Blizzard rewrites their
        -- OnClick script whenever a row is acquired. Install our independent
        -- Shift overlay after that initializer for every current and future row.
        ScrollUtil.AddAcquiredFrameCallback(scrollBox, function(_, entry)
            StyleEntry(entry, window)
        end)
    end
    if scrollBox and scrollBox.ForEachFrame then
        scrollBox:ForEachFrame(function(entry) StyleEntry(entry, window) end)
    end
    if window.MinimizeContainer and window.MinimizeContainer.LocalPlayerEntry then
        StyleEntry(window.MinimizeContainer.LocalPlayerEntry, window)
    end
end

local function StyleAll()
    if not DamageMeter then return end
    if DamageMeter.ForEachSessionWindow then DamageMeter:ForEachSessionWindow(StyleWindow)
    elseif DamageMeter.GetPrimarySessionWindow then StyleWindow(DamageMeter:GetPrimarySessionWindow()) end
end

local function InstallHooks()
    if hooksInstalled or not DamageMeter then return end
    hooksInstalled = true
    -- Session frames receive copied mixin methods before ADDON_LOADED, so hook
    -- the live owner object rather than the mixin table for future windows.
    if DamageMeter.SetupSessionWindow then
        hooksecurefunc(DamageMeter, "SetupSessionWindow", function() C_Timer.After(0, StyleAll) end)
    end
    -- DamageMeter is an Edit Mode system. Blizzard reapplies its own anchor while
    -- loading and whenever the active layout is refreshed, so restore DDM's saved
    -- placement after that layout pass has completely finished.
    if EditModeDamageMeterSystemMixin and EditModeDamageMeterSystemMixin.OnUpdateSystem then
        hooksecurefunc(EditModeDamageMeterSystemMixin, "OnUpdateSystem", function(frame)
            if frame == DamageMeter then QueuePlacementRestore() end
        end)
    end
    if EditModeSystemMixin and EditModeSystemMixin.ApplySystemAnchor then
        hooksecurefunc(EditModeSystemMixin, "ApplySystemAnchor", function(frame)
            if frame == DamageMeter then QueuePlacementRestore() end
        end)
    end
end

local function SetNativeMeterCVar(enabled)
    local setter = C_CVar and C_CVar.SetCVar or SetCVar
    if setter then pcall(setter, "damageMeterEnabled", enabled and "1" or "0") end
end

local function SetNativeMeterShown(enabled)
    if not DamageMeter then return end
    pcall(DamageMeter.SetShown, DamageMeter, enabled and true or false)
end

local function EnableNativeMeter()
    InitializeDatabase()
    if DDMDB.enabled == false then
        SetNativeMeterCVar(false)
        SetNativeMeterShown(false)
        return
    end
    SetNativeMeterCVar(true)
    InstallHooks(); InstallPlacementGuards(); ApplyPlacement(); ApplyMeterSettings(); StyleAll()
    SetNativeMeterShown(true)
    RestorePlacementThroughStartup()
    C_Timer.After(0, function() ApplyMeterSettings(); StyleAll() end)
    C_Timer.After(1, function() ApplyMeterSettings(); StyleAll() end)
end

function DDM_IsEnabled()
    InitializeDatabase()
    return DDMDB.enabled ~= false
end

function DDM_SetEnabled(enabled)
    if InCombatLockdown() then return false, "Finish combat before changing the damage meter." end
    InitializeDatabase()
    DDMDB.enabled = enabled and true or false
    if DDMDB.enabled then
        EnableNativeMeter()
    else
        SetNativeMeterCVar(false)
        SetNativeMeterShown(false)
        if settingsPanel then settingsPanel:Hide() end
    end
    return true
end

function DDM_OpenOptions()
    if not DDM_IsEnabled() then return false, "Turn on the Damage Meter before opening its options." end
    local window = DamageMeter and DamageMeter.GetPrimarySessionWindow and DamageMeter:GetPrimarySessionWindow()
    if not window then return false, "The native Damage Meter window is not available yet." end
    ToggleSettings(window)
    return true
end

controller:RegisterEvent("ADDON_LOADED"); controller:RegisterEvent("PLAYER_LOGIN"); controller:RegisterEvent("PLAYER_ENTERING_WORLD"); controller:RegisterEvent("PLAYER_LOGOUT"); controller:RegisterEvent("MODIFIER_STATE_CHANGED")
controller:SetScript("OnEvent", function(_, event, loadedAddon)
    if event == "MODIFIER_STATE_CHANGED" then
        RefreshReportOverlays()
        return
    end
    if event == "PLAYER_LOGOUT" then
        if not userAdjustingPlacement then SavePlacement() end
        return
    end
    if event == "ADDON_LOADED" and loadedAddon ~= addonName and loadedAddon ~= "Blizzard_DamageMeter" then return end
    EnableNativeMeter()
    if event == "PLAYER_ENTERING_WORLD" then
        RestorePlacementThroughStartup()
        StartPlacementWatch()
    end
end)
controller:SetScript("OnUpdate", function(_, delta)
    if placementWatchUntil == 0 or GetTime() >= placementWatchUntil then return end
    placementWatchElapsed = placementWatchElapsed + delta
    if placementWatchElapsed < 0.25 then return end
    placementWatchElapsed = 0
    if not applyingPlacement and not userAdjustingPlacement and not PlacementMatchesProfile() then ApplyPlacement() end
end)

SLASH_DEFYLERDAMAGEMETER1 = "/ddm"
SLASH_DEFYLERDAMAGEMETER2 = "/defylermeter"
SlashCmdList.DEFYLERDAMAGEMETER = function(message)
    message = string.lower((message or ""):match("^%s*(.-)%s*$"))
    if message == "reset" then
        if C_DamageMeter and C_DamageMeter.ResetAllCombatSessions then C_DamageMeter.ResetAllCombatSessions() end
        print("DDM: combat sessions reset.")
    elseif message == "reskin" then ApplyPlacement(); ApplyMeterSettings(); StyleAll(); print("DDM: skin reapplied.")
    elseif message == "options" or message == "config" then
        local success, reason = DDM_OpenOptions()
        if success == false then print("DDM: " .. (reason or "options unavailable.")) end
    else
        print("DDM: drag the header, resize from the lower-right, or click DUI. Commands: /ddm options, /ddm reset, /ddm reskin")
    end
end
