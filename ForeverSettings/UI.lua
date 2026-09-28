local _, FS = ...
local pending = {}

local function TakeWindowPositionOwnership(frame)
    if frame.SetUserPlaced then frame:SetUserPlaced(false) end
    if frame.SetDontSavePosition then frame:SetDontSavePosition(true) end
end

local function SaveWindowPosition(frame)
    local left, top = frame:GetLeft(), frame:GetTop()
    local scale = frame:GetEffectiveScale()
    if not left or not top or not scale or scale <= 0 then return end
    ForeverSettingsDB = type(ForeverSettingsDB) == "table" and ForeverSettingsDB or {}
    ForeverSettingsDB.windowPosition = {
        left = left * scale,
        top = top * scale,
    }
    if DefylerUI_SaveSuiteSettings then DefylerUI_SaveSuiteSettings() end
end

local function RestoreWindowPosition(frame)
    local position = type(ForeverSettingsDB) == "table" and ForeverSettingsDB.windowPosition
    local scale = frame:GetEffectiveScale()
    if type(position) ~= "table"
        or type(position.left) ~= "number"
        or type(position.top) ~= "number"
        or not scale
        or scale <= 0 then
        return
    end
    TakeWindowPositionOwnership(frame)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", position.left / scale, position.top / scale)
end

local function CreateText(parent, template, text)
    local label = parent:CreateFontString(nil, "OVERLAY", template)
    label:SetText(text or "")
    label:SetJustifyH("LEFT")
    return label
end

local function FormatValue(setting, value)
    if value == nil then return "Unavailable" end
    if setting.format == "percent" then return string.format("%.0f%%", value * 100) end
    if setting.step < 1 then return string.format("%.2f", value) end
    return tostring(math.floor(value + .5))
end

local function Round(setting, value)
    local steps = math.floor(((value - setting.min) / setting.step) + .5)
    return math.max(setting.min, math.min(setting.max, setting.min + steps * setting.step))
end

function FS:SetStatus(message, errorState)
    self.window.status:SetText(message)
    self.window.status:SetTextColor(errorState and 1 or .6, errorState and .35 or .8, errorState and .3 or .65)
end

function FS:RefreshFogToggle()
    local toggle = self.window and self.window.fogToggle
    if not toggle then return end
    local available, reason = self:GetAvailability("volumeFog")
    local value = self:GetValue("volumeFog")
    toggle.updating = true
    toggle:SetChecked(available and value ~= nil and value ~= 0)
    toggle:SetEnabled(available)
    toggle:SetAlpha(available and 1 or .5)
    toggle.tooltip = available
        and "Master fog switch. Volumetric fog quality remains available on the Effects tab."
        or reason
    toggle.updating = false
end

