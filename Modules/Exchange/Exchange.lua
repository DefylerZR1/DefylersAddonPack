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
local overviewStatus
local networkStatus
local statusProvider
local pageBuilders = {}

local PAGE_DEFINITIONS = {
    {key = "overview", label = "Overview", title = "DXM Exchange", description = "Defyler Exchange Market tools and shared market status."},
    {key = "earnings", label = "Earnings", title = "Gold Earned", description = "Track completed Auction House sales and daily proceeds."},
    {key = "ledger", label = "Ledger", title = "Auction Ledger", description = "Review purchases, postings, sales, returns, cost basis, profit, and ROI."},
    {key = "vendor", label = "Vendor Finder", title = "Vendor Finder", description = "Find Auction House listings priced below their guaranteed vendor sell value."},
    {key = "crafting", label = "Crafting", title = "Crafting Buy List", description = "Buy the exact Auction House quantities needed for planned crafts, one reagent at a time."},
    {key = "scanner", label = "Scanner", title = "Market Scanner", description = "Capture current Auction House listings and build local price history."},
    {key = "deals", label = "Deals", title = "Deal Finder", description = "Find listings priced below the market values collected by DXM."},
    {key = "valuation", label = "Valuation", title = "Item Valuation", description = "Review local and shared price history before buying or listing an item."},
    {key = "salvage", label = "Salvage", title = "DXM Salvage", description = "Find equipment whose expected disenchant materials are worth more than its buyout."},
    {key = "network", label = "Network", title = "DXM Network", description = "Share current market observations through the private DXM channel and Relay."},
    {key = "config", label = "Config", title = "DXM Configuration", description = "Manage market history, interface, network, and DXM information."},
}

local function setBodyText(page, text)
    local body = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
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
    page:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -14, 14)
    page:Hide()

    local title = page:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 4, -4)
    title:SetText(definition.title)
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
        "|cffffd100Scanner:|r Ready",
        "|cffffd100Upload queue:|r " .. (tonumber(data.queue) or 0) .. " observations",
        "|cffffd100Shared history:|r " .. (tonumber(data.imported) or 0) .. " items",
        "|cffffd100DXM Network:|r " .. connection,
        "|cffffd100Channel:|r " .. channelName,
        "|cffffd100Connection mode:|r " .. mode,
    }, "\n")
end

function Exchange:SetStatusProvider(provider)
    statusProvider = type(provider) == "function" and provider or nil
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
    if overviewStatus then overviewStatus:SetText(status) end
    if networkStatus then networkStatus:SetText(status) end
end

function Exchange:SelectPage(key)
    if not pages[key] then key = "overview" end
    currentPage = key
    for pageKey, page in pairs(pages) do
        page:SetShown(pageKey == key)
    end
    for pageKey, button in pairs(navButtons) do
        if pageKey == key then button:LockHighlight() else button:UnlockHighlight() end
    end
    self:Refresh()
end

local function showComingSoon(page, definition)
    local container = CreateFrame("Frame", nil, page, "InsetFrameTemplate")
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
    panel.Navigation = CreateFrame("Frame", nil, panel, "InsetFrameTemplate")
    panel.Navigation:SetPoint("TOPLEFT", 12, -12)
    panel.Navigation:SetPoint("BOTTOMLEFT", 12, 12)
    panel.Navigation:SetWidth(150)

    local navTitle = panel.Navigation:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    navTitle:SetPoint("TOPLEFT", 14, -14)
    navTitle:SetText("DXM FEATURES")

    local previous
    for _, definition in ipairs(PAGE_DEFINITIONS) do
        local button = CreateFrame("Button", nil, panel.Navigation, "UIPanelButtonTemplate")
        button:SetSize(126, 28)
        if previous then
            button:SetPoint("TOP", previous, "BOTTOM", 0, -7)
        else
            button:SetPoint("TOP", panel.Navigation, "TOP", 0, -42)
        end
        button:SetText(definition.label)
        button:SetScript("OnClick", function() Exchange:SelectPage(definition.key) end)
        navButtons[definition.key] = button
        previous = button

        local page = createPage(panel, definition)
        local builder = pageBuilders[definition.key]
        if builder then
            page.DXMFeatureBuilt = true
            builder(page)
        elseif definition.key == "overview" then
            overviewStatus = setBodyText(page, "Loading market status...")
            overviewStatus:ClearAllPoints()
            overviewStatus:SetPoint("TOPLEFT", page.Description, "BOTTOMLEFT", 0, -24)
            overviewStatus:SetPoint("RIGHT", page, "RIGHT", -22, 0)
        elseif definition.key == "network" then
            networkStatus = setBodyText(page, "Loading network status...")
            networkStatus:ClearAllPoints()
            networkStatus:SetPoint("TOPLEFT", page.Description, "BOTTOMLEFT", 0, -24)
            networkStatus:SetPoint("RIGHT", page, "RIGHT", -22, 0)
        else
            showComingSoon(page, definition)
        end
    end

    local footer = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    footer:SetPoint("BOTTOMRIGHT", -16, 8)
    footer:SetText("DXM 0.14.13")
end

local function ensureUI()
    if panel or not AuctionHouseFrame or not AuctionHouseFrame.Tabs then return end

    customMode = AuctionHouseFrameDisplayMode[DISPLAY_KEY]
    if not customMode then
        customMode = {"DXMFrame"}
        AuctionHouseFrameDisplayMode[DISPLAY_KEY] = customMode
    end

    panel = CreateFrame("Frame", "DXMExchangeFrame", AuctionHouseFrame, "InsetFrameTemplate")
    panel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 5, -28)
    panel:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -5, 30)
    panel:Hide()
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
    end)

    Exchange:SelectPage(currentPage)
end

function Exchange:Open(pageKey)
    ensureUI()
    if not panel or not customMode then
        print("DXM: open the Auction House to use DXM Exchange.")
        return
    end
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
