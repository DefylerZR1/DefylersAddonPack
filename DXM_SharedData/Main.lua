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
local QUEUE_FORMAT_VERSION = 3
local COMPACTION_BATCH_SIZE = 500
local queueCompaction

local function ensureTables()
    if type(DXMSharedExport) ~= "table" then DXMSharedExport = {} end
    DXMSharedExport.schema = 2
    if type(DXMSharedExport.queue) ~= "table" then DXMSharedExport.queue = {} end
    if type(DXMSharedExport.archive) ~= "table" then DXMSharedExport.archive = {} end
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

-- Return the stable queue key for a scan observation and its capture time.
-- Older builds included the scan hour in the table key, retaining another
-- copy of every item each hour even after Relay imported it.
local function observationIdentity(record)
    if type(record) ~= "string" or record:sub(1, 4) ~= PREFIX .. "|" then return end
    local _, capturedAt, product, ruleset, realm, realmID, market, id = strsplit("|", record)
    if not capturedAt or not product or not ruleset or not realm or not realmID or not market or not id then return end
    local marketKey = table.concat({product, ruleset, tostring(realmID) .. "-" .. realm, market}, "::")
    return "scan:" .. marketKey .. ":" .. id, tonumber(capturedAt) or 0
end

-- Move superseded hourly scan rows to a recoverable archive in small batches.
-- Relay reads only queue, while no retained observation is destroyed.
local function startQueueCompaction()
    ensureTables()
    if DXMSharedExport.queueFormat == QUEUE_FORMAT_VERSION or queueCompaction then return end

    queueCompaction = {
        phase = "find",
        cursor = nil,
        keys = {},
        latest = {},
        before = 0,
        archiveIndex = 1,
    }

    local function continueCompaction()
        local state = queueCompaction
        if not state then return end
        local queue, archive = DXMSharedExport.queue, DXMSharedExport.archive
        local processed = 0

        if state.phase == "find" then
            while processed < COMPACTION_BATCH_SIZE do
                local key, record = next(queue, state.cursor)
                if not key then
                    state.phase = "archive"
                    break
                end
                state.cursor = key
                state.keys[#state.keys + 1] = key
                state.before = state.before + 1
                local identity, capturedAt = observationIdentity(record)
                if identity then
                    local current = state.latest[identity]
                    if not current or capturedAt > current.capturedAt
                        or (capturedAt == current.capturedAt and tostring(key) > tostring(current.key)) then
                        state.latest[identity] = {key = key, capturedAt = capturedAt, record = record}
                    end
                end
                processed = processed + 1
            end
        end

        if state.phase == "archive" then
            processed = 0
            while processed < COMPACTION_BATCH_SIZE and state.archiveIndex <= #state.keys do
                local key = state.keys[state.archiveIndex]
                local record = queue[key]
                local identity = observationIdentity(record)
                if identity then
                    queue[key] = nil
                    local keep = state.latest[identity]
                    if keep and keep.key == key then
                        queue[identity] = keep.record
                    elseif record then
                        archive[key] = record
                    end
                end
                state.archiveIndex = state.archiveIndex + 1
                processed = processed + 1
            end
            if state.archiveIndex > #state.keys then
                DXMSharedExport.queueFormat = QUEUE_FORMAT_VERSION
                local before, after = state.before, queueSize()
                queueCompaction = nil
                print(("DXM: compacted active upload queue from %d to %d records; older observations were archived."):format(before, after))
                Module:UpdateDashboard()
                return
            end
        end

        C_Timer.After(0, continueCompaction)
    end

    C_Timer.After(0, continueCompaction)
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
    startQueueCompaction()
end

function Module:ScannerItemsCompleted(items)
    ensureTables()
    local capturedAt = GetServerTime()
    local identity = DXMCore:MarketIdentity()
    local marketKey = clean(identity.key)
    local queued = queueSize()

    for _, item in ipairs(items or {}) do
        local key = item.itemKey
        local data = item.itemData
        if key and data and data.minPrice and data.totalQuantity then
            local id = clean(item.id or DXMCore:ItemKeyKey(key))
            local recordKey = "scan:" .. marketKey .. ":" .. id
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
            if DXMSharedExport.queue[recordKey] or queued < MAX_QUEUE then
                if not DXMSharedExport.queue[recordKey] then queued = queued + 1 end
                DXMSharedExport.queue[recordKey] = record
            end
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
