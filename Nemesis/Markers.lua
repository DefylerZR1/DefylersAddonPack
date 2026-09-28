local N = Nemesis

local function plateForUnit(unit)
    if C_NamePlate and C_NamePlate.GetNamePlateForUnit then
        return C_NamePlate.GetNamePlateForUnit(unit)
    end
end

function N:ApplyMarker(unit, entry, key)
    if not self.db.settings.markersEnabled then return end
    local plate = plateForUnit(unit)
    if not plate then return end
    local previous = self.activeKeys[key]
    if previous and previous.frame and previous.unit ~= unit then previous.frame:Hide() end
    local frame = plate.NemesisMarker
    if not frame then
        frame = CreateFrame("Frame", nil, plate)
        frame:SetFrameStrata("HIGH")
        frame:SetFrameLevel((plate:GetFrameLevel() or 0) + 20)
        frame.Icon = frame:CreateTexture(nil, "OVERLAY")
        frame.Icon:SetAllPoints()
        plate.NemesisMarker = frame
    end
    local size = tonumber(entry.markerSize) or self.db.settings.markerSize
    local x = tonumber(entry.markerOffsetX) or self.db.settings.markerOffsetX
    local y = tonumber(entry.markerOffsetY) or self.db.settings.markerOffsetY
    local color = entry.markerColor or self.db.settings.markerColor
    frame:SetSize(size, size)
    frame:ClearAllPoints()
    frame:SetPoint("BOTTOM", plate, "TOP", x, y)
    frame.Icon:SetTexture(self:MarkerPath(entry.marker))
    frame.Icon:SetVertexColor(color.r or 1, color.g or 1, color.b or 1, color.a or 1)
    frame:Show()
    local state = {plate=plate, frame=frame, key=key, unit=unit}
    self.activeUnits[unit] = state
    self.activeKeys[key] = state
end

