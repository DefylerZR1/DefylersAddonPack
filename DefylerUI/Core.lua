local addonName = ...

local MIN_SCALE = .65
local MAX_SCALE = 1.50
local TITLE_HEIGHT = 24
local RESCAN_SECONDS = 3
local POSITION_EPSILON = 1

local ignored = {
    UIParent = true,
    WorldFrame = true,
    PlayerFrame = true,
    TargetFrame = true,
    FocusFrame = true,
    GameMenuFrame = true,
    CinematicFrame = true,
    MovieFrame = true,
    StaticPopup1 = true,
    StaticPopup2 = true,
    StaticPopup3 = true,
    StaticPopup4 = true,
    DamageMeter = true,
    -- Blizzard bag item actions are protected. Never add geometry hooks,
    -- drag handles, resize controls, or persistence writes to their owner.
    ContainerFrameCombinedBags = true,
}

local explicitFrames = {
    "AuctionHouseFrame",
    "BankFrame",
    "ProfessionsFrame",
    "TradeSkillFrame",
    "LFGParentFrame",
    "CharacterFrame",
    "SpellBookFrame",
    "QuestLogFrame",
    "QuestFrame",
    "FriendsFrame",
    "MailFrame",
    "MerchantFrame",
    "GossipFrame",
    "ClassTrainerFrame",
    "InspectFrame",
    "MacroFrame",
    "AddonList",
    "ObjectiveTrackerFrame",
    "MinimapCluster",
}

local specialManagedFrames = {
    ObjectiveTrackerFrame = true,
    MinimapCluster = true,
}

-- Blizzard refreshes managed panel positions during tradeskill updates. Once
-- DUI owns the tracker anchor, leave it out of that cycle so repeated crafts
-- cannot alternate between Blizzard's anchor and the saved DUI anchor.
local detachedPositionFrames = {
    ObjectiveTrackerFrame = true,
}

local unclampedFrames = {
    ObjectiveTrackerFrame = true,
    MinimapCluster = true,
}

local keepOnScreenFrames = {
    MinimapCluster = true,
}

local managed = setmetatable({}, { __mode = "k" })
local activeResizes = setmetatable({}, { __mode = "k" })
local activeDrags = setmetatable({}, { __mode = "k" })
local nativeMoves = setmetatable({}, { __mode = "k" })
local applyingRestores = setmetatable({}, { __mode = "k" })
local persistenceGuards = setmetatable({}, { __mode = "k" })
local frameRestorePending = setmetatable({}, { __mode = "k" })
local frameRestoreGeneration = setmetatable({}, { __mode = "k" })
local elapsed = 0
local restoreScheduled = false
local bagRestoreScheduled = false
local minimapButton
local variablesReady = false
local preloadDatabase = { frames = {}, enabled = true, coordinateVersion = 3 }

local function IsForbiddenFrame(frame)
    if not frame then return true end
    local ok, forbidden = pcall(function()
        return frame.IsForbidden and frame:IsForbidden()
    end)
    return not ok or forbidden
end

local function Database()
    -- Forever can fire ADDON_LOADED while it is still materializing nested
    -- SavedVariables. Never create those nested tables before VARIABLES_LOADED
    -- or the incoming saved frame records can be merged into an empty table.
    if not variablesReady then return preloadDatabase end
    DefylerUIDB = type(DefylerUIDB) == "table" and DefylerUIDB or {}
    DefylerUIDB.frames = type(DefylerUIDB.frames) == "table" and DefylerUIDB.frames or {}
    if DefylerUIDB.coordinateVersion ~= 3 then
        -- RestoreFrame supports both pixel top-left records and the older
        -- center fallback, so a version stamp never needs to erase positions.
        DefylerUIDB.coordinateVersion = 3
    end
    if DefylerUIDB.enabled == nil then DefylerUIDB.enabled = true end
    return DefylerUIDB
end

