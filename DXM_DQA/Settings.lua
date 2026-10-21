local frame
local bookLocationsFrame
local bookLocationRows = {}
local rows = {}
local GOLD = {1, .82, .18}

local function addText(parent, template, text)
    local fs = parent:CreateFontString(nil, "ARTWORK", template)
    fs:SetText(text or "")
    return fs
end

local function checkbox(parent, label, key, x, y, dependency)
    local box = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    box:SetPoint("TOPLEFT", x, y)
    box:SetSize(24, 24)
    local text = addText(parent, "GameFontHighlight", label)
    text:SetPoint("LEFT", box, "RIGHT", 3, 0)
    box.Label = text
    box:SetScript("OnClick", function(self)
        DQADB.modules[key] = self:GetChecked() and true or false
        if key == "objectiveMarkers" and DQA_SetObjectiveMarkersEnabled then DQA_SetObjectiveMarkersEnabled(DQADB.modules[key]) end
        if key == "killCounter" and DQA_RefreshNameplateMarkers then DQA_RefreshNameplateMarkers() end
        if (key == "secrets" or key == "mageBooks") and not DQADB.modules[key]
            and DQA_SetAllMageBookPinsShown then DQA_SetAllMageBookPinsShown(false) end
        DQA_RefreshSettings()
    end)
    rows[#rows + 1] = {box=box, key=key, dependency=dependency}
    return box
end

local function button(parent, text, width, callback)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 24); b:SetText(text); b:SetScript("OnClick", callback)
    return b
end

