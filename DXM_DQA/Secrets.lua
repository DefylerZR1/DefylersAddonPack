local data = DQASecretData
local function modules()
    DQADB.modules = DQADB.modules or {}
    local m = DQADB.modules
    if m.objectiveMarkers == nil then m.objectiveMarkers = DQADB.enabled ~= false end
    if m.secrets == nil then m.secrets = true end
    if m.sleepingBag == nil then m.sleepingBag = true end
    if m.mageBooks == nil then m.mageBooks = true end
    if m.autoOpenMap == nil then m.autoOpenMap = true end
    return m
end

local function completed(id)
    if not id or not C_QuestLog or not C_QuestLog.IsQuestFlaggedCompleted then return false end
    local ok, result = pcall(C_QuestLog.IsQuestFlaggedCompleted, id)
    return ok and result == true
end

local function active(id)
    if not id or not C_QuestLog or not C_QuestLog.GetLogIndexForQuestID then return false end
    local ok, index = pcall(C_QuestLog.GetLogIndexForQuestID, id)
    return ok and type(index) == "number" and index > 0
end

local function sleepingSteps()
    local bag = data.sleepingBag
    local horde = UnitFactionGroup("player") == "Horde"
    local result = { horde and bag.hordeStart or bag.allianceStart, horde and bag.hordeCross or bag.allianceCross }
    for _, step in ipairs(bag.shared) do result[#result + 1] = step end
    return result
end

function DQA_GetSleepingBagProgress()
    local steps, done, activeStep = sleepingSteps(), 0, nil
    for index, step in ipairs(steps) do
        if completed(step.questID) then
            done = index
        elseif not activeStep and active(step.questID) then
            activeStep = step
        end
    end
    if completed(79976) then done = #steps end
    return done, #steps, activeStep or steps[math.min(done + 1, #steps)], steps
end

local inventoryBooks = {}
local bankBooks = {}
local mageBookNames = {}
for _, book in ipairs(data.mageBooks) do mageBookNames[book[2]] = true end
local bankOpen = false
local mageBookProvider
local ensureMageBookProvider
local directMageBookPins = {}
local mageBookDebug = { canvas = "none", matches = 0 }

local function projectBookToMap(book, displayedMapID)
    if not book or not displayedMapID then return end
    local currentMapID = book[3]
    local x, y = book[4] / 100, book[5] / 100
    if currentMapID == displayedMapID then return x, y, true end
    if not C_Map or not C_Map.GetMapInfo or not C_Map.GetMapRectOnMap then return end
    for _ = 1, 8 do
        local okInfo, info = pcall(C_Map.GetMapInfo, currentMapID)
        local parentMapID = okInfo and info and info.parentMapID
        if not parentMapID or parentMapID == 0 or parentMapID == currentMapID then return end
        local okRect, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, currentMapID, parentMapID)
        if not okRect or type(minX) ~= "number" or type(maxX) ~= "number"
            or type(minY) ~= "number" or type(maxY) ~= "number" then return end
        x = minX + (maxX - minX) * x
        y = minY + (maxY - minY) * y
        currentMapID = parentMapID
        if currentMapID == displayedMapID then return x, y, false end
    end
end

local function bookPinSize(book, displayedMapID, exactZone)
    if not exactZone then return 20 end
    if not C_Map or not C_Map.GetBestMapForUnit or not C_Map.GetPlayerMapPosition then return 30 end
    local okMap, playerMapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not okMap or playerMapID ~= displayedMapID then return 30 end
    local okPosition, position = pcall(C_Map.GetPlayerMapPosition, displayedMapID, "player")
    if not okPosition or not position or not position.GetXY then return 30 end
    local okXY, playerX, playerY = pcall(position.GetXY, position)
    if not okXY or type(playerX) ~= "number" or type(playerY) ~= "number" then return 30 end
    local dx, dy = playerX - book[4] / 100, playerY - book[5] / 100
    local distance = math.sqrt(dx * dx + dy * dy)
    if distance <= .03 then return 14 end
    if distance <= .08 then return 20 end
    return 30