-- Only these two tested systems use the engine geometry methods retained by
-- Blizzard before installing its Edit Mode layout overrides. Never replace a
-- Blizzard method, invoke tracker Update, or read aura data from this addon.
local function UsesDirectGeometry(frame)
    return specialManagedFrames[frame:GetName()] == true
end

local function HasDirectGeometry(frame)
    return type(frame.SetScaleBase) == "function"
        and type(frame.SetPointBase) == "function"
        and type(frame.ClearAllPointsBase) == "function"
end

local function GeometrySupported(frame)
    if UsesDirectGeometry(frame) then return HasDirectGeometry(frame) end
    return type(frame.SetScaleOverride) ~= "function"
end

local function SetFrameScale(frame, scale)
    if UsesDirectGeometry(frame) then frame:SetScaleBase(scale)
    else frame:SetScale(scale) end
end

local function ClearFramePoints(frame)
    if UsesDirectGeometry(frame) then frame:ClearAllPointsBase()
    else frame:ClearAllPoints() end
end

local function SetFramePoint(frame, ...)
    if UsesDirectGeometry(frame) then frame:SetPointBase(...)
    else frame:SetPoint(...) end
end

local function CanChange(frame, notifyBlocked)
    if IsForbiddenFrame(frame) then return false end
    if ignored[frame:GetName()] or not GeometrySupported(frame) then return false end
    if UsesDirectGeometry(frame) and InCombatLockdown() then return false end
    if InCombatLockdown and InCombatLockdown() and frame.IsProtected and frame:IsProtected() then
        if notifyBlocked and UIErrorsFrame then
            UIErrorsFrame:AddMessage("That window cannot be moved during combat.", 1, .2, .2)
        end
        return false
    end
    return true
end

local function FrameKey(frame)
    if IsForbiddenFrame(frame) then return nil end
    return frame and frame.GetName and frame:GetName()
end

-- StartMoving and SetUserPlaced enroll named frames in Blizzard's
-- per-character layout-local.txt cache. DUI already owns persistence for
-- frames with saved geometry, so keep those frames out of the native cache
-- and request exclusion from managers that honor ignoreFramePositionManager. The
-- UI panel manager can still re-anchor panels; the drift repair below corrects it.
local function TakePositionOwnership(frame)
    if UsesDirectGeometry(frame) then return end

    -- These getters keep the periodic drift check read-only after ownership is
    -- established. StartMoving can turn userPlaced back on, so verify it each
    -- time instead of trusting a one-time cache.
    local userPlaced = frame.IsUserPlaced and frame:IsUserPlaced()
    if userPlaced and frame.SetUserPlaced then frame:SetUserPlaced(false) end

    local dontSave = frame.GetDontSavePosition and frame:GetDontSavePosition()
    if dontSave ~= true and frame.SetDontSavePosition then
        frame:SetDontSavePosition(true)
    end
    frame.ignoreFramePositionManager = true
end

local function SetAppropriateClamping(frame)
    local name = FrameKey(frame)
    frame:SetClampedToScreen(not (name and unclampedFrames[name]))
end

local function GetTopLeftPixels(frame)
    local left, top = frame:GetLeft(), frame:GetTop()
    if not left or not top then return nil, nil end
    local scale = frame:GetEffectiveScale()
    return left * scale, top * scale
end

local function NearlyEqual(left, right, epsilon)
    return type(left) == "number" and type(right) == "number"
        and math.abs(left - right) <= (epsilon or POSITION_EPSILON)
end

local function FrameMatchesSaved(frame, saved)
    if not NearlyEqual(frame:GetScale(), saved.scale or 1, .001) then return false end
    if saved.left and saved.top then
        local left, top = GetTopLeftPixels(frame)
        return NearlyEqual(left, saved.left) and NearlyEqual(top, saved.top)
    end
    local centerX, centerY = frame:GetCenter()
    return NearlyEqual(centerX, saved.centerX) and NearlyEqual(centerY, saved.centerY)
end

local function PinTopLeft(frame, leftPixels, topPixels)
    local scale = frame:GetEffectiveScale()
    if not scale or scale == 0 then return end
    ClearFramePoints(frame)
    SetFramePoint(frame, "TOPLEFT", UIParent, "BOTTOMLEFT", leftPixels / scale, topPixels / scale)
