local function safe(value)
    if issecretvalue and issecretvalue(value) then return nil end
    return value
end

local function characterKey()
    return (UnitName("player") or "Unknown") .. "-" .. (GetRealmName and GetRealmName() or "Realm")
end

local function store()
    DQADB.modules = DQADB.modules or {}
    if DQADB.modules.killCounter == nil then DQADB.modules.killCounter = true end
    if DQADB.modules.killMilestones == nil then DQADB.modules.killMilestones = true end
    -- Forever does not expose a reliable source-aware critical-hit event.
    -- UNIT_COMBAT reports the victim and critical flag, but not the attacker,
    -- so using it would display every party/raid member's critical hits.
    DQADB.modules.critSplashes = false
    DQADB.killCounts = DQADB.killCounts or {}
    local key = characterKey()
    DQADB.killCounts[key] = DQADB.killCounts[key] or { byID={}, byName={}, total=0 }
    local db = DQADB.killCounts[key]
    db.byID = db.byID or {}; db.byName = db.byName or {}; db.total = db.total or 0
    return db
end

local function creatureID(guid)
    guid = safe(guid)
    if type(guid) ~= "string" then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind ~= "Creature" and kind ~= "Vehicle" then return nil end
    return tonumber(id)
end

local function normalizeName(name)
    name = safe(name)
    if type(name) ~= "string" or name == "" then return nil end
    return name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
end

local MILESTONES = {
    [1]="FIRST KILL!", [50]="SPLAT!", [100]="BAM!", [250]="KRAK!", [500]="BLAM!", [1000]="KAPOW!",
}
local rewardFrame
local critFrames,critFrameIndex={},0
local lastCritSplashAt=0

local function createRewardFrame()
    local f = CreateFrame("Frame", "DQAKillMilestoneFrame", UIParent)
    f:SetSize(520, 300); f:SetPoint("CENTER", UIParent, "CENTER", 0, 70)
    f:SetFrameStrata("FULLSCREEN_DIALOG"); f:EnableMouse(false); f:Hide()
    f.Burst = f:CreateTexture(nil, "BACKGROUND")
    f.Burst:SetTexture("Interface\\Cooldown\\star4")
    f.Burst:SetBlendMode("ADD"); f.Burst:SetSize(330,330); f.Burst:SetPoint("CENTER")
    f.Word = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    f.Word:SetPoint("CENTER",0,18); f.Word:SetTextColor(1,.86,.05); f.Word:SetShadowColor(.1,0,.15,1); f.Word:SetShadowOffset(4,-4)
    local font = GameFontNormalHuge and GameFontNormalHuge:GetFont()
    if font then f.Word:SetFont(font,64,"THICKOUTLINE") end
    f.Detail = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.Detail:SetPoint("TOP",f.Word,"BOTTOM",0,-12); f.Detail:SetTextColor(1,1,1)
    f:SetScript("OnUpdate", function(self)
        local elapsed = GetTime() - self.started
        if elapsed >= 3.2 then self:Hide(); return end
        local scale, alpha = 1, 1
        if elapsed < .22 then
            local p = elapsed / .22
            scale = .45 + .65 * p
            alpha = p
        elseif elapsed < 2.35 then
            scale = 1.04 + math.sin(elapsed * 12) * .025
        else
            local p = (elapsed - 2.35) / .85
            scale = 1.04 + p * .35
            alpha = 1 - p
        end
        self:SetScale(scale); self:SetAlpha(alpha)
        self.Burst:SetRotation(elapsed * .32)
    end)
    return f
end

local function showMilestone(name, count)
    if not DQADB.modules or DQADB.modules.killMilestones == false then return end
    local word = MILESTONES[count]
    if not word then return end
    rewardFrame = rewardFrame or createRewardFrame()
    local colors = {{1,.82,.08},{1,.12,.08},{.1,.75,1},{.9,.08,1},{.2,1,.2},{1,.55,.02}}
    local color = colors[(count == 1 and 1) or (count == 50 and 2) or (count == 100 and 3) or (count == 250 and 4) or (count == 500 and 5) or 6]
    rewardFrame.Burst:SetVertexColor(color[1],color[2],color[3],.9)
    rewardFrame.Word:SetText(word)
    if count==1 then
        rewardFrame.Detail:SetText(("First %s defeated!"):format(name or "creature"))
    else
        rewardFrame.Detail:SetText(("%s defeated %s times!"):format(name or "Mob", BreakUpLargeNumbers and BreakUpLargeNumbers(count) or count))
    end
    rewardFrame.started = GetTime(); rewardFrame:SetScale(.45); rewardFrame:SetAlpha(0); rewardFrame:Show()
