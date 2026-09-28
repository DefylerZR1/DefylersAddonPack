if not DXMCore then return end

-- Create a new DXMCore module.
local Module = DXMCore:Module("Scanner")
local Const = DXMCore:Const()

-- We will fire this off when we have items.
Const.Trigger:Add("ScannerItemsPush")
Const.Trigger:Add("ScannerItemsCompleted")
Const.Trigger:Add("ScannerPurchaseCompleted")

local progressFrame

local THROTTLE_POLL_DELAY = 0.05
local ITEM_INFO_RETRY_DELAY = 0.05
local PREFETCH_COUNT = 250
local PROGRESS_UPDATE_INTERVAL = 250

-- Only one continuation may request the next browse-result page for a scan.
-- AUCTION_HOUSE_BROWSE_RESULTS_ADDED can arrive before an older timer fires;
-- generation-tagging prevents those stale timers from multiplying requests.
local function scheduleMoreResults(self, delay)
	local generation = self.scanGeneration or 0
	if self.moreResultsTimerGeneration == generation then return end
	self.moreResultsTimerGeneration = generation
	C_Timer.After(delay, function()
		if Module.moreResultsTimerGeneration == generation then
			Module.moreResultsTimerGeneration = nil
		end
		if Module.scanGeneration == generation and Module.scanning then
			Module:MoreResults()
		end
	end)
end

local function isScanDisplayMode(displayMode)
    if displayMode == AuctionHouseFrameDisplayMode.Buy then return true end
    return DXMExchange and DXMExchange.IsDisplayMode and DXMExchange:IsDisplayMode(displayMode)
end

local nativeSearchHooked = false
local function hookNativeSearchButton()
	if nativeSearchHooked or not AuctionHouseFrame then return end
	local browse = AuctionHouseFrame.BrowseResultsFrame
	local candidates = {
		browse and browse.SearchButton,
		browse and browse.SearchBar and browse.SearchBar.SearchButton,
		AuctionHouseFrame.SearchButton,
		AuctionHouseFrame.SearchBar and AuctionHouseFrame.SearchBar.SearchButton,
	}
	local expected = SEARCH or "Search"
	local function attach(button)
		if not button or button.DXMScannerSearchHooked or not button.HookScript then return false end
		local label = button.GetText and button:GetText()
		if label and label ~= expected and label ~= "Search" then return false end
		button.DXMScannerSearchHooked = true
		button:HookScript("OnClick", function(_, mouseButton)
			if not mouseButton or mouseButton == "LeftButton" then DXMScanner.RequestScan() end
		end)
		nativeSearchHooked = true
		return true
	end
	for _, button in ipairs(candidates) do
		if attach(button) then return end
	end
	local function visit(frame, depth)
		if not frame or depth > 6 or nativeSearchHooked or not frame.GetChildren then return end
		for _, child in ipairs({frame:GetChildren()}) do
			if child.GetObjectType and child:GetObjectType() == "Button" and child.GetText and child:GetText() == expected then
				if attach(child) then return end
			end
			visit(child, depth + 1)
			if nativeSearchHooked then return end
		end
	end
	visit(browse or AuctionHouseFrame, 0)
end
-- Hook our method
function Module:Boot(hook)
	hook(Const.BrowseResultsAvailable, Module.BrowseResultsAvailable)
	hook(Const.ItemKeyInfoFound, Module.ItemKeyInfoFound)
	hook(Const.AuctionHouseOpened, Module.AuctionHouseOpened)
	hook(Const.AuctionHouseClosed, Module.AuctionHouseClosed)
	hook(Const.DisplayModeChanged, Module.DisplayModeChanged)

	Module:CreateProgress()
end

-- Our job:
--   When the browse page updates, step through all available items.
--   Collect the information for the items.
--   Trigger a statistic update when the results are processed.

DXMScanner = DXMScanner or {}
-- Session-only tombstones: a confirmed auction ID must never be offered again.
local purchasedAuctions, purchaseKeys, quotedKeys = {}, {}, {}
function DXMScanner.IsPurchasedAuction(auctionID)
    return purchasedAuctions[auctionID] == true
