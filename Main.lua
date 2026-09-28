local private = CreateFrame("Frame")

if not Stubby then
	error("DXMCore requires Stubby")
end

if not LibStub then
	error("DXMCore requires LibStub")
end

local DXM_VERSION = "<%version%>"
if DXM_VERSION:byte(1) == 60 then -- 60 = '<'
	DXM_VERSION = "8.3.DEV"
end

local parts = {}
private.parts = parts

-- Get the original frame object.
function parts:Frame()
	return private
end

local libs = {}
libs.DebugLib = LibStub("DebugLib", true)
libs.Configator = LibStub("Configator", true)
libs.Babylonian = LibStub("Babylonian", true)
libs.TipHelper = LibStub("nTipHelper:1", true)
libs.LibDataBroker = LibStub("LibDataBroker-1.1", true)

local missing = ""
if not libs.Configator then
	missing = missing.." Configator"
end
if not libs.Babylonian then
	missing = missing.." Babylonian"
end
if not libs.TipHelper then
	missing = missing.." TipHelper"
end
if missing ~= "" then
	error("DXMCore is missing:"..missing)
end

if not DXMData then
	DXMData = {}
end

if not DXMLocal then
	DXMLocal = {}
end

if not DXMData.itemHasLevel then
	DXMData.itemHasLevel = {}
end

-- Register an DXMCore module.
function private:Module(name, ...)
	if not name then
		error("DXMCore: Registering module did not supply a name")
	end

	local reg = {}
	reg.name = name
	reg.deps = {...}
	reg.hooks = {}
	reg.bootType = parts.Const.BootType.AuctionHouseLoaded
	reg.Hook = parts.Internal.Hook
	reg.Dump = parts.Internal.Dump
	reg.Coins = libs.TipHelper.Coins

	for k,v in pairs(libs) do
		reg[k] = v
	end

	parts.Internal:Add(reg)
	return reg
end

-- Trigger an DXMCore event to be sent to all modules.
function private:Trigger(event, ...)
	for _, module in ipairs(parts.Internal.modules) do
		if module.hooks[event] then
			local status, err = pcall(module.hooks[event], module, ...)
			if not status then
				print("DXM: Error triggering", module.name, "("..parts.Const:Name(event).."):", err)
			end
		end
	end
end

-- Allow specific internal methods to boot up and get access to private object.
-- This method only functions from Main.lua load until Register.lua finishes.
function private:Boot(name)
	if private.booted or parts[name] then
		return
	end

	local item = {}
	item._ = parts
	item.libs = libs
	parts[name] = item
	return item
end

function private:Const()
	return parts.Const
end

local activeAuctionMarket

local function normalizedToken(value, fallback)
	value = tostring(value or ""):lower():gsub("[^%w%-]+", "-"):gsub("^-+", ""):gsub("-+$", "")
	return value ~= "" and value or fallback
end

local function foreverRuleset(realm)
	local configured = DXMConfig and DXMConfig.marketRuleset
	if configured and configured ~= "" then return normalizedToken(configured, "standard") end
	local lower = tostring(realm or ""):lower()
	if lower:find("rp[%s%-]*pvp") then return "rp-pvp" end
	if lower:find("pvp") then return "pvp" end
	if lower:find("pve") then return "pve" end
	if lower:find("hardcore") or lower:find("self[%s%-]*found") then return "hardcore" end
	if lower:find("roleplay") or lower:find("%f[%a]rp%f[%A]") then return "rp" end
	return "standard"
end

local function playerMarket()
	return normalizedToken(UnitFactionGroup and UnitFactionGroup("player"), "unknown")
end

local function neutralAuctionZone()
	local location = ((GetSubZoneText and GetSubZoneText()) or "") .. " " .. ((GetZoneText and GetZoneText()) or "")
	location = location:lower()
	return location:find("booty bay", 1, true) or location:find("gadgetzan", 1, true)
		or location:find("everlook", 1, true) or location:find("steamwheedle", 1, true)
end

local function detectAuctionMarket()
	local player = playerMarket()
	local npc = UnitFactionGroup and UnitFactionGroup("npc")
	local normalizedNPC = normalizedToken(npc, "")
	if normalizedNPC == "neutral" or (normalizedNPC ~= "" and normalizedNPC ~= player) or neutralAuctionZone() then
		return "neutral"
	end
	return player
end

local marketEvents = CreateFrame("Frame")
marketEvents:RegisterEvent("AUCTION_HOUSE_SHOW")
marketEvents:RegisterEvent("AUCTION_HOUSE_CLOSED")
marketEvents:SetScript("OnEvent", function(_, event)
	activeAuctionMarket = event == "AUCTION_HOUSE_SHOW" and detectAuctionMarket() or nil
end)

function private:MarketIdentity()
	local realm = GetRealmName() or "Unknown Realm"
	local realmID = type(GetRealmID) == "function" and tonumber(GetRealmID()) or 0
	local market = activeAuctionMarket or playerMarket()
	local ruleset = foreverRuleset(realm)
	local key = table.concat({"forever", ruleset, tostring(realmID or 0) .. "-" .. realm, market}, "::")
	return {product = "forever", ruleset = ruleset, realm = realm, realmID = realmID or 0, market = market, key = key}
end

function private:AuctionKey()
	return private:MarketIdentity().key
end

function private:Timeslice(whole)
	local ts = GetServerTime() / 3600
	if whole then ts = floor(ts) end
	return ts
end

-- This is all the outside world is allowed to access.
local major, minor, release, revision = strsplit(".", DXM_VERSION)
private.DXMCore = {
	Version = DXM_VERSION,
	MajorVersion = major,
	MinorVersion = minor,
	RelVersion = release,
	Revision = revision,
}

function private:Booted()
	private.DXMCore.Booted = nil

	private.DXMCore.Trigger = private.Trigger
	private.DXMCore.AuctionKey = private.AuctionKey
	private.DXMCore.MarketIdentity = private.MarketIdentity
	private.DXMCore.Timeslice = private.Timeslice

	private.DXMCore.Stat = parts.Statistics.NewStat
	private.DXMCore.Point = parts.Statistics.NewPoint
	private.DXMCore.Points = parts.Statistics.NewPoints
	private.DXMCore.Statistics = parts.Statistics.Stats

	private.DXMCore.Item = parts.Items.NewItem

	private.DXMCore.GUI = parts.GUI.Components
	private.DXMCore.Money = parts.GUI.Money

	private.DXMCore.Dump = parts.Internal.Dump
	private.DXMCore.DumpOne = parts.Internal.DumpOne
	private.DXMCore.ItemKeyKey = parts.Internal.ItemKeyKey
	private.DXMCore.ItemKeyString = parts.Internal.ItemKeyString
	private.DXMCore.ItemKeyFromLink = parts.Internal.ItemKeyFromLink
	private.DXMCore.ItemKeyFromString = parts.Internal.ItemKeyFromString

	private.booted = true
end

private.DXMCore.Boot = private.Boot
private.DXMCore.Booted = private.Booted
private.DXMCore.Const = private.Const
private.DXMCore.Module = private.Module

-- Expose the global DXMCore object.
DXMCore = {}
setmetatable(DXMCore, {__index = private.DXMCore})
