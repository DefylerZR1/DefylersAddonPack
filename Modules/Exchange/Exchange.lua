if not DXMCore then return end

local Module = DXMCore:Module("Exchange")
local Const = DXMCore.Const()

local Exchange = DXMExchange or {}
DXMExchange = Exchange

local DISPLAY_KEY = "DXM"
local panel
local tab
local customMode
local currentPage = "overview"
local pages = {}
local navButtons = {}
local statusDisplays = {}
local statusProvider
local pageBuilders = {}

local THEME = {
    surface = {.035, .043, .078, 1},
    raised = {.071, .082, .133, 1},
    hover = {.118, .09, .165, 1},
    active = {.165, .122, .231, 1},
    border = {.20, .157, .247, 1},
    accent = {.788, .643, .957, 1},
    text = {.933, .918, .961, 1},
}
DXMTheme = DXMTheme or {}

local function addFlatBorder(frame, color)
    local top = frame:CreateTexture(nil, "BORDER"); top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT"); top:SetHeight(1); top:SetColorTexture(unpack(color))
    local bottom = frame:CreateTexture(nil, "BORDER"); bottom:SetPoint("BOTTOMLEFT"); bottom:SetPoint("BOTTOMRIGHT"); bottom:SetHeight(1); bottom:SetColorTexture(unpack(color))
    local left = frame:CreateTexture(nil, "BORDER"); left:SetPoint("TOPLEFT"); left:SetPoint("BOTTOMLEFT"); left:SetWidth(1); left:SetColorTexture(unpack(color))
    local right = frame:CreateTexture(nil, "BORDER"); right:SetPoint("TOPRIGHT"); right:SetPoint("BOTTOMRIGHT"); right:SetWidth(1); right:SetColorTexture(unpack(color))
    return {top, bottom, left, right}
end

function DXMTheme:AnimateIn(frame, duration)
    if not frame or not frame.CreateAnimationGroup then return end
    if not frame.DXMFadeIn then
        local group = frame:CreateAnimationGroup()
        local fade = group:CreateAnimation("Alpha")
        fade:SetFromAlpha(0)
        fade:SetToAlpha(1)
        fade:SetDuration(duration or .16)
        group:SetScript("OnPlay", function() frame:SetAlpha(0) end)
        group:SetScript("OnFinished", function() frame:SetAlpha(1) end)
        group:SetScript("OnStop", function() frame:SetAlpha(1) end)
        frame.DXMFadeIn = group
    end
    frame.DXMFadeIn:Stop()
    frame.DXMFadeIn:Play()
end

function DXMTheme:AddButtonEffects(button)
    if button.DXMHoverGlow or not button.CreateAnimationGroup then return end
    local hover = button:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints(); hover:SetColorTexture(unpack(THEME.accent)); hover:SetBlendMode("ADD"); hover:SetAlpha(0)
    local hoverIn = hover:CreateAnimationGroup()
    local hoverFade = hoverIn:CreateAnimation("Alpha"); hoverFade:SetFromAlpha(0); hoverFade:SetToAlpha(.18); hoverFade:SetDuration(.12)
    hoverIn:SetScript("OnFinished", function() hover:SetAlpha(.18) end)
    local click = button:CreateTexture(nil, "OVERLAY")
    click:SetAllPoints(); click:SetColorTexture(unpack(THEME.accent)); click:SetBlendMode("ADD"); click:SetAlpha(0)
    local clickFade = click:CreateAnimationGroup()
    local clickAnimation = clickFade:CreateAnimation("Alpha"); clickAnimation:SetFromAlpha(.32); clickAnimation:SetToAlpha(0); clickAnimation:SetDuration(.18)
    clickFade:SetScript("OnFinished", function() click:SetAlpha(0) end)
    button.DXMHoverGlow, button.DXMHoverIn = hover, hoverIn
    button.DXMClickGlow, button.DXMClickFade = click, clickFade
end

function DXMTheme:PlayButtonHover(button, active)
    if not button.DXMHoverGlow then return end
    button.DXMHoverIn:Stop()
    button.DXMHoverGlow:SetAlpha(0)
    if active then button.DXMHoverIn:Play() end
end

function DXMTheme:PlayButtonClick(button)
    if not button.DXMClickGlow then return end
    button.DXMClickFade:Stop()
    button.DXMClickGlow:SetAlpha(.32)
    button.DXMClickFade:Play()
end