end
function DXMScanner.HasPurchasedItem(itemKey)
    return itemKey and purchaseKeys[DXMCore:ItemKeyKey(itemKey)] == true
end
local purchaseHooked=false
local function hookPurchaseIdentity()
    if purchaseHooked or not AuctionHouseFrame or not AuctionHouseFrame.StartItemBuyout then return end
    purchaseHooked=true
    hooksecurefunc(AuctionHouseFrame,"StartItemBuyout",function(_,auctionID)
        local info=C_AuctionHouse.GetAuctionInfoByID(auctionID)
        if info and info.itemKey then quotedKeys[auctionID]=info.itemKey end
    end)
end
local purchaseEvents=CreateFrame("Frame")
purchaseEvents:RegisterEvent("AUCTION_HOUSE_PURCHASE_COMPLETED")
purchaseEvents:SetScript("OnEvent",function(_,_,auctionID)
    if not auctionID or purchasedAuctions[auctionID] then return end
    purchasedAuctions[auctionID]=true
    local info=C_AuctionHouse.GetAuctionInfoByID(auctionID)
    local key=quotedKeys[auctionID] or (info and info.itemKey)
    quotedKeys[auctionID]=nil
    if key then purchaseKeys[DXMCore:ItemKeyKey(key)]=true end
    DXMCore:Trigger(Const.ScannerPurchaseCompleted,key)
end)

function DXMScanner.RequestScan()
	Module.scanRequested = true
	Module.scanRequestedAt = GetTime()
	Module.scanStartedAt = GetTime()
end
function Module:BrowseResultsAvailable(type, results)
	-- We have some browse results here, so lets process them.
	self:Fetch(type, results)
end

function Module:ItemKeyInfoFound(itemID)
	-- The grouped retry owns metadata completion while its short timer is pending.
	if self.awaitingDeferredRetry then return end
	self:Process(itemID)
end

function Module:AuctionHouseOpened()
	print("Welcome to DXM. Click the \"Search\" button to begin a scan.")
	self:Reset()
	C_Timer.After(0, hookNativeSearchButton)
    hookPurchaseIdentity()
end

function Module:AuctionHouseClosed()
	self:Push()
	self:Reset()
end

function Module:DisplayModeChanged(displayMode)
	if self.scanning and not isScanDisplayMode(displayMode) then
		self:Push()
		self:Reset()
	end
end

-- Stop browse pagination and process exactly one snapshot.
function Module:FinishBrowse()
	if not self.scanning or self.processing then return end
	local numResults = #(self.browseResults or {})
	self:InvertedProgress(true)
	self:SetProgress(0, ("Getting results: %d"):format(numResults))
	self.processing = numResults > 0
	self.browsePosition = 1
	self.browseSize = numResults
	self.batchPosition = 0
	self.items = {}
	self.deferredResults = {}
	self.retryingDeferred = false
	self.browseFinishedAt = GetTime()
	if numResults > 0 then
		self:Next()
	else
		self:Push()
	end
end

