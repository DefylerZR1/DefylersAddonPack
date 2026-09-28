if not DXMCore then return end

DXMPriceSummary = {}

function DXMPriceSummary.Get(itemKey)
    local key = DXMCore:ItemKeyKey(itemKey)
    local market = DXMCore:AuctionKey()
    local now = GetServerTime()
    local info = C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.GetItemKeyInfo(itemKey)
    local commodity = info and info.isCommodity
    local latestData = DXMData and DXMData.LatestPrices and DXMData.LatestPrices[market]
    local live = latestData and latestData[key]
    local commodityLive = latestData and latestData["commodity:" .. itemKey.itemID]
    if commodityLive then commodity = true end
    local observations = {}
    local latestPrice, latestAt, latestPriority, latestSource
    local function add(timestamp, price, priority, source)
        timestamp, price = tonumber(timestamp), tonumber(price)
        if not timestamp or timestamp > now or not price or price <= 0 then return end
        if not latestAt or timestamp > latestAt or (timestamp == latestAt and
            (priority > latestPriority or (priority == latestPriority and price < latestPrice))) then
            latestPrice, latestAt, latestPriority, latestSource = price, timestamp, priority, source
        end
        if timestamp < now - 7 * 86400 then return end
        local old = observations[timestamp]
        if not old or priority > old.priority or (priority == old.priority and price < old.price) then
            observations[timestamp] = {price = price, priority = priority, timestamp = timestamp, source = source}
        end
    end
    local function matches(candidate)
        if candidate == key then return true end
        -- Commodities have one unit market even if saved keys contain item level.
        return commodity and tonumber(tostring(candidate):match("^(%d+)")) == itemKey.itemID
    end
    local localMarket = DXMPriceHistoryData and DXMPriceHistoryData[market]
    for candidate, entries in pairs(localMarket or {}) do
        if matches(candidate) then
            for _, row in ipairs(entries) do add(row[1], row[2], 2, "local scan") end
        end
    end
    local function shared(import)
        local data = import and import.markets and import.markets[market]
        for candidate, entries in pairs(data or {}) do
            if matches(candidate) then
                for _, row in ipairs(entries) do add(row.capturedAt, row.price, 1, "shared observation") end
            end
        end
    end
    shared(DXMSharedSnapshot)
    shared(DXMSharedImport)
    if live then add(live.capturedAt, live.price, 3, "AH search") end
    if commodityLive then add(commodityLive.capturedAt, commodityLive.price, 3, "AH search") end
    local rows={}
    for _,row in pairs(observations) do rows[#rows+1]=row end
    local filtered,fairAverage,excluded=DXMFairPricing.Filter(rows)
    if #rows>0 then latestPrice,latestAt,latestPriority,latestSource=nil,nil,nil,nil end
    local sum7, count7, sum24, count24 = 0, 0, 0, 0
    for _, row in ipairs(filtered) do
        local timestamp=row.timestamp
        if not latestAt or timestamp>latestAt then latestPrice,latestAt,latestSource=row.price,timestamp,row.source end
        sum7, count7 = sum7 + row.price, count7 + 1
        if timestamp >= now - 86400 then sum24, count24 = sum24 + row.price, count24 + 1 end
    end
    return {average7 = count7 > 0 and math.floor(sum7 / count7 + .5) or nil,
        average24 = count24 > 0 and math.floor(sum24 / count24 + .5) or nil,
        count7 = count7, count24 = count24, latest = latestPrice,
        capturedAt = latestAt, source = latestSource, excluded = excluded, fairAverage = fairAverage}
end

-- Observe native results without sending queries or initiating any purchase.
local events = CreateFrame("Frame")
events:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
events:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
events:SetScript("OnEvent", function(_, event, item)
    local commodity = event == "COMMODITY_SEARCH_RESULTS_UPDATED"
    local minimum
    local count = commodity and C_AuctionHouse.GetNumCommoditySearchResults(item)
        or C_AuctionHouse.GetNumItemSearchResults(item)
    for index = 1, (count or 0) do
        local row
        if commodity then row = C_AuctionHouse.GetCommoditySearchResultInfo(item, index)
        else row = C_AuctionHouse.GetItemSearchResultInfo(item, index) end
        local price
        if row then
            price = commodity and tonumber(row.unitPrice) or
                (tonumber(row.buyoutAmount) or 0) / math.max(1, tonumber(row.quantity) or 1)
        end
        if price and price > 0 and (not minimum or price < minimum) then minimum = price end
    end
    if not minimum then return end
    DXMData = DXMData or {}
    DXMData.LatestPrices = DXMData.LatestPrices or {}
    local market = DXMCore:AuctionKey()
    DXMData.LatestPrices[market] = DXMData.LatestPrices[market] or {}
    local key = commodity and ("commodity:" .. item) or DXMCore:ItemKeyKey(item)
    DXMData.LatestPrices[market][key] = {price = minimum, capturedAt = GetServerTime(), commodity = commodity}
end)
