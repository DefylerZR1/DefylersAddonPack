DQADB = DQADB or {}

local frame = CreateFrame("Frame")
local overlays = {}
local cursorOverlay
local activeNameplateUnits = {}
local activeQuestTitles = {}
local activeObjectiveTexts = {}
local QUEST_MARKER_NAMEPLATE_DISTANCE = 60

local function printStatus(message)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage("|cffc9a4f4DQA:|r " .. message)
    end
end

local function normalValue(value)
    if issecretvalue and issecretvalue(value) then return nil end
    return value
end

local function normalizedText(value)
    value = normalValue(value)
    if type(value) ~= "string" then return nil end
    value = value:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    value = value:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    return value ~= "" and value or nil
end

local function applyQuestMarkerRange()
    if not GetCVar or not SetCVar then return end
    local ok, value = pcall(GetCVar, "nameplateMaxDistance")
    local current = ok and tonumber(normalValue(value)) or nil
    if not current or current >= QUEST_MARKER_NAMEPLATE_DISTANCE then return end
    if DQADB.previousNameplateMaxDistance == nil then
        DQADB.previousNameplateMaxDistance = current
    end
    pcall(SetCVar, "nameplateMaxDistance", QUEST_MARKER_NAMEPLATE_DISTANCE)
end

local function restoreNameplateRange()
    if DQADB.previousNameplateMaxDistance == nil or not SetCVar then return end
    pcall(SetCVar, "nameplateMaxDistance", DQADB.previousNameplateMaxDistance)
    DQADB.previousNameplateMaxDistance = nil
end

local function rebuildActiveQuestTitles()
    activeQuestTitles = {}
    activeObjectiveTexts = {}
    if not C_QuestLog or not C_QuestLog.GetNumQuestLogEntries or not C_QuestLog.GetInfo then return end
    local ok, count = pcall(C_QuestLog.GetNumQuestLogEntries)
    count = ok and normalValue(count) or nil
    if type(count) ~= "number" then return end
    for index = 1, count do
        local infoOK, info = pcall(C_QuestLog.GetInfo, index)
        if infoOK and type(info) == "table" and not normalValue(info.isHeader) then
            local title = normalizedText(info.title)
            local questID = normalValue(info.questID)
            local incomplete = true
            if title and questID and C_QuestLog.GetQuestObjectives then
                local objectivesOK, objectives = pcall(C_QuestLog.GetQuestObjectives, questID)
                if objectivesOK and type(objectives) == "table" and #objectives > 0 then
                    incomplete = false
                    for _, objective in ipairs(objectives) do
                        if type(objective) == "table" and normalValue(objective.finished) ~= true then
                            incomplete = true
                            local objectiveText = normalizedText(objective.text)
                            if objectiveText then activeObjectiveTexts[objectiveText] = true end
                        end
                    end
                end
            end
            if title and incomplete then activeQuestTitles[title] = true end
        end
    end
end

local function tooltipDataQuestState(data)
    if type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
    local lineTypes = Enum and Enum.TooltipDataLineType
    local questObjectiveType = lineTypes and lineTypes.QuestObjective or 8
    local questTitleType = lineTypes and lineTypes.QuestTitle or 17
    local sawObjective = false
    local titleMatches = false
    for _, line in ipairs(data.lines) do
        if type(line) == "table" then
            local lineType = normalValue(line.type)
            local text = normalizedText(line.leftText)
            if lineType == questObjectiveType then
                sawObjective = true
                if text and activeObjectiveTexts[text] then return true end
            elseif lineType == questTitleType and text and activeQuestTitles[text] then
                titleMatches = true
            end
        end
    end
    -- A typed objective row is authoritative. Completed objectives remain in
    -- unit tooltips, but are deliberately absent from activeObjectiveTexts.
    if sawObjective then return false end
    if titleMatches then return true end
    return nil
end

local function tooltipQuestState(unit)
    if not C_TooltipInfo or not C_TooltipInfo.GetUnit then return nil end
    local ok, data = pcall(C_TooltipInfo.GetUnit, unit)
    if not ok then return nil end
    return tooltipDataQuestState(data)
end

local function isQuestObjectiveUnit(unit)
    local tooltipState = tooltipQuestState(unit)
    if tooltipState ~= nil then return tooltipState end
    if C_QuestLog and C_QuestLog.UnitIsRelatedToActiveQuest then
        local ok, result = pcall(C_QuestLog.UnitIsRelatedToActiveQuest, unit)
        if ok and normalValue(result) == true then return true end
    end
    -- Keep the older boss flag as a fallback for clients or special quest
    -- targets that do not report through the active-objective API.
    if UnitIsQuestBoss then
        local ok, result = pcall(UnitIsQuestBoss, unit)
        if ok and normalValue(result) == true then return true end
    end
    return false
end