end

local function ClampTopLeftToScreen(frame, leftPixels, topPixels)
    local uiScale = UIParent:GetEffectiveScale()
    local frameScale = frame:GetEffectiveScale()
    local screenWidth = UIParent:GetWidth() * uiScale
    local screenHeight = UIParent:GetHeight() * uiScale
    local frameWidth = frame:GetWidth() * frameScale
    local frameHeight = frame:GetHeight() * frameScale
    if screenWidth <= 0 or screenHeight <= 0 or frameWidth <= 0 or frameHeight <= 0 then
        return leftPixels, topPixels
    end
    local margin = 8
    local maxLeft = math.max(margin, screenWidth - frameWidth - margin)
    local minTop = math.min(screenHeight - margin, frameHeight + margin)
    return math.max(margin, math.min(maxLeft, leftPixels)),
        math.max(minTop, math.min(screenHeight - margin, topPixels))
end

local function SaveFrame(frame)
    local name = FrameKey(frame)
    if not name then return end
    local left, top = GetTopLeftPixels(frame)
    local centerX, centerY = frame:GetCenter()
    if not left or not top or not centerX or not centerY then return end
    Database().frames[name] = {
        left = left,
        top = top,
        centerX = centerX,
        centerY = centerY,
        scale = frame:GetScale(),
    }
    if DefylerUI_SaveSuiteSettings then DefylerUI_SaveSuiteSettings() end
end

local function RestoreFrame(frame)
    if activeResizes[frame] or activeDrags[frame] or nativeMoves[frame] then return end
    local name = FrameKey(frame)
    local saved = name and Database().frames[name]
    if not saved or not CanChange(frame) then return end

    applyingRestores[frame] = true
    local ok, restoreError = pcall(function()
        TakePositionOwnership(frame)
        if FrameMatchesSaved(frame, saved) then return end

        SetFrameScale(frame, math.max(MIN_SCALE, math.min(MAX_SCALE, saved.scale or 1)))
        if saved.left and saved.top then
            local left, top = saved.left, saved.top
            if keepOnScreenFrames[name] then
                left, top = ClampTopLeftToScreen(frame, left, top)
                saved.left, saved.top = left, top
            end
            PinTopLeft(frame, left, top)
        else
            ClearFramePoints(frame)
            SetFramePoint(frame, "CENTER", UIParent, "BOTTOMLEFT", saved.centerX, saved.centerY)
        end
    end)
    applyingRestores[frame] = nil
    if not ok then error(restoreError) end
end

local function ScheduleFrameRestore(frame)
    if frameRestorePending[frame] or not Database().enabled then return end
    frameRestorePending[frame] = true
    C_Timer.After(0, function()
        frameRestorePending[frame] = nil
        RestoreFrame(frame)
    end)
end

local function RestoreFrameThroughStartup(frame)
    local generation = (frameRestoreGeneration[frame] or 0) + 1
    frameRestoreGeneration[frame] = generation
    for _, delay in ipairs({0, 0.1, 0.5, 1, 2, 4, 8}) do
        C_Timer.After(delay, function()
            if frameRestoreGeneration[frame] == generation then RestoreFrame(frame) end
        end)
    end
end