function N:ShowMarkerPrompt(unit, entry, key)
    if not self.db.settings.markersEnabled then return end
    if self.acknowledgedKeys[key] then
        self:ApplyMarker(unit, entry, key)
        return
    end
    local active = self.activeKeys[key]
    self.pendingMarkerPrompts = self.pendingMarkerPrompts or {}
    if active and active.key == key and active.frame and active.frame:IsShown() then
        self.pendingMarkerPrompts[key] = nil
        return
    end

    local prompt = self.markerPrompt
    if prompt and prompt:IsShown() then
        if prompt.key == key then prompt.unit = unit; return end
        self.pendingMarkerPrompts[key] = {unit=unit, key=key}
        return
    end
    if not prompt then
        prompt = CreateFrame("Frame", "NemesisMarkerPrompt", UIParent)
        prompt:SetSize(270, 56)
        local settings = self.db.settings
        prompt:SetPoint(settings.promptPoint or "BOTTOM", UIParent, settings.promptPoint or "BOTTOM", settings.promptX or 0, settings.promptY or 165)
        prompt:SetScale(0.85)
        prompt:SetFrameStrata("DIALOG")
        prompt:SetMovable(true)
        prompt:EnableMouse(true)
        prompt:RegisterForDrag("LeftButton")
        prompt:SetScript("OnDragStart", prompt.StartMoving)
        prompt:SetScript("OnDragStop", function(frame)
            frame:StopMovingOrSizing()
            local point, _, _, x, y = frame:GetPoint()
            settings.promptPoint, settings.promptX, settings.promptY = point, x, y
        end)
        prompt.Background = prompt:CreateTexture(nil, "BACKGROUND")
        prompt.Background:SetAllPoints()
        prompt.Background:SetColorTexture(0.015, 0.015, 0.015, 0.92)
        local function border(pointA, pointB, width, height)
            local line = prompt:CreateTexture(nil, "BORDER")
            line:SetColorTexture(0.65, 0.43, 0.08, 0.95)
            line:SetPoint(pointA)
            line:SetPoint(pointB)
            if width then line:SetWidth(width) end
            if height then line:SetHeight(height) end
        end
        border("TOPLEFT", "TOPRIGHT", nil, 1)
        border("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
        border("TOPLEFT", "BOTTOMLEFT", 1, nil)
        border("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
        prompt.Icon = prompt:CreateTexture(nil, "ARTWORK")
        prompt.Icon:SetSize(38, 38)
        prompt.Icon:SetPoint("LEFT", 9, 0)
        prompt.Text = prompt:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        prompt.Text:SetPoint("LEFT", 54, 0)
        prompt.Text:SetWidth(100)
        prompt.Text:SetJustifyH("LEFT")
        prompt.Mark = CreateFrame("Button", nil, prompt, "UIPanelButtonTemplate")
        prompt.Mark:SetSize(92, 25)
        prompt.Mark:SetPoint("LEFT", 158, 0)
        prompt.Mark:SetScript("OnClick", function()
            local currentUnit, currentKey = prompt.unit, prompt.key
            local currentEntry = currentKey and N.db.entries[currentKey]
            if currentUnit and currentEntry and UnitExists(currentUnit) then
                local _, foundKey = N:GetEntryByUnit(currentUnit)
                if foundKey == currentKey then
                    N.acknowledgedKeys[currentKey] = true
                    N:ApplyMarker(currentUnit, currentEntry, currentKey)
                end
            end
            if InCombatLockdown and InCombatLockdown() then
                N:Print("Target and Set Focus are unavailable during combat.")
                N.pendingMarkerPrompts[currentKey] = nil
                prompt:Hide()
                N:ShowNextMarkerPrompt()
            else
                prompt.Mark:Hide()
                prompt.Target:Show()
            end
        end)
        prompt.Target = CreateFrame("Button", nil, prompt, "UIPanelButtonTemplate,SecureActionButtonTemplate")
        prompt.Target:SetSize(92, 25)
        prompt.Target:SetPoint("LEFT", 158, 0)
        prompt.Target:SetText("Target")
        prompt.Target:SetAttribute("type", "target")
        prompt.Target:SetScript("PostClick", function(self)
            self:Hide()
            prompt.Focus:Show()
        end)
        prompt.Target:Hide()
        prompt.Focus = CreateFrame("Button", nil, prompt, "UIPanelButtonTemplate,SecureActionButtonTemplate")
        prompt.Focus:SetSize(92, 25)
        prompt.Focus:SetPoint("LEFT", 158, 0)
        prompt.Focus:SetText("Set Focus")
        prompt.Focus:SetAttribute("type", "focus")
        prompt.Focus:SetScript("PostClick", function()
            local currentKey = prompt.key
            N.pendingMarkerPrompts[currentKey] = nil
            prompt:Hide()
            N:ShowNextMarkerPrompt()
        end)
        prompt.Focus:Hide()
        prompt.Close = CreateFrame("Button", nil, prompt, "UIPanelCloseButton")
        prompt.Close:SetSize(20, 20)
        prompt.Close:SetPoint("TOPRIGHT", 3, 3)
        prompt:Hide()
        self.markerPrompt = prompt
    end

    prompt.unit, prompt.key = unit, key
    if not InCombatLockdown or not InCombatLockdown() then
        prompt.Target:SetAttribute("unit", unit)
        prompt.Focus:SetAttribute("unit", unit)
        prompt.Target:SetEnabled(true)
        prompt.Focus:SetEnabled(true)
    else
        prompt.Target:SetEnabled(false)
        prompt.Focus:SetEnabled(false)
    end
    prompt.Icon:SetTexture(self:MarkerPath(entry.marker))
    local color = entry.markerColor or self.db.settings.markerColor
    prompt.Icon:SetVertexColor(color.r or 1, color.g or 1, color.b or 1, color.a or 1)
    prompt.Text:SetText(entry.displayName or entry.name or "Unknown")
    prompt.Mark:SetText("Add Marker")
    prompt.Mark:Show()
    prompt.Target:Hide()
    prompt.Focus:Hide()
    prompt:Show()
end

function N:ShowNextMarkerPrompt()
    if not self.pendingMarkerPrompts or not self.db then return end
    for _, item in ipairs(self:SortedEntries("")) do
        local pending = self.pendingMarkerPrompts[item.key]
        if pending then
            self.pendingMarkerPrompts[item.key] = nil
            if UnitExists(pending.unit) then
                self:ShowMarkerPrompt(pending.unit, item.entry, item.key)
                return
            end
        end
    end
end

function N:RemoveUnit(unit)
    local state = self.activeUnits[unit]
    if state and state.frame then state.frame:Hide() end
    if state and self.activeKeys[state.key] == state then self.activeKeys[state.key] = nil end
    self.activeUnits[unit] = nil
    if self.markerPrompt and self.markerPrompt.unit == unit then
        self.markerPrompt:Hide()
        self:ShowNextMarkerPrompt()
    end
end

function N:ClearAllMarkers()
    for unit, state in pairs(self.activeUnits) do
        if state.frame then state.frame:Hide() end
        if self.activeKeys[state.key] == state then self.activeKeys[state.key] = nil end
        self.activeUnits[unit] = nil
    end
end

function N:RefreshActiveMarkers(key)
    for unit, state in pairs(self.activeUnits) do
        if not key or state.key == key then
            local entry = self.db.entries[state.key]
            if entry then self:ApplyMarker(unit, entry, state.key) else self:RemoveUnit(unit) end
        end
    end
end
