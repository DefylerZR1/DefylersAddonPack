if not DXMCore or not DXMExchange then return end

DXMConfig = DXMConfig or {}
if DXMConfig.historyEnabled == nil then DXMConfig.historyEnabled = true end
if DXMConfig.historyRetentionDays == nil then DXMConfig.historyRetentionDays = 30 end
if DXMConfig.historyMaxSamples == nil then DXMConfig.historyMaxSamples = 40 end
if DXMConfig.showTooltips == nil then DXMConfig.showTooltips = true end
if DXMConfig.scanQualityFilterVersion ~= 2 then
    DXMConfig.scanExcludePoor = true
    DXMConfig.scanExcludeCommon = true
    DXMConfig.scanQualityFilterVersion = 2
end

local function checkbox(parent, anchor, y, label, getter, setter)
    local box = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    box:SetSize(18, 18)
    box:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, y)
    local text = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    text:SetPoint("LEFT", box, "RIGHT", 4, 0)
    text:SetText(label)
    box:SetChecked(getter())
    box:SetScript("OnClick", function(self) setter(self:GetChecked() and true or false) end)
    box.Refresh = function(self) self:SetChecked(getter()) end
    return box, text
end

local function numberSetting(parent, anchor, y, label, key, minimum, maximum)
    local text = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 4, y)
    text:SetText(label)
    local input = DXMTheme:CreateInput(parent, 52, 20)
    input:SetPoint("LEFT", text, "RIGHT", 12, 0)
    input:SetAutoFocus(false)
    input:SetJustifyH("CENTER")
    input:SetNumeric(true)
    input:SetNumber(tonumber(DXMConfig[key]) or minimum)
    local function commit(self)
        local value = math.max(minimum, math.min(maximum, tonumber(self:GetText()) or minimum))
        DXMConfig[key] = math.floor(value + 0.5)
        self:SetNumber(DXMConfig[key])
        self:ClearFocus()
    end
    input:SetScript("OnEnterPressed", commit)
    input:SetScript("OnEditFocusLost", commit)
    return input, text
end

local function historyCounts()
    local realms, items, samples = 0, 0, 0
    for _, realm in pairs(DXMPriceHistoryData or {}) do
        realms = realms + 1
        for _, list in pairs(realm) do items = items + 1; samples = samples + #list end
    end
    return realms, items, samples
end