function FS:RefreshRows()
    local visible = {}
    for _, setting in ipairs(self.settings) do
        if setting.category == self.window.category then visible[#visible + 1] = setting end
    end
    for index, row in ipairs(self.window.rows) do
        local setting = visible[index]
        row.setting = setting
        if not setting then row:Hide() else
            row:Show()
            local available, reason = self:GetAvailability(setting.cvar)
            local current = self:GetValue(setting.cvar)
            row.label:SetText(setting.label)
            row.help:SetText(setting.help or setting.cvar .. (setting.raid and " + " .. setting.raid or ""))
            row.slider:SetMinMaxValues(setting.min, setting.max)
            row.slider:SetValueStep(setting.step)
            row.slider:SetObeyStepOnDrag(true)
            row.slider:SetEnabled(available)
            row.edit:SetEnabled(available)
            row.slider.setting = setting
            row.updating = true
            row.slider:SetValue(pending[setting.cvar] or current or setting.min)
            row.edit:SetText(tostring(pending[setting.cvar] or current or ""))
            row.updating = false
            row.actual:SetText(available and ("Current: " .. FormatValue(setting, current)) or reason)
            row.actual:SetTextColor(available and .65 or 1, available and .72 or .35, available and .82 or .3)
        end
    end
    self:RefreshFogToggle()
end

function FS:SelectCategory(category)
    self.window.category = category
    for id, button in pairs(self.window.categoryButtons) do
        button:SetEnabled(id ~= category)
    end
    self:RefreshRows()
end

function FS:ApplyPending()
    local changed, failed, clamped, reload = 0, 0, 0, false
    for _, setting in ipairs(self.settings) do
        local value = pending[setting.cvar]
        if value ~= nil then
            local success, message = self:SetValue(setting.cvar, value)
            if success then
                changed = changed + 1
                if message:find("Clamped", 1, true) then clamped = clamped + 1 end
                reload = reload or setting.reload
                if ForeverSettingsDB.linkRaid and setting.raid then
                    local raidSuccess, raidMessage = self:SetValue(setting.raid, value)
                    if not raidSuccess then failed = failed + 1
                    elseif raidMessage:find("Clamped", 1, true) then clamped = clamped + 1 end
                end
            else failed = failed + 1 end
        end
    end
    wipe(pending)
    self:SaveProfile()
    self:RefreshRows()
    local suffix = reload and " Some display changes may require /reload or a client restart." or ""
    self:SetStatus(string.format("Applied %d setting(s); %d clamped; %d rejected.%s", changed, clamped, failed, suffix), failed > 0)
end

function FS:CreateRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(650, 43)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * 47)
    row.label = CreateText(row, "GameFontNormal", "")
    row.label:SetPoint("TOPLEFT", 0, -2)
    row.label:SetWidth(175)
    row.help = CreateText(row, "GameFontDisableSmall", "")
    row.help:SetPoint("TOPLEFT", 0, -21)
    row.help:SetWidth(175)
    row.help:SetWordWrap(false)
    row.slider = CreateFrame("Slider", nil, row, "OptionsSliderTemplate")
    row.slider:SetSize(270, 16)
    row.slider:SetPoint("LEFT", 190, 3)
    row.slider.Low:SetText("")
    row.slider.High:SetText("")
    row.slider.Text:SetText("")
    row.edit = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    row.edit:SetSize(75, 24)
    row.edit:SetPoint("LEFT", row.slider, "RIGHT", 12, 0)
    row.edit:SetAutoFocus(false)
    row.edit:SetNumeric(false)
    row.actual = CreateText(row, "GameFontDisableSmall", "")
    row.actual:SetPoint("LEFT", row.edit, "RIGHT", 12, 0)
    row.actual:SetWidth(120)
    row.slider:SetScript("OnValueChanged", function(slider, value)
        if row.updating or not row.setting then return end
        value = Round(row.setting, value)
        pending[row.setting.cvar] = value
        row.edit:SetText(tostring(value))
    end)
    row.edit:SetScript("OnEnterPressed", function(edit)
        local value = tonumber(edit:GetText())
        if value and row.setting then
            value = math.max(row.setting.min, math.min(row.setting.max, value))
            pending[row.setting.cvar] = value
            row.updating = true
            row.slider:SetValue(value)
            row.updating = false
            edit:SetText(tostring(value))
            edit:ClearFocus()
        else
            FS:SetStatus("Enter a number inside the displayed range.", true)
        end
    end)
    row.edit:SetScript("OnEscapePressed", function(edit) edit:ClearFocus(); FS:RefreshRows() end)
    return row
end