local function updateThemeButton(button)
    local enabled = button.IsEnabled and button:IsEnabled()
    local color = not enabled and {.043, .047, .071, 1}
        or button.DXMPressed and THEME.active
        or button.DXMHovered and THEME.hover
        or THEME.raised
    button.DXMBackground:SetColorTexture(unpack(color))
    button.DXMAccent:SetColorTexture(unpack(not enabled and THEME.border or THEME.accent))
    button.DXMLabel:SetTextColor(unpack(not enabled and {.38, .39, .46, 1} or THEME.text))
end

function DXMTheme:CreateButton(parent)
    local button = CreateFrame("Button", nil, parent)
    button.DXMBackground = button:CreateTexture(nil, "BACKGROUND"); button.DXMBackground:SetAllPoints()
    button.DXMAccent = button:CreateTexture(nil, "ARTWORK"); button.DXMAccent:SetPoint("BOTTOMLEFT"); button.DXMAccent:SetPoint("BOTTOMRIGHT"); button.DXMAccent:SetHeight(2)
    addFlatBorder(button, THEME.border)
    button.DXMLabel = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    button.DXMLabel:SetPoint("LEFT", 8, 0); button.DXMLabel:SetPoint("RIGHT", -8, 0); button.DXMLabel:SetJustifyH("CENTER")
    button:SetFontString(button.DXMLabel)
    self:AddButtonEffects(button)
    button:SetScript("OnEnter", function(self) self.DXMHovered = true; updateThemeButton(self); DXMTheme:PlayButtonHover(self, true) end)
    button:SetScript("OnLeave", function(self) self.DXMHovered = nil; self.DXMPressed = nil; updateThemeButton(self); DXMTheme:PlayButtonHover(self, false) end)
    button:SetScript("OnMouseDown", function(self) self.DXMPressed = true; updateThemeButton(self) end)
    button:SetScript("OnMouseUp", function(self) self.DXMPressed = nil; updateThemeButton(self); DXMTheme:PlayButtonClick(self) end)
    button:SetScript("OnEnable", updateThemeButton)
    button:SetScript("OnDisable", updateThemeButton)
    updateThemeButton(button)
    return button
end

function DXMTheme:CreatePanel(parent, name)
    local frame = CreateFrame("Frame", name, parent)
    frame.DXMBackground = frame:CreateTexture(nil, "BACKGROUND"); frame.DXMBackground:SetAllPoints(); frame.DXMBackground:SetColorTexture(.047, .055, .094, .96)
    addFlatBorder(frame, THEME.border)
    return frame
end

function DXMTheme:CreateInput(parent, width, height)
    local input = CreateFrame("EditBox", nil, parent)
    input:SetSize(width or 92, height or 24)
    input:SetAutoFocus(false)
    input:SetFontObject(GameFontHighlight)
    input:SetTextColor(unpack(THEME.text))
    input:SetTextInsets(8, 8, 0, 0)
    input:SetHighlightColor(.788, .643, .957, .28)
    input.DXMOutline = input:CreateTexture(nil, "BACKGROUND"); input.DXMOutline:SetAllPoints(); input.DXMOutline:SetColorTexture(.29, .235, .36, 1)
    input.DXMBackground = input:CreateTexture(nil, "BACKGROUND", nil, 1)
    input.DXMBackground:SetPoint("TOPLEFT", 2, -2); input.DXMBackground:SetPoint("BOTTOMRIGHT", -2, 2); input.DXMBackground:SetColorTexture(.055, .063, .11, 1)
    input:HookScript("OnEditFocusGained", function() input.DXMOutline:SetColorTexture(unpack(THEME.accent)); input.DXMBackground:SetColorTexture(.071, .082, .133, 1) end)
    input:HookScript("OnEditFocusLost", function() input.DXMOutline:SetColorTexture(.29, .235, .36, 1); input.DXMBackground:SetColorTexture(.055, .063, .11, 1) end)
    return input
end

local function updateNavButton(button)
    local color = button.DXMSelected and THEME.active or (button.DXMHovered and THEME.hover or THEME.raised)
    button.Background:SetColorTexture(unpack(color))
    button.Accent:SetShown(button.DXMSelected == true)
    button.Label:SetTextColor(unpack(button.DXMSelected and THEME.accent or THEME.text))
end

