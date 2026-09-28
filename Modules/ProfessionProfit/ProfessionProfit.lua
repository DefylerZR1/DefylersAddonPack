if not DXMCore then return end

local Module = DXMCore:Module("ProfessionProfit")
local Const = DXMCore.Const()
Module.bootType = Const.BootType.PlayerEnteringWorld

DXMVendorPrices = DXMVendorPrices or {}
DXMConfig = DXMConfig or {}
DXMLocal = DXMLocal or {}
DXMLocal.DXMRecipeCache = DXMLocal.DXMRecipeCache or {}
if not DXMConfig.craftPlanPreference then DXMConfig.craftPlanPreference = "balanced" end

local PREFERENCES = {"cost", "balanced", "speed"}
local PREFERENCE_LABELS = {cost = "Lowest Cost", balanced = "Balanced", speed = "Fastest"}
local TIME_VALUE = {cost = 0, balanced = 10, speed = 100} -- copper per crafting second
local recipeCache = DXMLocal.DXMRecipeCache
local recipeIndex = {}

local PAGE_SIZE = 12
local panel, tab, titleText, statusText, countText
local previousButton, nextButton
local rows, headers = {}, {}
local results = {}
local pageOffset = 0
local sortKey, sortAscending = "profit", false
local analysisGeneration = 0
local analysisRunning = false
local priceCache = {}
local currentPriceCache = {}
local historyKeyIndex = {}
local historyIndexReady = false

