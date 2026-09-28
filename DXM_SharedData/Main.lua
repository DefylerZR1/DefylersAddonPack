if not DXMCore then return end

local Module = DXMCore:Module("Stats:SharedMarket", "Scanner")

local function importedData()
    local saved = type(DXMSharedImport) == "table" and DXMSharedImport or nil
    local snapshot = type(DXMSharedSnapshot) == "table" and DXMSharedSnapshot or nil
    local savedAt = saved and tonumber(saved.updatedAt) or 0
    local snapshotAt = snapshot and tonumber(snapshot.updatedAt) or 0
    if snapshot and type(snapshot.markets) == "table" and snapshotAt >= savedAt then
        return snapshot
    end
    return saved
end
local Const = DXMCore.Const()
local MAX_QUEUE = 50000
local PREFIX = "DX2"

local function ensureTables()
    if type(DXMSharedExport) ~= "table" then DXMSharedExport = {} end
    DXMSharedExport.schema = 2
    if type(DXMSharedExport.queue) ~= "table" then DXMSharedExport.queue = {} end
    if type(DXMSharedImport) ~= "table" then DXMSharedImport = {} end
    DXMSharedImport.schema = 2
    if type(DXMSharedImport.markets) ~= "table" then DXMSharedImport.markets = {} end
    if type(DXMSharedImport.vendors) ~= "table" then DXMSharedImport.vendors = {} end
    -- Keep old realm-only imports quarantined for migration/debugging. Version 2 never prices from them.
    if type(DXMSharedImport.realms) ~= "table" then DXMSharedImport.realms = {} end
end

local function clean(value)
    return tostring(value or ""):gsub("[%c|]", "_")
end

local function queueSize()
    local count = 0
    for _ in pairs(DXMSharedExport.queue) do count = count + 1 end
    return count
end

function DXMQueueVendorObservation(itemID, unitPrice)
    ensureTables()
    itemID, unitPrice = tonumber(itemID), tonumber(unitPrice)
    if not itemID or itemID <= 0 or not unitPrice or unitPrice <= 0 then return end
    local identity = DXMCore:MarketIdentity()
    local capturedAt = GetServerTime()
    local day = floor(capturedAt / 86400)
    local marketKey = clean(identity.key)
    local recordKey = "vendor:" .. marketKey .. ":" .. day .. ":" .. itemID
    DXMSharedExport.queue[recordKey] = table.concat({
        "DV1", capturedAt, clean(identity.product), clean(identity.ruleset), clean(identity.realm),
        identity.realmID or 0, clean(identity.market), floor(itemID), floor(unitPrice)
    }, "|")
end

function DXMQueueSaleObservation(itemID, quantity, proceeds, costBasis, capturedAt, saleSignature)
    ensureTables()
    itemID, quantity = tonumber(itemID), tonumber(quantity)
    proceeds, costBasis = tonumber(proceeds), tonumber(costBasis) or 0
    capturedAt = tonumber(capturedAt) or GetServerTime()
    if not itemID or itemID <= 0 or not quantity or quantity <= 0 or not proceeds or proceeds <= 0 then return end
    local identity = DXMCore:MarketIdentity()
    local marketKey = clean(identity.key)
    local signature = clean(saleSignature or (capturedAt .. ":" .. itemID .. ":" .. quantity .. ":" .. proceeds))
    local recordKey = "sale:" .. marketKey .. ":" .. signature
    DXMSharedExport.queue[recordKey] = table.concat({
        "DS1", floor(capturedAt), clean(identity.product), clean(identity.ruleset), clean(identity.realm),
        identity.realmID or 0, clean(identity.market), floor(itemID), floor(quantity),
        floor(proceeds), math.max(0, floor(costBasis)), signature
    }, "|")
end
function Module:Boot(hook)
    ensureTables()
    hook(Const.ScannerItemsCompleted, Module.ScannerItemsCompleted)
    hook(Const.AuctionHouseOpened, Module.AuctionHouseOpened)
    hook(Const.AuctionHouseClosed, Module.AuctionHouseClosed)