-- Add the current browse results to our list and keep fetching more until we
-- have all the results loaded.
function Module:Fetch(eventKind, results)
	if not isScanDisplayMode(AuctionHouseFrame:GetDisplayMode()) then
		if self.scanning then
			self:Push()
			self:Reset()
		end
		return
	end

	if eventKind == "updated" and self.scanning and not self.processing then
		-- Forever reports RequestMoreBrowseResults responses as UPDATED rather
		-- than ADDED. Treat them as continuation snapshots so retry/deadline
		-- state is preserved instead of restarting forever at 500 results.
		self.moreResultsRequestSerial = (self.moreResultsRequestSerial or 0) + 1
		self.throttleWaitStartedAt = nil
		local before = #(self.browseResults or {})
		self.browseResults = C_AuctionHouse.GetBrowseResults() or self.browseResults or {}
		local after = #self.browseResults
		if after <= before then
			self.stalledBrowseUpdates = (self.stalledBrowseUpdates or 0) + 1
		else
			self.stalledBrowseUpdates = 0
		end
		self.lastBrowseCount = after
	elseif eventKind == "updated" then
		-- Ignore Blizzard's periodic browse refreshes. Only the DXM scan button
		-- may authorize a new statistics pass.
		local requestedAt = tonumber(self.scanRequestedAt) or 0
		if not self.scanRequested or GetTime() - requestedAt > 10 then
			self.scanRequested = false
			self.scanRequestedAt = nil
			return
		end
		self.scanRequested = false
		self.scanRequestedAt = nil
		self.scanGeneration = (self.scanGeneration or 0) + 1
		self.moreResultsTimerGeneration = nil
		self.scanning = true
		self.processing = false
		self.browseResults = C_AuctionHouse.GetBrowseResults() or {}
		self.browseSize = 12000
		self.stalledBrowseUpdates = 0
		self.lastBrowseCount = #self.browseResults
		self:InvertedProgress(false)
		local generation = self.scanGeneration
		C_Timer.After(30, function()
			if Module.scanGeneration == generation and Module.scanning and not Module.processing then
				Module:FinishBrowse()
			end
		end)
	elseif not self.scanning then
		return
	else
		-- Any browse-result event satisfies the active page request and cancels
		-- its watchdog, even when the server reports no additional rows.
		self.moreResultsRequestSerial = (self.moreResultsRequestSerial or 0) + 1
		self.throttleWaitStartedAt = nil
		local before = #self.browseResults
		if type(results) == "table" then tAppendAll(self.browseResults, results) end
		local after = #self.browseResults
		if after <= before then
			self.stalledBrowseUpdates = (self.stalledBrowseUpdates or 0) + 1
		else
			self.stalledBrowseUpdates = 0
		end
		self.lastBrowseCount = after
	end

	local numResults = #self.browseResults
	if C_AuctionHouse.HasFullBrowseResults() or (self.stalledBrowseUpdates or 0) >= 3 then
		self:FinishBrowse()
		return
	end

	if numResults > self.browseSize - 1000 then
		self.browseSize = self.browseSize + 1000
	end

	self:SetProgress(numResults/self.browseSize * 100,
		("Getting results: %d"):format(numResults))

	-- A browse-result event completes the previous request. Ask for the next
	-- server page immediately; MoreResults still enforces throttle readiness and
	-- permits only one outstanding request through its serial watchdog.
	self:MoreResults()
end

function Module:MoreResults()
	if not isScanDisplayMode(AuctionHouseFrame:GetDisplayMode()) then
		if self.scanning then
			self:Push()
			self:Reset()
		end
		return
	end

	if C_AuctionHouse.IsThrottledMessageSystemReady() then
		self.throttleWaitStartedAt = nil
		local generation = self.scanGeneration or 0
		local before = #(self.browseResults or {})
		self.moreResultsRequestSerial = (self.moreResultsRequestSerial or 0) + 1
		local requestSerial = self.moreResultsRequestSerial
		C_AuctionHouse.RequestMoreBrowseResults()
		C_Timer.After(2.5, function()
			if Module.scanGeneration ~= generation or not Module.scanning or Module.processing then return end
			if Module.moreResultsRequestSerial ~= requestSerial then return end
			if #(Module.browseResults or {}) <= before then
				Module.stalledBrowseUpdates = (Module.stalledBrowseUpdates or 0) + 1
				if Module.stalledBrowseUpdates >= 3 then
					Module:FinishBrowse()
				else
					scheduleMoreResults(Module, 0.1)
				end
			end
		end)
		return
	end

	self.throttleWaitStartedAt = self.throttleWaitStartedAt or GetTime()
	if GetTime() - self.throttleWaitStartedAt >= 5 then
		self:FinishBrowse()
		return
	end
	scheduleMoreResults(self, THROTTLE_POLL_DELAY)
end

-- Static callback function to use in C_Timer.After calls
function Module.MoreResultsCallback()
	Module:MoreResults()
end