local function InstallPersistenceGuards(frame)
    if persistenceGuards[frame] then return end
    persistenceGuards[frame] = true
    local function GeometryChanged()
        if applyingRestores[frame] or activeResizes[frame] or activeDrags[frame] or nativeMoves[frame] then return end
        local name = FrameKey(frame)
        if name and Database().frames[name] then ScheduleFrameRestore(frame) end
    end
    local function NativeMoveStarted()
        if applyingRestores[frame] or activeResizes[frame] or activeDrags[frame] then return end
        nativeMoves[frame] = true
        -- Cancel delayed restores while the player is dragging through a
        -- Blizzard or another addon's title bar.
        frameRestoreGeneration[frame] = (frameRestoreGeneration[frame] or 0) + 1
    end
    local function NativeMoveStopped()
        if not nativeMoves[frame] then return end
        nativeMoves[frame] = nil
        C_Timer.After(0, function()
            if CanChange(frame) then
                TakePositionOwnership(frame)
                SaveFrame(frame)
            end
        end)
    end
    if not detachedPositionFrames[FrameKey(frame)] then
        hooksecurefunc(frame, "SetPoint", GeometryChanged)
    end
    hooksecurefunc(frame, "SetScale", GeometryChanged)
    hooksecurefunc(frame, "StartMoving", NativeMoveStarted)
    hooksecurefunc(frame, "StopMovingOrSizing", NativeMoveStopped)
end

local function StopDragging(handle)
    local frame = handle.owner
    if not frame then return end
    handle:SetScript("OnUpdate", nil)
    if not CanChange(frame) then activeDrags[frame] = nil; return end
    if not UsesDirectGeometry(frame) then frame:StopMovingOrSizing() end
    TakePositionOwnership(frame)
    SaveFrame(frame)
    activeDrags[frame] = nil
end

local function CreateTitleHandle(frame)
    local handle = CreateFrame("Button", nil, frame)
    handle.owner = frame
    if FrameKey(frame) == "MinimapCluster" and frame.BorderTop then
        handle:SetPoint("TOPLEFT", frame.BorderTop, "TOPLEFT", -4, 4)
        handle:SetPoint("BOTTOMRIGHT", frame.BorderTop, "BOTTOMRIGHT", 4, -4)
        handle:SetFrameStrata("DIALOG")
        handle:SetFrameLevel(10000)
    else
        handle:SetPoint("TOPLEFT", frame, "TOPLEFT", 42, -1)
        handle:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -42, -1)
        handle:SetHeight(TITLE_HEIGHT)
        handle:SetFrameLevel(math.min(10000, frame:GetFrameLevel() + 900))
    end
    handle:RegisterForDrag("LeftButton")
    handle:SetScript("OnDragStart", function(self)
        if not Database().enabled or not CanChange(self.owner, true) then return end
        activeDrags[self.owner] = true
        if UsesDirectGeometry(self.owner) then
            local left, top = GetTopLeftPixels(self.owner)
            if not left or not top then activeDrags[self.owner] = nil; return end
            local startX, startY = GetCursorPosition()
            self:SetScript("OnUpdate", function(handle)
                if not CanChange(handle.owner) then
                    handle:SetScript("OnUpdate", nil)
                    activeDrags[handle.owner] = nil
                    return
                end
                local x, y = GetCursorPosition()
                PinTopLeft(handle.owner, left + x - startX, top + y - startY)
            end)
            return
        end
        self.owner:SetMovable(true)
        SetAppropriateClamping(self.owner)
        self.owner:StartMoving()
        -- StartMoving automatically sets the native user-placed flag. Clear it
        -- immediately so layout-local.txt cannot become a second authority.
        TakePositionOwnership(self.owner)
    end)
    handle:SetScript("OnDragStop", StopDragging)
    handle:SetScript("OnHide", function(self) if activeDrags[self.owner] then StopDragging(self) end end)
    handle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Drag to move")
    end)
    handle:SetScript("OnLeave", GameTooltip_Hide)
    frame.DefylerUITitleHandle = handle
end

local function StopScaling(grip)
    if not grip.resizing then return end
    grip:SetScript("OnUpdate", nil)
    grip.resizing = nil
    if not CanChange(grip.owner) then
        activeResizes[grip.owner] = nil; grip.currentScale = nil; return
    end
    if grip.currentScale then
        SetFrameScale(grip.owner, grip.currentScale)
        PinTopLeft(grip.owner, grip.anchorLeft, grip.anchorTop)
    end
    SaveFrame(grip.owner)
    activeResizes[grip.owner] = nil
    grip.currentScale = nil
end