function FS:CreateWindow()
    local window = CreateFrame("Frame", "ForeverSettingsWindow", UIParent, "BackdropTemplate")
    window:SetSize(860, 660)
    window:SetPoint("CENTER")
    window:SetFrameStrata("DIALOG")
    window:SetMovable(true)
    window:EnableMouse(true)
    TakeWindowPositionOwnership(window)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", function(self)
        self:StartMoving()
        TakeWindowPositionOwnership(self)
    end)
    window:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        TakeWindowPositionOwnership(self)
        SaveWindowPosition(self)
    end)
    window:SetScript("OnShow", function(self)
        RestoreWindowPosition(self)
    end)
    window:SetBackdrop({ bgFile="Interface\\Buttons\\WHITE8X8", edgeFile="Interface\\Buttons\\WHITE8X8", edgeSize=1 })
    window:SetBackdropColor(.035, .05, .075, .98)
    window:SetBackdropBorderColor(.32, .4, .5, 1)
    local title = CreateText(window, "GameFontNormalLarge", "Forever Settings")
    title:SetPoint("TOPLEFT", 22, -18)
    local subtitle = CreateText(window, "GameFontHighlightSmall", "Extended controls with client readback")
    subtitle:SetPoint("TOPLEFT", 22, -45)
    local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    window.categoryButtons = {}
    for index, category in ipairs(self.categories) do
        local button = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
        button:SetSize(120, 25)
        button:SetPoint("TOPLEFT", 22 + (index - 1) * 126, -76)
        button:SetText(category.name)
        button:SetScript("OnClick", function() FS:SelectCategory(category.id) end)
        window.categoryButtons[category.id] = button
    end

    local fogToggle = CreateFrame("CheckButton", nil, window, "UICheckButtonTemplate")
    fogToggle:SetPoint("TOPRIGHT", -405, -73)
    fogToggle.Text:SetText("Enable fog")
    fogToggle.Text:SetWidth(120)
    fogToggle:SetScript("OnClick", function(button)
        if button.updating then return end
        local requested = button:GetChecked() and 1 or 0
        local success, message, actual = FS:SetValue("volumeFog", requested)
        FS:RefreshFogToggle()
        if success then
            FS:SaveProfile()
            FS:SetStatus(actual ~= 0 and "Fog enabled." or "Fog disabled.")
        else
            FS:SetStatus("Fog setting rejected: " .. (message or "unknown error"), true)
        end
    end)
    fogToggle:SetScript("OnEnter", function(button)
        GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
        GameTooltip:SetText("Fog")
        GameTooltip:AddLine(button.tooltip or "Master fog switch.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    fogToggle:SetScript("OnLeave", GameTooltip_Hide)
    window.fogToggle = fogToggle

    local linkRaid = CreateFrame("CheckButton", nil, window, "UICheckButtonTemplate")
    linkRaid:SetPoint("TOPRIGHT", -180, -73)
    linkRaid:SetChecked(ForeverSettingsDB.linkRaid)
    linkRaid.Text:SetText("Apply linked raid settings")
    linkRaid.Text:SetWidth(160)
    linkRaid:SetScript("OnClick", function(button) ForeverSettingsDB.linkRaid = button:GetChecked() and true or false end)

    local content = CreateFrame("Frame", nil, window)
    content:SetSize(815, 520)
    content:SetPoint("TOPLEFT", 24, -120)
    window.rows = {}
    for index = 1, self.PAGE_SIZE do window.rows[index] = self:CreateRow(content, index) end

    local apply = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    apply:SetSize(120, 26)
    apply:SetPoint("BOTTOMRIGHT", -20, 18)
    apply:SetText("Apply changes")
    apply:SetScript("OnClick", function() FS:ApplyPending() end)
    local refresh = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    refresh:SetSize(100, 26)
    refresh:SetPoint("RIGHT", apply, "LEFT", -8, 0)
    refresh:SetText("Read current")
    refresh:SetScript("OnClick", function() wipe(pending); FS:RefreshRows(); FS:SetStatus("Read current values from the client.") end)
    local save = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    save:SetSize(100, 26)
    save:SetPoint("BOTTOMLEFT", 20, 18)
    save:SetText("Save profile")
    save:SetScript("OnClick", function() FS:SaveProfile(); FS:SetStatus("Saved the current settings profile.") end)
    local restore = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    restore:SetSize(110, 26)
    restore:SetPoint("LEFT", save, "RIGHT", 8, 0)
    restore:SetText("Restore profile")
    restore:SetScript("OnClick", function()
        local applied, failed = FS:RestoreProfile()
        FS:RefreshRows()
        FS:SetStatus(string.format("Restored %d values; %d rejected.", applied, failed), failed > 0)
    end)
    window.status = CreateText(window, "GameFontHighlightSmall", "Move a slider or type a value, then Apply changes.")
    window.status:SetPoint("BOTTOMLEFT", restore, "RIGHT", 16, 7)
    window.status:SetWidth(350)
    window.category = "rendering"
    window:Hide()
    self.window = window
    table.insert(UISpecialFrames, "ForeverSettingsWindow")
    self:SelectCategory("rendering")
end

function FS:Toggle()
    if self.window:IsShown() then self.window:Hide() else
        wipe(pending)
        self:RefreshRows()
        self.window:Show()
    end
end