-- Processes one item from the browseResults list.
function Module:Next()
	if not self.scanning or not self.processing then
		return
	end

	if self.browsePosition == 1 or self.browsePosition % PROGRESS_UPDATE_INTERVAL == 0 then
		self:SetProgress(self.browsePosition / self.browseSize * 100,
			("Processing results: %d"):format(self.browsePosition))
	end

	-- Prefetch a large block once. The first processing pass stays synchronous.
	if self.batchPosition < self.browsePosition then
		for i=1,PREFETCH_COUNT do
			if self.browsePosition + i < self.browseSize then
				local futureItem = self.browseResults[self.browsePosition + i]
				if futureItem and futureItem.itemKey then
					C_AuctionHouse.GetItemKeyInfo(futureItem.itemKey)
				end
			end
		end
		self.batchPosition = self.batchPosition + PREFETCH_COUNT
	end

	local itemData = self.browseResults[self.browsePosition]
	--[[
	{ Name = "itemKey", Type = "ItemKey", Nilable = false },
	{ Name = "appearanceLink", Type = "string", Nilable = true },
	{ Name = "totalQuantity", Type = "number", Nilable = false },
	{ Name = "minPrice", Type = "number", Nilable = false },
	{ Name = "containsOwnerItem", Type = "bool", Nilable = false },
	]]

	if not itemData then
		-- Retry uncached item metadata once as a group instead of blocking the
		-- entire scan for one second per item.
		if not self.retryingDeferred and #self.deferredResults > 0 then
			self.browseResults = self.deferredResults
			self.deferredResults = {}
			self.retryingDeferred = true
			self.browsePosition = 1
			self.browseSize = #self.browseResults
			self.batchPosition = 0
			self.awaitingDeferredRetry = true
			C_Timer.After(ITEM_INFO_RETRY_DELAY, function()
				Module.awaitingDeferredRetry = false
				if Module.scanning and Module.processing then Module:Next() end
			end)
			return
		end
		self:SetProgress(100, "Finished")
		self:Push()
		return
	end

	self.processing = itemData
	return self:Process() -- tailcall to avoid building up the call stack
end

-- Process the current item for our items.
function Module:Process(itemID)
	if not self.processing then
		return
	end

	local itemKey = self.processing.itemKey
	--[[
	{ Name = "itemID", Type = "number", Nilable = false },
	{ Name = "itemLevel", Type = "number", Nilable = false, Default = 0 },
	{ Name = "itemSuffix", Type = "number", Nilable = false, Default = 0 },
	{ Name = "battlePetSpeciesID", Type = "number", Nilable = false, Default = 0 },
	]]
	if not itemKey then
		self.browsePosition = self.browsePosition + 1
		return self:Next()
	end

	local hasLevel = DXMData.itemHasLevel[itemKey.itemID]
	if itemKey.itemLevel > 0 and hasLevel ~= 1 then
		DXMData.itemHasLevel[itemKey.itemID] = 1
	elseif not hasLevel then
		DXMData.itemHasLevel[itemKey.itemID] = 0
	end

	-- If we got an itemID in the call, check to make sure we process the same item.
	if itemID and itemID ~= itemKey.itemID then
		return
	end

	-- Check to see if the itemInfo is available.
	local itemInfo = C_AuctionHouse.GetItemKeyInfo(itemKey)
	--[[
		{ Name = "itemName", Type = "string", Nilable = false },
		{ Name = "battlePetLink", Type = "string", Nilable = true },
		{ Name = "quality", Type = "number", Nilable = false },
		{ Name = "iconFileID", Type = "number", Nilable = false },
		{ Name = "isPet", Type = "bool", Nilable = false },
		{ Name = "isCommodity", Type = "bool", Nilable = false },
		{ Name = "isEquipment", Type = "bool", Nilable = false },
	]]

	if not itemInfo then
		if not self.retryingDeferred then
			tinsert(self.deferredResults, self.processing)
		end
		self.browsePosition = self.browsePosition + 1
		return self:Next()
	end

	-- Add the items.
	self:Add(itemKey, itemInfo, self.processing)

	-- Process cached rows without frame yields. Server pagination is the dominant
	-- cost and several thousand local rows complete well under a second.
	self.browsePosition = self.browsePosition + 1
	return self:Next()
end

