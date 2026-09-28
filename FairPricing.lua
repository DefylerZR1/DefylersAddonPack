DXMFairPricing = {}

-- Bootstrap from the average of the lower-priced half of hourly minimums.
-- This reduces the influence of expensive asks and repeated scans on the cap.
-- It estimates fair value from listings; it does not establish completed sales.
-- Preserve raw observations elsewhere; callers receive a filtered view only.
function DXMFairPricing.Filter(rows)
    local hours = {}
    for index, row in ipairs(rows) do
        local price = tonumber(row.price)
        local timestamp = tonumber(row.timestamp) or tonumber(row.capturedAt) or (tonumber(row.timeslice) and row.timeslice*3600)
        if price and price > 0 then
            local key = timestamp and math.floor(timestamp/3600) or index
            hours[key] = math.min(hours[key] or price,price)
        end
    end
    local prices = {}
    for _, price in pairs(hours) do prices[#prices+1]=price end
    table.sort(prices)
    if #prices==0 then return {},nil,0 end
    local lowerCount=math.max(1,math.floor(#prices/2))
    local sum=0
    for index=1,lowerCount do sum=sum+prices[index] end
    local fairAverage=sum/lowerCount
    local filtered,excluded={},0
    for _,row in ipairs(rows) do
        local price=tonumber(row.price)
        if price and price>0 then
            if price<=fairAverage*2 then filtered[#filtered+1]=row
            else excluded=excluded+1 end
        end
    end
    return filtered,fairAverage,excluded
end
