local BAR_HEIGHT=24
local GOLD="|cffffd100"
local WHITE="|cffffffff"
local MUTED="|cffaaaaaa"

local bar=CreateFrame("Frame","DefylerUIBottomBar",UIParent,"BackdropTemplate")
bar:SetPoint("TOPLEFT")
bar:SetPoint("TOPRIGHT")
bar:SetHeight(BAR_HEIGHT)
bar:SetFrameStrata("HIGH")
bar:SetFrameLevel(20)
bar:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",edgeFile="Interface\\Buttons\\WHITE8X8",edgeSize=1})
bar:SetBackdropColor(.025,.03,.045,.96)
bar:SetBackdropBorderColor(.30,.22,.38,1)

local function field(width)
    local frame=CreateFrame("Frame",nil,bar)
    frame:SetSize(width,BAR_HEIGHT-2)
    frame:EnableMouse(true)
    local text=frame:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    text:SetPoint("CENTER")
    text:SetJustifyH("CENTER")
    frame.text=text
    frame:SetScript("OnLeave",function() GameTooltip:Hide() end)
    return frame
end
local coords=field(120)
local gold=field(190)
local inventory=field(220)
local honor=field(170)
local xpRate=field(190)
local eta=field(210)
-- Center all fields as one 1,120-pixel group.
coords:SetPoint("LEFT",bar,"CENTER",-560,0)
gold:SetPoint("LEFT",coords,"RIGHT",4,0)
inventory:SetPoint("LEFT",gold,"RIGHT",4,0)
honor:SetPoint("LEFT",inventory,"RIGHT",4,0)
xpRate:SetPoint("LEFT",honor,"RIGHT",4,0)
eta:SetPoint("LEFT",xpRate,"RIGHT",4,0)

local function formatMoney(value)
    if DefylerUIInventoryValue and DefylerUIInventoryValue.FormatMoney then
        return DefylerUIInventoryValue.FormatMoney(value)
    end
    value=math.floor(tonumber(value) or 0)
    return ("%dg %02ds %02dc"):format(math.floor(value/10000),math.floor(value/100)%100,value%100)
end
local function safeNumber(callback)
    local ok,value=pcall(callback)
    if not ok or type(value)~="number" then return nil end
    return value
end
local function coordinateText()
    if not C_Map or not C_Map.GetBestMapForUnit or not C_Map.GetPlayerMapPosition then return "--, --" end
    local mapID=safeNumber(function() return C_Map.GetBestMapForUnit("player") end)
    if not mapID then return "--, --" end
    local ok,pos=pcall(C_Map.GetPlayerMapPosition,mapID,"player")
    if not ok or not pos or not pos.GetXY then return "--, --" end
    local okXY,x,y=pcall(pos.GetXY,pos)
    if not okXY or type(x)~="number" or type(y)~="number" then return "--, --" end
    return ("%.1f, %.1f"):format(x*100,y*100)
end

local sessionStart,sessionXP,lastLevel,lastXP,lastMax
local function currentXP()
    local level=safeNumber(function() return UnitLevel("player") end) or 0
    local xp=safeNumber(function() return UnitXP("player") end) or 0
    local maximum=safeNumber(function() return UnitXPMax("player") end) or 0
    return level,xp,maximum
end
local function updateSessionXP()
    local level,xp,maximum=currentXP()
    if not sessionStart then
        sessionStart=GetTime();sessionXP=0;lastLevel=level;lastXP=xp;lastMax=maximum
    elseif level>lastLevel then
        sessionXP=sessionXP+math.max(0,(lastMax or 0)-lastXP)+xp
        lastLevel,lastXP,lastMax=level,xp,maximum
    elseif level==lastLevel and xp>=lastXP then
        sessionXP=sessionXP+(xp-lastXP);lastXP,lastMax=xp,maximum
    else
        lastLevel,lastXP,lastMax=level,xp,maximum
    end
end
local function rateAndETA()
    updateSessionXP()
    local elapsed=math.max(1,GetTime()-sessionStart)
    local rate=sessionXP*3600/elapsed
    local _,xp,maximum=currentXP()
    if maximum<=0 then return rate,nil end
    local remaining=math.max(0,maximum-xp)
    return rate,rate>0 and remaining/rate*3600 or nil