local function StartScaling(grip)
    local frame = grip.owner
    if not Database().enabled or not CanChange(frame, true) then return end
    local left, top = GetTopLeftPixels(frame)
    if not left or not top then return end
    TakePositionOwnership(frame)
    activeResizes[frame] = grip
    frame:SetClampedToScreen(false)
    PinTopLeft(frame, left, top)
    grip.anchorLeft = left
    grip.anchorTop = top
    local cursorX, cursorY = GetCursorPosition()
    grip.startX = cursorX
    grip.startY = cursorY
    grip.startScale = frame:GetScale()
    grip.currentScale = grip.startScale
    grip.resizing = true
    grip:SetScript("OnUpdate", function(self)
        if not self.resizing then return end
        if not CanChange(self.owner) then StopScaling(self); return end
        local x, y = GetCursorPosition()
        local uiScale = UIParent:GetEffectiveScale()
        local diagonal = ((x - self.startX) - (y - self.startY)) / uiScale
        local reference = math.max(240, self.owner:GetWidth() + self.owner:GetHeight())
        local scale = self.startScale + diagonal / reference
        self.currentScale = math.max(MIN_SCALE, math.min(MAX_SCALE, scale))
        SetFrameScale(self.owner, self.currentScale)
        PinTopLeft(self.owner, self.anchorLeft, self.anchorTop)
    end)
end

local function CreateResizeGrip(frame)
    local grip = CreateFrame("Button", nil, frame)
    grip.owner = frame
    if FrameKey(frame) == "MinimapCluster" then
        grip:SetSize(26, 26)
        grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
        grip:SetFrameStrata("DIALOG")
        grip:SetFrameLevel(10000)
    else
        grip:SetSize(20, 20)
        grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
        grip:SetFrameLevel(math.min(10000, frame:GetFrameLevel() + 900))
    end
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:RegisterForClicks("LeftButtonDown", "LeftButtonUp")
    grip:SetScript("OnMouseDown", StartScaling)
    grip:SetScript("OnMouseUp", StopScaling)
    grip:SetScript("OnHide", StopScaling)
    grip:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Drag to resize")
    end)
    grip:SetScript("OnLeave", GameTooltip_Hide)
    frame.DefylerUIResizeGrip = grip
end

local function HasWindowChrome(frame, name)
    if UIPanelWindows and UIPanelWindows[name] then return true end
    if frame.TitleContainer or frame.CloseButton then return true end
    if _G[name .. "CloseButton"] or _G[name .. "TitleText"] then return true end
    return false
end

local function IsCandidate(frame)
    if not frame or frame == UIParent or IsForbiddenFrame(frame) then return false end
    if managed[frame] then return false end
    local name = FrameKey(frame)
    if not name or ignored[name] then return false end
    if not GeometrySupported(frame) then return false end
    if frame:GetParent() ~= UIParent and not specialManagedFrames[name] then return false end
    if not specialManagedFrames[name] and (frame:GetWidth() < 220 or frame:GetHeight() < 120) then return false end
    return specialManagedFrames[name] or HasWindowChrome(frame, name)
end

local function Manage(frame)
    if not IsCandidate(frame) or not CanChange(frame) then return end
    managed[frame] = true
    if detachedPositionFrames[FrameKey(frame)] then
        frame.ignoreFramePositionManager = true
    end
    if Database().frames[FrameKey(frame)] then TakePositionOwnership(frame) end
    SetAppropriateClamping(frame)
    CreateTitleHandle(frame)
    CreateResizeGrip(frame)
    InstallPersistenceGuards(frame)
    frame:HookScript("OnShow", function(self)
        if not Database().enabled then return end
        RestoreFrameThroughStartup(self)
    end)
    if Database().frames[FrameKey(frame)] then RestoreFrameThroughStartup(frame) end
end

local function ScanWindows()
    if not Database().enabled then return end
    if UIPanelWindows then
        for name in pairs(UIPanelWindows) do Manage(_G[name]) end
    end
    for _, name in ipairs(explicitFrames) do Manage(_G[name]) end
    local children = { UIParent:GetChildren() }
    for _, child in ipairs(children) do Manage(child) end