end
local function scanBags()
    wipe(inventoryBooks)
    local lastBag = NUM_BAG_SLOTS or 4
    if Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag then lastBag = Enum.BagIndex.ReagentBag end
    for bag = 0, lastBag do
        local count = C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, count do
            local link = C_Container.GetContainerItemLink(bag, slot)
            local name = link and link:match("%[(.-)%]")
            if name then inventoryBooks[name] = true end
        end
    end
end

local function characterKey()
    return (UnitName("player") or "Unknown") .. "-" .. (GetRealmName and GetRealmName() or "Realm")
end

local function collectedBookStore()
    DQADB.collectedMageBooks = DQADB.collectedMageBooks or {}
    local key = characterKey()
    DQADB.collectedMageBooks[key] = DQADB.collectedMageBooks[key] or {}
    return DQADB.collectedMageBooks[key]
end

local function rememberCollectedBooks(source)
    local collected = collectedBookStore()
    for name in pairs(source) do
        if mageBookNames[name] then collected[name] = true end
    end
end

local function scanContainerForBooks(bag, destination)
    local count = C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerNumSlots(bag) or 0
    for slot = 1, count do
        local link = C_Container.GetContainerItemLink(bag, slot)
        local name = link and link:match("%[(.-)%]")
        if name then destination[name] = true end
    end
end

local function loadBankBooks()
    DQADB.bankMageBooks = DQADB.bankMageBooks or {}
    wipe(bankBooks)
    for name, present in pairs(DQADB.bankMageBooks[characterKey()] or {}) do
        if present then bankBooks[name] = true end
    end
end

local function scanBank()
    if not bankOpen then return end
    wipe(bankBooks)
    scanContainerForBooks(BANK_CONTAINER or -1, bankBooks)
    local purchased = GetNumBankSlots and GetNumBankSlots() or (NUM_BANKBAGSLOTS or 7)
    local firstBankBag = (NUM_BAG_SLOTS or 4) + 1
    for bag = firstBankBag, firstBankBag + math.max(0, purchased) - 1 do
        scanContainerForBooks(bag, bankBooks)
    end
    DQADB.bankMageBooks = DQADB.bankMageBooks or {}
    DQADB.bankMageBooks[characterKey()] = {}
    for name in pairs(bankBooks) do DQADB.bankMageBooks[characterKey()][name] = true end
    rememberCollectedBooks(bankBooks)
end

