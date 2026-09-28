local N = Nemesis

function N:RegisterCommands()
    SLASH_NEMESIS1 = "/nemesis"
    SLASH_NEMESIS2 = "/nem"
    SlashCmdList.NEMESIS = function(message)
        local command, rest = tostring(message or ""):match("^%s*(%S*)%s*(.-)%s*$")
        command = command:lower()
        if command == "add" then
            local entry, key = N:AddEntry(rest)
            if entry then N:Print("Watching "..entry.name.."-"..entry.realm..".") else N:Print(key) end
        elseif command == "remove" then
            local _,_,key=N:SplitCharacter(rest)
            if key and N:RemoveEntry(key) then N:Print("Removed "..rest..".") else N:Print("That character is not on the watchlist.") end
        elseif command == "list" then
            local list=N:SortedEntries(""); N:Print(("%d watched player(s):"):format(#list)); for _,item in ipairs(list) do N:Print("  "..item.label) end
        elseif command == "enable" then N.db.settings.enabled=true; N:ReconcileUnits(); N:Print("Enabled.")
        elseif command == "disable" then N.db.settings.enabled=false; for unit in pairs(N.activeUnits) do N:RemoveUnit(unit) end; N:Print("Disabled.")
        elseif command == "test" then N:TestAlert()
        elseif command == "probe" then
            local name, realm, key, guid = N:UnitIdentity("target")
            local entry, matchedKey = N:GetEntryByUnit("target")
            N:Print(("Target name=%s realm=%s key=%s guid=%s match=%s"):format(
                tostring(name), tostring(realm), tostring(key), tostring(guid), tostring(matchedKey or (entry and "yes") or "none")))
            if entry then N:ShowMarkerPrompt("target", entry, matchedKey) end
        elseif command == "help" then
            N:Print("/nemesis add Name-Realm, remove Name-Realm, list, enable, disable, test, probe")
        else N:ToggleUI() end
    end
end
