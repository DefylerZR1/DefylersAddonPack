-- Never export cached secret font-string contents. Query a fresh session only
-- after combat, then check every field before using it in a report.
local function Public(value)
    if issecretvalue and issecretvalue(value) then return false end
    return not canaccessvalue or canaccessvalue(value)
end
local function ReadSession(window)
    local meterType = window:GetDamageMeterType()
    local sessionType = window:GetSessionType()
    if not Public(meterType) or not Public(sessionType) then return end
    if sessionType ~= nil then
        return C_DamageMeter.GetCombatSessionFromType(sessionType, meterType)
    end
    local id = window:GetSessionID()
    if not Public(id) or type(id) ~= "number" then return end
    return C_DamageMeter.GetCombatSessionFromID(id, meterType)
end
function DDMBuildRowReport(entry, window)
    if InCombatLockdown() then return nil, "DDM: Report after combat ends." end
    if not entry or not window then return nil, "DDM: Reopen the meter, then select a row." end
    local index = entry.index
    if not Public(index) or type(index) ~= "number" or index < 1 or index % 1 ~= 0 then
        return nil, "DDM: This row is not available for reporting."
    end
    local ok, session = pcall(ReadSession, window)
    if not ok or not Public(session) or type(session) ~= "table" then
        return nil, "DDM: Combat session is not available yet. Try again after combat."
    end
    local sources = session.combatSources
    if not Public(sources) or type(sources) ~= "table" then return nil, "DDM: Session data is still protected." end
    local source = sources[index]
    if not Public(source) or type(source) ~= "table" then return nil, "DDM: That row is no longer in this session." end
    local name, total, rate = source.name, source.totalAmount, source.amountPerSecond
    if not Public(name) or not Public(total) or not Public(rate) then
        return nil, "DDM: The client still protects this session's data; no report was sent."
    end
    if type(name) ~= "string" or type(total) ~= "number" then return nil, "DDM: Session data is incomplete." end
    -- Do not silently report another unit if the visible list changed order.
    local shownName = entry.sourceName
    if Public(shownName) and type(shownName) == "string" and shownName ~= name then
        return nil, "DDM: Rows changed. Select the refreshed row again."
    end
    local text = string.format("DDM: %s - %.0f", name, total)
    if type(rate) == "number" and rate > 0 then text = text .. string.format(" (%.1f/s)", rate) end
    return text
end