function DQA_GetMageBookProgress()
    local done, held, missing = 0, 0, {}
    local collected = collectedBookStore()
    for _, book in ipairs(data.mageBooks) do
        if inventoryBooks[book[2]] or bankBooks[book[2]] then
            held = held + 1
            collected[book[2]] = true
        elseif collected[book[2]] then
            done = done + 1
        else
            missing[#missing + 1] = book
        end
    end
    return done, held, #data.mageBooks, missing
end

local function bookLocationKey(book)
    return tostring(book and (book[1] or book[2]) or "")
end

local function bookLocationStore()
    DQADB.mageBookLocations = DQADB.mageBookLocations or {}
    local character = (UnitName("player") or "Unknown") .. "-" .. (GetRealmName and GetRealmName() or "Realm")
    DQADB.mageBookLocations[character] = DQADB.mageBookLocations[character] or {}
    return DQADB.mageBookLocations[character]
end

function DQA_IsMageBookLocationEnabled(book)
    local value = bookLocationStore()[bookLocationKey(book)]
    return value ~= false
end

function DQA_SetMageBookLocationEnabled(book, enabled)
    if not book then return end
    bookLocationStore()[bookLocationKey(book)] = enabled and true or false
    local provider = mageBookProvider
    if provider then provider:RefreshAllData() end
end

function DQA_EnableConfiguredMageBookPins()
    modules().showAllMageBooks = true
    local provider = ensureMageBookProvider()
    if provider then provider:RefreshAllData() end
end

function DQA_IsMageBookFound(book)
    if not book then return false end
    return collectedBookStore()[book[2]] == true
        or inventoryBooks[book[2]] == true
        or bankBooks[book[2]] == true
end

ensureMageBookProvider = function()
    if mageBookProvider then return mageBookProvider end
    if not WorldMapFrame or not WorldMapFrame.GetMapID then return end
    -- Classic's visible map texture is the scroll container's child. GetCanvas
    -- can resolve to a wrapper frame, which accepts our buttons but never draws
    -- them over the zone texture.
    local canvas = WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
    if canvas then mageBookDebug.canvas = "ScrollContainer.Child"
    elseif WorldMapFrame.GetCanvas then
        canvas = WorldMapFrame:GetCanvas()
        mageBookDebug.canvas = "GetCanvas"
    end
    if not canvas then return end
    mageBookProvider = {}
    function mageBookProvider:RemoveAllData()
        for _, pin in ipairs(directMageBookPins) do pin:Hide() end
    end
    function mageBookProvider:RefreshAllData()
        self:RemoveAllData()
        mageBookDebug.matches = 0
        if not modules().showAllMageBooks or not WorldMapFrame:IsShown() then return end
        local mapID = WorldMapFrame:GetMapID()
        local width, height = canvas:GetWidth(), canvas:GetHeight()
        if not mapID or not width or width <= 0 or not height or height <= 0 then return end
        local _, _, _, missing = DQA_GetMageBookProgress()
        local index = 0
        for _, book in ipairs(missing) do
            local x, y, exactZone = projectBookToMap(book, mapID)
            if x and y and DQA_IsMageBookLocationEnabled(book) then
                index = index + 1
                mageBookDebug.matches = index
                local pin = directMageBookPins[index]
                if not pin then
                    pin = CreateFrame("Button", nil, canvas)
                    pin:SetSize(30, 30); pin:RegisterForClicks("LeftButtonUp")
                    pin:SetFrameStrata("TOOLTIP")
                    pin.Icon = pin:CreateTexture(nil, "OVERLAY", nil, 7)
                    pin.Icon:SetAllPoints()
                    pin.Icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
                    pin.Icon:SetTexCoord(.08,.92,.08,.92)
                    pin.Border = pin:CreateTexture(nil, "OVERLAY", nil, 6)
                    pin.Border:SetPoint("TOPLEFT",-2,2); pin.Border:SetPoint("BOTTOMRIGHT",2,-2)
                    pin.Border:SetColorTexture(.82,.62,.12,1)
                    pin:SetScript("OnEnter",function(self)
                        GameTooltip:SetOwner(self,"ANCHOR_RIGHT"); GameTooltip:SetText(self.book[2])
                        GameTooltip:AddLine("Click to set this waypoint.",.45,.8,1); GameTooltip:Show()
                    end)
                    pin:SetScript("OnLeave",GameTooltip_Hide)
                    pin:SetScript("OnClick",function(self) DQA_SetSecretWaypoint(self.book) end)
                    directMageBookPins[index] = pin
                end
                pin.book = book
                local pinSize = bookPinSize(book, mapID, exactZone)
                pin:SetSize(pinSize, pinSize)
                pin:SetParent(canvas); pin:ClearAllPoints()
                -- The world-map canvas clips its upper and lower overlays. Keep
                -- edge locations visible while retaining the exact coordinates
                -- on the book and its waypoint.
                local displayX = math.max(.025, math.min(.975, x))
                local displayY = math.max(.025, math.min(.975, y))
                pin:SetPoint("CENTER",canvas,"TOPLEFT",width*displayX,-height*displayY)
                pin:SetFrameLevel(500); pin:Show()
            end
        end
    end
    local lastMapID,lastWidth,lastHeight,positionRefreshAt
    WorldMapFrame:HookScript("OnShow",function() lastMapID=nil; C_Timer.After(0,function() mageBookProvider:RefreshAllData() end) end)
    WorldMapFrame:HookScript("OnHide",function() mageBookProvider:RemoveAllData() end)
    WorldMapFrame:HookScript("OnUpdate",function()
        local mapID=WorldMapFrame:GetMapID(); local width,height=canvas:GetWidth(),canvas:GetHeight()
        if mapID~=lastMapID or width~=lastWidth or height~=lastHeight then
            lastMapID,lastWidth,lastHeight=mapID,width,height
            mageBookProvider:RefreshAllData()
            positionRefreshAt=GetTime()
        elseif not positionRefreshAt or GetTime()-positionRefreshAt>=.5 then
            positionRefreshAt=GetTime()
            mageBookProvider:RefreshAllData()
        end
    end)
    return mageBookProvider
end

SLASH_DQABOOKS1 = "/dqabooks"
SlashCmdList.DQABOOKS = function()
    local target
    for _, book in ipairs(data.mageBooks) do
        if book[2] == "Arcanic Systems Manual" then target = book break end
    end
    local mapID = WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
    local collected = target and collectedBookStore()[target[2]] == true
    local carried = target and inventoryBooks[target[2]] == true
    local banked = target and bankBooks[target[2]] == true
    local enabled = target and DQA_IsMageBookLocationEnabled(target)
    if mageBookProvider then mageBookProvider:RefreshAllData() end
    print(("DQA books: map=%s expected=%s shown=%s canvas=%s pins=%d"):format(
        tostring(mapID), tostring(target and target[3]), tostring(WorldMapFrame and WorldMapFrame:IsShown()),
        mageBookDebug.canvas, mageBookDebug.matches))
    print(("DQA Arcanic: collected=%s carried=%s banked=%s checked=%s showAll=%s"):format(
        tostring(collected), tostring(carried), tostring(banked), tostring(enabled),
        tostring(modules().showAllMageBooks)))
end

function DQA_SetAllMageBookPinsShown(shown)
    modules().showAllMageBooks = shown and true or false
    local provider = mageBookProvider or (modules().showAllMageBooks and ensureMageBookProvider())
    if shown and modules().autoOpenMap and C_Map and C_Map.OpenWorldMap and not InCombatLockdown() then
        -- Azeroth overview: both continents can display every missing book.
        pcall(C_Map.OpenWorldMap, 947)
    end
    if provider then
        -- OpenWorldMap changes the displayed map after this click begins.
        -- Refresh on the next frame so pins are evaluated against that zone.
        C_Timer.After(0, function()
            if mageBookProvider then mageBookProvider:RefreshAllData() end
        end)
    end
end

function DQA_AreAllMageBookPinsShown()
    return modules().showAllMageBooks == true
end

function DQA_SetSecretWaypoint(entry)
    if not entry or not C_Map or not C_Map.SetUserWaypoint or not UiMapPoint then return false end
    local mapID, x, y = entry.mapID or entry[3], entry.x or entry[4], entry.y or entry[5]
    local ok, point = pcall(UiMapPoint.CreateFromCoordinates, mapID, x / 100, y / 100)
    if not ok or not point then return false end
    if not pcall(C_Map.SetUserWaypoint, point) then return false end
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true) end
    if modules().autoOpenMap and C_Map.OpenWorldMap and not InCombatLockdown() then pcall(C_Map.OpenWorldMap, mapID) end
    return true
end

function DQA_SecretsRefresh()
    modules()
    scanBags()
    if bankOpen then scanBank() end
    local provider = ensureMageBookProvider()
    if provider then provider:RefreshAllData() end
    if DQA_RefreshSettings then DQA_RefreshSettings() end
end

local secretEvents = CreateFrame("Frame")
secretEvents:SetScript("OnEvent", function(_, eventName)
    if eventName == "PLAYER_LOGIN" then loadBankBooks()
    elseif eventName == "BANKFRAME_OPENED" then bankOpen = true
    elseif eventName == "BANKFRAME_CLOSED" then bankOpen = false end
    DQA_SecretsRefresh()
end)
for _, eventName in ipairs({"PLAYER_LOGIN","ADDON_LOADED","QUEST_LOG_UPDATE","QUEST_ACCEPTED","QUEST_TURNED_IN","BAG_UPDATE_DELAYED","BANKFRAME_OPENED","BANKFRAME_CLOSED","PLAYERBANKSLOTS_CHANGED"}) do
    pcall(secretEvents.RegisterEvent, secretEvents, eventName)
end