end

function Module:ScannerItemsCompleted(items)
    ensureTables()
    local capturedAt = GetServerTime()
    local identity = DXMCore:MarketIdentity()
    local marketKey = clean(identity.key)
    local hour = floor(capturedAt / 3600)
    local queued = queueSize()

    for _, item in ipairs(items or {}) do
        if queued >= MAX_QUEUE then break end
        local key = item.itemKey
        local data = item.itemData
        if key and data and data.minPrice and data.totalQuantity then
            local id = clean(item.id or DXMCore:ItemKeyKey(key))
            local recordKey = marketKey .. ":" .. hour .. ":" .. id
            local record = table.concat({
                PREFIX,
                capturedAt,
                clean(identity.product),
                clean(identity.ruleset),
                clean(identity.realm),
                identity.realmID or 0,
                clean(identity.market),
                id,
                key.itemID or 0,
                key.itemLevel or 0,
                key.itemSuffix or 0,
                key.battlePetSpeciesID or 0,
                floor(data.minPrice),
                floor(data.totalQuantity)
            }, "|")
            if not DXMSharedExport.queue[recordKey] then queued = queued + 1 end
            DXMSharedExport.queue[recordKey] = record
        end
    end
    self:UpdateDashboard()
end

function Module:Stats(auctionKey, id)
    ensureTables()
    local imported = importedData()
    local marketData = imported and imported.markets and imported.markets[auctionKey]
    local rows = marketData and marketData[id]
    if type(rows) ~= "table" or #rows == 0 then return end

    local points = DXMCore:Points{}
    for _, row in ipairs(rows) do
        local price = tonumber(row.price)
        local capturedAt = tonumber(row.capturedAt)
        if price and price > 0 and capturedAt then
            local contributors = tonumber(row.contributors) or 1
            points:Add(price, tonumber(row.quantity), capturedAt / 3600, math.min(contributors, 5))
        end
    end
    if #points == 0 then return end
    return DXMCore:Stat{name = "Shared market", points = points}
end

local function importedCount()
    ensureTables()
    local count = 0
    local imported = importedData()
    for _, market in pairs(imported and imported.markets or {}) do
        for _ in pairs(market) do count = count + 1 end
    end
    return count
end

local function dashboardData()
    ensureTables()
    local channel = DXMSharedConfig and DXMSharedConfig.channel or "defyler"
    local channelId = 0
    if type(GetChannelName) == "function" then
        channelId = tonumber((GetChannelName(channel))) or 0
    end
    local identity = DXMCore:MarketIdentity()
    return {
        queue = queueSize(),
        imported = importedCount(),
        channel = channel,
        channelID = channelId,
        automatic = not DXMSharedConfig or DXMSharedConfig.autoJoin ~= false,
        market = identity.market,
        ruleset = identity.ruleset,
    }
end

if DXMExchange and DXMExchange.SetStatusProvider then
    DXMExchange:SetStatusProvider(dashboardData)
end

function Module:UpdateDashboard()
    if DXMExchange and DXMExchange.Refresh then DXMExchange:Refresh() end
end

function Module:AuctionHouseOpened()
    self:UpdateDashboard()
end

function Module:AuctionHouseClosed()
end

SLASH_DXM1 = "/dxm"
SlashCmdList.DXM = function(input)
    local page = strtrim((input or ""):lower())
    if page == "" then page = "overview" end
    if DXMExchange and DXMExchange.Open then
        DXMExchange:Open(page)
    else
        print("DXM: open the Auction House to use DXM Exchange.")
    end
end

SLASH_DXMSYNC1 = "/dxmsync"
SlashCmdList.DXMSYNC = function()
    ensureTables()
    local identity = DXMCore:MarketIdentity()
    print(("DXM: %d queued observations, %d imported item histories. Market=%s, ruleset=%s. DXM Relay syncs every five minutes."):format(queueSize(), importedCount(), identity.market, identity.ruleset))
end