local function rebuildHistoryKeyIndex()
    wipe(historyKeyIndex)
    local realm = DXMPriceHistoryData and DXMPriceHistoryData[DXMCore:AuctionKey()]
    for key in pairs(realm or {}) do
        local itemID = tonumber(tostring(key):match("^(%d+)"))
        if itemID then
            local keys = historyKeyIndex[itemID]
            if not keys then keys = {}; historyKeyIndex[itemID] = keys end
            keys[#keys + 1] = key
        end
    end
    historyIndexReady = true
end

local function money(value)
    if value == nil then return "--" end
    value = math.floor(tonumber(value) or 0)
    local sign = value < 0 and "-" or ""
    value = math.abs(value)
    local gold = math.floor(value / 10000)
    local silver = math.floor((value % 10000) / 100)
    local copper = value % 100
    local parts = {}
    if gold > 0 then parts[#parts + 1] = gold .. "g" end
    if silver > 0 then parts[#parts + 1] = silver .. "s" end
    if copper > 0 or #parts == 0 then parts[#parts + 1] = copper .. "c" end
    return sign .. table.concat(parts, " ")
end

local function marketValue(itemID)
    itemID = tonumber(itemID)
    if not itemID then return end
    local cached = priceCache[itemID]
    if cached then return cached.value or nil, cached.samples or 0 end

    if not historyIndexReady then rebuildHistoryKeyIndex() end
    local base = tostring(itemID)
    local itemLevel = select(4, C_Item.GetItemInfo(itemID))
    itemLevel = tonumber(itemLevel) or 0
    local keys = itemLevel > 0 and {base .. ":" .. itemLevel, base} or {base}
    for _, key in ipairs(historyKeyIndex[itemID] or {}) do keys[#keys + 1] = key end
    local values, samples = {}, 0
    local checked = {}
    for _, key in ipairs(keys) do
        if not checked[key] then
            checked[key] = true
            for _, stat in ipairs(DXMCore:Statistics(key)) do
                local count = tonumber(stat:Number()) or 0
                samples = math.max(samples, count)
                if count > 0 then
                    local ok, value = pcall(stat.Percentile, stat, 15, {weighted = true})
                    if not ok or not value then ok, value = pcall(stat.Minimum, stat) end
                    value = ok and tonumber(value) or nil
                    if value and value > 0 then values[#values + 1] = value end
                end
            end
        end
    end
    table.sort(values)
    local value = #values > 0 and values[math.ceil(#values / 2)] or nil
    priceCache[itemID] = {value = value or false, samples = samples}
    return value, samples
end

local function currentMarketValue(itemID)
    itemID = tonumber(itemID)
    if not itemID then return end
    local cached = currentPriceCache[itemID]
    if cached then return cached.value or nil, cached.capturedAt end
    if not historyIndexReady then rebuildHistoryKeyIndex() end

    local auctionKey = DXMCore:AuctionKey()
    local history = DXMPriceHistoryData and DXMPriceHistoryData[auctionKey]
    local meta = DXMPriceHistoryMeta and DXMPriceHistoryMeta[auctionKey]
    local lastScanAt = meta and tonumber(meta.lastScanAt)
    local newestAt, newestPrice
    for _, key in ipairs(historyKeyIndex[itemID] or {}) do
        local entries = history and history[key]
        if type(entries) == "table" then
            for index = #entries, 1, -1 do
                local entry = entries[index]
                local capturedAt = type(entry) == "table" and tonumber(entry[1])
                local price = type(entry) == "table" and tonumber(entry[2])
                if capturedAt and price and price > 0 then
                    if not newestAt or capturedAt > newestAt then
                        newestAt, newestPrice = capturedAt, price
                    elseif capturedAt == newestAt and price < newestPrice then
                        newestPrice = price
                    end
                    break
                end
            end
        end
    end

    -- Relay snapshots are loaded from a read-only addon file because WoW can
    -- overwrite SavedVariables on logout. Use the freshest shared observation
    -- as a fallback (or when it is newer than the last local scan).
    local imported = DXMSharedImport
    local snapshotAt = type(DXMSharedSnapshot) == "table" and tonumber(DXMSharedSnapshot.updatedAt) or 0
    local importedAt = type(imported) == "table" and tonumber(imported.updatedAt) or 0
    if type(DXMSharedSnapshot) == "table" and type(DXMSharedSnapshot.markets) == "table" and snapshotAt >= importedAt then
        imported = DXMSharedSnapshot
    end
    local sharedMarket = type(imported) == "table" and type(imported.markets) == "table" and imported.markets[auctionKey]
    local itemPrefix = tostring(itemID)
    for key, entries in pairs(sharedMarket or {}) do
        key = tostring(key)
        if key == itemPrefix or key:match("^" .. itemPrefix .. ":") then
            for _, entry in ipairs(entries) do
                local capturedAt = type(entry) == "table" and tonumber(entry.capturedAt)
                local price = type(entry) == "table" and tonumber(entry.price)
                if capturedAt and price and price > 0 then
                    if not newestAt or capturedAt > newestAt or (capturedAt == newestAt and price < newestPrice) then
                        newestAt, newestPrice = capturedAt, price
                    end
                end
            end
        end
    end

    currentPriceCache[itemID] = {value = newestPrice or false, capturedAt = newestAt}
    return newestPrice, newestAt
end

local function scanAge(capturedAt)
    capturedAt = tonumber(capturedAt)
    if not capturedAt then return "unknown age" end
    local age = math.max(0, GetServerTime() - capturedAt)
    if age < 60 then return "just now" end
    if age < 3600 then return ("%dm ago"):format(math.floor(age / 60)) end
    if age < 86400 then return ("%dh ago"):format(math.floor(age / 3600)) end
    return ("%dd ago"):format(math.floor(age / 86400))
end

local function reagentPrice(itemID)
    local market, capturedAt = currentMarketValue(itemID)
    local vendor = tonumber(DXMVendorPrices[tostring(itemID)])
    if vendor and vendor > 0 and (not market or vendor < market) then return vendor, "vendor" end
    if market and market > 0 then return market, "AH", scanAge(capturedAt) end
    if vendor and vendor > 0 then return vendor, "vendor" end
end

local function scanMerchant()
    if not GetMerchantNumItems then return end
    if not GetMerchantItemInfo and not (C_MerchantFrame and C_MerchantFrame.GetItemInfo) then return end
    local changed = false
    for index = 1, GetMerchantNumItems() or 0 do
        local price, quantity, extendedCost, itemID
        if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
            local first, _, third, fourth, _, _, _, eighth = C_MerchantFrame.GetItemInfo(index)
            if type(first) == "table" then
                price, quantity, extendedCost, itemID = first.price, first.stackCount, first.hasExtendedCost, first.itemID
            else
                -- Some Forever builds expose the legacy tuple through C_MerchantFrame.
                price, quantity, extendedCost = third, fourth, eighth
            end
        else
            local _, _, legacyPrice, legacyQuantity, _, _, _, legacyExtendedCost = GetMerchantItemInfo(index)
            price, quantity, extendedCost = legacyPrice, legacyQuantity, legacyExtendedCost
        end
        if not itemID and GetMerchantItemID then itemID = GetMerchantItemID(index) end
        local link = (C_MerchantFrame and C_MerchantFrame.GetItemLink and C_MerchantFrame.GetItemLink(index))
            or (GetMerchantItemLink and GetMerchantItemLink(index))
        if not itemID and link then itemID = C_Item.GetItemInfoInstant(link) end
        price, quantity = tonumber(price), math.max(1, tonumber(quantity) or 1)
        if itemID and price and price > 0 and not extendedCost then
            local unit = math.floor(price / quantity + 0.5)
            local key = tostring(itemID)
            if not DXMVendorPrices[key] or unit < DXMVendorPrices[key] then
                DXMVendorPrices[key] = unit
                changed = true
            end
            if DXMQueueVendorObservation then DXMQueueVendorObservation(itemID, unit) end
        end
    end
    if changed then
        wipe(priceCache)
        wipe(currentPriceCache)
    end
end

local function scheduleMerchantScan()
    -- Merchant links can be unavailable during the first MERCHANT_SHOW callback.
    scanMerchant()
    if C_Timer and C_Timer.After then
        C_Timer.After(0, scanMerchant)
        C_Timer.After(0.20, scanMerchant)
        C_Timer.After(0.75, scanMerchant)
    end
end

local function recipeCastSeconds(recipeID)
    local spell
    if C_Spell and C_Spell.GetSpellInfo then spell = C_Spell.GetSpellInfo(recipeID) end
    local milliseconds = spell and tonumber(spell.castTime)
    if not milliseconds and GetSpellInfo then
        local _, _, _, legacyCast = GetSpellInfo(recipeID)
        milliseconds = tonumber(legacyCast)
    end
    return math.max(0, (milliseconds or 3000) / 1000)
end

local function rememberRecipes(recipeIDs)
    for _, recipeID in ipairs(recipeIDs or {}) do
        local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
        local schematic = info and info.learned and not info.isDummyRecipe and C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
        if schematic and schematic.outputItemID then
            local reagents = {}
            local complete = true
            for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
                if slot.required ~= false then
                    local reagent = slot.reagents and slot.reagents[1]
                    local itemID = reagent and (reagent.itemID or (reagent.item and reagent.item.itemID))
                    local quantity = tonumber(slot.quantityRequired) or 0
                    if itemID and quantity > 0 then
                        reagents[#reagents + 1] = {itemID = itemID, quantity = quantity}
                    elseif quantity > 0 then
                        complete = false
                    end
                end
            end
            if complete then
                local minimum = tonumber(schematic.quantityMin) or 1
                local maximum = tonumber(schematic.quantityMax) or minimum
                recipeCache[tostring(recipeID)] = {
                    recipeID = recipeID,
                    name = info.name or ("Recipe " .. recipeID),
                    outputItemID = schematic.outputItemID,
                    outputQuantity = math.max(1, (minimum + maximum) / 2),
                    castSeconds = recipeCastSeconds(recipeID),
                    reagents = reagents,
                }
            end
        end
    end
end

local function rebuildRecipeIndex()
    wipe(recipeIndex)
    for _, recipe in pairs(recipeCache) do
        if type(recipe) == "table" and recipe.outputItemID and type(recipe.reagents) == "table" then
            local key = tonumber(recipe.outputItemID)
            recipeIndex[key] = recipeIndex[key] or {}
            recipeIndex[key][#recipeIndex[key] + 1] = recipe
        end
    end
    for _, list in pairs(recipeIndex) do
        table.sort(list, function(a, b) return (tonumber(a.recipeID) or 0) < (tonumber(b.recipeID) or 0) end)
    end
end

local function sharedVendorPrice(itemID)
    local identity = DXMCore:MarketIdentity()
    local marketKey = identity and identity.key
    local best
    for _, source in ipairs({DXMSharedSnapshot, DXMSharedImport}) do
        local point = type(source) == "table" and type(source.vendors) == "table" and source.vendors[marketKey] and source.vendors[marketKey][tostring(itemID)]
        local price = type(point) == "table" and tonumber(point.price) or tonumber(point)
        if price and price > 0 and (not best or price < best) then best = price end
    end
    return best
end

local function directCandidates(itemID, quantity)
    local candidates = {}
    local market, capturedAt = currentMarketValue(itemID)
    local vendor = tonumber(DXMVendorPrices[tostring(itemID)]) or sharedVendorPrice(itemID)
    if vendor and vendor > 0 then
        candidates[#candidates + 1] = {cost = vendor * quantity, cashCost = vendor * quantity, time = 0, source = "vendor", unit = vendor}
    end
    if market and market > 0 then
        candidates[#candidates + 1] = {cost = market * quantity, cashCost = market * quantity, time = 0, source = "AH", unit = market, age = scanAge(capturedAt)}
    end
    return candidates
end

local function candidateScore(candidate)
    local rate = TIME_VALUE[DXMConfig.craftPlanPreference] or TIME_VALUE.balanced
    return candidate.cashCost + candidate.time * rate
end

local function planItem(itemID, quantity, visiting, depth)
    itemID, quantity = tonumber(itemID), tonumber(quantity) or 0
    if not itemID or quantity <= 0 then return end
    depth = depth or 0
    if depth > 12 or visiting[itemID] then return end
    visiting[itemID] = true

    local name = C_Item.GetItemNameByID(itemID) or ("Item " .. itemID)
    local candidates = directCandidates(itemID, quantity)
    for _, recipe in ipairs(recipeIndex[itemID] or {}) do
        local crafts = math.ceil(quantity / math.max(1, tonumber(recipe.outputQuantity) or 1))
        local candidate = {cashCost = 0, time = crafts * (tonumber(recipe.castSeconds) or 3), source = "craft", recipe = recipe, children = {}, unit = nil}
        local complete = true
        for _, reagent in ipairs(recipe.reagents) do
            local child = planItem(reagent.itemID, reagent.quantity * crafts, visiting, depth + 1)
            if not child then complete = false; break end
            candidate.cashCost = candidate.cashCost + child.cashCost
            candidate.time = candidate.time + child.time
            candidate.children[#candidate.children + 1] = child
        end
        if complete then candidates[#candidates + 1] = candidate end
    end
    visiting[itemID] = nil
    if #candidates == 0 then return end

    table.sort(candidates, function(a, b)
        local as, bs = candidateScore(a), candidateScore(b)
        if as == bs then
            if a.time == b.time then return (a.source or "") < (b.source or "") end
            return a.time < b.time
        end
        return as < bs
    end)
    local chosen = candidates[1]
    chosen.itemID, chosen.name, chosen.quantity = itemID, name, quantity
    chosen.cost = candidateScore(chosen)
    chosen.alternatives = {}
    for _, candidate in ipairs(candidates) do
        local label = candidate.source == "craft" and ("craft " .. (candidate.recipe.name or "recipe")) or candidate.source
        chosen.alternatives[#chosen.alternatives + 1] = {label = label, cashCost = candidate.cashCost, time = candidate.time, score = candidateScore(candidate)}
    end
    return chosen
end

local function planLines(node, level, lines)
    level, lines = level or 0, lines or {}
    local indent = string.rep("  ", level)
    local route = node.source == "craft" and ("craft " .. (node.recipe and node.recipe.name or "recipe")) or node.source
    lines[#lines + 1] = ("%s%d x %s: %s via %s; %s"):format(indent, node.quantity, node.name, money(node.cashCost), route, node.time > 0 and (("%.1fs"):format(node.time)) or "instant")
    if #node.alternatives > 1 then
        local choices = {}
        for _, alt in ipairs(node.alternatives) do choices[#choices + 1] = ("%s %s/%0.1fs"):format(alt.label, money(alt.cashCost), alt.time) end
        lines[#lines + 1] = indent .. "  Compared: " .. table.concat(choices, "; ")
    end
    for _, child in ipairs(node.children or {}) do planLines(child, level + 1, lines) end
    return lines
end

DXMProfessionPlanner = DXMProfessionPlanner or {}
function DXMProfessionPlanner:RebuildRecipeIndex() rebuildRecipeIndex() end
function DXMProfessionPlanner:PlanItem(itemID, quantity) return planItem(itemID, quantity, {}, 0) end
function DXMProfessionPlanner:PreferenceLabel() return PREFERENCE_LABELS[DXMConfig.craftPlanPreference] or "Balanced" end
local function currentCraftable(recipeID)
    if not C_TradeSkillUI or not C_TradeSkillUI.GetCraftableCount then return 0 end
    local ok, count = pcall(C_TradeSkillUI.GetCraftableCount, recipeID)
    return ok and math.max(0, math.floor(tonumber(count) or 0)) or 0
end

local function recipeResult(recipeID)
    local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
    if not info or not info.learned or info.isDummyRecipe then return end
    local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
    if not schematic then return end

    local outputItemID = schematic.outputItemID
    local outputName, outputLink, outputQuality, _, _, _, _, _, _, outputIcon, vendorSell
    if outputItemID then
        outputName, outputLink, outputQuality, _, _, _, _, _, _, outputIcon, vendorSell = C_Item.GetItemInfo(outputItemID)
        if not outputName and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(outputItemID) end
    end

    local craftCost, complete = 0, true
    local detail, missing, reagents = {}, {}, {}
    for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
        if slot.required ~= false then
            local reagent = slot.reagents and slot.reagents[1]
            local itemID = reagent and (reagent.itemID or (reagent.item and reagent.item.itemID))
            local quantity = tonumber(slot.quantityRequired) or 0
            if itemID and quantity > 0 then
                local name = C_Item.GetItemNameByID(itemID) or ("Item " .. itemID)
                local plan = planItem(itemID, quantity, {}, 0)
                local source = plan and plan.source
                reagents[#reagents + 1] = {itemID = itemID, name = name, quantity = quantity, source = source or "AH", plan = plan}
                if plan then
                    craftCost = craftCost + plan.cashCost
                    for _, line in ipairs(planLines(plan)) do detail[#detail + 1] = line end
                else
                    complete = false
                    missing[#missing + 1] = name
                    detail[#detail + 1] = ("%d x %s @ no price"):format(quantity, name)
                    if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
                end
            elseif quantity > 0 then
                complete = false
                missing[#missing + 1] = "selectable reagent"
            end
        end
    end

    local ownCraftTime = recipeCastSeconds(recipeID)
    local reagentCraftTime = 0
    for _, reagent in ipairs(reagents) do
        if reagent.plan then reagentCraftTime = reagentCraftTime + (reagent.plan.time or 0) end
    end
    local craftingTime = ownCraftTime + reagentCraftTime
    local effectiveCost = complete and (craftCost + craftingTime * (TIME_VALUE[DXMConfig.craftPlanPreference] or TIME_VALUE.balanced)) or nil

    local outputUnit, outputSamples
    if outputItemID then outputUnit, outputSamples = marketValue(outputItemID) end
    local outputSource = "AH"
    if not outputUnit and tonumber(vendorSell) and vendorSell > 0 then outputUnit, outputSource = vendorSell, "vendor sell" end
    local minimum = tonumber(schematic.quantityMin) or 1
    local maximum = tonumber(schematic.quantityMax) or minimum
    local outputQuantity = math.max(1, (minimum + maximum) / 2)
    local gross = outputUnit and math.floor(outputUnit * outputQuantity + 0.5) or nil
    local net = gross and math.floor(gross * 0.95 + 0.5) or nil
    local profit = effectiveCost and net and (net - effectiveCost) or nil
    local roi = profit and effectiveCost > 0 and (profit / effectiveCost * 100) or nil

    return {
        recipeID = recipeID,
        name = info.name or outputName or ("Recipe " .. recipeID),
        outputItemID = outputItemID,
        link = outputLink,
        icon = outputIcon or info.icon or 134400,
        quality = outputQuality or 1,
        cost = complete and craftCost or nil,
        effectiveCost = effectiveCost,
        time = craftingTime,
        canCraft = currentCraftable(recipeID),
        value = gross,
        net = net,
        profit = profit,
        roi = roi,
        outputQuantity = outputQuantity,
        outputSource = outputSource,
        outputSamples = outputSamples or 0,
        details = detail,
        missing = missing,
        reagents = reagents,
    }
end

local function compare(a, b)
    if a == b then return false end
    if a == nil then return false end
    if b == nil then return true end
    if sortKey == "name" then
        local av, bv = (a.name or ""):lower(), (b.name or ""):lower()
        if av == bv then return (tonumber(a.recipeID) or 0) < (tonumber(b.recipeID) or 0) end
        if sortAscending then return av < bv end
        return av > bv
    end
    local av, bv = a[sortKey], b[sortKey]
    if av == nil and bv == nil then return (a.name or "") < (b.name or "") end
    if av == nil then return false end
    if bv == nil then return true end
    if av == bv then local an, bn = (a.name or ""):lower(), (b.name or ""):lower(); if an == bn then return (tonumber(a.recipeID) or 0) < (tonumber(b.recipeID) or 0) end; return an < bn end
    if sortAscending then return av < bv end
    return av > bv
end

local function updateHeaders()
    for key, entry in pairs(headers) do
        entry.Label:SetText(entry.label .. (key == sortKey and (sortAscending and " ^" or " v") or ""))
    end
end

local function showRowTooltip(row)
    local result = row.result
    if not result then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if result.link then GameTooltip:SetHyperlink(result.link) else GameTooltip:SetText(result.name) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Material cost", money(result.cost), 1, .82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Total crafting time", result.time and ("%.1f seconds"):format(result.time) or "--", 1, .82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Time-adjusted cost", money(result.effectiveCost), 1, .82, 0, 1, 1, 1)
    GameTooltip:AddLine(("Planning preference: %s (%dc per crafting second)"):format(PREFERENCE_LABELS[DXMConfig.craftPlanPreference] or "Balanced", TIME_VALUE[DXMConfig.craftPlanPreference] or TIME_VALUE.balanced), .72, .72, .72, true)
    GameTooltip:AddDoubleLine("Expected output", money(result.value), 1, .82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Net after 5% AH cut", money(result.net), 1, .82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Profit / Loss", money(result.profit), 1, .82, 0, result.profit and result.profit >= 0 and .2 or 1, result.profit and result.profit >= 0 and 1 or .2, .2)
    GameTooltip:AddLine(("Output price source: %s; history samples: %d"):format(result.outputSource, result.outputSamples), .72, .72, .72, true)
    if #result.details > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Reagents", 1, .82, 0)
        for _, line in ipairs(result.details) do GameTooltip:AddLine(line, .85, .85, .85, true) end
    end
    if #result.missing > 0 then GameTooltip:AddLine("Missing prices: " .. table.concat(result.missing, ", "), 1, .3, .3, true) end
    GameTooltip:AddLine("Right-click: choose quantity and add to crafting queue", .35, .8, 1)
    GameTooltip:Show()
end

StaticPopupDialogs["DXM_CRAFT_QUEUE_QUANTITY"] = {
    text = "How many %s should DXM queue?",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    editBoxWidth = 90,
    maxLetters = 5,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
    OnShow = function(self)
        self:GetEditBox():SetText("1")
        self:GetEditBox():HighlightText()
        self:GetEditBox():SetFocus()
    end,
    OnAccept = function(self, result)
        local crafts = math.max(1, math.min(9999, math.floor(tonumber(self:GetEditBox():GetText()) or 1)))
        local added = DXMShopping and DXMShopping.AddRecipe and DXMShopping:AddRecipe(result, crafts) or 0
        if added > 0 and statusText then
            statusText:SetText(("Queued %d x %s (%d reagent units)."):format(crafts, result.name, added))
        end
    end,
    EditBoxOnEnterPressed = function(editBox)
        editBox:GetParent():GetButton1():Click()
    end,
}

local function addRowToBuyList(row)
    local result = row and row.result
    if not result or not DXMShopping or not DXMShopping.AddRecipe then return end
    GameTooltip:Hide()
    StaticPopup_Show("DXM_CRAFT_QUEUE_QUANTITY", result.name, nil, result)
end
local function updateRows()
    local compact = {}
    for _, result in pairs(results) do
        if type(result) == "table" then compact[#compact + 1] = result end
    end
    results = compact
    table.sort(results, compare)
    updateHeaders()
    local total = #results
    local maxOffset = math.max(0, total - PAGE_SIZE)
    pageOffset = math.max(0, math.min(pageOffset, maxOffset))
    for index, row in ipairs(rows) do
        local result = results[pageOffset + index]
        row.result = result
        if result then
            row.Icon:SetTexture(result.icon)
            row.Name:SetText(result.name)
            local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[result.quality]
            if color then row.Name:SetTextColor(color.r, color.g, color.b) else row.Name:SetTextColor(1, 1, 1) end
            row.Cost:SetText(money(result.cost))
            row.Time:SetText(result.time and ("%.1fs"):format(result.time) or "--")
            result.canCraft = currentCraftable(result.recipeID)
            row.CanCraft:SetText(result.canCraft)
            row.Value:SetText(money(result.value))
            row.Profit:SetText(money(result.profit))
            row.ROI:SetText(result.roi and ("%.0f%%"):format(result.roi) or "--")
            if result.profit and result.profit >= 0 then row.Profit:SetTextColor(.2, 1, .2) elseif result.profit then row.Profit:SetTextColor(1, .25, .25) else row.Profit:SetTextColor(.65, .65, .65) end
            row:Show()
        else row:Hide() end
    end
    if countText then
        countText:SetText(total == 0 and "No learned item recipes found." or ("Showing %d-%d of %d recipes"):format(pageOffset + 1, math.min(pageOffset + PAGE_SIZE, total), total))
    end
    if previousButton then previousButton:SetEnabled(pageOffset > 0) end
    if nextButton then nextButton:SetEnabled(pageOffset < maxOffset) end
end

local function analyze()
    if analysisRunning or not panel or not panel:IsShown() or not C_TradeSkillUI or not C_TradeSkillUI.GetAllRecipeIDs then return end
    analysisRunning = true
    analysisGeneration = analysisGeneration + 1
    local generation = analysisGeneration
    wipe(results); wipe(priceCache); wipe(currentPriceCache); historyIndexReady = false; pageOffset = 0
    local profession = C_TradeSkillUI.GetBaseProfessionInfo and C_TradeSkillUI.GetBaseProfessionInfo()
    titleText:SetText("DXM Craft Profit - " .. (profession and profession.professionName or "Profession"))
    local ids = C_TradeSkillUI.GetAllRecipeIDs() or {}
    rememberRecipes(ids)
    rebuildRecipeIndex()
    local position, batchSize = 1, 20
    statusText:SetText(("Analyzing %d recipes..."):format(#ids))
    local function step()
        if generation ~= analysisGeneration or not panel:IsShown() then analysisRunning = false; return end
        local last = math.min(#ids, position + batchSize - 1)
        while position <= last do
            local result = recipeResult(ids[position])
            if result then results[#results + 1] = result end
            position = position + 1
        end
        statusText:SetText(("Analyzing recipes: %d / %d"):format(math.min(position - 1, #ids), #ids))
        if position <= #ids then C_Timer.After(0, step) else
            statusText:SetText(("%s planning compares AH, vendor, and recursive crafting. Profit includes time at %dc/sec and a 5%% AH cut."):format(PREFERENCE_LABELS[DXMConfig.craftPlanPreference] or "Balanced", TIME_VALUE[DXMConfig.craftPlanPreference] or TIME_VALUE.balanced))
            analysisRunning = false
            updateRows()
        end
    end
    step()
end

local function raisePanel()
    if not panel then return end
    local parent = panel:GetParent()
    if not parent then return end
    local strata = parent:GetFrameStrata() or "MEDIUM"
    local pageLevel = parent:GetFrameLevel() + 1
    panel:SetFrameStrata(strata)
    panel:SetFrameLevel(pageLevel)

    local chromeLevel = pageLevel + 20
    for _, key in ipairs({"NineSlice", "TitleContainer", "PortraitContainer", "CloseButton"}) do
        local region = parent[key]
        if region and region.SetFrameStrata then region:SetFrameStrata(strata) end
        if region and region.SetFrameLevel then region:SetFrameLevel(chromeLevel) end
    end
    if parent.ProfessionsOverviewTab then parent.ProfessionsOverviewTab:SetFrameLevel(chromeLevel + 1) end
    for _, nativeTab in ipairs(parent.rightProfessionTabs or {}) do nativeTab:SetFrameLevel(chromeLevel + 1) end
end
local function hideProfessionPages(frame)
    for _, page in ipairs(frame.Pages or {}) do page:Hide() end
    if frame.BookPage then frame.BookPage:Hide() end
    if frame.CraftingPage then frame.CraftingPage:Hide() end
end
local function restoreProfessionOverview(frame)
    if frame.SelectBookPage then
        frame:SelectBookPage()
    else
        if frame.BookPage then frame.BookPage:Show() end
        if frame.CraftingPage then frame.CraftingPage:Hide() end
    end
end
local function createPanel(frame)
    panel = CreateFrame("Frame", "DXMProfessionProfitFrame", frame, "InsetFrameTemplate")
    panel:SetPoint("TOPLEFT", frame, "TOPLEFT", 3, -21)
    panel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -3, 3)
    panel:SetScript("OnShow", function()
        if _G.DXMDDQFrame then _G.DXMDDQFrame:Hide() end
        if _G.DXMDDQProfessionTab and PanelTemplates_DeselectTab then PanelTemplates_DeselectTab(_G.DXMDDQProfessionTab) end
        hideProfessionPages(frame)
        raisePanel()
    end)
    raisePanel()
    panel:EnableMouse(true)
    panel:Hide()
    local fill = panel:CreateTexture(nil, "BACKGROUND")
    fill:SetPoint("TOPLEFT", 4, -4); fill:SetPoint("BOTTOMRIGHT", -4, 4); fill:SetColorTexture(.025, .025, .025, 1)

    titleText = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    titleText:SetPoint("TOPLEFT", 18, -16); titleText:SetText("DXM Craft Profit")
    local refresh = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    refresh:SetSize(120, 25); refresh:SetPoint("TOPRIGHT", -16, -12); refresh:SetText("Refresh Prices"); refresh:SetScript("OnClick", analyze)
    local queue = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    queue:SetSize(120, 25); queue:SetPoint("RIGHT", refresh, "LEFT", -8, 0); queue:SetText("Crafting Queue")
    queue:SetScript("OnClick", function() if DXMCraftingQueue then DXMCraftingQueue:Show(panel) end end)
    local preference = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    preference:SetSize(130, 25); preference:SetPoint("RIGHT", queue, "LEFT", -8, 0)
    local function refreshPreference() preference:SetText("Plan: " .. (PREFERENCE_LABELS[DXMConfig.craftPlanPreference] or "Balanced")) end
    refreshPreference()
    preference:SetScript("OnClick", function()
        local current = 2
        for index, key in ipairs(PREFERENCES) do if key == DXMConfig.craftPlanPreference then current = index; break end end
        DXMConfig.craftPlanPreference = PREFERENCES[current % #PREFERENCES + 1]
        refreshPreference()
        analysisGeneration = analysisGeneration + 1
        analysisRunning = false
        analyze()
    end)
    statusText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    statusText:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 0, -10); statusText:SetPoint("RIGHT", preference, "LEFT", -12, 0); statusText:SetJustifyH("LEFT")

    local list = CreateFrame("Frame", nil, panel, "InsetFrameTemplate")
    list:SetPoint("TOPLEFT", statusText, "BOTTOMLEFT", -6, -12); list:SetPoint("RIGHT", panel, "RIGHT", -12, 0); list:SetPoint("BOTTOM", panel, "BOTTOM", 0, 56)
    local header = CreateFrame("Frame", nil, list)
    header:SetPoint("TOPLEFT", 5, -5); header:SetPoint("TOPRIGHT", -5, -5); header:SetHeight(22)
    local bg = header:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetColorTexture(.16, .12, .05, .9)
    local boundaries = {0, .32, .44, .53, .62, .75, .90, 1}
    local definitions = {{"Recipe", "name"}, {"Craft Cost", "cost"}, {"Time", "time"}, {"Can Craft", "canCraft"}, {"Market", "value"}, {"Profit", "profit"}, {"ROI", "roi"}}
    local function place(region, owner, left, right, leftInset, rightInset)
        region:ClearAllPoints(); region:SetPoint("LEFT", owner, "LEFT", left + (leftInset or 0), 0); region:SetWidth(math.max(1, right - left - (leftInset or 0) - (rightInset or 0)))
    end
    local function makeHeader(label, key)
        local button = CreateFrame("Button", nil, header); button:SetHeight(21); button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        button.Label = button:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall"); button.Label:SetAllPoints(); button.Label:SetJustifyH("CENTER")
        headers[key] = {Button = button, Label = button.Label, label = label}
        button:SetScript("OnClick", function()
            if sortKey == key then sortAscending = not sortAscending else sortKey = key; sortAscending = key == "name" or key == "cost" end
            pageOffset = 0; updateRows()
        end)
    end
    for _, definition in ipairs(definitions) do makeHeader(definition[1], definition[2]) end

    local previous
    for index = 1, PAGE_SIZE do
        local row = CreateFrame("Button", nil, list); row:SetHeight(25); row:SetPoint("LEFT", header); row:SetPoint("RIGHT", header); row:SetPoint("TOP", previous or header, "BOTTOM")
        local rb = row:CreateTexture(nil, "BACKGROUND"); rb:SetAllPoints(); rb:SetColorTexture(index % 2 == 0 and .10 or .035, index % 2 == 0 and .10 or .035, index % 2 == 0 and .10 or .035, .78)
        local line = row:CreateTexture(nil, "BORDER"); line:SetPoint("BOTTOMLEFT"); line:SetPoint("BOTTOMRIGHT"); line:SetHeight(1); line:SetColorTexture(.31, .27, .19, .72)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetScript("OnClick", function(self, button) if button == "RightButton" then addRowToBuyList(self) end end)
        row:SetScript("OnEnter", showRowTooltip); row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.Icon = row:CreateTexture(nil, "ARTWORK"); row.Icon:SetSize(22,22); row.Icon:SetPoint("LEFT",2,0)
        for _, field in ipairs({"Name","Cost","Time","CanCraft","Value","Profit","ROI"}) do row[field] = row:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); row[field]:SetJustifyH(field == "Name" and "LEFT" or "RIGHT") end
        rows[index] = row; previous = row
    end
    local function layout(width)
        local pixels = {}; for index, value in ipairs(boundaries) do pixels[index] = math.floor(width * value) end
        local keys = {"name","cost","time","canCraft","value","profit","roi"}
        for index, key in ipairs(keys) do place(headers[key].Button, header, pixels[index], pixels[index+1], 2, 2) end
        for _, row in ipairs(rows) do
            local fields = {row.Name,row.Cost,row.Time,row.CanCraft,row.Value,row.Profit,row.ROI}
            for index, field in ipairs(fields) do place(field,row,pixels[index],pixels[index+1],index == 1 and 28 or 5,5) end
        end
    end
    header:SetScript("OnSizeChanged", function(_, width) if width > 0 then layout(width) end end)
    C_Timer.After(0, function() if header:GetWidth() > 0 then layout(header:GetWidth()) end end)

    previousButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate"); previousButton:SetSize(28,22); previousButton:SetPoint("BOTTOMLEFT",panel,"BOTTOMLEFT",18,15); previousButton:SetText("<"); previousButton:SetScript("OnClick",function() pageOffset=pageOffset-PAGE_SIZE; updateRows() end)
    nextButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate"); nextButton:SetSize(28,22); nextButton:SetPoint("LEFT",previousButton,"RIGHT",5,0); nextButton:SetText(">"); nextButton:SetScript("OnClick",function() pageOffset=pageOffset+PAGE_SIZE; updateRows() end)
    countText = panel:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); countText:SetPoint("LEFT",nextButton,"RIGHT",10,0)
    local back = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate"); back:SetSize(145,25); back:SetPoint("BOTTOMRIGHT",-14,14); back:SetText("Return to Profession"); back:SetScript("OnClick",function() panel:Hide(); if tab then PanelTemplates_DeselectTab(tab) end; restoreProfessionOverview(frame) end)
end

local function ensureUI()
    local frame = _G.ProfessionsFrame
    if not frame then return end
    if not panel then createPanel(frame) end
    if not tab then
        tab = CreateFrame("Button", "DXMProfessionTab", frame, "PanelTabButtonTemplate")
        tab:SetText("DXM")
        tab:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 28, 4)
        tab:SetFrameStrata("DIALOG")
        tab:SetFrameLevel(math.max(frame:GetFrameLevel() + 210, 510))
        if PanelTemplates_TabResize then PanelTemplates_TabResize(tab, 12) end
        PanelTemplates_DeselectTab(tab)
        tab:SetScript("OnClick", function()
            if panel:IsShown() then panel:Hide(); PanelTemplates_DeselectTab(tab); restoreProfessionOverview(frame)
            else panel:Show(); raisePanel(); PanelTemplates_SelectTab(tab); analyze() end
        end)
        tab:Show()

        local function leaveDXMPage()
            if panel:IsShown() then panel:Hide(); PanelTemplates_DeselectTab(tab) end
        end
        if frame.ProfessionsOverviewTab then frame.ProfessionsOverviewTab:HookScript("OnMouseUp", leaveDXMPage) end
        for _, nativeTab in ipairs(frame.rightProfessionTabs or {}) do nativeTab:HookScript("OnMouseUp", leaveDXMPage) end
        frame:HookScript("OnHide", function()
            if panel:IsShown() then panel:Hide(); PanelTemplates_DeselectTab(tab); restoreProfessionOverview(frame) end
        end)
        if EventRegistry and EventRegistry.RegisterCallback then
            EventRegistry:RegisterCallback("ProfessionsFrame.TabSet", leaveDXMPage, tab)
        end
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("TRADE_SKILL_SHOW")
events:RegisterEvent("MERCHANT_SHOW")
events:RegisterEvent("MERCHANT_UPDATE")
events:SetScript("OnEvent", function(_, event, addonName)
    if event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
        scheduleMerchantScan()
        return
    end
    if event == "ADDON_LOADED" and addonName ~= "Blizzard_Professions" then return end
    C_Timer.After(0, function()
        ensureUI()
    end)
end)

function Module:ScannerItemsCompleted()
    wipe(priceCache)
    wipe(currentPriceCache)
    wipe(historyKeyIndex)
    historyIndexReady = false
    -- Price caches are invalid now; the pane recalculates on open or Refresh Prices.
end

function Module:Boot(hook)
    hook(Const.ScannerItemsCompleted, Module.ScannerItemsCompleted)
    ensureUI()
    if MerchantFrame and MerchantFrame:IsShown() then scheduleMerchantScan() end
end