-- Add the given item to the items.
function Module:Add(itemKey, itemInfo, itemData)
	local item = DXMCore:Item{
		id = DXMCore:ItemKeyKey(itemKey),
		itemKey = itemKey,
		itemInfo = itemInfo,
		itemData = itemData,
	}
	--[[
		item = {
			id: string,
			itemKey: { itemID, itemLevel, itemSuffix, battlePetSpeciesID },
			itemInfo: { itemName, battlePetLink, quality, iconFileID, isPet, isCommodity, isEquipment },
			itemData: { itemKey, appearanceLink, totalQuantity, minPrice, containsOwnerItem },
		}
	]]

	tinsert(self.items, item)
end

-- Collate the current items and push to the stats modules.
function Module:Push()
	self.processing = false

	if not self.items then
		return
	end

	self:InvertedProgress(false)
	self:SetProgress(0, "Updating statistics")
	local items = self.items
	self.items = false

	DXMCore:Trigger(Const.ScannerItemsPush, items)
	DXMCore:Trigger(Const.ScannerItemsCompleted, items)
	local finishedAt = GetTime()
	local startedAt = self.scanStartedAt or finishedAt
	local browseFinishedAt = self.browseFinishedAt or finishedAt
	DXMScanner.LastTimings = {
		total = finishedAt - startedAt,
		browse = browseFinishedAt - startedAt,
		localProcessing = finishedAt - browseFinishedAt,
		items = #items,
	}
	print(("DXM scan: %d items in %.2fs (server %.2fs, local %.2fs)"):format(
		#items, DXMScanner.LastTimings.total, DXMScanner.LastTimings.browse,
		DXMScanner.LastTimings.localProcessing))
	self:Reset()
end

-- Reset state.
function Module:Reset()
	self.scanRequested = false
	self.scanRequestedAt = nil
	self.scanGeneration = (self.scanGeneration or 0) + 1
	self.moreResultsTimerGeneration = nil
	self.scanning = false
	self.processing = false
	self.awaitingDeferredRetry = false
	self.items = false
	self:ClearProgress()
end

function Module:CreateProgress()
	progressFrame = CreateFrame("STATUSBAR", "DXMScannerFrame", AuctionHouseFrame)
	progressFrame:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "TOPRIGHT")
	progressFrame:SetWidth(200)
	progressFrame:SetHeight(20)
	progressFrame:SetStatusBarTexture("Interface\\TARGETINGFRAME\\UI-StatusBar")
	progressFrame:GetStatusBarTexture():SetHorizTile(false)
	progressFrame:GetStatusBarTexture():SetVertTile(false)
	progressFrame:SetMinMaxValues(0, 100)
	progressFrame:Hide()

	progressFrame.bg = progressFrame:CreateTexture(nil, "BACKGROUND")
	progressFrame.bg:SetTexture("Interface\\TARGETINGFRAME\\UI-StatusBar")
	progressFrame.bg:SetAllPoints(true)

	progressFrame.value = progressFrame:CreateFontString(nil, "OVERLAY")
	progressFrame.value:SetPoint("LEFT", progressFrame, "LEFT", 4, 0)
	progressFrame.value:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
	progressFrame.value:SetJustifyH("LEFT")
	progressFrame.value:SetTextColor(0.6, 0.6, 0.6)

	progressFrame.Set = Module.SetProgress
	progressFrame.Clear = Module.ClearProgress
	progressFrame.Inverted = Module.InvertedProgress

	self:InvertedProgress(false)
end

function Module:InvertedProgress(invert)
	if invert then
		progressFrame:SetStatusBarColor(0.1, 0.1, 0.1)
		progressFrame.bg:SetVertexColor(0, 0.35, 0.65)
	else
		progressFrame:SetStatusBarColor(0, 0.35, 0.65)
		progressFrame.bg:SetVertexColor(0.1, 0.1, 0.1)
	end
	progressFrame.invert = invert
end

function Module:SetProgress(percent, text)
	progressFrame:Show()
	progressFrame:SetValue(percent)
	progressFrame.value:SetText(text)
end

function Module:ClearProgress()
	progressFrame:Hide()
end
