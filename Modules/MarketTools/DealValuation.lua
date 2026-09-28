-- Listing observations are not sales. Repeated scans of one expensive listing
-- must not establish a resale price or multiply confidence in that price.
DXMDealValuation = {}

function DXMDealValuation.Get(id, currentPrice)
    local now = GetServerTime()
    local hours, oldest, newest = {}, nil, nil
    local function observe(timestamp, price)
        timestamp, price = tonumber(timestamp), tonumber(price)
        if timestamp and timestamp <= now and timestamp >= now - 7 * 86400 and price and price > 0 then
            local hour = math.floor(timestamp / 3600)
            local old = hours[hour]
            if not old or price < old.price then hours[hour] = {price=price,timestamp=timestamp} end
            oldest = math.min(oldest or timestamp,timestamp)
            newest = math.max(newest or timestamp,timestamp)
        end
    end
    for _, stat in ipairs(DXMCore:Statistics(id)) do
        -- Summary-only estimates have no timestamps and cannot establish freshness.
        for _, point in ipairs(stat.points or {}) do
            local timestamp = tonumber(point.timeslice)
            timestamp = timestamp and timestamp * 3600
            observe(timestamp,point.price)
        end
    end
    local latest = DXMData and DXMData.LatestPrices and DXMData.LatestPrices[DXMCore:AuctionKey()]
    local exact = latest and latest[id]
    if exact then observe(exact.capturedAt,exact.price) end
    local commodity = latest and latest["commodity:" .. (tostring(id):match("^(%d+)") or "")]
    if commodity and commodity.commodity then observe(commodity.capturedAt,commodity.price) end
    observe(now,currentPrice)
    local hourly = {}
    for _,row in pairs(hours) do hourly[#hourly+1]=row end
    local filtered,fairAverage,excluded=DXMFairPricing.Filter(hourly)
    oldest,newest=nil,nil
    local all, recent = {}, {}
    for _, row in ipairs(filtered) do
        all[#all+1] = row.price
        oldest=math.min(oldest or row.timestamp,row.timestamp)
        newest=math.max(newest or row.timestamp,row.timestamp)
        if row.timestamp >= now - 86400 then recent[#recent+1] = row.price end
    end
    local samples = #all
    if samples < 6 or not oldest or newest-oldest < 86400 then
        return nil,samples,"Insufficient history across time"
    end
    if newest < now - 6*3600 or #recent < 3 then
        return nil,samples,"Insufficient recent history"
    end
    table.sort(all); table.sort(recent)
    -- Use the lower fifth of both windows. A recent price drop cannot be hidden
    -- by excluding the newest hour or by selecting an older source's estimate.
    local value = math.min(all[math.max(1,math.ceil(#all*.20))],recent[math.max(1,math.ceil(#recent*.20))])
    return value,samples,("Listing baseline from %d distinct hours over %.1f days; %d high outliers excluded (over 200%% of fair average). Not a confirmed sale price. Spread excludes auction fees and deposits."):format(samples,(newest-oldest)/86400,excluded)
end
