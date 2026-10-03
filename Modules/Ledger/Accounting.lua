DXMLedgerAccounting = {}
local Accounting = DXMLedgerAccounting

function Accounting.ResolveItem(data, name, link, id)
    id = tonumber(id)
    if id then return id end
    local getter = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
    if link and getter then id = tonumber((getter(link))) end
    if not id and type(link)=="string" then id=tonumber(link:match("item:(%d+)")) end
    if id then return id end
    -- Sale invoices often have a name but no attached item link. Only use an
    -- unambiguous identity already recorded in this market.
    local candidate
    for _, row in ipairs(data.transactions or {}) do
        if name and row.name == name and tonumber(row.itemID) then
            if candidate and candidate ~= tonumber(row.itemID) then return nil end
            candidate = tonumber(row.itemID)
        end
    end
    return candidate
end

function Accounting.Suffix(link)
    local data=type(link)=="string" and link:match("item:([^|]+)")
    if not data then return end
    local index=0
    for field in (data..":"):gmatch("(.-):") do
        index=index+1
        if index==7 then return tonumber(field) or 0 end
    end
end

function Accounting.UpdateSale(row)
    if row.status ~= "sold" or not row.collected then return end
    row.saleProceeds = math.max(0, (tonumber(row.total) or 0) - (tonumber(row.deposit) or 0))
    row.gross = row.saleProceeds + (tonumber(row.fee) or 0)
    row.profit, row.roi = nil, nil
    if row.costAssigned and (tonumber(row.costQuantity) or 0) == (tonumber(row.quantity) or 1)
        and (tonumber(row.unmatchedQuantity) or 0) == 0 then
        row.profit = row.saleProceeds - (tonumber(row.costBasis) or 0)
        row.roi = (tonumber(row.costBasis) or 0) > 0 and row.profit / row.costBasis * 100 or nil
        row.confidence = "FIFO"
    else
        row.confidence = (tonumber(row.costQuantity) or 0) > 0 and "partial cost; profit unknown" or "unknown cost"
    end
end

function Accounting.Summary(rows)
    local result = {spent=0, received=0, deposits=0, pending=0, profit=0, known=0, unknown=0, tradeEarned=0, tradeSpent=0}
    for _, row in ipairs(rows) do
        local timestamp = tonumber(row.timestamp)
        if timestamp then result.since = math.min(result.since or timestamp, timestamp) end
        if row.kind == "purchase" then result.spent = result.spent + (tonumber(row.total) or 0) end
        if row.kind == "posting" then result.deposits = result.deposits + (tonumber(row.deposit) or 0) end
        if row.kind == "vendor" and row.status == "sold" then result.received = result.received + (tonumber(row.total) or 0) end
        if row.kind == "trade" and row.status == "received" then result.tradeEarned = result.tradeEarned + (tonumber(row.total) or 0) end
        if row.kind == "trade" and row.status == "spent" then result.tradeSpent = result.tradeSpent + (tonumber(row.total) or 0) end
        if row.kind == "mail" and row.status == "sold" then
            if row.collected then
                result.received = result.received + (tonumber(row.total) or 0)
                if row.profit == nil then result.unknown = result.unknown + 1 end
            else result.pending = result.pending + (tonumber(row.total) or 0) end
        end
        if row.profit ~= nil then
            result.profit = result.profit + row.profit
            result.known = result.known + 1
        end
    end
    result.cashFlow = result.received + result.tradeEarned - result.spent - result.deposits - result.tradeSpent
    return result
end
