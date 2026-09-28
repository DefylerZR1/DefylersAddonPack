if not DXMCore or not DXMExchange then return end

local Module = DXMCore:Module("MarketTools", "Scanner")
local Const = DXMCore.Const()
local PAGE_SIZE = 11
local lastItems = {}
local dealResults, salvageResults = {}, {}
local views = {}
local scannerStatus
local lastScanCount = 0
local maxDealSamples = 0
local unsupportedDeals = 0
local salvageMissingMaterials = {}
local materialHistoryKeys = {}
local materialPriceCache = {}
local scanMarketValueCache = {}
local processGeneration = 0

local function money(value)
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

local function parseMoney(text)
    text = tostring(text or ""):lower():gsub(",", "")
    if text:match("^%s*$") then return 0 end
    local gold = tonumber(text:match("([%d%.]+)%s*g")) or 0
    local silver = tonumber(text:match("([%d%.]+)%s*s")) or 0
    local copper = tonumber(text:match("([%d%.]+)%s*c")) or 0
    if gold == 0 and silver == 0 and copper == 0 then copper = tonumber(text:match("[%d%.]+")) or 0 end
    return math.max(0, math.floor(gold * 10000 + silver * 100 + copper + .5))
end

local function parseROI(text)
    return math.max(0, tonumber(tostring(text or ""):match("[%d%.]+")) or 0)
end

local function stableBefore(a, b)
    local aID, bID = tonumber(a.itemID) or 0, tonumber(b.itemID) or 0
    if aID ~= bID then return aID < bID end
    local aSequence, bSequence = tonumber(a.sequence) or 0, tonumber(b.sequence) or 0
    if aSequence ~= bSequence then return aSequence < bSequence end
    return tostring(a.link or "") < tostring(b.link or "")
end