end
local function duration(seconds)
    if not seconds then return "--" end
    if seconds>=3600 then return ("%dh %02dm"):format(math.floor(seconds/3600),math.floor(seconds/60)%60) end
    return ("%dm"):format(math.max(1,math.floor(seconds/60+.5)))
end
local function honorText()
    local current=safeNumber(function() return UnitHonor("player") end)
    local maximum=safeNumber(function() return UnitHonorMax("player") end)
    if current then
        return maximum and maximum>0 and (BreakUpLargeNumbers(current).." / "..BreakUpLargeNumbers(maximum)) or BreakUpLargeNumbers(current)
    end
    if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
        local ok,info=pcall(C_CurrencyInfo.GetCurrencyInfo,1792)
        if ok and type(info)=="table" and type(info.quantity)=="number" then return BreakUpLargeNumbers(info.quantity) end
    end
    return "--"
end
local function inventorySummary()
    return DefylerUIInventoryValue and DefylerUIInventoryValue.GetSummary and DefylerUIInventoryValue.GetSummary() or nil
end
local function refresh()
    local rate,seconds=rateAndETA()
    coords.text:SetText(GOLD.."Coords "..WHITE..coordinateText())
    gold.text:SetText(GOLD.."Gold "..WHITE..formatMoney(GetMoney and GetMoney() or 0))
    local summary=inventorySummary()
    local marker=summary and (summary.missing+summary.pending+summary.fallback>0) and " *" or ""
    inventory.text:SetText(GOLD.."Inventory "..WHITE..formatMoney(summary and summary.total or 0)..marker)
    honor.text:SetText(GOLD.."Honor "..WHITE..honorText())
    xpRate.text:SetText(GOLD.."XP/hr "..WHITE..BreakUpLargeNumbers(math.floor(rate+.5)))
    eta.text:SetText(GOLD.."Next level "..WHITE..duration(seconds))
end

local function inventoryTooltip(self)
    local summary=inventorySummary()
    if not summary then return end
    GameTooltip:SetOwner(self,"ANCHOR_TOP")
    GameTooltip:AddLine("Estimated inventory value",1,.82,0)
    GameTooltip:AddDoubleLine("Auction estimate",formatMoney(summary.auction),1,1,1,1,1,1)
    GameTooltip:AddDoubleLine("Vendor fallback",formatMoney(summary.vendor),1,1,1,1,1,1)
    GameTooltip:AddDoubleLine("Disenchant fallback",formatMoney(summary.disenchant),1,1,1,1,1,1)
    if summary.fallback>0 then GameTooltip:AddLine(summary.fallback.." units use fallback pricing.",1,.65,.2,true) end
    if summary.pending>0 then GameTooltip:AddLine(summary.pending.." units await item data.",1,.65,.2,true) end
    GameTooltip:Show()
end
inventory:SetScript("OnEnter",inventoryTooltip)
xpRate:SetScript("OnEnter",function(self)
    GameTooltip:SetOwner(self,"ANCHOR_TOP")
    GameTooltip:AddLine("Session experience",1,.82,0)
    GameTooltip:AddDoubleLine("XP gained",BreakUpLargeNumbers(math.floor(sessionXP or 0)),1,1,1,1,1,1)
    GameTooltip:AddDoubleLine("Session time",duration(sessionStart and GetTime()-sessionStart),1,1,1,1,1,1)
    GameTooltip:Show()
end)

local events=CreateFrame("Frame")
for _,event in ipairs({"PLAYER_LOGIN","PLAYER_ENTERING_WORLD","PLAYER_XP_UPDATE","PLAYER_LEVEL_UP","PLAYER_MONEY","HONOR_XP_UPDATE","BAG_UPDATE_DELAYED"}) do
    pcall(events.RegisterEvent,events,event)
end
events:SetScript("OnEvent",function() updateSessionXP();refresh() end)
local elapsed=0
events:SetScript("OnUpdate",function(_,delta)
    elapsed=elapsed+delta
    if elapsed<1 then return end
    elapsed=0
    refresh()
end)
if DefylerUIInventoryValue and DefylerUIInventoryValue.RegisterRefresh then DefylerUIInventoryValue.RegisterRefresh(refresh) end
refresh()