local function buildPage(page)
    local summary = DXMTheme:CreatePanel(page)
    summary:SetPoint("TOPLEFT", page.Description, "BOTTOMLEFT", 0, -12)
    summary:SetPoint("RIGHT", page, "RIGHT", -18, 0)
    summary:SetHeight(136)

    local statusTitle = summary:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    statusTitle:SetPoint("TOPLEFT", 12, -10)
    statusTitle:SetText("Market & Network")
    local statusText = summary:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    statusText:SetPoint("TOPLEFT", statusTitle, "BOTTOMLEFT", 0, -5)
    statusText:SetPoint("RIGHT", summary, "RIGHT", -150, 0)
    statusText:SetHeight(78)
    statusText:SetJustifyH("LEFT")
    statusText:SetJustifyV("TOP")
    statusText:SetText("Loading market status...")
    DXMExchange:RegisterStatusDisplay(statusText)

    local networkBox = checkbox(summary, statusText, -1, "Connect automatically",
        function() return not DXMSharedConfig or DXMSharedConfig.autoJoin ~= false end,
        function(value)
            DXMSharedConfig = DXMSharedConfig or {}
            DXMSharedConfig.channel = DXMSharedConfig.channel or "defyler"
            DXMSharedConfig.autoJoin = value
            if value and SlashCmdList and SlashCmdList.DXMCHANNEL then SlashCmdList.DXMCHANNEL("on") end
        end)

    local onlineTitle = summary:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    onlineTitle:SetPoint("TOPRIGHT", -25, -10)
    onlineTitle:SetText("DXM Online")
    local qr = summary:CreateTexture(nil, "ARTWORK")
    qr:SetSize(78, 78)
    qr:SetPoint("TOP", onlineTitle, "BOTTOM", 0, -4)
    qr:SetTexture("Interface\\AddOns\\DXM\\Media\\defyler-dev-qr")
    qr:SetTexCoord(0, 1, 0, 1)
    local url = summary:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    url:SetPoint("TOP", qr, "BOTTOM", 0, -3)
    url:SetText("defyler.dev")

    local left = CreateFrame("Frame", nil, page)
    left:SetPoint("TOPLEFT", summary, "BOTTOMLEFT", 0, -12)
    left:SetPoint("RIGHT", page, "CENTER", -10, 0)
    left:SetHeight(176)
    local filterTitle = left:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    filterTitle:SetPoint("TOPLEFT", 0, 0)
    filterTitle:SetText("Scan Filter")
    local poorBox = checkbox(left, filterTitle, -5, "Exclude poor (gray) items",
        function() return DXMConfig.scanExcludePoor ~= false end,
        function(value) DXMConfig.scanExcludePoor = value end)
    local commonBox = checkbox(left, poorBox, -1, "Exclude common (white) items except crafting reagents",
        function() return DXMConfig.scanExcludeCommon == true end,
        function(value) DXMConfig.scanExcludeCommon = value end)
    local filterHint = left:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    filterHint:SetPoint("TOPLEFT", commonBox, "BOTTOMLEFT", 3, -2)
    filterHint:SetPoint("RIGHT", left, "RIGHT", -8, 0)
    filterHint:SetJustifyH("LEFT")
    filterHint:SetWordWrap(true)
    filterHint:SetText("White Trade Goods remain included for Salvage and Crafting prices.")
    local interfaceTitle = left:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    interfaceTitle:SetPoint("TOPLEFT", filterHint, "BOTTOMLEFT", -3, -12)
    interfaceTitle:SetText("Interface")
    local tooltipBox = checkbox(left, interfaceTitle, -5, "Show DXM values in item tooltips",
        function() return DXMConfig.showTooltips ~= false end,
        function(value) DXMConfig.showTooltips = value end)

    local right = CreateFrame("Frame", nil, page)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 20, 0)
    right:SetPoint("RIGHT", page, "RIGHT", -18, 0)
    right:SetHeight(176)
    local historyTitle = right:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    historyTitle:SetPoint("TOPLEFT", 0, 0)
    historyTitle:SetText("Market History")
    local historyBox = checkbox(right, historyTitle, -5, "Store an observation after each completed scan",
        function() return DXMConfig.historyEnabled ~= false end,
        function(value) DXMConfig.historyEnabled = value end)
    local retention, retentionLabel = numberSetting(right, historyBox, -9, "Retention days", "historyRetentionDays", 1, 365)
    retention:ClearAllPoints()
    retention:SetPoint("LEFT", retentionLabel, "LEFT", 165, 0)
    local samples, samplesLabel = numberSetting(right, retention, -7, "Samples per item", "historyMaxSamples", 5, 200)
    samplesLabel:ClearAllPoints()
    samplesLabel:SetPoint("TOPLEFT", retentionLabel, "BOTTOMLEFT", 0, -12)
    samples:ClearAllPoints()
    samples:SetPoint("LEFT", samplesLabel, "LEFT", 165, 0)
    local historyStatus = right:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    historyStatus:SetPoint("TOPLEFT", samplesLabel, "BOTTOMLEFT", 0, -10)
    historyStatus:SetPoint("RIGHT", right, "RIGHT", -4, 0)
    historyStatus:SetJustifyH("LEFT")
    historyStatus:SetWordWrap(true)

    page:SetScript("OnShow", function()
        poorBox:Refresh(); commonBox:Refresh(); historyBox:Refresh(); tooltipBox:Refresh(); networkBox:Refresh()
        retention:SetNumber(tonumber(DXMConfig.historyRetentionDays) or 30)
        samples:SetNumber(tonumber(DXMConfig.historyMaxSamples) or 40)
        local partitions, items, observations = historyCounts()
        historyStatus:SetText(("%d observations / %d items / %d market%s"):format(observations, items, partitions, partitions == 1 and "" or "s"))
        DXMExchange:Refresh()
    end)
end

DXMExchange:RegisterPageBuilder("overview", buildPage)