local function createQuestOverlay()
    local questOverlay = CreateFrame("Frame", nil, UIParent)
    questOverlay:SetSize(174, 34)
    questOverlay:EnableMouse(false)
    questOverlay:Hide()

    questOverlay.Diamond = questOverlay:CreateTexture(nil, "OVERLAY")
    questOverlay.Diamond:SetSize(10, 10)
    questOverlay.Diamond:SetPoint("BOTTOM", questOverlay, "TOP", 0, 2)
    questOverlay.Diamond:SetColorTexture(1, .82, .18, 1)
    questOverlay.Diamond:SetRotation(math.rad(45))

    questOverlay.Label = questOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    questOverlay.Label:SetPoint("BOTTOM", questOverlay.Diamond, "TOP", 0, 4)
    questOverlay.Label:SetText("QUEST OBJECTIVE")
    questOverlay.Label:SetTextColor(1, .82, .18, 1)

    questOverlay.FlameSparks = {}
    local function addFlameSpark(offsetX, red, green, blue, delay, driftX, rise)
        local spark = questOverlay:CreateTexture(nil, "ARTWORK")
        spark:SetTexture("Interface\\Cooldown\\star4")
        spark:SetBlendMode("ADD")
        spark:SetVertexColor(red, green, blue, 1)
        spark:SetSize(28, 28)
        spark:SetPoint("CENTER", questOverlay.Label, "CENTER", offsetX, 0)
        spark:SetAlpha(0)

        local flame = spark:CreateAnimationGroup()
        flame:SetLooping("REPEAT")
        local lowerRise = flame:CreateAnimation("Translation")
        lowerRise:SetOffset(driftX * .45, rise * .45)
        lowerRise:SetDuration(.32)
        lowerRise:SetStartDelay(delay)
        lowerRise:SetOrder(1)
        local appear = flame:CreateAnimation("Alpha")
        appear:SetFromAlpha(0)
        appear:SetToAlpha(.9)
        appear:SetDuration(.16)
        appear:SetStartDelay(delay)
        appear:SetOrder(1)
        local upperRise = flame:CreateAnimation("Translation")
        upperRise:SetOffset(driftX * .55, rise * .55)
        upperRise:SetDuration(.48)
        upperRise:SetOrder(2)
        local vanish = flame:CreateAnimation("Alpha")
        vanish:SetFromAlpha(.9)
        vanish:SetToAlpha(0)
        vanish:SetDuration(.48)
        vanish:SetOrder(2)
        flame:Play()
        questOverlay.FlameSparks[#questOverlay.FlameSparks + 1] = spark
    end

    addFlameSpark(-40, 1, .12, .08, 0, -5, 28)
    addFlameSpark(-20, .2, 1, .18, .14, 4, 34)
    addFlameSpark(0, .12, .55, 1, .28, -2, 38)
    addFlameSpark(20, 1, .16, .82, .42, 5, 32)
    addFlameSpark(40, .1, 1, 1, .56, -4, 29)
    return questOverlay
end

local function createWorldCursorOverlay()
    local questOverlay = createQuestOverlay()

    questOverlay.BlueGlow = questOverlay:CreateTexture(nil, "ARTWORK")
    questOverlay.BlueGlow:SetTexture("Interface\\Cooldown\\star4")
    questOverlay.BlueGlow:SetBlendMode("ADD")
    questOverlay.BlueGlow:SetVertexColor(.08, .62, 1, 1)
    questOverlay.BlueGlow:SetSize(30, 30)
    questOverlay.BlueGlow:SetPoint("CENTER", questOverlay.Diamond, "CENTER", 0, 0)
    questOverlay.BlueGlow:SetAlpha(.25)

    local glowAnimation = questOverlay.BlueGlow:CreateAnimationGroup()
    glowAnimation:SetLooping("REPEAT")
    local glowIn = glowAnimation:CreateAnimation("Alpha")
    glowIn:SetFromAlpha(.2)
    glowIn:SetToAlpha(.85)
    glowIn:SetDuration(.42)
    glowIn:SetOrder(1)
    local grow = glowAnimation:CreateAnimation("Scale")
    grow:SetScale(.28, .28)
    grow:SetDuration(.42)
    grow:SetOrder(1)
    local glowOut = glowAnimation:CreateAnimation("Alpha")
    glowOut:SetFromAlpha(.85)
    glowOut:SetToAlpha(.2)
    glowOut:SetDuration(.58)
    glowOut:SetOrder(2)
    glowAnimation:Play()

    questOverlay.BlueFlame = questOverlay:CreateTexture(nil, "OVERLAY")
    questOverlay.BlueFlame:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    questOverlay.BlueFlame:SetBlendMode("ADD")
    questOverlay.BlueFlame:SetVertexColor(.18, .72, 1, 1)
    questOverlay.BlueFlame:SetSize(10, 22)
    questOverlay.BlueFlame:SetPoint("BOTTOM", questOverlay.Diamond, "CENTER", 0, -4)
    questOverlay.BlueFlame:SetAlpha(.7)
    return questOverlay
end

local function hideQuestOverlay(unit)
    local overlay = overlays[unit]
    if not overlay then return end
    overlay:Hide()
    overlay:ClearAllPoints()
    overlay:SetParent(UIParent)
end

local function hideAllQuestOverlays()
    for unit in pairs(overlays) do hideQuestOverlay(unit) end
end

local function hideWorldCursorOverlay()
    if not cursorOverlay then return end
    cursorOverlay:Hide()
    cursorOverlay:ClearAllPoints()
end

local function showWorldCursorOverlay()
    if DQADB.enabled == false or not C_TooltipInfo or not C_TooltipInfo.GetWorldCursor then
        hideWorldCursorOverlay()
        return
    end
    local ok, data = pcall(C_TooltipInfo.GetWorldCursor)
    local objectType = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Object or 4
    if not ok or type(data) ~= "table" or normalValue(data.type) ~= objectType
        or tooltipDataQuestState(data) ~= true then
        hideWorldCursorOverlay()
        return
    end
    local x, y = GetCursorPosition()
    x, y = normalValue(x), normalValue(y)
    if type(x) ~= "number" or type(y) ~= "number" then
        hideWorldCursorOverlay()
        return
    end
    local scale = UIParent.GetEffectiveScale and UIParent:GetEffectiveScale() or 1
    scale = tonumber(normalValue(scale)) or 1
    if scale <= 0 then scale = 1 end
    cursorOverlay = cursorOverlay or createWorldCursorOverlay()
    cursorOverlay:SetParent(UIParent)
    cursorOverlay:SetFrameStrata("TOOLTIP")
    cursorOverlay:SetFrameLevel(101)
    cursorOverlay:ClearAllPoints()
    cursorOverlay:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / scale, y / scale + 4)
    cursorOverlay:Show()