local function createNavButton(parent, label)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(110, 24)
    button.Background = button:CreateTexture(nil, "BACKGROUND"); button.Background:SetAllPoints()
    button.Accent = button:CreateTexture(nil, "ARTWORK"); button.Accent:SetPoint("TOPLEFT", 0, 0); button.Accent:SetPoint("BOTTOMLEFT", 0, 0); button.Accent:SetWidth(3); button.Accent:SetColorTexture(unpack(THEME.accent))
    button.Label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.Label:SetPoint("LEFT", 10, 0); button.Label:SetPoint("RIGHT", -8, 0); button.Label:SetJustifyH("LEFT"); button.Label:SetText(label)
    DXMTheme:AddButtonEffects(button)
    button:SetScript("OnEnter", function(self) self.DXMHovered = true; updateNavButton(self); DXMTheme:PlayButtonHover(self, true) end)
    button:SetScript("OnLeave", function(self) self.DXMHovered = nil; updateNavButton(self); DXMTheme:PlayButtonHover(self, false) end)
    button:SetScript("OnMouseUp", function(self) DXMTheme:PlayButtonClick(self) end)
    updateNavButton(button)
    return button
end

local PAGE_DEFINITIONS = {
    {key = "overview", label = "Overview", title = "Overview", description = "Market, network, and DXM settings."},
    {key = "earnings", label = "Earnings", title = "Gold Earned", description = "Track completed Auction House sales and daily proceeds."},
    {key = "ledger", label = "Ledger", title = "Auction Ledger", description = "Review purchases, postings, sales, returns, cost basis, profit, and ROI."},
    {key = "vendor", label = "Vendor Finder", title = "Vendor Finder", description = "Find Auction House listings priced below their guaranteed vendor sell value."},
    {key = "crafting", label = "Crafting", title = "Crafting Buy List", description = "Buy the exact Auction House quantities needed for planned crafts, one reagent at a time."},
    {key = "sell", label = "Sell", title = "Sell Items", description = "List sellable bag items with your saved DXM pricing strategy, one confirmation at a time."},
    {key = "scanner", label = "Scanner", title = "Market Scanner", description = "Capture current Auction House listings and build local price history."},
    {key = "deals", label = "Deals", title = "Deal Finder", description = "Find listings priced below the market values collected by DXM."},
    {key = "valuation", label = "Valuation", title = "Item Valuation", description = "Review local and shared price history before buying or listing an item."},
    {key = "salvage", label = "Salvage", title = "DXM Salvage", description = "Find equipment whose expected disenchant materials are worth more than its buyout."},
}

local function setBodyText(page, text)
    local body = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    body:SetPoint("TOPLEFT", page.Title, "BOTTOMLEFT", 0, -12)
    body:SetPoint("RIGHT", page, "RIGHT", -22, 0)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetText(text)
    return body
end

local function createPage(parent, definition)
    local page = CreateFrame("Frame", nil, parent)
    page:SetPoint("TOPLEFT", parent.Navigation, "TOPRIGHT", 14, 0)
    page:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -14, 46)
    page:Hide()

    local title = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", 4, -4)
    title:SetText(definition.title)
    title:SetTextColor(.788, .643, .957)
    page.Title = title

    local description = setBodyText(page, definition.description)
    page.Description = description
    pages[definition.key] = page
    return page
end

local function formatStatus(data)
    data = data or {}
    local channelName = data.channel or "defyler"
    local channelID = tonumber(data.channelID) or 0
    local connection = channelID > 0 and ("Connected (channel " .. channelID .. ")") or "Connecting"
    local mode = data.automatic == false and "Off" or "Automatic"
    return table.concat({
        "|cffc9a4f4Scanner:|r Ready",
        "|cffc9a4f4Upload queue:|r " .. (tonumber(data.queue) or 0) .. " observations",
        "|cffc9a4f4Shared history:|r " .. (tonumber(data.imported) or 0) .. " items",
        "|cffc9a4f4DXM Network:|r " .. connection,
        "|cffc9a4f4Channel:|r " .. channelName,
        "|cffc9a4f4Connection mode:|r " .. mode,
    }, "\n")
end

function Exchange:SetStatusProvider(provider)
    statusProvider = type(provider) == "function" and provider or nil
    self:Refresh()
end

function Exchange:RegisterStatusDisplay(display)
    if not display then return end
    statusDisplays[display] = true
    self:Refresh()
end

function Exchange:RegisterPageBuilder(key, builder)
    if type(key) ~= "string" or type(builder) ~= "function" then return end
    pageBuilders[key] = builder
    local page = pages[key]
    if page and not page.DXMFeatureBuilt then
        if page.DXMComingSoon then page.DXMComingSoon:Hide() end
        page.DXMFeatureBuilt = true
        builder(page)
    end