local function refreshBookLocations()
    if not bookLocationsFrame then return end
    local found, held, total = DQA_GetMageBookProgress()
    bookLocationsFrame.Status:SetText("Checked books are marked automatically. Uncheck one to hide it.")
    local grouped, zones = {}, {}
    for _, book in ipairs(DQASecretData.mageBooks) do
        local zone = book[6]
        if not grouped[zone] then grouped[zone] = {}; zones[#zones + 1] = zone end
        grouped[zone][#grouped[zone] + 1] = book
    end
    table.sort(zones)
    local entries = {}
    for _, zone in ipairs(zones) do
        entries[#entries + 1] = {zone=zone}
        for _, book in ipairs(grouped[zone]) do entries[#entries + 1] = {book=book} end
    end
    local needed = #entries
    bookLocationsFrame.Child:SetHeight(math.max(450, needed * 30 + 8))
    for index = 1, needed do
        local row = bookLocationRows[index]
        if not row then
            row = CreateFrame("Frame",nil,bookLocationsFrame.Child)
            row:SetSize(560,26)
            row:SetPoint("TOPLEFT", 4, -4 - (index - 1) * 30)
            row.Zone=addText(row,"GameFontNormal",""); row.Zone:SetPoint("LEFT",4,0); row.Zone:SetTextColor(unpack(GOLD))
            row.Check=CreateFrame("CheckButton",nil,row,"UICheckButtonTemplate"); row.Check:SetSize(24,24); row.Check:SetPoint("LEFT",0,0)
            row.Label=addText(row,"GameFontHighlightSmall",""); row.Label:SetPoint("LEFT",row.Check,"RIGHT",3,0); row.Label:SetWidth(520); row.Label:SetJustifyH("LEFT")
            row.Check:SetScript("OnClick",function(self)
                local owner=self:GetParent()
                if owner.book then DQA_SetMageBookLocationEnabled(owner.book,self:GetChecked()); refreshBookLocations() end
            end)
            bookLocationRows[index] = row
        end
        local entry=entries[index]
        row.book=entry.book
        if entry.zone then
            row.Zone:SetText(entry.zone); row.Zone:Show(); row.Check:Hide(); row.Label:Hide()
        else
            local book=entry.book
            local bookFound=DQA_IsMageBookFound(book)
            row.Zone:Hide(); row.Check:Show(); row.Label:Show()
            row.Check:SetChecked(not bookFound and DQA_IsMageBookLocationEnabled(book))
            row.Check:SetEnabled(not bookFound)
            local shortName=book[2]
            if #shortName>26 then shortName=shortName:sub(1,23).."..." end
            row.Label:SetText(shortName..(bookFound and "  |cff66dd88Found|r" or ""))
            row.Label:SetTextColor(bookFound and .45 or 1,bookFound and .65 or 1,bookFound and .5 or 1)
        end
        row:Show()
    end
    for index = needed + 1, #bookLocationRows do bookLocationRows[index]:Hide() end
end

local function openBookLocations()
    if not bookLocationsFrame then
        local f = CreateFrame("Frame", "DQAMageBookLocationsFrame", UIParent, "BackdropTemplate")
        f:SetSize(610, 520); f:SetFrameStrata("DIALOG"); f:SetClampedToScreen(true)
        f:SetFrameLevel(((frame and frame:GetFrameLevel()) or 1)+20)
        if f.SetToplevel then f:SetToplevel(true) end
        if frame and frame:IsShown() then f:SetPoint("LEFT",frame,"RIGHT",18,0) else f:SetPoint("CENTER",UIParent,"CENTER",330,0) end
        f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8", edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize=24, insets={left=6,right=6,top=6,bottom=6}})
        f:SetBackdropColor(.025,.03,.055,.98)
        local title=addText(f,"GameFontNormalLarge","Configure Book Locations"); title:SetPoint("TOP",0,-18); title:SetTextColor(.79,.62,.95)
        local close=CreateFrame("Button",nil,f,"UIPanelCloseButton"); close:SetPoint("TOPRIGHT",-5,-5)
        f.Status=addText(f,"GameFontHighlightSmall",""); f.Status:SetPoint("TOPLEFT",24,-50)
        local scroll=CreateFrame("ScrollFrame",nil,f,"UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT",20,-76); scroll:SetPoint("BOTTOMRIGHT",-42,22)
        local child=CreateFrame("Frame",nil,scroll); child:SetSize(568,450); scroll:SetScrollChild(child)
        f.Child=child
        f:SetScript("OnShow",function(self)
            self:SetFrameLevel(((frame and frame:GetFrameLevel()) or 1)+20)
            self:Raise()
            refreshBookLocations()
        end)
        bookLocationsFrame=f
        f:Hide()
    end
    if bookLocationsFrame:IsShown() then bookLocationsFrame:Hide() else
        bookLocationsFrame:Show()
        refreshBookLocations()
        C_Timer.After(0,function()
            if DQA_EnableConfiguredMageBookPins then pcall(DQA_EnableConfiguredMageBookPins) end
        end)
    end
end

local function create()
    frame = CreateFrame("Frame", "DQASettingsFrame", UIParent, "BackdropTemplate")
    frame:SetSize(610, 520); frame:SetPoint("CENTER"); frame:SetFrameStrata("DIALOG"); frame:SetClampedToScreen(true)
    frame:SetMovable(true); frame:EnableMouse(true); frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving); frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8", edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize=24, insets={left=6,right=6,top=6,bottom=6}})
    frame:SetBackdropColor(.025,.03,.055,.98)
    local title = addText(frame,"GameFontNormalLarge","DQA Settings"); title:SetPoint("TOP",0,-18); title:SetTextColor(.79,.62,.95)
    local close = CreateFrame("Button",nil,frame,"UIPanelCloseButton"); close:SetPoint("TOPRIGHT",-5,-5)
    local intro = addText(frame,"GameFontHighlightSmall","Quest highlighting and compact trackers for hidden or unreliable quest interactions.")
    intro:SetPoint("TOPLEFT",24,-48); intro:SetTextColor(.75,.75,.78)

    local markerTitle=addText(frame,"GameFontNormal","OBJECTIVE MARKERS"); markerTitle:SetPoint("TOPLEFT",24,-78); markerTitle:SetTextColor(unpack(GOLD))
    checkbox(frame,"Highlight active quest targets","objectiveMarkers",24,-96)

    local secretTitle=addText(frame,"GameFontNormal","SECRET TRACKING"); secretTitle:SetPoint("TOPLEFT",24,-136); secretTitle:SetTextColor(unpack(GOLD))
    checkbox(frame,"Enable secret tracking","secrets",24,-154)
    checkbox(frame,"Cozy Sleeping Bag chain","sleepingBag",46,-182,"secrets")
    checkbox(frame,"Mage book collection","mageBooks",46,-210,"secrets")
    checkbox(frame,"Open map when setting a waypoint","autoOpenMap",46,-238,"secrets")

    local killTitle=addText(frame,"GameFontNormal","KILL COUNTER"); killTitle:SetPoint("TOPLEFT",24,-282); killTitle:SetTextColor(unpack(GOLD))
    checkbox(frame,"Track defeated creatures","killCounter",24,-300)
    checkbox(frame,"Show comic milestone rewards","killMilestones",46,-328,"killCounter")
    frame.KillStatus=addText(frame,"GameFontHighlightSmall",""); frame.KillStatus:SetPoint("TOPLEFT",50,-356); frame.KillStatus:SetTextColor(.72,.72,.75)
    local resetKills=button(frame,"Reset my tally",120,function()
        StaticPopup_Show("DQA_RESET_KILL_COUNTS")
    end)
    resetKills:SetPoint("TOPLEFT",46,-380)
    local previewKills=button(frame,"Preview",88,function()
        if DQA_PreviewKillMilestone then DQA_PreviewKillMilestone() end
    end)
    previewKills:SetPoint("LEFT",resetKills,"RIGHT",8,0)

    frame.SleepTitle=addText(frame,"GameFontNormal","Sleeping Bag"); frame.SleepTitle:SetPoint("TOPLEFT",315,-82); frame.SleepTitle:SetTextColor(unpack(GOLD))
    frame.SleepStatus=addText(frame,"GameFontHighlight",""); frame.SleepStatus:SetPoint("TOPLEFT",315,-108); frame.SleepStatus:SetWidth(265); frame.SleepStatus:SetJustifyH("LEFT")
    frame.SleepNext=addText(frame,"GameFontHighlightSmall",""); frame.SleepNext:SetPoint("TOPLEFT",315,-134); frame.SleepNext:SetWidth(265); frame.SleepNext:SetJustifyH("LEFT")
    frame.SleepNext:SetTextColor(.72,.72,.75)
    frame.SleepButton=button(frame,"Mark next step",130,function() local _,_,step=DQA_GetSleepingBagProgress(); DQA_SetSecretWaypoint(step) end)
    frame.SleepButton:SetPoint("TOPLEFT",315,-190)

    frame.BookTitle=addText(frame,"GameFontNormal","Mage Books"); frame.BookTitle:SetPoint("TOPLEFT",315,-238); frame.BookTitle:SetTextColor(unpack(GOLD))
    frame.BookStatus=addText(frame,"GameFontHighlight",""); frame.BookStatus:SetPoint("TOPLEFT",315,-264)
    frame.BookPinsButton=button(frame,"Configure Book Locations",228,function()
        openBookLocations()
    end)
    frame.BookPinsButton:SetPoint("TOPLEFT",315,-300)

    local note=addText(frame,"GameFontDisableSmall","DQA records progress from quest completion and current bag contents. More focused trackers can be added here without installing separate addons.")
    note:SetPoint("BOTTOMLEFT",24,24); note:SetWidth(555); note:SetJustifyH("LEFT")
    frame:SetScript("OnShow", function() DQA_SecretsRefresh() end)
    frame:Hide()
end

function DQA_RefreshSettings()
    if not frame then return end
    local m=DQADB.modules or {}
    for _, row in ipairs(rows) do
        row.box:SetChecked(m[row.key] ~= false)
        local enabled=not row.dependency or m[row.dependency] ~= false
        row.box:SetEnabled(enabled); row.box.Label:SetTextColor(enabled and 1 or .45, enabled and 1 or .45, enabled and 1 or .45)
    end
    local done,total,nextStep=DQA_GetSleepingBagProgress()
    frame.SleepStatus:SetText(("Progress: %d / %d steps"):format(done,total))
    frame.SleepNext:SetText(nextStep and (nextStep.title.."\n"..nextStep.zone..("  %.1f, %.1f"):format(nextStep.x,nextStep.y).."\n"..nextStep.note) or "Complete")
    frame.SleepButton:SetEnabled(m.secrets ~= false and m.sleepingBag ~= false and done < total)
    local books,held,bookTotal,missing=DQA_GetMageBookProgress()
    frame.BookStatus:SetText(("Turned in: %d / %d   In bags/bank: %d"):format(books,bookTotal,held))
    local nextBook=missing[1]
    frame.BookPinsButton:SetText("Configure Book Locations")
    frame.BookPinsButton:SetEnabled(m.secrets ~= false and m.mageBooks ~= false)
    if bookLocationsFrame and bookLocationsFrame:IsShown() then refreshBookLocations() end
    local kills, unique = 0, 0
    if DQA_GetKillStats then kills, unique = DQA_GetKillStats() end
    local killText=("%s kills across %s mob types"):format(
        BreakUpLargeNumbers and BreakUpLargeNumbers(kills) or tostring(kills),
        BreakUpLargeNumbers and BreakUpLargeNumbers(unique) or tostring(unique))
    if DQADB.killCounterError then killText=killText.."\n|cffff5555"..DQADB.killCounterError.."|r" end
    frame.KillStatus:SetText(killText)
end

function DQA_OpenSettings()
    if not frame then create() end
    if frame:IsShown() then frame:Hide() else frame:Show(); DQA_RefreshSettings() end
end


StaticPopupDialogs["DQA_RESET_KILL_COUNTS"] = {
    text = "Reset this character's entire DQA kill tally?",
    button1 = YES,
    button2 = NO,
    OnAccept = function() if DQA_ResetKillCounts then DQA_ResetKillCounts() end end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}