end

local function scheduleWorldCursorRefresh()
    C_Timer.After(0, showWorldCursorOverlay)
end

local function showQuestOverlay(unit)
    if not activeNameplateUnits[unit] or DQADB.enabled == false or not isQuestObjectiveUnit(unit) then
        hideQuestOverlay(unit)
        return
    end
    local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit(unit)
    if not plate then
        hideQuestOverlay(unit)
        return
    end
    local overlay = overlays[unit]
    if not overlay then
        overlay = createQuestOverlay()
        overlays[unit] = overlay
    end
    local anchor = plate.UnitFrame or plate
    -- Keep the visual outside the nameplate's inherited alpha and clipping,
    -- while anchoring it to the plate so it still follows the target in-world.
    overlay:SetParent(UIParent)
    overlay:SetFrameStrata("TOOLTIP")
    overlay:SetFrameLevel(100)
    overlay:ClearAllPoints()
    overlay:SetPoint("CENTER", anchor, "CENTER", 0, 0)
    overlay:Show()
end

local function scheduleUnitRefresh(unit)
    C_Timer.After(0, function()
        showQuestOverlay(unit)
    end)
    -- Structured tooltip data can settle just after the nameplate appears.
    C_Timer.After(.1, function() showQuestOverlay(unit) end)
end

local function refreshAllNameplates()
    for unit in pairs(activeNameplateUnits) do scheduleUnitRefresh(unit) end
end

for _, event in ipairs({
    "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD",
    "QUEST_LOG_UPDATE", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED",
    "WORLD_CURSOR_TOOLTIP_UPDATE", "TOOLTIP_DATA_UPDATE",
}) do
    frame:RegisterEvent(event)
end
frame:SetScript("OnEvent", function(_, event, unit)
    if event == "PLAYER_LOGIN" and DQADB.enabled == nil then DQADB.enabled = true end
    if event == "PLAYER_LOGIN" and DQADB.enabled ~= false then applyQuestMarkerRange() end
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" or event == "QUEST_LOG_UPDATE" then
        rebuildActiveQuestTitles()
    end
    if event == "WORLD_CURSOR_TOOLTIP_UPDATE" or event == "TOOLTIP_DATA_UPDATE" then
        scheduleWorldCursorRefresh()
    elseif event == "NAME_PLATE_UNIT_ADDED" and unit then
        activeNameplateUnits[unit] = true
        scheduleUnitRefresh(unit)
    elseif event == "NAME_PLATE_UNIT_REMOVED" and unit then
        activeNameplateUnits[unit] = nil
        hideQuestOverlay(unit)
    else
        refreshAllNameplates()
        scheduleWorldCursorRefresh()
    end
end)

SLASH_DQA1 = "/dqa"
SlashCmdList.DQA = function(input)
    local command = (input or ""):lower():match("^%s*(%S*)")
    if command == "on" then
        DQADB.enabled = true
        applyQuestMarkerRange()
        printStatus("quest-objective highlighting enabled.")
        refreshAllNameplates()
        scheduleWorldCursorRefresh()
    elseif command == "off" then
        DQADB.enabled = false
        restoreNameplateRange()
        hideAllQuestOverlays()
        hideWorldCursorOverlay()
        printStatus("quest-objective highlighting disabled.")
    else
        printStatus(("quest-objective highlighting is %s. Use /dqa on or /dqa off."):format(
            DQADB.enabled == false and "off" or "on"))
    end
end
