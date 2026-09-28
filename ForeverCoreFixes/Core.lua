-- Camelot loads Blizzard_GroupFinder_VanillaStyle's three-tab parent but omits
-- the WhoList files. The parent still dereferences LFGWhoListFrame for every
-- tab, so provide the missing frame and a functional Who browser.
if not LFGWhoListFrame then
    local ROWS = 10
    local pageOffset = 0
    local waitingForResults = false
    local rows = {}

    local frame = CreateFrame("Frame", "LFGWhoListFrame", UIParent, "BackdropTemplate")
    frame:SetSize(590, 405)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetBackdrop({
        bgFile = "Interface\DialogFrame\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\DialogFrame\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = {left = 8, right = 8, top = 8, bottom = 8},
    })
    frame:SetBackdropColor(.025, .03, .04, .98)

    -- Some Forever builds do not draw BackdropTemplate textures here. Keep a
    -- plain backing and border so the Who controls never float over the world.
    local backing = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    backing:SetAllPoints()
    backing:SetColorTexture(.018, .024, .035, .97)
    local borders = {}
    for index = 1, 4 do
        borders[index] = frame:CreateTexture(nil, "BORDER")
        borders[index]:SetColorTexture(.54, .36, .14, .95)
    end
    borders[1]:SetPoint("TOPLEFT"); borders[1]:SetPoint("TOPRIGHT"); borders[1]:SetHeight(2)
    borders[2]:SetPoint("BOTTOMLEFT"); borders[2]:SetPoint("BOTTOMRIGHT"); borders[2]:SetHeight(2)
    borders[3]:SetPoint("TOPLEFT"); borders[3]:SetPoint("BOTTOMLEFT"); borders[3]:SetWidth(2)
    borders[4]:SetPoint("TOPRIGHT"); borders[4]:SetPoint("BOTTOMRIGHT"); borders[4]:SetWidth(2)

    frame.isForeverCompatibilityWhoList = true
    frame:Hide()

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -16)
    title:SetText("Who")

    local searchBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    searchBox:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 2, -12)
    searchBox:SetSize(210, 26)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(80)

    local searchButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    searchButton:SetPoint("LEFT", searchBox, "RIGHT", 10, 0)
    searchButton:SetSize(80, 26)
    searchButton:SetText("Search")

    local refreshButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    refreshButton:SetPoint("LEFT", searchButton, "RIGHT", 8, 0)
    refreshButton:SetSize(80, 26)
    refreshButton:SetText("Refresh")

    local status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", 0, -8)
    status:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
    status:SetJustifyH("LEFT")
    status:SetText("Enter a name, guild, zone, class, or level range, then click Search.")

    local header = CreateFrame("Frame", nil, frame)
    header:SetPoint("TOPLEFT", status, "BOTTOMLEFT", -4, -8)
    header:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
    header:SetHeight(22)
    local headerBackground = header:CreateTexture(nil, "BACKGROUND")
    headerBackground:SetAllPoints()
    headerBackground:SetColorTexture(.16, .12, .05, .95)

    local columns = {
        {"Name", 0, .26, "LEFT"},
        {"Level", .26, .38, "CENTER"},
        {"Class", .38, .53, "LEFT"},
        {"Zone", .53, .76, "LEFT"},
        {"Guild", .76, 1, "LEFT"},
    }

    local function Place(region, owner, width, leftFraction, rightFraction, inset)
        region:ClearAllPoints()
        region:SetPoint("LEFT", owner, "LEFT", math.floor(width * leftFraction) + (inset or 4), 0)
        region:SetWidth(math.max(1, math.floor(width * (rightFraction - leftFraction)) - (inset or 4) - 4))
    end

    local headerLabels = {}
    for index, column in ipairs(columns) do
        local label = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetText(column[1])
        label:SetTextColor(1, .82, 0)
        label:SetJustifyH(column[4])
        headerLabels[index] = label
    end

    local previous
    for index = 1, ROWS do
        local row = CreateFrame("Button", nil, frame)
        row:SetHeight(24)
        row:SetPoint("LEFT", header, "LEFT")
        row:SetPoint("RIGHT", header, "RIGHT")
        row:SetPoint("TOP", previous or header, "BOTTOM")
        local background = row:CreateTexture(nil, "BACKGROUND")
        background:SetAllPoints()
        local shade = index % 2 == 0 and .10 or .035
        background:SetColorTexture(shade, shade, shade, .8)
        local divider = row:CreateTexture(nil, "BORDER")
        divider:SetPoint("BOTTOMLEFT")
        divider:SetPoint("BOTTOMRIGHT")
        divider:SetHeight(1)
        divider:SetColorTexture(.31, .27, .19, .72)
        row:SetHighlightTexture("Interface\QuestFrame\UI-QuestTitleHighlight", "ADD")
        row.fields = {}
        for columnIndex, column in ipairs(columns) do
            local value = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            value:SetJustifyH(column[4])
            row.fields[columnIndex] = value
        end
        row:SetScript("OnDoubleClick", function(self)
            if self.playerName and ChatFrame_SendTell then ChatFrame_SendTell(self.playerName) end
        end)
        row:SetScript("OnEnter", function(self)
            if not self.playerName then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.playerName)
            GameTooltip:AddLine("Double-click to whisper.", .75, .75, .75)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)
        rows[index] = row
        previous = row
    end

    local previousButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    previousButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 18, 16)
    previousButton:SetSize(30, 23)
    previousButton:SetText("<")

    local nextButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    nextButton:SetPoint("LEFT", previousButton, "RIGHT", 6, 0)
    nextButton:SetSize(30, 23)
    nextButton:SetText(">")

    local countText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    countText:SetPoint("LEFT", nextButton, "RIGHT", 12, 0)

    local function GetCounts()
        if C_FriendList and C_FriendList.GetNumWhoResults then
            local total, displayed = C_FriendList.GetNumWhoResults()
            return tonumber(total) or 0, tonumber(displayed) or tonumber(total) or 0
        elseif GetNumWhoResults then
            local total, displayed = GetNumWhoResults()
            return tonumber(total) or 0, tonumber(displayed) or tonumber(total) or 0
        end
        return 0, 0
    end

    local function GetInfo(index)
        if C_FriendList and C_FriendList.GetWhoInfo then
            local info = C_FriendList.GetWhoInfo(index)
            if type(info) == "table" then
                return info.fullName or info.name, info.fullGuildName or info.guild, info.level,
                    info.raceStr or info.race, info.classStr or info.class, info.area or info.zone,
                    info.filename or info.classFileName
            end
        elseif GetWhoInfo then
            return GetWhoInfo(index)
        end
    end

    local function Layout(width)
        if not width or width <= 0 then return end
        searchBox:SetWidth(math.max(120, frame:GetWidth() - 214))
        for index, column in ipairs(columns) do
            Place(headerLabels[index], header, width, column[2], column[3], 4)
        end
        for _, row in ipairs(rows) do
            for index, column in ipairs(columns) do
                Place(row.fields[index], row, width, column[2], column[3], 4)
            end
        end
    end

    local function UpdateRows()
        local total, displayed = GetCounts()
        local available = math.max(0, displayed)
        local maxOffset = math.max(0, available - ROWS)
        pageOffset = math.max(0, math.min(pageOffset, maxOffset))
        for rowIndex, row in ipairs(rows) do
            local resultIndex = pageOffset + rowIndex
            local name, guild, level, _, className, zone, classFile = GetInfo(resultIndex)
            row.playerName = name
            if name then
                row.fields[1]:SetText(name)
                row.fields[2]:SetText(tostring(level or ""))
                row.fields[3]:SetText(className or "")
                row.fields[4]:SetText(zone or "")
                row.fields[5]:SetText((guild and guild ~= "") and ("<" .. guild .. ">") or "")
                local color = classFile and C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(classFile)
                if color then row.fields[1]:SetTextColor(color.r, color.g, color.b) else row.fields[1]:SetTextColor(1, 1, 1) end
                row:Show()
            else
                row:Hide()
            end
        end
        previousButton:SetEnabled(pageOffset > 0)
        nextButton:SetEnabled(pageOffset < maxOffset)
        if available == 0 then
            countText:SetText(waitingForResults and "Searching..." or "No Who results. Enter a filter and click Search.")
        else
            local suffix = total > available and (" (%d total matches)"):format(total) or ""
            countText:SetText(("Showing %d-%d of %d%s"):format(pageOffset + 1, math.min(pageOffset + ROWS, available), available, suffix))
        end
    end

    local function SendQuery()
        local query = searchBox:GetText() or ""
        if C_FriendList and C_FriendList.SetWhoToUi then C_FriendList.SetWhoToUi(true) end
        waitingForResults = true
        pageOffset = 0
        status:SetText("Searching for " .. (query ~= "" and query or "online players") .. "...")
        UpdateRows()
        if C_FriendList and C_FriendList.SendWho then
            C_FriendList.SendWho(query, Enum and Enum.SocialWhoOrigin and Enum.SocialWhoOrigin.Social or 1)
        elseif SendWho then
            SendWho(query)
        else
            waitingForResults = false
            status:SetText("The Who service is unavailable in this client build.")
            UpdateRows()
        end
    end

    searchButton:SetScript("OnClick", SendQuery)
    refreshButton:SetScript("OnClick", SendQuery)
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); SendQuery() end)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    previousButton:SetScript("OnClick", function() pageOffset = pageOffset - ROWS; UpdateRows() end)
    nextButton:SetScript("OnClick", function() pageOffset = pageOffset + ROWS; UpdateRows() end)
    header:SetScript("OnSizeChanged", function(_, width) Layout(width) end)

    frame:RegisterEvent("WHO_LIST_UPDATE")
    frame:RegisterEvent("ADDON_LOADED")
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:SetScript("OnEvent", function(self, event, loadedAddon)
        if event == "WHO_LIST_UPDATE" then
            waitingForResults = false
            status:SetText("Who results updated.")
            UpdateRows()
        elseif event == "ADDON_LOADED" and loadedAddon ~= "Blizzard_GroupFinder_VanillaStyle" then
            return
        end
        if LFGParentFrame and self:GetParent() ~= LFGParentFrame then
            self:SetParent(LFGParentFrame)
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", LFGParentFrame, "TOPLEFT", 12, -34)
            self:SetPoint("BOTTOMRIGHT", LFGParentFrame, "BOTTOMRIGHT", -58, 12)
            self:SetFrameLevel(LFGParentFrame:GetFrameLevel() + 2)
            C_Timer.After(0, function() Layout(header:GetWidth()); UpdateRows() end)
        end
    end)
    frame:SetScript("OnShow", function()
        if C_FriendList and C_FriendList.SetWhoToUi then C_FriendList.SetWhoToUi(true) end
        Layout(header:GetWidth())
        UpdateRows()
    end)
    frame:SetScript("OnHide", function()
        if C_FriendList and C_FriendList.SetWhoToUi then C_FriendList.SetWhoToUi(false) end
        GameTooltip:Hide()
    end)