end

function Exchange:IsDisplayMode(displayMode)
    return customMode ~= nil and displayMode == customMode
end

function Exchange:Refresh()
    local data
    if statusProvider then
        local ok, result = pcall(statusProvider)
        if ok then data = result end
    end
    local status = formatStatus(data)
    for display in pairs(statusDisplays) do display:SetText(status) end
end

function Exchange:SelectPage(key)
    if key == "network" or key == "config" then key = "overview" end
    if not pages[key] then key = "overview" end
    local changed = currentPage ~= key
    currentPage = key
    for pageKey, page in pairs(pages) do
        page:SetShown(pageKey == key)
    end
    if changed and pages[key] then DXMTheme:AnimateIn(pages[key], .14) end
    for pageKey, button in pairs(navButtons) do
        button.DXMSelected = pageKey == key
        updateNavButton(button)
    end
    self:Refresh()
end

local function showComingSoon(page, definition)
    local container = DXMTheme:CreatePanel(page)
    container:SetPoint("TOPLEFT", page.Description, "BOTTOMLEFT", 0, -28)
    container:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -18, 28)

    local heading = container:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
    heading:SetPoint("CENTER", container, "CENTER", 0, 28)
    heading:SetText("Coming Soon")

    local message = container:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    message:SetPoint("TOP", heading, "BOTTOM", 0, -16)
    message:SetPoint("LEFT", container, "LEFT", 42, 0)
    message:SetPoint("RIGHT", container, "RIGHT", -42, 0)
    message:SetJustifyH("CENTER")
    message:SetWordWrap(true)
    message:SetText((definition.label or "This feature") .. " is planned for a future DXM release.")

    local detail = container:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    detail:SetPoint("TOP", message, "BOTTOM", 0, -10)
    detail:SetText("The button is visible so you can see what is planned; no unfinished controls are active.")
    detail:SetWidth(420)
    detail:SetJustifyH("CENTER")
    detail:SetWordWrap(true)
    page.DXMComingSoon = container
end
local function createContent()
    panel.Navigation = CreateFrame("Frame", nil, panel)
    panel.Navigation:SetPoint("TOPLEFT", 12, -12)
    panel.Navigation:SetPoint("BOTTOMLEFT", 12, 46)
    panel.Navigation:SetWidth(132)
    local navBackground = panel.Navigation:CreateTexture(nil, "BACKGROUND"); navBackground:SetAllPoints(); navBackground:SetColorTexture(.047, .055, .094, 1)
    addFlatBorder(panel.Navigation, THEME.border)

    local navTitle = panel.Navigation:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    navTitle:SetPoint("TOPLEFT", 11, -11)
    navTitle:SetText("DXM FEATURES")
    navTitle:SetTextColor(.788, .643, .957)

    local previous
    for _, definition in ipairs(PAGE_DEFINITIONS) do
        local button = createNavButton(panel.Navigation, definition.label)
        if previous then
            button:SetPoint("TOP", previous, "BOTTOM", 0, -4)
        else
            button:SetPoint("TOP", panel.Navigation, "TOP", 0, -32)
        end
        button:SetScript("OnClick", function() Exchange:SelectPage(definition.key) end)
        navButtons[definition.key] = button
        previous = button

        local page = createPage(panel, definition)
        local builder = pageBuilders[definition.key]
        if builder then
            page.DXMFeatureBuilt = true
            builder(page)
        elseif definition.key == "overview" then
            local status = setBodyText(page, "Loading market status...")
            status:ClearAllPoints()
            status:SetPoint("TOPLEFT", page.Description, "BOTTOMLEFT", 0, -24)
            status:SetPoint("RIGHT", page, "RIGHT", -22, 0)
            Exchange:RegisterStatusDisplay(status)
        else
            showComingSoon(page, definition)
        end
    end

    local footerBar = CreateFrame("Frame", nil, panel)
    footerBar:SetPoint("BOTTOMLEFT", 12, 10); footerBar:SetPoint("BOTTOMRIGHT", -12, 10); footerBar:SetHeight(28)
    footerBar:SetFrameLevel(panel:GetFrameLevel() + 20)
    local footerBackground = footerBar:CreateTexture(nil, "BACKGROUND"); footerBackground:SetAllPoints(); footerBackground:SetColorTexture(unpack(THEME.raised))
    addFlatBorder(footerBar, THEME.border)
    local balance = footerBar:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    balance:SetPoint("LEFT", 10, 0); balance:SetTextColor(unpack(THEME.text))
    local back = DXMTheme:CreateButton(footerBar); back:SetSize(145, 22); back:SetPoint("RIGHT", -4, 0); back:SetText("Auction House")
    back:SetScript("OnClick", function() AuctionHouseFrame:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy) end)
    local footer = footerBar:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    footer:SetPoint("RIGHT", back, "LEFT", -14, 0)
    local version=(C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata("DXM","Version")) or "0.14.33"
    footer:SetText("DXM "..version)
    local function refreshBalance() balance:SetText("Balance  "..GetMoneyString(GetMoney())) end
    local moneyEvents = CreateFrame("Frame"); moneyEvents:RegisterEvent("PLAYER_MONEY"); moneyEvents:SetScript("OnEvent", refreshBalance)
    panel:HookScript("OnShow", refreshBalance)
    panel:HookScript("OnShow", function(self) DXMTheme:AnimateIn(self, .18) end)
    refreshBalance()
