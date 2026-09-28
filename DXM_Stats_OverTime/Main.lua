if not DXMCore then return end

local Module = DXMCore:Module("Stats:OverTime")
local Const = DXMCore.Const()

DXMStatsOverTimeData = DXMStatsOverTimeData or {}
DXMPriceHistoryData = DXMPriceHistoryData or {}
DXMPriceHistoryMeta = DXMPriceHistoryMeta or {}

local function settings()
    local config = DXMConfig or {}
    local days = math.max(1, math.min(365, tonumber(config.historyRetentionDays) or 30))
    local maximum = math.max(5, math.min(200, tonumber(config.historyMaxSamples) or 40))
    return config.historyEnabled ~= false, days, maximum
end

local function prune(list, cutoff, maximum)
    local write = 1
    for read = 1, #list do
        local point = list[read]
        if type(point) == "table" and (tonumber(point[1]) or 0) >= cutoff then
            list[write] = point
            write = write + 1
        end
    end
    for index = #list, write, -1 do list[index] = nil end
    while #list > maximum do table.remove(list, 1) end
end

function Module:Boot(hook)
    hook(Const.ScannerItemsPush, Module.ScannerItemsPush)
    hook(Const.ScannerItemsCompleted, Module.ScannerItemsCompleted)
end

-- Preserve the compact hourly table for compatibility and as a fallback.
function Module:ScannerItemsPush(items)
    local auctionKey = DXMCore:AuctionKey()
    local data = DXMStatsOverTimeData[auctionKey]
    if not data then data = {}; DXMStatsOverTimeData[auctionKey] = data end
    local timeslice = floor(DXMCore:Timeslice())
    for key in pairs(data) do if key < timeslice - 24 * 30 then data[key] = nil end end
    local bucket = data[timeslice]
    if not bucket then bucket = {count = {}, price = {}}; data[timeslice] = bucket end
    for _, item in ipairs(items or {}) do
        local id = item.id
        local itemData = item.itemData
        local count = itemData and tonumber(itemData.totalQuantity)
        local price = itemData and tonumber(itemData.minPrice)
        if id and price and price > 0 then
            if not bucket.count[id] or (count and count > bucket.count[id]) then bucket.count[id] = count or 0 end
            if not bucket.price[id] or price < bucket.price[id] then bucket.price[id] = price end
        end
    end
end

-- Append one observation per item after every completed scan.
function Module:ScannerItemsCompleted(items)
    local enabled, days, maximum = settings()
    if not enabled then return end
    local auctionKey = DXMCore:AuctionKey()
    local realm = DXMPriceHistoryData[auctionKey]
    if not realm then realm = {}; DXMPriceHistoryData[auctionKey] = realm end
    local now = GetServerTime()
    local oldMeta = DXMPriceHistoryMeta[auctionKey]
    local lastPrunedAt = type(oldMeta) == "table" and tonumber(oldMeta.lastPrunedAt) or 0
    local fullPrune = now - lastPrunedAt >= 3600
    DXMPriceHistoryMeta[auctionKey] = {
        lastScanAt = now,
        itemCount = #(items or {}),
        lastPrunedAt = fullPrune and now or lastPrunedAt,
    }
    local cutoff = now - days * 86400

    if fullPrune then
        for id, list in pairs(realm) do
            prune(list, cutoff, maximum)
            if #list == 0 then realm[id] = nil end
        end
    end
    for _, item in ipairs(items or {}) do
        local id = item.id
        local itemData = item.itemData
        local price = itemData and tonumber(itemData.minPrice)
        if id and price and price > 0 then
            local list = realm[id]
            if not list then list = {}; realm[id] = list end
            if not fullPrune then prune(list, cutoff, maximum) end
            list[#list + 1] = {now, price, tonumber(itemData.totalQuantity) or 0}
            while #list > maximum do table.remove(list, 1) end
        end
    end
end

local function weightForAge(hours)
    if hours <= 1 then return 5 end
    if hours <= 24 then return 2 end
    if hours <= 72 then return 1.5 end
    return 1
end

function Module:Stats(auctionKey, id)
    local points = DXMCore:Points{}
    local nowSeconds = GetServerTime()
    local history = DXMPriceHistoryData[auctionKey]
    local list = history and history[id]
    if list then
        for _, entry in ipairs(list) do
            local timestamp, price, count = tonumber(entry[1]), tonumber(entry[2]), tonumber(entry[3])
            if timestamp and price and price > 0 then
                points:Add(price, count or 0, timestamp / 3600, weightForAge((nowSeconds - timestamp) / 3600))
            end
        end
    end

    if #points == 0 then
        local compact = DXMStatsOverTimeData[auctionKey]
        if compact then
            local now = DXMCore:Timeslice()
            for timeslice, bucket in pairs(compact) do
                local price = bucket.price and bucket.price[id]
                if price then points:Add(price, bucket.count and bucket.count[id], timeslice, weightForAge(now - timeslice)) end
            end
        end
    end
    if #points == 0 then return end
    return DXMCore:Stat{name = list and "Scan history" or "Hourly history", points = points}
end

function Module:GetServerKeyList()
    local found, list = {}, {}
    for key in pairs(DXMStatsOverTimeData) do found[key] = true end
    for key in pairs(DXMPriceHistoryData) do found[key] = true end
    for key in pairs(DXMPriceHistoryMeta) do found[key] = true end
    for key in pairs(found) do list[#list + 1] = key end
    return list
end

local function moveStore(store, oldKey, newKey)
    local old = store[oldKey]
    store[oldKey] = nil
    if old and newKey and not store[newKey] then store[newKey] = old end
end

function Module:ChangeServerKey(oldKey, newKey)
    if type(self) ~= "table" or type(oldKey) ~= "string" or (newKey ~= nil and type(newKey) ~= "string") then return "Invalid parameters" end
    moveStore(DXMStatsOverTimeData, oldKey, newKey)
    moveStore(DXMPriceHistoryData, oldKey, newKey)
    moveStore(DXMPriceHistoryMeta, oldKey, newKey)
end