end

function DefylerUI_RestoreWindowPositions()
    if not Database().enabled then return end
    ScanWindows()
    for frame in pairs(managed) do
        if Database().frames[FrameKey(frame)] then RestoreFrame(frame) end
    end
end

local function SetControlsEnabled(enabled)
    local db = Database()
    db.enabled = enabled
    for frame in pairs(managed) do
        if frame.DefylerUITitleHandle then frame.DefylerUITitleHandle:SetShown(enabled) end
        if frame.DefylerUIResizeGrip then frame.DefylerUIResizeGrip:SetShown(enabled) end
    end
    if minimapButton and minimapButton.Icon then
        minimapButton.Icon:SetDesaturated(not enabled)
        minimapButton.Icon:SetAlpha(enabled and 1 or .55)
    end
    if enabled then ScanWindows() end
end

function DefylerUI_SetWindowControlsEnabled(enabled)
    SetControlsEnabled(enabled and true or false)
    if DefylerUI_SaveSuiteSettings then DefylerUI_SaveSuiteSettings() end
    if DefylerUI_RefreshSuitePanel then DefylerUI_RefreshSuitePanel() end
end

function DefylerUI_RefreshWindowControls()
    SetControlsEnabled(Database().enabled ~= false)
end

function DefylerUI_AreWindowControlsEnabled()
    return Database().enabled
end

function DefylerUI_ResetWindowPositions()
    local db = Database()
    db.frames = {}
    db.suitePanelPosition = nil
    if type(ForeverSettingsDB) == "table" then
        ForeverSettingsDB.windowPosition = nil
    end
    if DefylerUI_SaveSuiteSettings then DefylerUI_SaveSuiteSettings() end
    ReloadUI()
end

function DefylerUI_ReflowAfterGlobalScale()
    if not Database().enabled then return end
    C_Timer.After(0, function()
        for frame in pairs(managed) do
            if frame:IsShown() then RestoreFrame(frame) end
        end
    end)
end

local function PositionMinimapButton(button)
    local angle = math.rad(Database().minimapAngle or 225)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * 82, math.sin(angle) * 82)
end

local function UpdateMinimapButtonDrag(button)
    local centerX, centerY = Minimap:GetCenter()
    if not centerX or not centerY then return end
    local cursorX, cursorY = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    cursorX, cursorY = cursorX / scale, cursorY / scale
    Database().minimapAngle = math.deg(math.atan2(cursorY - centerY, cursorX - centerX))
    PositionMinimapButton(button)
end

