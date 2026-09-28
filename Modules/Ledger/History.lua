-- Keep durable accounting separate from disposable item caches. Do not create
-- SavedVariables tables until the client has finished restoring them.
local ready = IsLoggedIn and IsLoggedIn() or false
local early = {version = 1, markets = {}}
DXMLedgerHistory = {}

function DXMLedgerHistory:Get()
    if not ready then return early end
    local legacy = DXMData and DXMData.Ledger
    if type(DXMLedgerData) ~= "table" then
        DXMLedgerData = type(legacy) == "table" and legacy or {version = 1, markets = {}}
    end
    DXMLedgerData.markets = DXMLedgerData.markets or {}
    -- Preserve old records for rollback; never replace an existing market with
    -- an older legacy copy on subsequent logins.
    if type(legacy) == "table" and type(legacy.markets) == "table" then
        for key, data in pairs(legacy.markets) do
            if DXMLedgerData.markets[key] == nil then DXMLedgerData.markets[key] = data end
        end
    end
    return DXMLedgerData
end

local events = CreateFrame("Frame")
events:RegisterEvent("VARIABLES_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
    ready = true
    DXMLedgerHistory:Get()
end)