end

local function ensureUI()
    if panel or not AuctionHouseFrame or not AuctionHouseFrame.Tabs then return end

    customMode = AuctionHouseFrameDisplayMode[DISPLAY_KEY]
    if not customMode then
        customMode = {"DXMFrame"}
        AuctionHouseFrameDisplayMode[DISPLAY_KEY] = customMode
    end

    panel = CreateFrame("Frame", "DXMExchangeFrame", AuctionHouseFrame)
    panel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 4, -34)
    panel:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -4, 4)
    panel:Hide()
    local themeFill = panel:CreateTexture(nil, "BACKGROUND", nil, 7)
    themeFill:SetAllPoints(panel)
    themeFill:SetColorTexture(.035, .043, .078, 1)
    AuctionHouseFrame.DXMFrame = panel
    createContent()

    tab = CreateFrame("Button", "AuctionHouseFrameDXMTab", AuctionHouseFrame, "AuctionHouseFrameDisplayModeTabTemplate")
    tab:SetText("DXM")
    tab.displayMode = customMode
    tab:ClearAllPoints()
    tab:SetPoint("LEFT", AuctionHouseFrame.AuctionsTab, "RIGHT", -15, 0)

    local tabIndex
    for index, existing in ipairs(AuctionHouseFrame.Tabs) do
        if existing == tab then tabIndex = index break end
    end
    if not tabIndex then
        table.insert(AuctionHouseFrame.Tabs, tab)
        tabIndex = #AuctionHouseFrame.Tabs
    end
    tab:SetID(tabIndex)
    AuctionHouseFrame.tabsForDisplayMode[customMode] = tabIndex
    PanelTemplates_SetNumTabs(AuctionHouseFrame, #AuctionHouseFrame.Tabs)
    if PanelTemplates_TabResize then PanelTemplates_TabResize(tab, 0) end
    PanelTemplates_DeselectTab(tab)
    local activeMode = AuctionHouseFrame.GetDisplayMode and AuctionHouseFrame:GetDisplayMode()
    local activeTab = activeMode and AuctionHouseFrame.tabsForDisplayMode[activeMode]
    if activeTab then PanelTemplates_SetTab(AuctionHouseFrame, activeTab) end
    tab:Show()

    hooksecurefunc(AuctionHouseFrame, "SetDisplayMode", function(frame, displayMode)
        if displayMode == customMode then
            frame:SetTitle("DXM Exchange")
            Exchange:SelectPage(currentPage)
        end
        if DXMHostStyle and DXMHostStyle.Set then DXMHostStyle:Set(frame, displayMode == customMode, "DXM Exchange", true, true) end
    end)

    Exchange:SelectPage(currentPage)
end

function Exchange:Open(pageKey)
    ensureUI()
    if not panel or not customMode then
        print("DXM: open the Auction House to use DXM Exchange.")
        return
    end
    if pageKey == "network" or pageKey == "config" then pageKey = "overview" end
    currentPage = pages[pageKey] and pageKey or "overview"
    AuctionHouseFrame:SetDisplayMode(customMode)
    self:SelectPage(currentPage)
end

function Module:Boot(hook)
    hook(Const.AuctionHouseOpened, Module.AuctionHouseOpened)
    hook(Const.DisplayModeChanged, Module.DisplayModeChanged)
end

function Module:AuctionHouseOpened()
    ensureUI()
    Exchange:Refresh()
end

function Module:DisplayModeChanged(displayMode)
    if customMode and displayMode == customMode then Exchange:Refresh() end
end