local function CreateMinimapButton()
    if minimapButton or not Minimap then return end
    local button = CreateFrame("Button", "DUIMinimapButton", Minimap)
    minimapButton = button
    button:SetSize(34, 34)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")

    local icon = button:CreateTexture(nil, "ARTWORK")
    button.Icon = icon
    icon:SetTexture("Interface\\AddOns\\DefylerUI\\Assets\\dui_icon")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    highlight:SetBlendMode("ADD")
    highlight:SetAllPoints(button)

    button:SetScript("OnDragStart", function(self)
        self.dragged = true
        self:SetScript("OnUpdate", UpdateMinimapButtonDrag)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    button:SetScript("OnClick", function(self, mouseButton)
        if self.dragged then
            self.dragged = nil
            return
        end
        if mouseButton == "LeftButton" then
            if DefylerUI_ToggleSuitePanel then DefylerUI_ToggleSuitePanel() end
        elseif mouseButton == "RightButton" and IsShiftKeyDown() then
            DefylerUI_ResetWindowPositions()
        elseif mouseButton == "RightButton" then
            DefylerUI_SetWindowControlsEnabled(not Database().enabled)
        end
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Defyler Suite Control")
        GameTooltip:AddLine("Left-click: open suite controls", 1, 1, 1)
        GameTooltip:AddLine("Right-click: toggle move/resize controls", 1, 1, 1)
        GameTooltip:AddLine("Drag: move this minimap button", 1, 1, 1)
        GameTooltip:AddLine("Shift-right-click: reset window positions", 1, 1, 1)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)
    PositionMinimapButton(button)
    SetControlsEnabled(Database().enabled)
end

local function RestoreShownWindows()
    restoreScheduled = false
    if not Database().enabled then return end
    for frame in pairs(managed) do
        if frame:IsShown() and not detachedPositionFrames[FrameKey(frame)] then
            RestoreFrame(frame)
        end
    end
end

local function RestoreAllThroughStartup()
    ScanWindows()
    for frame in pairs(managed) do
        if Database().frames[FrameKey(frame)] then RestoreFrameThroughStartup(frame) end
    end
end

local function ScheduleRestoreShownWindows()
    if restoreScheduled or not Database().enabled then return end
    restoreScheduled = true
    C_Timer.After(0, RestoreShownWindows)
end

local function ReassertActiveResizes()
    bagRestoreScheduled = false
    for frame, grip in pairs(activeResizes) do
        if grip.resizing and frame:IsShown() and CanChange(frame) then
            SetFrameScale(frame, grip.currentScale)
            PinTopLeft(frame, grip.anchorLeft, grip.anchorTop)
        end
    end
end

local function ContainerAnchorsUpdated()
    if next(activeResizes) then
        if not bagRestoreScheduled then
            bagRestoreScheduled = true
            C_Timer.After(0, ReassertActiveResizes)
        end
    else
        ScheduleRestoreShownWindows()
    end
end

if hooksecurefunc then
    hooksecurefunc("ShowUIPanel", ScheduleRestoreShownWindows)
    hooksecurefunc("UpdateUIPanelPositions", ScheduleRestoreShownWindows)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("VARIABLES_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("DISPLAY_SIZE_CHANGED")
eventFrame:RegisterEvent("UI_SCALE_CHANGED")
eventFrame:RegisterEvent("LOADING_SCREEN_DISABLED")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "VARIABLES_LOADED" then
        variablesReady = true
    elseif not variablesReady then
        return
    end
    Database()
    if event == "PLAYER_LOGIN" then CreateMinimapButton() end
    if event == "ADDON_LOADED" then
        C_Timer.After(0, ScanWindows)
    else
        C_Timer.After(0, RestoreAllThroughStartup)
    end
    if event == "PLAYER_REGEN_ENABLED" then
        for frame in pairs(managed) do
            if frame:IsShown() and not detachedPositionFrames[FrameKey(frame)] then
                RestoreFrame(frame)
            end
        end
    end
end)
eventFrame:SetScript("OnUpdate", function(_, delta)
    if not variablesReady then return end
    elapsed = elapsed + delta
    if elapsed < RESCAN_SECONDS then return end
    elapsed = 0
    ScanWindows()
    -- Native AccountData/layout updates can bypass Lua SetPoint hooks. This is
    -- a cheap drift check; RestoreFrame performs no writes when geometry
    -- already matches the saved record.
    RestoreShownWindows()
end)

SLASH_DEFYLERUI1 = "/dui"
SLASH_DEFYLERUI2 = "/moveframes"
SlashCmdList.DEFYLERUI = function(message)
    local command = string.lower(strtrim(message or ""))
    local db = Database()
    if command == "" then
        if DefylerUI_ToggleSuitePanel then DefylerUI_ToggleSuitePanel() end
    elseif command == "scale" or command:match("^scale%s") then
        DefylerUI_ScaleCommand(command:match("^scale%s*(.*)$"))
    elseif command == "reset" then
        DefylerUI_ResetWindowPositions()
    elseif command == "off" then
        SetControlsEnabled(false)
        print("Defyler UI window controls disabled. Type /dui on to enable them.")
    elseif command == "on" then
        SetControlsEnabled(true)
        print("Defyler UI window controls enabled.")
    else
        if DefylerUI_ToggleSuitePanel then DefylerUI_ToggleSuitePanel() end
        print("Commands: /dui scale, /dui reset, /dui off, /dui on")
    end
end
