local N = Nemesis
local frame, rows, pageText, searchBox, addBox, selectedText, preview
local markerButtons, colorSliders, offset = {}, {}, 0
local PAGE_SIZE = 8
N.selectedKey = nil

local function makeButton(parent, text, width, height)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, height); button:SetText(text)
    return button
end

local function makeCheck(parent, label, x, y, getter, setter)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetPoint("TOPLEFT", x, y)
    check.Text = check:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    check.Text:SetPoint("LEFT", check, "RIGHT", 2, 0); check.Text:SetText(label)
    check:SetScript("OnClick", function(self) setter(self:GetChecked() and true or false) end)
    check.Refresh = function(self) self:SetChecked(getter()) end
    return check
end

local function formatSeen(timestamp)
    timestamp = tonumber(timestamp) or 0
    if timestamp <= 0 then return "Never" end
    return date("%m/%d %H:%M", timestamp)
end

local function updateSelectedPanel()
    local entry = N.selectedKey and N.db.entries[N.selectedKey]
    selectedText:SetText(entry and (entry.displayName or entry.name or "") or "Select a watched player")
    local color = entry and entry.markerColor or {r=1,g=1,b=1,a=1}
    for channel, slider in pairs(colorSliders) do
        slider.updating = true; slider:SetValue(color[channel] or 1); slider.Value:SetText(("%.2f"):format(color[channel] or 1)); slider.updating = false
        slider:SetEnabled(entry ~= nil)
    end
    if preview then
        preview:SetTexture(entry and N:MarkerPath(entry.marker) or N:MarkerPath(N.db.settings.defaultMarker))
        preview:SetVertexColor(color.r or 1,color.g or 1,color.b or 1,color.a or 1)
    end
    for index, button in ipairs(markerButtons) do
        button:SetEnabled(entry ~= nil)
        button.Selected:SetShown(entry and tonumber(entry.marker)==index)
    end
end

function N:RefreshUI(selectKey)
    if not frame then return end
    if selectKey and self.db.entries[selectKey] then self.selectedKey = selectKey end
    local list = self:SortedEntries(searchBox and searchBox:GetText() or "")
    offset = math.max(0, math.min(offset, math.max(0, #list-PAGE_SIZE)))
    for index, row in ipairs(rows) do
        local item = list[offset+index]
        row.item = item
        if item then
            local entry=item.entry; local color=entry.markerColor or self.db.settings.markerColor
            row.Icon:SetTexture(self:MarkerPath(entry.marker)); row.Icon:SetVertexColor(color.r,color.g,color.b,color.a)
            row.Slot:SetText(entry.order or "--"); row.Name:SetText(item.label); row.Seen:SetText(formatSeen(entry.lastSeen)); row.Zone:SetText(entry.lastZone ~= "" and entry.lastZone or "--")
            row.Rivalry:SetText(("%d / %d"):format(entry.kills or 0,entry.deaths or 0)); row.Count:SetText(entry.encounters or 0); row.Enabled:SetChecked(entry.enabled ~= false); row:Show()
        else row:Hide() end
    end
    pageText:SetText(("Showing %d-%d of %d"):format(#list==0 and 0 or offset+1, math.min(offset+PAGE_SIZE,#list),#list))
    frame.Previous:SetEnabled(offset>0); frame.Next:SetEnabled(offset+PAGE_SIZE<#list)
    updateSelectedPanel()
end

local function createRow(parent, previous, index)
    local row=CreateFrame("Button",nil,parent)
    row:SetHeight(34); row:SetPoint("LEFT",20,0); row:SetPoint("RIGHT",-20,0); row:SetPoint("TOP",previous,"BOTTOM",0,0)
    local bg=row:CreateTexture(nil,"BACKGROUND"); bg:SetAllPoints(); local shade=index%2==0 and .12 or .055; bg:SetColorTexture(shade,shade,shade,.95)
    row.Icon=row:CreateTexture(nil,"ARTWORK"); row.Icon:SetSize(28,28); row.Icon:SetPoint("LEFT",4,0)
    row.Slot=row:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); row.Slot:SetPoint("LEFT",38,0); row.Slot:SetWidth(28)
    row.Name=row:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); row.Name:SetPoint("LEFT",70,0); row.Name:SetWidth(178); row.Name:SetJustifyH("LEFT")
    row.Seen=row:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); row.Seen:SetPoint("LEFT",252,0); row.Seen:SetWidth(100)
    row.Zone=row:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); row.Zone:SetPoint("LEFT",357,0); row.Zone:SetWidth(125)
    row.Rivalry=row:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); row.Rivalry:SetPoint("LEFT",487,0); row.Rivalry:SetWidth(70)
    row.Count=row:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); row.Count:SetPoint("LEFT",557,0); row.Count:SetWidth(44)
    row.Enabled=CreateFrame("CheckButton",nil,row,"UICheckButtonTemplate"); row.Enabled:SetPoint("LEFT",603,0)
    row.Enabled:SetScript("OnClick",function(self) if row.item then row.item.entry.enabled=self:GetChecked() and true or false; N:RefreshActiveMarkers(row.item.key) end end)
    row.Up=makeButton(row,"^",28,23); row.Up:SetPoint("LEFT",642,0); row.Up:SetScript("OnClick",function() if row.item then N:MoveEntry(row.item.key,-1) end end)
    row.Down=makeButton(row,"v",28,23); row.Down:SetPoint("LEFT",row.Up,"RIGHT",3,0); row.Down:SetScript("OnClick",function() if row.item then N:MoveEntry(row.item.key,1) end end)
    row.Edit=makeButton(row,"Edit",48,23); row.Edit:SetPoint("LEFT",row.Down,"RIGHT",5,0)
    row.Edit:SetScript("OnClick",function() if row.item then N.selectedKey=row.item.key; updateSelectedPanel() end end)
    row.Remove=makeButton(row,"Remove",62,23); row.Remove:SetPoint("RIGHT",-4,0)
    row.Remove:SetScript("OnClick",function() if row.item then if N.selectedKey==row.item.key then N.selectedKey=nil end; N:RemoveEntry(row.item.key) end end)
    row:SetScript("OnClick",function() if row.item then N.selectedKey=row.item.key; updateSelectedPanel() end end)
    return row