end

-- Some Forever client builds return nil for an achievement's point value.
-- Blizzard_AchievementUI passes that value through this helper and then makes
-- two numeric comparisons with it while building the summary. Normalize the
-- helper's result so the summary can still open when the server omits points.
local achievementPointsGuardInstalled = false

local function InstallAchievementPointsGuard()
    if achievementPointsGuardInstalled or type(AchievementFrame_GetOverridePoints) ~= "function" then
        return
    end

    local originalGetOverridePoints = AchievementFrame_GetOverridePoints
    AchievementFrame_GetOverridePoints = function(points, achievementId)
        local resolvedPoints = originalGetOverridePoints(points, achievementId)
        return tonumber(resolvedPoints) or tonumber(points) or 0
    end

    achievementPointsGuardInstalled = true
end

local achievementPointsEventFrame = CreateFrame("Frame")
achievementPointsEventFrame:RegisterEvent("ADDON_LOADED")
achievementPointsEventFrame:SetScript("OnEvent", function(self, _, loadedAddon)
    if loadedAddon == "Blizzard_AchievementUI" then
        InstallAchievementPointsGuard()
        if achievementPointsGuardInstalled then
            self:UnregisterEvent("ADDON_LOADED")
        end
    end
end)

local achievementUIIsLoaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_AchievementUI")
if not achievementUIIsLoaded and IsAddOnLoaded then
    achievementUIIsLoaded = IsAddOnLoaded("Blizzard_AchievementUI")
end
if achievementUIIsLoaded then
    InstallAchievementPointsGuard()
    achievementPointsEventFrame:UnregisterEvent("ADDON_LOADED")
end