end

local function createCritFrame(index)
    local offsets={{-210,105},{205,95},{-155,-35},{170,-50}}
    local offset=offsets[index] or {0,60}
    local f=CreateFrame("Frame",nil,UIParent)
    f:SetSize(300,180);f:SetPoint("CENTER",UIParent,"CENTER",offset[1],offset[2])
    f:SetFrameStrata("FULLSCREEN_DIALOG");f:EnableMouse(false);f:Hide()
    f.Burst=f:CreateTexture(nil,"BACKGROUND")
    f.Burst:SetTexture("Interface\\Cooldown\\star4");f.Burst:SetBlendMode("ADD")
    f.Burst:SetVertexColor(1,.16,.03,.88);f.Burst:SetSize(185,185);f.Burst:SetPoint("CENTER")
    f.Word=f:CreateFontString(nil,"OVERLAY","GameFontNormalHuge")
    f.Word:SetPoint("CENTER");f.Word:SetText("POW!");f.Word:SetTextColor(1,.88,.03)
    f.Word:SetShadowColor(.12,0,0,1);f.Word:SetShadowOffset(4,-4)
    local font=GameFontNormalHuge and GameFontNormalHuge:GetFont()
    if font then f.Word:SetFont(font,52,"THICKOUTLINE") end
    f:SetScript("OnUpdate",function(self)
        local elapsed=GetTime()-self.started
        if elapsed>=1.05 then self:Hide();return end
        local alpha=elapsed<.12 and elapsed/.12 or (elapsed>.72 and (1-(elapsed-.72)/.33) or 1)
        local scale=elapsed<.12 and (.35+elapsed/.12*.75) or (1.10+elapsed*.035)
        self:SetAlpha(alpha);self:SetScale(scale);self.Burst:SetRotation(elapsed*.7)
    end)
    return f
end

local function showCriticalSplash()
    if not DQADB.modules or DQADB.modules.critSplashes==false then return end
    local now=GetTime()
    if now-lastCritSplashAt<.08 then return end
    lastCritSplashAt=now
    critFrameIndex=critFrameIndex%4+1
    local f=critFrames[critFrameIndex]
    if not f then f=createCritFrame(critFrameIndex);critFrames[critFrameIndex]=f end
    f.started=GetTime();f:SetAlpha(0);f:SetScale(.35);f:Show()
end

local function detectCombatTextCritical(eventType)
    eventType=safe(eventType)
    if type(eventType)~="string" then return end
    eventType=eventType:upper()
    if eventType=="DAMAGE_CRIT" or eventType=="SPELL_DAMAGE_CRIT"
        or eventType=="DAMAGE_SHIELD_CRIT" or eventType=="SPELL_PERIODIC_DAMAGE_CRIT" then
        showCriticalSplash()
    end
end

local function detectCritical(message)
    message=safe(message)
    if type(message)~="string" then return false end
    local lower=message:lower()
    if lower:find("critical",1,true) or lower:find(" crit ",1,true)
        or lower:find(" crits ",1,true) then
        showCriticalSplash()
        return true
    end
    return false
end

local lastSelfDamageAt,pendingTargetCritAt=0,0
local CRIT_CORRELATION_WINDOW=.12

local function noteSelfDamage(message)
    local now=GetTime()
    lastSelfDamageAt=now
    if pendingTargetCritAt>0 and now-pendingTargetCritAt<=CRIT_CORRELATION_WINDOW then
        pendingTargetCritAt=0
        showCriticalSplash()
        return
    end
    detectCritical(message)
end

local function detectUnitCritical(unit,action,descriptor)
    unit=safe(unit);action=safe(action);descriptor=safe(descriptor)
    if type(unit)~="string" then return end
    local unitGUID=safe(UnitGUID(unit))
    local targetGUID=safe(UnitGUID("target"))
    local mouseoverGUID=safe(UnitGUID("mouseover"))
    if unit~="target" and unit~="mouseover"
        and (not unitGUID or (unitGUID~=targetGUID and unitGUID~=mouseoverGUID)) then return end
    if type(action)~="string" or action~="WOUND" then return end
    if type(descriptor)=="string" and descriptor:upper():find("CRITICAL",1,true) then
        pendingTargetCritAt=0
        showCriticalSplash()
    end
