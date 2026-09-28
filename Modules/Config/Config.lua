if not DXMCore or not DXMExchange then return end

DXMConfig = DXMConfig or {}
if DXMConfig.historyEnabled == nil then DXMConfig.historyEnabled = true end
if DXMConfig.historyRetentionDays == nil then DXMConfig.historyRetentionDays = 30 end
if DXMConfig.historyMaxSamples == nil then DXMConfig.historyMaxSamples = 40 end
if DXMConfig.showTooltips == nil then DXMConfig.showTooltips = true end

local function checkbox(parent, anchor, y, label, getter, setter)
    local box = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    box:SetSize(24, 24)
    box:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, y)
    local text = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("LEFT", box, "RIGHT", 6, 0)
    text:SetText(label)
    box:SetChecked(getter())
    box:SetScript("OnClick", function(self) setter(self:GetChecked() and true or false) end)
    box.Refresh = function(self) self:SetChecked(getter()) end
    return box, text
end

local function numberSetting(parent, anchor, y, label, key, minimum, maximum)
    local text = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 4, y)
    text:SetText(label)
    local input = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    input:SetSize(64, 24)
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
    return input
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
    local settingsTitle = page:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    settingsTitle:SetPoint("TOPLEFT", page.Description, "BOTTOMLEFT", 0, -22)
    settingsTitle:SetText("Market History")

    local historyBox = checkbox(page, settingsTitle, -10, "Store one price observation after every completed scan",
        function() return DXMConfig.historyEnabled ~= false end,
        function(value) DXMConfig.historyEnabled = value end)
    local retention = numberSetting(page, historyBox, -14, "Retention days", "historyRetentionDays", 1, 365)
    local samples = numberSetting(page, historyBox, -48, "Maximum observations per item", "historyMaxSamples", 5, 200)

    local historyStatus = page:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    historyStatus:SetPoint("TOPLEFT", historyBox, "BOTTOMLEFT", 0, -82)
    historyStatus:SetJustifyH("LEFT")

    local interfaceTitle = page:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    interfaceTitle:SetPoint("TOPLEFT", historyStatus, "BOTTOMLEFT", 0, -28)
    interfaceTitle:SetText("Interface")
    local tooltipBox = checkbox(page, interfaceTitle, -10, "Show DXM values in item tooltips",
        function() return DXMConfig.showTooltips ~= false end,
        function(value) DXMConfig.showTooltips = value end)

    local networkTitle = page:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    networkTitle:SetPoint("TOPLEFT", tooltipBox, "BOTTOMLEFT", 0, -28)
    networkTitle:SetText("Network")
    local networkBox = checkbox(page, networkTitle, -10, "Connect to the DXM private channel automatically",
        function() return not DXMSharedConfig or DXMSharedConfig.autoJoin ~= false end,
        function(value)
            DXMSharedConfig = DXMSharedConfig or {}
            DXMSharedConfig.channel = DXMSharedConfig.channel or "defyler"
            DXMSharedConfig.autoJoin = value
            if value and SlashCmdList and SlashCmdList.DXMCHANNEL then SlashCmdList.DXMCHANNEL("on") end
        end)

    local qrFrame = CreateFrame("Frame", nil, page, "InsetFrameTemplate")
    qrFrame:SetSize(218, 282)
    qrFrame:SetPoint("TOPRIGHT", page, "TOPRIGHT", -18, -76)
    local qrTitle = qrFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    qrTitle:SetPoint("TOP", 0, -14)
    qrTitle:SetText("DXM Online")
    local qr = qrFrame:CreateTexture(nil, "ARTWORK")
    qr:SetSize(164, 164)
    qr:SetPoint("TOP", qrTitle, "BOTTOM", 0, -12)
    qr:SetTexture("Interface\\AddOns\\DXM\\Media\\defyler-dev-qr")
    qr:SetTexCoord(0, 1, 0, 1)
    local url = qrFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    url:SetPoint("TOP", qr, "BOTTOM", 0, -9)
    url:SetWidth(188)
    url:SetJustifyH("CENTER")
    url:SetWordWrap(false)
    url:SetText("defyler.dev")
    local qrHint = qrFrame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    qrHint:SetPoint("TOP", url, "BOTTOM", 0, -5)
    qrHint:SetPoint("LEFT", qrFrame, "LEFT", 14, 0)
    qrHint:SetPoint("RIGHT", qrFrame, "RIGHT", -14, 0)
    qrHint:SetHeight(28)
    qrHint:SetJustifyH("CENTER")
    qrHint:SetWordWrap(true)
    qrHint:SetText("Scan for downloads and updates")

    local credits = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    credits:SetPoint("TOP", qrFrame, "BOTTOM", 0, -20)
    credits:SetWidth(218)
    credits:SetJustifyH("CENTER")
    credits:SetText("Defyler Exchange Market\nCreated by DefylerZR1\nBuilt for WoW Forever")

    historyStatus:SetPoint("RIGHT", qrFrame, "LEFT", -22, 0)
    historyStatus:SetWordWrap(true)

    page:SetScript("OnShow", function()
        historyBox:Refresh(); tooltipBox:Refresh(); networkBox:Refresh()
        retention:SetNumber(tonumber(DXMConfig.historyRetentionDays) or 30)
        samples:SetNumber(tonumber(DXMConfig.historyMaxSamples) or 40)
        local partitions, items, observations = historyCounts()
        historyStatus:SetText(("Stored history: %d observations across %d items and %d market partition%s."):format(observations, items, partitions, partitions == 1 and "" or "s"))
    end)
end

DXMExchange:RegisterPageBuilder("config", buildPage)