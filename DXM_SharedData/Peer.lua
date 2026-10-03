if not DXMCore then return end

local PREFIX = "DXMPrice"
local MAX_PAYLOAD = 220
local SEND_DELAY = 1.0
local DEFAULT_CHANNEL = "defyler"
local JOIN_RETRY_DELAY = 3
local JOIN_RETRY_LIMIT = 5
local sendQueue = {}
local sending = false
local frame = CreateFrame("Frame")

if type(DXMSharedConfig) ~= "table" then DXMSharedConfig = {} end
if not DXMSharedConfig.channel or DXMSharedConfig.channel == "" then
    DXMSharedConfig.channel = DEFAULT_CHANNEL
end
if DXMSharedConfig.autoJoin == nil then
    DXMSharedConfig.autoJoin = true
end

local joinAttempts = 0

local function channelID()
    local name = DXMSharedConfig.channel
    if not name or name == "" or type(GetChannelName) ~= "function" then return 0 end
    return tonumber((GetChannelName(name))) or 0
end

local function queueCount()
    return #sendQueue
end

local function ensureChannel()
    if not DXMSharedConfig.autoJoin then return end
    if channelID() > 0 then
        joinAttempts = 0
        return
    end
    local name = DXMSharedConfig.channel or DEFAULT_CHANNEL
    if type(JoinTemporaryChannel) ~= "function" then return end
    joinAttempts = joinAttempts + 1
    JoinTemporaryChannel(name)
    if joinAttempts < JOIN_RETRY_LIMIT then
        C_Timer.After(JOIN_RETRY_DELAY, ensureChannel)
    end
end

local function sendNext()
    if #sendQueue == 0 then sending = false return end
    local id = channelID()
    if id == 0 then sending = false return end
    local result = C_ChatInfo.SendAddonMessage(PREFIX, sendQueue[1], "CHANNEL", tostring(id))
    if result == 0 then
        table.remove(sendQueue, 1)
        C_Timer.After(SEND_DELAY, sendNext)
    elseif result == 3 or result == 8 then
        C_Timer.After(2, sendNext)
    else
        table.remove(sendQueue, 1)
        C_Timer.After(SEND_DELAY, sendNext)
    end
end

local function enqueue(message)
    if #message > MAX_PAYLOAD or #sendQueue >= 250 then return end
    table.insert(sendQueue, message)
    if not sending then sending = true C_Timer.After(SEND_DELAY, sendNext) end
end

local function validID(id)
    return type(id) == "string" and #id <= 80 and id:match("^[%d:%-]+$") ~= nil and id:match("%d") ~= nil
end

local function validMarketKey(key)
    return type(key) == "string" and #key >= 8 and #key <= 180 and not key:find("[%c|]")
end

local function addPeerPoint(marketKey, capturedAt, id, price, quantity)
    local now = GetServerTime()
    capturedAt = tonumber(capturedAt)
    price = tonumber(price)
    quantity = tonumber(quantity)
    if not validMarketKey(marketKey) then return end
    if not capturedAt or capturedAt < now - 7 * 86400 or capturedAt > now + 300 then return end
    if not validID(id) or not price or price < 1 or price > 9999999999999 then return end
    if not quantity or quantity < 0 or quantity > 2147483647 then return end

    if type(DXMSharedImport) ~= "table" then DXMSharedImport = {schema = 2, markets = {}} end
    DXMSharedImport.schema = 2
    if type(DXMSharedImport.markets) ~= "table" then DXMSharedImport.markets = {} end
    local market = DXMSharedImport.markets[marketKey]
    if type(market) ~= "table" then market = {}; DXMSharedImport.markets[marketKey] = market end
    local rows = market[id]
    if type(rows) ~= "table" then
        rows = {}
        market[id] = rows
        if DXMPriceSummary and DXMPriceSummary.Invalidate then DXMPriceSummary.Invalidate(true) end
    end

    local hour = floor(capturedAt / 3600)
    for _, row in ipairs(rows) do
        if floor((tonumber(row.capturedAt) or 0) / 3600) == hour and row.peer then
            row.price = price
            row.quantity = quantity
            row.capturedAt = capturedAt
            return
        end
    end
    table.insert(rows, {price = price, quantity = quantity, capturedAt = capturedAt, contributors = 1, peer = true})
    while #rows > 168 do table.remove(rows, 1) end