end

local function recordKill(destGUID, destName)
    if not DQADB.modules or DQADB.modules.killCounter == false then return end
    local id, name = creatureID(destGUID), normalizeName(destName)
    if not id and not name then return end
    local db = store()
    if id then db.byID[id] = (db.byID[id] or 0) + 1 end
    if name then db.byName[name] = (db.byName[name] or 0) + 1 end
    db.total = db.total + 1
    local count = id and db.byID[id] or (name and db.byName[name])
    if count then showMilestone(name, count) end
end

local function onCombatLogEvent()
    local getEvent = C_CombatLog and C_CombatLog.GetCurrentEventInfo or CombatLogGetCurrentEventInfo
    if not getEvent then return end
    local _, subEvent, _, sourceGUID, _, sourceFlags, _, destGUID, destName = getEvent()
    if safe(subEvent) ~= "PARTY_KILL" then return end
    sourceFlags = safe(sourceFlags)
    local mine = sourceFlags and bit and bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) ~= 0
    if not mine then
        local playerGUID, petGUID = safe(UnitGUID("player")), safe(UnitGUID("pet"))
        local source = safe(sourceGUID)
        mine = source and (source == playerGUID or source == petGUID)
    end
    if mine then recordKill(destGUID, destName) end
end

store()
-- Forever 1.60.1 rejects COMBAT_LOG_EVENT_UNFILTERED registration for addons.
-- The legacy hostile-death event remains public and identifies a death without
-- touching the protected combat-log callback. Recent visible units supply the
-- creature ID when the death message itself contains only a name.
local observedByName={}
local recordedDeathGUIDs={}
local OBSERVATION_LIFETIME=20

local function observeUnit(unit)
    if type(unit)~="string" or not UnitExists(unit) then return end
    local okPlayer,isPlayer=pcall(UnitIsPlayer,unit)
    if okPlayer and safe(isPlayer)==true then return end
    local okName,name=pcall(UnitName,unit)
    name=okName and normalizeName(name) or nil
    if not name then return end
    local okGUID,guid=pcall(UnitGUID,unit)
    guid=okGUID and safe(guid) or nil
    observedByName[name:lower()]={id=creatureID(guid),name=name,at=GetTime()}
end

local function captureFromFormat(message,template)
    if type(message)~="string" or type(template)~="string" then return nil end
    local pattern=template:gsub("%%[%d%$%.%-]*s","\1"):gsub("%%[%d%$%.%-]*d","\2")
    pattern=pattern:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])","%%%1")
    pattern=pattern:gsub("\1","(.+)"):gsub("\2","%%d+")
    return message:match("^"..pattern.."$")
end

local function victimFromDeathMessage(message)
    message=safe(message)
    if type(message)~="string" then return nil end
    return normalizeName(captureFromFormat(message,_G.UNITDIESOTHER))
        or normalizeName(message:match("^(.+) dies[%.!]?$"))
        or normalizeName(message:match("^[Yy]ou have slain (.+)[%.!]?$"))
        or normalizeName(message:match("^(.+) is slain by .+[%.!]?$"))
        or normalizeName(message:match("^(.+) is killed by .+[%.!]?$"))
end

local lastRecordedName,lastRecordedAt
local function recentlyRecordedGUID(guid)
    guid=safe(guid)
    if type(guid)~="string" then return false end
    local now=GetTime()
    local prior=recordedDeathGUIDs[guid]
    recordedDeathGUIDs[guid]=now
    return prior and now-prior<30
end

local function recordNamedDeath(name)
    if not name then return end
    local key=name:lower()
    local observed=observedByName[key]
    local now=GetTime()
    if lastRecordedName==key and now-(lastRecordedAt or 0)<.5 then return end
    lastRecordedName,lastRecordedAt=key,now
    if observed and now-(observed.at or 0)>OBSERVATION_LIFETIME then observed=nil end
    local guid=observed and observed.id and ("Creature-0-0-0-0-"..observed.id.."-0000000000") or nil
    recordKill(guid,(observed and observed.name) or name)
    observedByName[key]=nil
end