end
local function createSlider(parent, channel, label, y)
    local name="NemesisColorSlider"..channel:upper()
    local slider=CreateFrame("Slider",name,parent,"OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT",500,y); slider:SetSize(160,16); slider:SetMinMaxValues(0,1); slider:SetValueStep(.01); slider:SetObeyStepOnDrag(true)
    _G[name.."Low"]:SetText("0"); _G[name.."High"]:SetText("1"); _G[name.."Text"]:SetText(label)
    slider.Value=parent:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); slider.Value:SetPoint("LEFT",slider,"RIGHT",10,0); slider.Value:SetWidth(36)
    slider:SetScript("OnValueChanged",function(self,value)
        self.Value:SetText(("%.2f"):format(value))
        if self.updating then return end
        local entry=N.selectedKey and N.db.entries[N.selectedKey]
        if entry then entry.markerColor[channel]=value; N:RefreshActiveMarkers(N.selectedKey); updateSelectedPanel() end
    end)
    colorSliders[channel]=slider
end

function N:CreateUI()
    if frame then return end
    frame=CreateFrame("Frame","NemesisFrame",UIParent,"BasicFrameTemplateWithInset")
    frame:SetSize(900,650); frame:SetClampedToScreen(true); frame:SetMovable(true); frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton"); frame:SetScript("OnDragStart",frame.StartMoving); frame:SetScript("OnDragStop",function(self) self:StopMovingOrSizing(); local p,_,rp,x,y=self:GetPoint(); N.db.window={point=p,relativePoint=rp,x=x,y=y} end)
    local w=N.db.window; frame:SetPoint(w.point or "CENTER",UIParent,w.relativePoint or "CENTER",w.x or 0,w.y or 0)
    frame.TitleText:SetText("Nemesis")

    local subtitle=frame:CreateFontString(nil,"ARTWORK","GameFontHighlight"); subtitle:SetPoint("TOPLEFT",20,-38); subtitle:SetText("Watch for named players and mark their nameplates.")
    searchBox=CreateFrame("EditBox",nil,frame,"InputBoxTemplate"); searchBox:SetSize(210,24); searchBox:SetPoint("TOPLEFT",20,-66); searchBox:SetAutoFocus(false); searchBox:SetTextInsets(8,8,0,0)
    searchBox:SetScript("OnTextChanged",function() offset=0; N:RefreshUI() end)
    addBox=CreateFrame("EditBox",nil,frame,"InputBoxTemplate"); addBox:SetSize(210,24); addBox:SetPoint("LEFT",searchBox,"RIGHT",18,0); addBox:SetAutoFocus(false); addBox:SetTextInsets(8,8,0,0)
    local add=makeButton(frame,"Add Nemesis",105,24); add:SetPoint("LEFT",addBox,"RIGHT",8,0)
    local function addEntry() local entry,key=N:AddEntry(addBox:GetText()); if entry then addBox:SetText(""); N.selectedKey=key; N:RefreshUI(key) else N:Print(key) end end
    add:SetScript("OnClick",addEntry); addBox:SetScript("OnEnterPressed",addEntry)
    local test=makeButton(frame,"Test Alert",85,24); test:SetPoint("LEFT",add,"RIGHT",8,0); test:SetScript("OnClick",function() N:TestAlert() end)

    local checks={}
    checks[1]=makeCheck(frame,"Enabled",20,-96,function() return N.db.settings.enabled end,function(v) N.db.settings.enabled=v; if v then N:ReconcileUnits() else for unit in pairs(N.activeUnits) do N:RemoveUnit(unit) end end end)
    checks[2]=makeCheck(frame,"Markers",130,-96,function() return N.db.settings.markersEnabled end,function(v) N.db.settings.markersEnabled=v; if v then N:ReconcileUnits() else for unit in pairs(N.activeUnits) do N:RemoveUnit(unit) end end end)
    checks[3]=makeCheck(frame,"Sound",250,-96,function() return N.db.settings.soundsEnabled end,function(v) N.db.settings.soundsEnabled=v end)
    checks[4]=makeCheck(frame,"Screen alert",360,-96,function() return N.db.settings.messagesEnabled end,function(v) N.db.settings.messagesEnabled=v end)
    for _,check in ipairs(checks) do check:Refresh() end

    local header=CreateFrame("Frame",nil,frame); header:SetPoint("TOPLEFT",20,-130); header:SetPoint("RIGHT",-20,0); header:SetHeight(25)
    local hbg=header:CreateTexture(nil,"BACKGROUND"); hbg:SetAllPoints(); hbg:SetColorTexture(.18,.12,.03,1)
    for text,x in pairs({["Slot"]=40,["Character"]=70,["Last seen"]=252,["Zone"]=357,["K / D"]=495,["Seen"]=564,["On"]=611,["Reorder"]=642,["Actions"]=745}) do local f=header:CreateFontString(nil,"ARTWORK","GameFontNormalSmall"); f:SetPoint("LEFT",x,0); f:SetText(text) end
    rows={}; local previous=header; for i=1,PAGE_SIZE do rows[i]=createRow(frame,previous,i); previous=rows[i] end
    frame.Previous=makeButton(frame,"<",30,22); frame.Previous:SetPoint("TOPLEFT",20,-438); frame.Previous:SetScript("OnClick",function() offset=math.max(0,offset-PAGE_SIZE); N:RefreshUI() end)
    frame.Next=makeButton(frame,">",30,22); frame.Next:SetPoint("LEFT",frame.Previous,"RIGHT",5,0); frame.Next:SetScript("OnClick",function() offset=offset+PAGE_SIZE; N:RefreshUI() end)
    pageText=frame:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); pageText:SetPoint("LEFT",frame.Next,"RIGHT",10,0)

    local divider=frame:CreateTexture(nil,"ARTWORK"); divider:SetPoint("TOPLEFT",20,-470); divider:SetPoint("RIGHT",-20,0); divider:SetHeight(1); divider:SetColorTexture(.55,.38,.08,1)
    selectedText=frame:CreateFontString(nil,"ARTWORK","GameFontNormalLarge"); selectedText:SetPoint("TOPLEFT",20,-486)
    preview=frame:CreateTexture(nil,"ARTWORK"); preview:SetSize(64,64); preview:SetPoint("TOPLEFT",20,-520)
    local reset=makeButton(frame,"Reset Color",90,23); reset:SetPoint("TOPLEFT",18,-596); reset:SetScript("OnClick",function() local e=N.selectedKey and N.db.entries[N.selectedKey]; if e then e.markerColor={r=1,g=1,b=1,a=1}; updateSelectedPanel(); N:RefreshActiveMarkers(N.selectedKey) end end)

    local markerLabel=frame:CreateFontString(nil,"ARTWORK","GameFontNormal"); markerLabel:SetPoint("TOPLEFT",100,-518); markerLabel:SetText("Marker")
    for i=1,20 do
        local b=CreateFrame("Button",nil,frame); b:SetSize(30,30); local col=(i-1)%10; local row=math.floor((i-1)/10); b:SetPoint("TOPLEFT",100+col*34,-540-row*34)
        b.Icon=b:CreateTexture(nil,"ARTWORK"); b.Icon:SetAllPoints(); b.Icon:SetTexture(N:MarkerPath(i))
        b.Selected=b:CreateTexture(nil,"OVERLAY"); b.Selected:SetPoint("TOPLEFT",-2,2); b.Selected:SetPoint("BOTTOMRIGHT",2,-2); b.Selected:SetColorTexture(1,.72,0,.35); b.Selected:Hide()
        b:SetScript("OnClick",function() local e=N.selectedKey and N.db.entries[N.selectedKey]; if e then e.marker=i; updateSelectedPanel(); N:RefreshActiveMarkers(N.selectedKey); N:RefreshUI() end end)
        b:SetScript("OnEnter",function(self) GameTooltip:SetOwner(self,"ANCHOR_TOP"); GameTooltip:SetText(('%02d - %s'):format(i,N.markerNames[i])); GameTooltip:Show() end); b:SetScript("OnLeave",GameTooltip_Hide)
        markerButtons[i]=b
    end
    createSlider(frame,"r","Red",-500); createSlider(frame,"g","Green",-535); createSlider(frame,"b","Blue",-570); createSlider(frame,"a","Alpha",-605)

    frame:SetScript("OnShow",function() N:RefreshUI() end); frame:Hide(); self.frame=frame
    self:RefreshUI()
end

function N:ToggleUI()
    if not frame then self:CreateUI() end
    if frame:IsShown() then frame:Hide() else frame:Show() end
end