local function marketValue(id, minimumSamples)
    local values, samples = {}, 0
    minimumSamples = tonumber(minimumSamples) or 3
    for _, stat in ipairs(DXMCore:Statistics(id)) do
        local count = tonumber(stat:Number()) or 0
        samples = math.max(samples, count)
        if count >= minimumSamples then
            local ok, price = pcall(stat.Percentile, stat, 15, {weighted = true, before = DXMCore:Timeslice() - 1})
            if not ok or not price then
                ok, price = pcall(stat.Minimum, stat)
            end
            price = ok and tonumber(price) or nil
            if price and price > 0 then
                values[#values + 1] = price
            end
        end
    end
    if #values == 0 then return nil, samples end
    table.sort(values)
    return values[math.ceil(#values / 2)], samples
end

local function scanMarketValue(id, currentPrice)
    local cached = scanMarketValueCache[id]
    if cached then return cached.value or nil, cached.samples, cached.detail end
    local value, samples, detail = DXMDealValuation.Get(id,currentPrice)
    scanMarketValueCache[id] = {value = value or false, samples = samples or 0, detail = detail}
    return value, samples, detail
end

local function materialMarketValue(itemID)
    itemID = tonumber(itemID)
    if not itemID then return end
    local cached = materialPriceCache[itemID]
    if cached then return cached.value or nil, cached.samples end

    local base = tostring(itemID)
    local key = materialHistoryKeys[itemID]
    if not key then
        local itemLevel = select(4, C_Item.GetItemInfo(itemID))
        itemLevel = tonumber(itemLevel) or 0
        key = itemLevel > 0 and (base .. ":" .. itemLevel) or base
    end

    local value, samples = marketValue(key, 1)
    if not value and key ~= base then value, samples = marketValue(base, 1) end
    materialPriceCache[itemID] = {value = value or false, samples = samples or 0}
    return value, samples
end

local function itemInfo(item)
    local key = item.itemKey
    local itemID = key and key.itemID
    if not itemID then return end
    local query = item.itemData and item.itemData.appearanceLink or itemID
    local name, link, quality, level, _, itemType, itemSubType, maxStack, equipLoc, icon, vendor, classID = C_Item.GetItemInfo(query)
    if not name and query ~= itemID then
        name, link, quality, level, _, itemType, itemSubType, maxStack, equipLoc, icon, vendor, classID = C_Item.GetItemInfo(itemID)
    end
    if not name then
        if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
        return
    end
    return {
        id = item.id or DXMCore:ItemKeyKey(key), itemID = itemID, itemKey = key,
        name = name, link = link, quality = quality or 1, level = level or 0,
        itemType = itemType, itemSubType = itemSubType, maxStack = maxStack or 1,
        equipLoc = equipLoc, icon = icon, vendor = vendor or 0,
        classID = classID, buyout = tonumber(item.itemData and item.itemData.minPrice) or 0,
        browseResult = item.itemData,
    }
end

local MATERIALS = {
    strange={10940,"Strange Dust"}, lmagic={10938,"Lesser Magic Essence"}, gmagic={10939,"Greater Magic Essence"}, sglimmer={10978,"Small Glimmering Shard"},
    soul={11083,"Soul Dust"}, lastral={10998,"Lesser Astral Essence"}, gastral={11082,"Greater Astral Essence"}, lglimmer={11084,"Large Glimmering Shard"},
    vision={11137,"Vision Dust"}, lmystic={11134,"Lesser Mystic Essence"}, gmystic={11135,"Greater Mystic Essence"}, sglowing={11138,"Small Glowing Shard"}, lglowing={11139,"Large Glowing Shard"},
    dream={11176,"Dream Dust"}, lnether={11174,"Lesser Nether Essence"}, gnether={11175,"Greater Nether Essence"}, sradiant={11177,"Small Radiant Shard"}, lradiant={11178,"Large Radiant Shard"},
    illusion={16204,"Illusion Dust"}, leternal={16202,"Lesser Eternal Essence"}, geternal={16203,"Greater Eternal Essence"}, sbrilliant={14343,"Small Brilliant Shard"}, lbrilliant={14344,"Large Brilliant Shard"}, nexus={20725,"Nexus Crystal"},
    arcane={22445,"Arcane Dust"}, lplanar={22447,"Lesser Planar Essence"}, gplanar={22446,"Greater Planar Essence"}, sprismatic={22448,"Small Prismatic Shard"}, lprismatic={22449,"Large Prismatic Shard"}, void={22450,"Void Crystal"},
    infinite={34054,"Infinite Dust"}, lcosmic={34056,"Lesser Cosmic Essence"}, gcosmic={34055,"Greater Cosmic Essence"}, sdream={34053,"Small Dream Shard"}, dreamshard={34052,"Dream Shard"}, abyss={34057,"Abyss Crystal"},
}

local WEAPON_CLASS = Enum and Enum.ItemClass and Enum.ItemClass.Weapon or 2
local ARMOR_CLASS = Enum and Enum.ItemClass and Enum.ItemClass.Armor or 4

local EQUIPMENT_SLOTS = {
    INVTYPE_2HWEAPON=true, INVTYPE_WEAPON=true, INVTYPE_WEAPONMAINHAND=true,
    INVTYPE_WEAPONOFFHAND=true, INVTYPE_RANGED=true, INVTYPE_RANGEDRIGHT=true,
    INVTYPE_THROWN=true, INVTYPE_CHEST=true, INVTYPE_CLOAK=true, INVTYPE_FEET=true,
    INVTYPE_FINGER=true, INVTYPE_HAND=true, INVTYPE_HEAD=true, INVTYPE_HOLDABLE=true,
    INVTYPE_LEGS=true, INVTYPE_NECK=true, INVTYPE_ROBE=true, INVTYPE_SHIELD=true,
    INVTYPE_SHOULDER=true, INVTYPE_TABARD=true, INVTYPE_TRINKET=true,
    INVTYPE_WAIST=true, INVTYPE_WRIST=true, INVTYPE_RELIC=true,
}

local NON_DISENCHANTABLE = {
    [3456]=true, [5976]=true, [11287]=true, [11288]=true, [11289]=true, [11290]=true,
    [13544]=true, [17690]=true, [17691]=true, [17900]=true, [17901]=true, [17902]=true,
    [17903]=true, [17904]=true, [17905]=true, [17906]=true, [17907]=true, [17908]=true,
    [17909]=true, [18706]=true, [20406]=true, [20407]=true, [20408]=true, [22206]=true,
    [32538]=true, [32539]=true, [32757]=true, [33292]=true, [34073]=true, [34484]=true,
    [34648]=true, [34649]=true, [34650]=true, [34651]=true, [34652]=true, [34653]=true,
    [34655]=true, [34656]=true, [35279]=true, [35494]=true, [35497]=true, [36941]=true,
    [37892]=true, [37897]=true, [38288]=true, [40483]=true, [40643]=true, [42943]=true,
    [42944]=true, [42945]=true, [42946]=true, [42947]=true, [42948]=true, [42949]=true,
    [42950]=true, [42951]=true, [42952]=true, [42984]=true, [42985]=true, [42991]=true,
    [42992]=true, [43348]=true, [44050]=true, [44062]=true, [44073]=true, [44095]=true,
    [44167]=true, [44173]=true, [44180]=true, [44196]=true, [44202]=true, [44303]=true,
    [44597]=true, [44731]=true, [44800]=true, [44803]=true, [45067]=true, [45574]=true,
    [45577]=true, [45578]=true, [45579]=true, [45580]=true, [45581]=true, [45582]=true,
    [45858]=true, [46861]=true, [46874]=true, [48685]=true, [48691]=true, [49123]=true,
    [49715]=true, [50376]=true, [50377]=true, [50387]=true, [50397]=true, [50398]=true,
}

-- Entries are {maximum item level, {{material key, chance, average quantity}, ...}}.
local DISENCHANT_TABLE = {
    [2] = {
        [WEAPON_CLASS] = {
            {15,{{"strange",.20,1.5},{"lmagic",.80,1.5}}},
            {20,{{"strange",.20,2.5},{"gmagic",.75,1.5},{"sglimmer",.05,1}}},
            {25,{{"strange",.15,5},{"lastral",.75,1.5},{"sglimmer",.10,1}}},
            {30,{{"soul",.20,1.5},{"gastral",.75,1.5},{"lglimmer",.05,1}}},
            {35,{{"soul",.20,3.5},{"lmystic",.75,1.5},{"sglowing",.05,1}}},
            {40,{{"vision",.20,1.5},{"gmystic",.75,1.5},{"lglowing",.05,1}}},
            {45,{{"vision",.20,3.5},{"lnether",.75,1.5},{"sradiant",.05,1}}},
            {50,{{"dream",.20,1.5},{"gnether",.75,1.5},{"lradiant",.05,1}}},
            {55,{{"dream",.20,3.5},{"leternal",.75,1.5},{"sbrilliant",.05,1}}},
            {60,{{"illusion",.20,1.5},{"geternal",.75,1.5},{"lbrilliant",.05,1}}},
            {65,{{"illusion",.20,3.5},{"geternal",.75,2.5},{"lbrilliant",.05,1}}},
            {99,{{"arcane",.20,2.5},{"lplanar",.75,2.5},{"sprismatic",.05,1}}},
            {120,{{"arcane",.20,3.5},{"gplanar",.75,1.5},{"lprismatic",.05,1}}},
            {151,{{"infinite",.20,2.5},{"lcosmic",.75,1.5},{"sdream",.05,1}}},
            {200,{{"infinite",.20,5.5},{"gcosmic",.75,1.5},{"dreamshard",.05,1}}},
        },
        [ARMOR_CLASS] = {
            {15,{{"strange",.80,1.5},{"lmagic",.20,1.5}}},
            {20,{{"strange",.75,2.5},{"gmagic",.20,1.5},{"sglimmer",.05,1}}},
            {25,{{"strange",.75,5},{"lastral",.15,1.5},{"sglimmer",.10,1}}},
            {30,{{"soul",.75,1.5},{"gastral",.20,1.5},{"lglimmer",.05,1}}},
            {35,{{"soul",.75,3.5},{"lmystic",.20,1.5},{"sglowing",.05,1}}},
            {40,{{"vision",.75,1.5},{"gmystic",.20,1.5},{"lglowing",.05,1}}},
            {45,{{"vision",.75,3.5},{"lnether",.20,1.5},{"sradiant",.05,1}}},
            {50,{{"dream",.75,1.5},{"gnether",.20,1.5},{"lradiant",.05,1}}},
            {55,{{"dream",.75,3.5},{"leternal",.20,1.5},{"sbrilliant",.05,1}}},
            {60,{{"illusion",.75,1.5},{"geternal",.20,1.5},{"lbrilliant",.05,1}}},
            {65,{{"illusion",.75,3.5},{"geternal",.20,2.5},{"lbrilliant",.05,1}}},
            {99,{{"arcane",.75,2.5},{"lplanar",.20,2.5},{"sprismatic",.05,1}}},
            {120,{{"arcane",.75,3.5},{"gplanar",.20,1.5},{"lprismatic",.05,1}}},
            {151,{{"infinite",.75,2.5},{"lcosmic",.20,1.5},{"sdream",.05,1}}},
            {200,{{"infinite",.75,5.5},{"gcosmic",.20,1.5},{"dreamshard",.05,1}}},
        },
    },
    [3] = {
        [ARMOR_CLASS] = {
            {25,{{"sglimmer",1,1}}}, {30,{{"lglimmer",1,1}}},
            {35,{{"sglowing",1,1}}}, {40,{{"lglowing",1,1}}},
            {45,{{"sradiant",1,1}}}, {50,{{"lradiant",1,1}}},
            {55,{{"sbrilliant",1,1}}}, {65,{{"lbrilliant",1,1}}},
            {99,{{"sprismatic",1,1}}}, {120,{{"lprismatic",1,1}}},
            {164,{{"sdream",1,1}}}, {200,{{"dreamshard",1,1}}},
        },
    },
    [4] = {
        [ARMOR_CLASS] = {
            {40,{{"sradiant",1,3}}}, {45,{{"sradiant",1,3.5}}},
            {50,{{"lradiant",1,3.5}}}, {55,{{"sbrilliant",1,3.5}}},
            {66,{{"lbrilliant",.60,4},{"geternal",.25,3.5},{"illusion",.15,4.5}}},
            {94,{{"nexus",1,1.5}}}, {99,{{"void",1,1}}},
            {164,{{"void",1,1.5}}}, {299,{{"abyss",1,1}}},
        },
    },
}

local function salvageYield(info, referenceOnly)
    local quality = tonumber(info.quality)
    if quality ~= 2 and quality ~= 3 and quality ~= 4 then return end
    if info.classID ~= WEAPON_CLASS and info.classID ~= ARMOR_CLASS then return end
    if not EQUIPMENT_SLOTS[info.equipLoc] then return end
    if (tonumber(info.maxStack) or 1) > 1 then return end
    if NON_DISENCHANTABLE[tonumber(info.itemID)] then return end

    local observed=not referenceOnly and DXMSalvageObservations and DXMSalvageObservations.Get(info.itemID)
    if observed and (tonumber(observed.attempts) or 0)>0 then
        local yields={}
        for _,output in pairs(observed.outputs or {}) do
            local total=tonumber(output.total) or 0
            if total>0 and output.itemID then yields[#yields+1]={tonumber(output.itemID),total/observed.attempts} end
        end
        table.sort(yields,function(a,b)return a[1]<b[1] end)
        if #yields>0 then return yields,tonumber(observed.attempts) end
    end

    local qualityTable = DISENCHANT_TABLE[quality]
    local levelTable = qualityTable and (qualityTable[info.classID] or qualityTable[ARMOR_CLASS])
    if not levelTable then return end

    local outcomes
    for _, bracket in ipairs(levelTable) do
        if (tonumber(info.level) or 0) <= bracket[1] then outcomes = bracket[2]; break end
    end
    if not outcomes then return end

    local yields = {}
    for _, output in ipairs(outcomes) do
        yields[#yields + 1] = {output[1], output[2] * output[3]}
    end
    return yields,nil
end
local function possibleSalvageOutputs(info)
    local possible={}
    -- A small observed sample must not erase rare outcomes in the reference table.
    for _,referenceOnly in ipairs({true,false}) do
        local yields=salvageYield(info,referenceOnly)
        for _,output in ipairs(yields or {}) do
            local id=type(output[1])=="number" and output[1] or (MATERIALS[output[1]] and MATERIALS[output[1]][1])
            if id and output[2]>0 then possible[id]=true end
        end
    end
    return possible
end
local function excludedSalvage(result)
    local config=DXMConfig or {}
    local exclude=tonumber(config.salvageExcludedMaterialID)
    if exclude==nil then exclude=10978 end
    local include=tonumber(config.salvageIncludedMaterialID) or 0
    local outputs=result.possibleOutputs or {}
    if exclude>0 and outputs[exclude] then return true end
    if include>0 and not outputs[include] then return true end
    for id in tostring(config.salvageExcludedItemIDs or ""):gmatch("%d+") do
        if tonumber(id)==result.itemID then return true end
    end
    return false
end

local function salvageValue(info)
    local yields,observedAttempts = salvageYield(info)
    if not yields then return end
    local total, labels = 0, {}
    for _, output in ipairs(yields) do
        local material = type(output[1])=="number" and {output[1],(C_Item.GetItemInfo(output[1]) or ("Item "..output[1]))} or MATERIALS[output[1]]
        local price = materialMarketValue(material[1])
        if not price then return nil, nil, "Missing price for " .. material[2],observedAttempts end
        total = total + price * output[2]
        labels[#labels + 1] = ("%.2f x %s"):format(output[2], material[2])
    end
    return math.floor(total + .5), table.concat(labels, ", "),nil,observedAttempts
end

local function openResult(result)
    if result and result.browseResult and AuctionHouseFrame then AuctionHouseFrame:SelectBrowseResult(result.browseResult) end
end

local function groupSalvageResults(raw)
    local grouped, byKey = {}, {}
    for _, result in ipairs(raw) do
        local key = result.itemKey or {}
        -- Random enchant suffix does not change the disenchant opportunity.
        local identity = table.concat({key.itemID or result.itemID or 0,key.itemLevel or 0,key.battlePetSpeciesID or 0}, ":")
        local id = identity .. "@" .. tostring(result.buyout)
        local variant = tostring(key.itemSuffix or 0)
        local group = byKey[id]
        if not group then
            group = {variants={}, quantityAtPrice=0, quantityPartial=false}
            for field,value in pairs(result) do if field~="quantityAtPrice" then group[field]=value end end
            group.name = (C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(key.itemID or result.itemID))
                or (result.name and result.name:gsub(" of .+$", ""))
            group.selectedQuantity = result.quantityAtPrice
            byKey[id]=group; grouped[#grouped+1]=group
        end
        if not group.variants[variant] then
            group.variants[variant]=result
            if result.quantityAtPrice==nil then group.quantityPartial=true
            else
                group.quantityAtPrice=group.quantityAtPrice+result.quantityAtPrice
                if result.quantityPartial then group.quantityPartial=true end
            end
            -- Select an available actual variant; never send the merged identity to Buy Now.
            local rank=result.quantityAtPrice==nil and 1 or (result.quantityAtPrice>0 and 2 or 0)
            local current=group.selectedQuantity==nil and 1 or (group.selectedQuantity>0 and 2 or 0)
            if rank>current then
                group.itemKey=result.itemKey; group.link=result.link; group.browseResult=result.browseResult
                group.selectedQuantity=result.quantityAtPrice
            end
        end
    end
    for _,group in ipairs(grouped) do
        if group.quantityAtPrice==0 and group.quantityPartial then group.quantityAtPrice=nil end
    end
    return grouped
end

-- Browse totals can span prices; only count loaded auctions at this unit price.
local function loadedQuantityAtPrice(itemKey, price)
    local quantity, seen = 0, {}
    for index=1,(C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0) do
        local auction=C_AuctionHouse.GetItemSearchResultInfo(itemKey,index)
        if auction and auction.auctionID and not seen[auction.auctionID]
            and (tonumber(auction.bidAmount) or 0)<=0
            and not (DXMScanner and DXMScanner.IsPurchasedAuction and DXMScanner.IsPurchasedAuction(auction.auctionID)) then
            seen[auction.auctionID]=true
            local units=math.max(1,tonumber(auction.quantity) or 1)
            if tonumber(auction.buyoutAmount)==price*units then quantity=quantity+units end
        end
    end
    return quantity
end

local salvageQuantityQueue, salvageQuantityQueued = {}, {}
local salvageQuantityPending
local salvageQuantityGeneration = 0
local requestNextSalvageQuantity
local refreshView

local function salvageQuantityKey(result)
    if not result or not result.itemKey then return end
    return DXMCore:ItemKeyKey(result.itemKey) .. "@" .. tostring(result.buyout or 0)
end

local function queueSalvageQuantity(result)
    local key=salvageQuantityKey(result)
    if not key or result.quantityAtPrice~=nil or salvageQuantityQueued[key] then return end
    salvageQuantityQueued[key]=true
    salvageQuantityQueue[#salvageQuantityQueue+1]=result
end

local function resetSalvageQuantities()
    salvageQuantityGeneration=salvageQuantityGeneration+1
    salvageQuantityPending=nil
    wipe(salvageQuantityQueue);wipe(salvageQuantityQueued)
end

requestNextSalvageQuantity=function()
    if salvageQuantityPending or #salvageQuantityQueue==0 or not AuctionHouseFrame then return end
    if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
        C_Timer.After(.25,requestNextSalvageQuantity);return
    end
    local result=table.remove(salvageQuantityQueue,1)
    local keyInfo=C_AuctionHouse.GetItemKeyInfo(result.itemKey)
    if not keyInfo then
        result.quantityAttempts=(result.quantityAttempts or 0)+1
        if result.quantityAttempts<20 then table.insert(salvageQuantityQueue,result) end
        C_Timer.After(.10,requestNextSalvageQuantity);return
    end
    local generation=salvageQuantityGeneration
    salvageQuantityPending={result=result,key=salvageQuantityKey(result),generation=generation}
    AuctionHouseFrame:QueryItem(AuctionHouseSearchContext.BuyItems,result.itemKey)
    C_Timer.After(5,function()
        local pending=salvageQuantityPending
        if pending and pending.result==result and pending.generation==generation then
            salvageQuantityPending=nil
            salvageQuantityQueued[pending.key]=nil
            C_Timer.After(.10,requestNextSalvageQuantity)
        end
    end)
end

refreshView=function(view)
    if not view then return end
    local raw = view.data() or {}
    local rawCount=view.kind=="salvage" and #groupSalvageResults(raw) or #raw
    local list = {}
    for _, result in ipairs(raw) do
        local matches = not (view.kind=="salvage" and excludedSalvage(result))
        if view.kind=="salvage" and result.quantityAtPrice~=nil
            and result.quantityAtPrice<=0 and not result.quantityPartial then matches=false end
        if view.kind=="salvage" and DXMScanner and DXMScanner.HasPurchasedItem and DXMScanner.HasPurchasedItem(result.itemKey) then
            result.quantityAtPrice=loadedQuantityAtPrice(result.itemKey,result.buyout)
            if result.quantityAtPrice==0 and C_AuctionHouse.HasFullItemSearchResults and C_AuctionHouse.HasFullItemSearchResults(result.itemKey) then matches=false end
        end
        if view.kind == "salvage" or view.kind == "deals" then
            local maximumCost = tonumber(view.maximumCost) or 0
            local hunting=view.kind=="salvage" and (tonumber(DXMConfig and DXMConfig.salvageIncludedMaterialID) or 0)>0
            local profitRequired=not hunting or tostring(DXMConfig.salvageMinimumProfitText or ""):match("%S")
            local roiRequired=not hunting or tostring(DXMConfig.salvageMinimumROIText or ""):match("%S")
            matches = matches and (maximumCost <= 0 or (tonumber(result.buyout) or 0) <= maximumCost)
                and (not profitRequired or (result.profit~=nil and (tonumber(result.profit) or 0) >= (tonumber(view.minimumProfit) or 0)))
                and (not roiRequired or (result.roi~=nil and (tonumber(result.roi) or 0) >= (tonumber(view.minimumROI) or 0)))
            if view.kind=="salvage" and not hunting then matches=matches and result.profit~=nil and result.profit>0 end
        end
        if matches then list[#list + 1] = result end
    end
    if view.kind=="salvage" then list=groupSalvageResults(list) end
    table.sort(list, function(a,b)
        if view.sortKey == "name" then
            local av, bv = tostring(a.name or ""), tostring(b.name or "")
            if av == bv then return stableBefore(a, b) end
            if view.ascending then return av < bv end
            return av > bv
        end
        local av, bv = tonumber(a[view.sortKey]) or 0, tonumber(b[view.sortKey]) or 0
        if av == bv then
            local an, bn = tostring(a.name or ""), tostring(b.name or "")
            if an == bn then return stableBefore(a, b) end
            return an < bn
        end
        if view.ascending then return av < bv end
        return av > bv
    end)
    local pageSize=view.pageSize or PAGE_SIZE
    local maxOffset = math.max(0, #list - pageSize)
    view.offset = math.max(0, math.min(view.offset, maxOffset))
    for i,row in ipairs(view.rows) do
        local result = list[view.offset + i]
        row.result = result
        if result then
            row.Icon:SetTexture(result.icon or 134400)
            row.Name:SetText(result.name)
            if row.Quantity then row.Quantity:SetText(result.quantityAtPrice==nil and "?" or (tostring(result.quantityAtPrice)..(result.quantityPartial and "+" or ""))) end
            local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[result.quality]
            if color then row.Name:SetTextColor(color.r,color.g,color.b) else row.Name:SetTextColor(1,1,1) end
            row.Buyout:SetText(money(result.buyout))
            row.Value:SetText(result.value and money(result.value) or "--")
            row.Profit:SetText(result.profit and money(result.profit) or "--")
            row.ROI:SetText(result.roi and ("%.0f%%"):format(result.roi) or "--")
            row:Show()
        else row:Hide() end
    end
    local emptyMessage
    if view.kind == "deals" then
        if #raw > 0 and #list == 0 then
            emptyMessage = ("No deals match the current filters (%d before filters)."):format(#raw)
        elseif lastScanCount == 0 then
            emptyMessage = "No scan results yet. Click Scan Auction House."
        elseif unsupportedDeals > 0 then
            emptyMessage = ("No supported discounts. %d items lack enough recent history across time."):format(unsupportedDeals)
        else
            emptyMessage = "No listings are below the supported recent listing baseline."
        end
    else
        if #raw > 0 and #list == 0 then
            emptyMessage = ("No available salvage candidates match the current filters (%d before filters)."):format(#raw)
        elseif lastScanCount == 0 then
            emptyMessage = "No scan results yet. Click Scan Auction House."
        elseif next(salvageMissingMaterials) then
            local names = {}
            for name in pairs(salvageMissingMaterials) do names[#names + 1] = name end
            table.sort(names)
            local shown = {}
            for index = 1, math.min(4, #names) do shown[#shown + 1] = names[index] end
            local suffix = #names > #shown and (" and %d more"):format(#names - #shown) or ""
            emptyMessage = "Missing material prices: " .. table.concat(shown, ", ") .. suffix .. "."
        else
            emptyMessage = "No profitable disenchant candidates found in this scan."
        end
    end
    if #list == 0 then
        view.Count:SetText(emptyMessage)
    else
        local suffix = #list < rawCount and (" (%d before filters)"):format(rawCount) or ""
        view.Count:SetText(("Showing %d-%d of %d%s"):format(view.offset+1, math.min(view.offset+pageSize,#list),#list,suffix))
    end
    view.Previous:SetEnabled(view.offset > 0)
    view.Next:SetEnabled(view.offset < maxOffset)
    for key,button in pairs(view.headers) do
        button.Label:SetText(button.label .. (key == view.sortKey and (view.ascending and " ^" or " v") or ""))
    end
    if view.kind=="salvage" and AuctionHouseFrame then
        for index=1,pageSize do
            local group=list[view.offset+index]
            if group then for _,variant in pairs(group.variants or {}) do queueSalvageQuantity(variant) end end
        end
        C_Timer.After(0,requestNextSalvageQuantity)
    end
end
local salvageQuantityEvents=CreateFrame("Frame")
salvageQuantityEvents:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
salvageQuantityEvents:RegisterEvent("ITEM_SEARCH_RESULTS_ADDED")
salvageQuantityEvents:RegisterEvent("AUCTION_HOUSE_CLOSED")
salvageQuantityEvents:SetScript("OnEvent",function(_,event,itemKey)
    if event=="AUCTION_HOUSE_CLOSED" then
        resetSalvageQuantities()
        for _,result in ipairs(salvageResults) do result.quantityAtPrice=nil end
    elseif itemKey then
        local id=DXMCore:ItemKeyKey(itemKey)
        local pending=salvageQuantityPending
        local pendingMatches=pending and pending.result.itemKey and DXMCore:ItemKeyKey(pending.result.itemKey)==id
        local full=not C_AuctionHouse.HasFullItemSearchResults or C_AuctionHouse.HasFullItemSearchResults(itemKey)
        if pendingMatches and not full and C_AuctionHouse.RequestMoreItemSearchResults then
            C_AuctionHouse.RequestMoreItemSearchResults(itemKey)
            return
        end
        local counts={}
        for _,result in ipairs(salvageResults) do
            if result.itemKey and DXMCore:ItemKeyKey(result.itemKey)==id then
                if counts[result.buyout]==nil then counts[result.buyout]=loadedQuantityAtPrice(itemKey,result.buyout) end
                result.quantityAtPrice=counts[result.buyout]
                result.quantityPartial=not full
            end
        end
        if pendingMatches then
            salvageQuantityPending=nil
            C_Timer.After(.10,requestNextSalvageQuantity)
        end
    end
    for _,view in ipairs(views) do if view.kind=="salvage" then refreshView(view) end end
end)

local function startScan(destination)
    if not DXMVendorFinder or not DXMVendorFinder.StartScan then
        if scannerStatus then scannerStatus:SetText("Vendor Finder is not loaded, so DXM cannot start a scan.") end
        return
    end
    if scannerStatus then scannerStatus:SetText("Scan in progress. DXM will update every market feature when it completes.") end
    for _, view in ipairs(views) do
        if view.Status then view.Status:SetText("Scan in progress...") end
    end
    DXMVendorFinder.StartScan(destination)
end

local function buildTable(page, data, valueLabel, intro, kind)
    local view = {data=data, rows={}, headers={}, sortKey="profit", ascending=false, offset=0, kind=kind,
        pageSize=kind=="salvage" and 8 or PAGE_SIZE}
    views[#views+1] = view
    local status = page:CreateFontString(nil,"ARTWORK","GameFontHighlight")
    status:SetPoint("TOPLEFT",page.Description,"BOTTOMLEFT",0,-15); status:SetText(intro)
    view.Status=status
    local scan=CreateFrame("Button",nil,page,"UIPanelButtonTemplate")
    scan:SetSize(150,25); scan:SetPoint("TOPRIGHT",page,"TOPRIGHT",-8,-2); scan:SetText("Scan Auction House")
    scan:SetScript("OnClick",function() startScan(kind) end)

    local resultAnchor = status
    local resultGap = -12
    if kind == "salvage" or kind == "deals" then
        DXMConfig = DXMConfig or {}
        local filters = CreateFrame("Frame",nil,page)
        filters:SetPoint("TOPLEFT",status,"BOTTOMLEFT",0,-8); filters:SetPoint("RIGHT",page,"RIGHT",-8,0); filters:SetHeight(kind=="salvage" and 132 or 52)
        resultAnchor = filters
        resultGap = -7

        local function label(text, relative, gap)
            local value=filters:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
            if relative then value:SetPoint("LEFT",relative,"RIGHT",gap or 18,0) else value:SetPoint("TOPLEFT",filters,"TOPLEFT",0,-14) end
            value:SetText(text)
            return value
        end
        local function input(relative,width,text)
            local value=CreateFrame("EditBox",nil,filters,"InputBoxTemplate")
            value:SetSize(width,24); value:SetPoint("LEFT",relative,"RIGHT",8,0); value:SetAutoFocus(false); value:SetJustifyH("CENTER"); value:SetText(text or "")
            return value
        end

        local isDeals = kind == "deals"
        local costLabel=label(isDeals and "Maximum price" or "Maximum cost")
        local costInput=input(costLabel,92,isDeals and DXMConfig.dealsMaximumPriceText or (not isDeals and DXMConfig.salvageMaximumCostText))
        local profitLabel=label("Minimum profit",costInput,22)
        local profitInput=input(profitLabel,92,isDeals and DXMConfig.dealsMinimumProfitText or (not isDeals and DXMConfig.salvageMinimumProfitText))
        local roiLabel=label("Minimum ROI",profitInput,22)
        local roiInput=input(roiLabel,58,isDeals and DXMConfig.dealsMinimumROIText or (not isDeals and DXMConfig.salvageMinimumROIText))
        local percent=filters:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        percent:SetPoint("LEFT",roiInput,"RIGHT",4,0); percent:SetText("%")
        local hint=filters:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
        hint:SetPoint("BOTTOMLEFT",filters,"BOTTOMLEFT",0,0)
        hint:SetPoint("BOTTOMRIGHT",filters,"BOTTOMRIGHT",0,0)
        hint:SetJustifyH("LEFT")
        hint:SetText("Money format: 1g 25s. Blank maximum " .. (isDeals and "price" or "cost") .. " = no limit; blank minimums = 0.")

        if kind=="salvage" then
            hint:SetText("Material search: blank profit/ROI = any. Left-click to buy; excludes win. IDs: comma-separated.")
            local choices={{0,"None"}}
            for _,material in pairs(MATERIALS) do choices[#choices+1]={material[1],material[2]} end
            table.sort(choices,function(a,b) if a[1]==0 then return b[1]~=0 elseif b[1]==0 then return false end return a[2]<b[2] end)
            local function materialDropdown(text,key,default,x)
                local title=filters:CreateFontString(nil,"ARTWORK","GameFontNormalSmall")
                title:SetPoint("TOPLEFT",filters,"TOPLEFT",x,-37);title:SetText(text)
                local dropdown=CreateFrame("Frame",nil,filters,"UIDropDownMenuTemplate")
                dropdown:SetPoint("TOPLEFT",title,"BOTTOMLEFT",-16,-2)
                UIDropDownMenu_SetWidth(dropdown,220)
                local selected=tonumber(DXMConfig[key]) or default
                local function caption()
                    for _,choice in ipairs(choices) do if choice[1]==selected then UIDropDownMenu_SetText(dropdown,choice[2]);return end end
                    UIDropDownMenu_SetText(dropdown,"Unknown material")
                end
                UIDropDownMenu_Initialize(dropdown,function()
                    for _,choice in ipairs(choices) do
                        local id,name=choice[1],choice[2]
                        local entry=UIDropDownMenu_CreateInfo()
                        entry.text=name;entry.checked=id==selected
                        entry.func=function()
                            selected=id;DXMConfig[key]=id;caption()
                            view.offset=0;refreshView(view)
                        end
                        UIDropDownMenu_AddButton(entry)
                    end
                end)
                caption()
            end
            materialDropdown("Exclude possible output","salvageExcludedMaterialID",10978,0)
            materialDropdown("Only show possible output","salvageIncludedMaterialID",0,255)
            local idsLabel=filters:CreateFontString(nil,"ARTWORK","GameFontNormalSmall")
            idsLabel:SetPoint("TOPLEFT",filters,"TOPLEFT",0,-91);idsLabel:SetText("Exclude item IDs")
            local ids=input(idsLabel,160,DXMConfig.salvageExcludedItemIDs)
            local function applyIDs()
                DXMConfig.salvageExcludedItemIDs=ids:GetText() or ""
                view.offset=0;refreshView(view)
            end
            ids:SetScript("OnEnterPressed",function(self) self:ClearFocus();applyIDs() end)
            ids:SetScript("OnEditFocusLost",applyIDs)
            ids:SetScript("OnEscapePressed",function(self) self:ClearFocus() end)
        end

        local function applyFilters()
            if isDeals then
                DXMConfig.dealsMaximumPriceText=costInput:GetText() or ""
                DXMConfig.dealsMinimumProfitText=profitInput:GetText() or ""
                DXMConfig.dealsMinimumROIText=roiInput:GetText() or ""
            else
                DXMConfig.salvageMaximumCostText=costInput:GetText() or ""
                DXMConfig.salvageMinimumProfitText=profitInput:GetText() or ""
                DXMConfig.salvageMinimumROIText=roiInput:GetText() or ""
            end
            view.maximumCost=parseMoney(costInput:GetText())
            view.minimumProfit=parseMoney(profitInput:GetText())
            view.minimumROI=parseROI(roiInput:GetText())
            view.offset=0
            refreshView(view)
        end
        for _,editBox in ipairs({costInput,profitInput,roiInput}) do
            editBox:SetScript("OnEnterPressed",function(self) self:ClearFocus(); applyFilters() end)
            editBox:SetScript("OnEditFocusLost",applyFilters)
            editBox:SetScript("OnEscapePressed",function(self) self:ClearFocus() end)
        end
        view.maximumCost=parseMoney(costInput:GetText())
        view.minimumProfit=parseMoney(profitInput:GetText())
        view.minimumROI=parseROI(roiInput:GetText())
        view.FilterInputs={costInput,profitInput,roiInput}
    end

    local frame=CreateFrame("Frame",nil,page,"InsetFrameTemplate")
    frame:SetPoint("TOPLEFT",resultAnchor,"BOTTOMLEFT",-6,resultGap); frame:SetPoint("RIGHT",page,"RIGHT",-8,0); frame:SetHeight(view.pageSize*25+32)
    local header=CreateFrame("Frame",nil,frame); header:SetPoint("TOPLEFT",5,-5); header:SetPoint("TOPRIGHT",-5,-5); header:SetHeight(22)
    header:SetFrameLevel(frame:GetFrameLevel()+2)
    local bg=header:CreateTexture(nil,"BACKGROUND"); bg:SetAllPoints(); bg:SetColorTexture(.16,.12,.05,.9)
    local widths=kind=="salvage" and {0,.38,.47,.61,.78,.92,1} or {0,.46,.62,.78,.92,1}
    local costLabel = kind == "salvage" and "Cost / unit" or "Buyout"
    local displayValueLabel = kind == "salvage" and "Expected Value" or valueLabel
    local labels={{"Item","name"},{costLabel,"buyout"},{displayValueLabel,"value"},{kind=="deals" and "Gross spread" or "Profit","profit"},{"ROI","roi"}}
    if kind=="salvage" then table.insert(labels,2,{"Qty loaded","quantityAtPrice"}) end
    local function place(region,owner,l,r,pad)
        region:ClearAllPoints(); region:SetPoint("LEFT",owner,"LEFT",l,0); region:SetWidth(math.max(1,r-l-(pad or 0)))
    end
    local function layout(width)
        for i,entry in ipairs(labels) do
            local left=math.floor(width*widths[i]); local right=math.floor(width*widths[i+1]); place(view.headers[entry[2]],header,left,right,2)
        end
        for _,row in ipairs(view.rows) do
            local fields={row.Name,row.Buyout,row.Value,row.Profit,row.ROI}
            if row.Quantity then table.insert(fields,2,row.Quantity) end
            for i,field in ipairs(fields) do local left=math.floor(width*widths[i]); local right=math.floor(width*widths[i+1]); place(field,row,left+(i==1 and 27 or 4),right,8) end
        end
    end
    for _,entry in ipairs(labels) do
        local button=CreateFrame("Button",nil,header)
        button.label=entry[1]
        button:SetHeight(22)
        button:SetFrameLevel(header:GetFrameLevel()+1)
        button:SetHighlightTexture("Interface\QuestFrame\UI-QuestTitleHighlight","ADD")
        button.Label=button:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        button.Label:SetAllPoints(); button.Label:SetJustifyH(entry[2]=="name" and "LEFT" or "CENTER"); button.Label:SetTextColor(1,.82,0); button.Label:SetText(entry[1])
        button:SetScript("OnClick",function()
            if view.sortKey==entry[2] then view.ascending=not view.ascending
            else view.sortKey=entry[2]; view.ascending=entry[2]=="name" or entry[2]=="buyout" end
            view.offset=0
            refreshView(view)
        end)
        view.headers[entry[2]]=button
    end
    local previous
    for i=1,view.pageSize do
        local row=CreateFrame("Button",nil,frame); row:SetHeight(25); row:SetPoint("LEFT",header); row:SetPoint("RIGHT",header); row:SetPoint("TOP",previous or header,"BOTTOM")
        local rb=row:CreateTexture(nil,"BACKGROUND"); rb:SetAllPoints(); rb:SetColorTexture(i%2==0 and .10 or .035,i%2==0 and .10 or .035,i%2==0 and .10 or .035,.75)
        local line=row:CreateTexture(nil,"BORDER"); line:SetPoint("BOTTOMLEFT"); line:SetPoint("BOTTOMRIGHT"); line:SetHeight(1); line:SetColorTexture(.31,.27,.19,.72)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetHighlightTexture("Interface\QuestFrame\UI-QuestTitleHighlight","ADD"); row:SetScript("OnClick",function(self,button)
            if button=="RightButton" and view.kind=="salvage" and DXMVendorFinder and DXMVendorFinder.BuyResult then
                DXMVendorFinder.BuyResult(self.result)
            elseif IsModifiedClick and IsModifiedClick("CHATLINK") and self.result and self.result.link then
                ChatEdit_InsertLink(self.result.link)
            elseif DXMVendorFinder and DXMVendorFinder.OpenResult then
                DXMVendorFinder.OpenResult(self.result)
            else
                openResult(self.result)
            end
        end)
        row:SetScript("OnEnter",function(self) local r=self.result if not r then return end GameTooltip:SetOwner(self,"ANCHOR_RIGHT"); if r.link then GameTooltip:SetHyperlink(r.link) end; GameTooltip:AddLine(" "); GameTooltip:AddDoubleLine("Cost",money(r.buyout),1,.82,0,1,1,1); GameTooltip:AddDoubleLine(valueLabel,r.value and money(r.value) or "--",1,.82,0,1,1,1); GameTooltip:AddDoubleLine(view.kind=="deals" and "Gross spread" or "Expected profit",r.profit and money(r.profit) or "--",.2,1,.2,1,1,1); GameTooltip:AddDoubleLine("ROI",r.roi and ("%.0f%%"):format(r.roi) or "--",1,.82,0,1,1,1); if r.detail then GameTooltip:AddLine(r.detail,.75,.75,.75,true) end; GameTooltip:Show() end)
        row:SetScript("OnLeave",function() GameTooltip:Hide() end)
        row.Icon=row:CreateTexture(nil,"ARTWORK"); row.Icon:SetSize(22,22); row.Icon:SetPoint("LEFT",2,0)
        local names={"Name","Buyout","Value","Profit","ROI"}; if kind=="salvage" then table.insert(names,2,"Quantity") end; for _,n in ipairs(names) do row[n]=row:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); row[n]:SetJustifyH(n=="Name" and "LEFT" or "RIGHT") end
        view.rows[i]=row; previous=row
    end
    header:SetScript("OnSizeChanged",function(_,w) if w>0 then layout(w) end end); C_Timer.After(0,function() if header:GetWidth()>0 then layout(header:GetWidth()) end end)
    view.Previous=CreateFrame("Button",nil,page,"UIPanelButtonTemplate"); view.Previous:SetSize(28,22); view.Previous:SetPoint("TOPLEFT",frame,"BOTTOMLEFT",4,-6); view.Previous:SetText("<"); view.Previous:SetScript("OnClick",function() view.offset=view.offset-view.pageSize; refreshView(view) end)
    view.Next=CreateFrame("Button",nil,page,"UIPanelButtonTemplate"); view.Next:SetSize(28,22); view.Next:SetPoint("LEFT",view.Previous,"RIGHT",5,0); view.Next:SetText(">"); view.Next:SetScript("OnClick",function() view.offset=view.offset+view.pageSize; refreshView(view) end)
    view.Count=page:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); view.Count:SetPoint("LEFT",view.Next,"RIGHT",10,0)
    refreshView(view)
    return view
end
local function process(items)
    processGeneration = processGeneration + 1
    resetSalvageQuantities()
    local generation = processGeneration
    wipe(dealResults); wipe(salvageResults); lastItems=items or {}
    lastScanCount = #lastItems
    maxDealSamples = 0
    unsupportedDeals = 0
    wipe(salvageMissingMaterials)
    wipe(materialHistoryKeys)
    wipe(materialPriceCache)
    wipe(scanMarketValueCache)
    for _, item in ipairs(lastItems) do
        local itemID = item.itemKey and item.itemKey.itemID
        if itemID and item.id then materialHistoryKeys[itemID] = item.id end
    end

    local position = 1
    local minimumBatchSize = 75
    local maximumBatchSize = 300
    local frameBudgetMS = 6
    local function finish()
        if generation ~= processGeneration then return end
        for _,view in ipairs(views) do
            view.offset=0
            if view.Status then view.Status:SetText(view.intro or "") end
            refreshView(view)
        end
        if scannerStatus then
            scannerStatus:SetText(("Last scan: %d items, %d deals, %d salvage opportunities."):format(lastScanCount, #dealResults, #salvageResults))
        end
    end
    local function step()
        if generation ~= processGeneration then return end
        local started = debugprofilestop and debugprofilestop() or nil
        local processed = 0
        while position <= #lastItems and processed < maximumBatchSize do
            local info=itemInfo(lastItems[position])
            if info and info.buyout>0 then
                local value,samples,detail=scanMarketValue(info.id,info.buyout)
                if not value then unsupportedDeals = unsupportedDeals + 1 end
                maxDealSamples = math.max(maxDealSamples, tonumber(samples) or 0)
                if value and value>info.buyout then
                    dealResults[#dealResults+1]={itemID=info.itemID,sequence=#dealResults+1,name=info.name,link=info.link,icon=info.icon,quality=info.quality,buyout=info.buyout,value=value,profit=value-info.buyout,roi=(value-info.buyout)/info.buyout*100,samples=samples,browseResult=info.browseResult,detail=detail}
                end
                local salvage,outputs,missing,observedAttempts=salvageValue(info)
                if missing then salvageMissingMaterials[missing:gsub("^Missing price for ", "")] = true end
                local possible=possibleSalvageOutputs(info)
                if next(possible) then
                    local basis=observedAttempts and ("Observed from %d disenchant%s: "):format(observedAttempts,observedAttempts==1 and "" or "s") or "Reference estimate: "
                    salvageResults[#salvageResults+1]={itemID=info.itemID,itemKey=info.itemKey,sequence=#salvageResults+1,name=info.name,link=info.link,icon=info.icon,quality=info.quality,buyout=info.buyout,maximumBuyout=info.buyout,value=salvage,purchaseLimit=salvage,profit=salvage and salvage-info.buyout or nil,roi=salvage and (salvage-info.buyout)/info.buyout*100 or nil,browseResult=info.browseResult,detail=basis..(outputs or missing or "No valuation available"),observedAttempts=observedAttempts,possibleOutputs=possible}
                end
            end
            position = position + 1
            processed = processed + 1
            if processed >= minimumBatchSize and started and debugprofilestop() - started >= frameBudgetMS then break end
        end
        if position <= #lastItems then
            local message = ("Analyzing market data: %d / %d items..."):format(position - 1, #lastItems)
            if scannerStatus then scannerStatus:SetText(message) end
            for _, view in ipairs(views) do if view.Status then view.Status:SetText(message) end end
            C_Timer.After(0, step)
        else
            finish()
        end
    end
    step()
end

local function buildDeals(page)
    local view=buildTable(page,function() return dealResults end,"Listing baseline","Discounts supported by recent price history. Resale is not guaranteed.","deals")
    view.intro="Discounts supported by recent price history. Resale is not guaranteed."
end
local function buildSalvage(page)
    local view=buildTable(page,function() return salvageResults end,"Salvage Value","Same item and price, suffixes combined. Qty: + = more variants to load; values are per unit.","salvage")
    view.intro="Same item and price, suffixes combined. Qty: + = more variants to load; values are per unit."
end

local function historySummary()
    local realms, items, observations = 0, 0, 0
    for _, realmData in pairs(DXMPriceHistoryData or {}) do
        if type(realmData) == "table" then
            realms = realms + 1
            for _, entries in pairs(realmData) do
                if type(entries) == "table" then
                    items = items + 1
                    observations = observations + #entries
                end
            end
        end
    end
    return realms, items, observations
end

local function buildScanner(page)
    local button=CreateFrame("Button",nil,page,"UIPanelButtonTemplate")
    button:SetSize(180,30); button:SetPoint("TOPLEFT",page.Description,"BOTTOMLEFT",0,-20); button:SetText("Scan Auction House")
    button:SetScript("OnClick",function() startScan("scanner") end)
    scannerStatus=page:CreateFontString(nil,"ARTWORK","GameFontHighlight")
    scannerStatus:SetPoint("TOPLEFT",button,"BOTTOMLEFT",0,-18); scannerStatus:SetPoint("RIGHT",page,"RIGHT",-20,0)
    scannerStatus:SetJustifyH("LEFT"); scannerStatus:SetJustifyV("TOP")
    local realms,items,observations=historySummary()
    scannerStatus:SetText(("Ready to scan. Stored history: %d items, %d observations across %d market partitions."):format(items,observations,realms))
    local help=page:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall")
    help:SetPoint("TOPLEFT",scannerStatus,"BOTTOMLEFT",0,-24); help:SetPoint("RIGHT",page,"RIGHT",-20,0); help:SetJustifyH("LEFT"); help:SetJustifyV("TOP")
    help:SetText("One scan updates Vendor Finder, Valuation, Deals, and DXM Salvage.\n\nDeals requires at least 6 distinct hours spanning a day, including 3 recent hours. Prices above twice the estimated fair average are excluded. Valuation and Salvage can begin using history after the first completed scan.")
end

local valuationText
local valuationSlot
local valuationItemID

local function showValuation(itemID)
    itemID = tonumber(itemID)
    valuationItemID = itemID
    if not itemID then
        if valuationSlot then valuationSlot.Icon:SetTexture(nil); valuationSlot.itemID = nil end
        valuationText:SetText("Drag an item from your bags onto the box above.")
        return
    end
    local name, link, quality, _, _, _, _, _, _, icon, vendor = C_Item.GetItemInfo(itemID)
    if valuationSlot then
        valuationSlot.itemID = itemID
        valuationSlot.Icon:SetTexture(icon or 134400)
    end
    if not name then
        if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
        valuationText:SetText("Item data is loading...")
        return
    end
    local value, samples = marketValue(itemID, 1)
    local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality or 1]
    local hex = color and color.hex or "ffffffff"
    valuationText:SetText(table.concat({
        hex .. name .. "|r", "",
        "Vendor: " .. money(vendor),
        "DXM market value: " .. (value and money(value) or "No history yet"),
        "Historical samples: " .. (samples or 0), "",
        "Pricing: median of available DXM sources,",
        "using the conservative 15th percentile."
    }, "\n"))
end

local valuationItemEvent = CreateFrame("Frame")
valuationItemEvent:RegisterEvent("GET_ITEM_INFO_RECEIVED")
valuationItemEvent:SetScript("OnEvent", function(_, _, itemID, success)
    if success and tonumber(itemID) == valuationItemID and valuationText then showValuation(itemID) end
end)

local function buildValuation(page)
    valuationSlot = CreateFrame("Button", "DXMValuationItemSlot", page)
    valuationSlot:SetSize(64, 64)
    valuationSlot:SetPoint("TOPLEFT", page.Description, "BOTTOMLEFT", 4, -20)
    valuationSlot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    valuationSlot:RegisterForDrag("LeftButton")
    valuationSlot:SetNormalTexture("Interface\\Buttons\\UI-Quickslot2")
    valuationSlot:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
    valuationSlot:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    valuationSlot.Icon = valuationSlot:CreateTexture(nil, "ARTWORK")
    valuationSlot.Icon:SetPoint("TOPLEFT", 7, -7)
    valuationSlot.Icon:SetPoint("BOTTOMRIGHT", -7, 7)
    valuationSlot.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local prompt = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    prompt:SetPoint("LEFT", valuationSlot, "RIGHT", 14, 8)
    prompt:SetText("Drop an item here")
    local hint = page:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", prompt, "BOTTOMLEFT", 0, -6)
    hint:SetText("Drag from your bags. Right-click the slot to clear it.")

    valuationText = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    valuationText:SetPoint("TOPLEFT", valuationSlot, "BOTTOMLEFT", -4, -20)
    valuationText:SetPoint("RIGHT", page, "RIGHT", -20, 0)
    valuationText:SetJustifyH("LEFT")
    valuationText:SetJustifyV("TOP")
    valuationText:SetHeight(150)
    if valuationText.SetWordWrap then valuationText:SetWordWrap(true) end

    local function acceptCursorItem()
        local cursorType, itemID, itemLink = GetCursorInfo()
        if cursorType ~= "item" then return end
        if not itemID and itemLink and C_Item.GetItemInfoInstant then itemID = C_Item.GetItemInfoInstant(itemLink) end
        if itemID then
            ClearCursor()
            showValuation(itemID)
        end
    end
    valuationSlot:SetScript("OnReceiveDrag", acceptCursorItem)
    valuationSlot:SetScript("OnClick", function(_, button)
        if button == "RightButton" then showValuation(nil) else acceptCursorItem() end
    end)
    valuationSlot:SetScript("OnEnter", function(self)
        if not self.itemID then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.itemID) end
        GameTooltip:Show()
    end)
    valuationSlot:SetScript("OnLeave", function() GameTooltip:Hide() end)
    showValuation(nil)
end

function Module:Boot(hook) hook(Const.ScannerPurchaseCompleted,Module.PurchaseCompleted); hook(Const.ScannerItemsCompleted,Module.ScannerItemsCompleted); hook(Const.SellItemLoaded,Module.SellItemLoaded) end
function Module:PurchaseCompleted()
    for _,view in ipairs(views) do if view.kind=="salvage" then refreshView(view) end end
end
function Module:ScannerItemsCompleted(items)
    -- History is appended by a later scan listener. Defer calculations one frame
    -- so Deals, Valuation, and Salvage immediately see the completed scan.
    C_Timer.After(0, function() process(items) end)
end
function Module:SellItemLoaded(itemType,itemLocation)
    if not itemType or not itemLocation or not valuationText then return end
    local key=C_AuctionHouse.GetItemKeyFromItem(itemLocation); if key then showValuation(key.itemID) end
end

DXMSalvage = {
    CanDisenchant = function(item)
        local getter=C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
        local itemID=item and getter and tonumber((getter(item))) or tonumber(item)
        if not itemID then return false end
        local name, link, quality, level, _, itemType, itemSubType, maxStack, equipLoc, icon, vendor, classID = C_Item.GetItemInfo(item)
        if not name and item~=itemID then
            name, link, quality, level, _, itemType, itemSubType, maxStack, equipLoc, icon, vendor, classID = C_Item.GetItemInfo(itemID)
        end
        if not name then
            if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
            return false
        end
        local info={itemID=itemID,name=name,link=link,quality=quality or 1,level=level or 0,itemType=itemType,itemSubType=itemSubType,maxStack=maxStack or 1,equipLoc=equipLoc,icon=icon,vendor=vendor or 0,classID=classID}
        return salvageYield(info,true)~=nil,info
    end,
    Value = function(itemID)
        itemID = tonumber(itemID)
        if not itemID then return end
        local name, link, quality, level, _, itemType, itemSubType, maxStack, equipLoc, icon, vendor, classID = C_Item.GetItemInfo(itemID)
        if not name then return end
        return salvageValue({itemID=itemID, name=name, link=link, quality=quality or 1, level=level or 0, itemType=itemType, itemSubType=itemSubType, maxStack=maxStack or 1, equipLoc=equipLoc, icon=icon, vendor=vendor or 0, classID=classID})
    end,
    MaterialValue = function(itemID)
        return materialMarketValue(itemID)
    end,
}
DXMExchange:RegisterPageBuilder("scanner",buildScanner)
DXMExchange:RegisterPageBuilder("deals",buildDeals)
DXMExchange:RegisterPageBuilder("valuation",buildValuation)
DXMExchange:RegisterPageBuilder("salvage",buildSalvage)