local function recordDeadUnit(unit)
    if type(unit)~="string" or not UnitExists(unit) then return end
    local okDead,dead=pcall(UnitIsDeadOrGhost,unit)
    if not okDead or safe(dead)~=true then return end
    local okPlayer,isPlayer=pcall(UnitIsPlayer,unit)
    if okPlayer and safe(isPlayer)==true then return end
    local okAttack,canAttack=pcall(UnitCanAttack,"player",unit)
    if not okAttack or safe(canAttack)~=true then return end
    if UnitIsTapDenied then
        local okDenied,denied=pcall(UnitIsTapDenied,unit)
        if okDenied and safe(denied)==true then return end
    end
    local okGUID,guid=pcall(UnitGUID,unit)
    guid=okGUID and safe(guid) or nil
    if not guid or recentlyRecordedGUID(guid) then return end
    local okName,name=pcall(UnitName,unit)
    name=okName and normalizeName(name) or nil
    if not name then return end
    local key,now=name:lower(),GetTime()
    if lastRecordedName==key and now-(lastRecordedAt or 0)<.5 then return end
    lastRecordedName,lastRecordedAt=key,now
    recordKill(guid,name)
end

local function recordObservedDeath(message)
    recordNamedDeath(victimFromDeathMessage(message))
end

local function recordXPDeath(message)
    message=safe(message)
    if type(message)~="string" then return end
    local name=captureFromFormat(message,_G.COMBATLOG_XPGAIN_FIRSTPERSON)
        or message:match("^(.+) dies, you gain .+ experience[%.!]?$")
    recordNamedDeath(normalizeName(name))
end

local killEvents=CreateFrame("Frame")
killEvents:SetScript("OnEvent",function(_,event,...)
    if event=="CHAT_MSG_COMBAT_HOSTILE_DEATH" then
        recordObservedDeath(...)
    elseif event=="CHAT_MSG_COMBAT_XP_GAIN" then
        recordXPDeath(...)
    elseif event=="NAME_PLATE_UNIT_ADDED" then
        observeUnit(...)
    elseif event=="PLAYER_TARGET_CHANGED" then
        observeUnit("target")
    elseif event=="UPDATE_MOUSEOVER_UNIT" then
        observeUnit("mouseover")
    elseif event=="UNIT_HEALTH" or event=="UNIT_HEALTH_FREQUENT" then
        local unit=...
        if type(unit)=="string" and (unit:match("^nameplate%d+$") or unit=="target" or unit=="mouseover") then
            observeUnit(unit)
            recordDeadUnit(unit)
        end
    end
end)
local registeredDeath=pcall(killEvents.RegisterEvent,killEvents,"CHAT_MSG_COMBAT_HOSTILE_DEATH")
local registeredXP=pcall(killEvents.RegisterEvent,killEvents,"CHAT_MSG_COMBAT_XP_GAIN")
for _,event in ipairs({"NAME_PLATE_UNIT_ADDED","PLAYER_TARGET_CHANGED","UPDATE_MOUSEOVER_UNIT","UNIT_HEALTH","UNIT_HEALTH_FREQUENT"}) do
    pcall(killEvents.RegisterEvent,killEvents,event)
end
DQADB.killCounterError=(registeredDeath or registeredXP) and nil or "Kill events unavailable on this client"

function DQA_GetKillStats()
    local db = store()
    local unique=0
    for _ in pairs(db.byName) do unique=unique+1 end
    if unique==0 then for _ in pairs(db.byID) do unique=unique+1 end end
    return db.total, unique
end

function DQA_GetKillCountForUnit(unit)
    if not DQADB.modules or DQADB.modules.killCounter == false then return 0 end
    if type(unit) ~= "string" or not UnitExists(unit) then return 0 end
    local db = store()
    local id = creatureID(UnitGUID(unit))
    if id and tonumber(db.byID[id]) then return tonumber(db.byID[id]) or 0 end
    local name = normalizeName(UnitName(unit))
    return name and (tonumber(db.byName[name]) or 0) or 0
end

function DQA_ResetKillCounts()
    DQADB.killCounts = DQADB.killCounts or {}
    DQADB.killCounts[characterKey()] = { byID={}, byName={}, total=0 }
    if DQA_RefreshSettings then DQA_RefreshSettings() end
end


function DQA_PreviewKillMilestone()
    showMilestone("Hillsbrad Farmer", 250)
end