end

local function receive(message)
    local kind, capturedAt, marketKey, body = strsplit("|", message, 4)
    if kind ~= "D2" or not capturedAt or not marketKey or not body then return end
    for encoded in body:gmatch("[^;]+") do
        local id, price, quantity = strsplit(",", encoded)
        addPeerPoint(marketKey, capturedAt, id, price, quantity)
    end
end

local Module = DXMCore:Module("SharedMarket:Peer", "Scanner")
local Const = DXMCore.Const()
function Module:Boot(hook)
    hook(Const.ScannerItemsCompleted, Module.ScannerItemsCompleted)
end

function Module:ScannerItemsCompleted(items)
    if channelID() == 0 then return end
    local capturedAt = GetServerTime()
    local prefix = "D2|" .. capturedAt .. "|" .. DXMCore:AuctionKey() .. "|"
    local payload = prefix
    for _, item in ipairs(items or {}) do
        local data = item.itemData
        local id = item.id or (item.itemKey and DXMCore:ItemKeyKey(item.itemKey))
        if validID(id) and data and data.minPrice and data.totalQuantity then
            local encoded = id .. "," .. floor(data.minPrice) .. "," .. floor(data.totalQuantity)
            if #payload + #encoded + 1 > MAX_PAYLOAD then
                enqueue(payload)
                payload = prefix
            end
            payload = payload .. encoded .. ";"
        end
    end
    if payload ~= prefix then enqueue(payload) end
end

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:SetScript("OnEvent", function(_, event, prefix, message, channel, sender, _, _, localID)
    if event == "PLAYER_LOGIN" then
        local result = C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        if result ~= 0 then print("DXM: could not register peer prefix (" .. tostring(result) .. ")") end
        C_Timer.After(1, ensureChannel)
        print("DXM Network loaded. Market partitions enabled.")
    elseif prefix == PREFIX and channel == "CHANNEL" and tonumber(localID) == channelID() and sender then
        local shortSender = type(Ambiguate) == "function" and Ambiguate(sender, "short") or sender
        if shortSender ~= UnitName("player") then receive(message) end
    end
end)

SLASH_DXMCHANNEL1 = "/dxmchannel"
SlashCmdList.DXMCHANNEL = function(input)
    local command, rest = (input or ""):match("^(%S*)%s*(.-)$")
    if command == "use" and rest ~= "" then
        DXMSharedConfig.channel = rest
        DXMSharedConfig.autoJoin = true
        joinAttempts = 0
        ensureChannel()
        print("DXM: connecting automatically to " .. rest .. ".")
    elseif command == "join" and rest ~= "" then
        local name, password = rest:match("^(%S+)%s*(%S*)$")
        DXMSharedConfig.channel = name
        DXMSharedConfig.autoJoin = true
        if type(JoinTemporaryChannel) == "function" then
            JoinTemporaryChannel(name, password ~= "" and password or nil)
            print("DXM: requested private channel " .. name .. ". Password was not saved.")
        else
            print("DXM: use /join " .. name .. " [password], then /dxmchannel use " .. name)
        end
    elseif command == "on" then
        DXMSharedConfig.channel = DXMSharedConfig.channel or DEFAULT_CHANNEL
        DXMSharedConfig.autoJoin = true
        joinAttempts = 0
        ensureChannel()
        print("DXM: automatic network connection enabled.")
    elseif command == "off" then
        DXMSharedConfig.autoJoin = false
        wipe(sendQueue)
        sending = false
        print("DXM: peer channel disabled.")
    else
        local name = DXMSharedConfig.channel or DEFAULT_CHANNEL
        local mode = DXMSharedConfig.autoJoin and "automatic" or "off"
        print(("DXM: channel=%s, channelID=%d, mode=%s, queued messages=%d"):format(name, channelID(), mode, queueCount()))
        print("Commands: /dxmchannel on, /dxmchannel off")
    end
end

