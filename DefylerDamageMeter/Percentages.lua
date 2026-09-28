-- Configure native rendering via client-owned saved data, not tainted Lua
-- meter setters. All combat arithmetic remains inside Blizzard's renderer.
local layoutName = "DDM Percentages"
local busy
local function Copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k,v in pairs(value) do result[k] = Copy(v) end
    return result
end
local function FindNumbers(layout)
    for _,system in ipairs(layout and layout.systems or {}) do
        if system.system == Enum.EditModeSystem.DamageMeter then
            for _,setting in ipairs(system.settings or {}) do
                if setting.setting == Enum.EditModeDamageMeterSetting.Numbers then return setting end
            end
        end
    end
end
function DDMPercentagesEnabled()
    local manager = EditModeManagerFrame
    local layout = manager and manager:GetActiveLayoutInfo()
    local numbers = FindNumbers(layout)
    return numbers and numbers.value == Enum.DamageMeterNumbers.Complete or false
end
function DDMSetPercentages(enabled)
    if busy then return end
    if InCombatLockdown() then print("DDM: Change percentages after combat."); return end
    local manager = EditModeManagerFrame
    if not manager or not manager.layoutInfo or not C_EditMode then
        print("DDM: Native layout data is not ready yet."); return
    end
    if manager:IsShown() or manager.overrideLayoutInfo then
        print("DDM: Close Edit Mode or the temporary layout preview first."); return
    end
    local current = manager:GetActiveLayoutInfo()
    if not FindNumbers(current) then print("DDM: This layout does not expose damage-meter number formatting."); return end
    local desired = enabled and Enum.DamageMeterNumbers.Complete or Enum.DamageMeterNumbers.Compact
    if FindNumbers(current).value == desired then return end
    local payload = Copy(manager.layoutInfo)
    local index = payload.activeLayout
    local isCopy = current.layoutName == layoutName and DDMDB and DDMDB.percentageLayoutCreated
    local added = not isCopy
    if added then
        local count = 0
        for _,layout in ipairs(payload.layouts) do
            if layout.layoutType == Enum.EditModeLayoutType.Character then count=count+1 end
            if layout.layoutName == layoutName then
                print("DDM: A DDM Percentages layout already exists. Select it before changing this setting."); return
            end
        end
        if count >= 5 then print("DDM: No free character layout slot. Your current layout has not been changed."); return end
        local clone = Copy(current)
        clone.layoutName = layoutName
        clone.layoutType = Enum.EditModeLayoutType.Character
        clone.layoutIndex = nil
        payload.layouts[#payload.layouts+1] = clone
        index = #payload.layouts
    end
    FindNumbers(payload.layouts[index]).value = desired
    busy = true
    local ok = pcall(C_EditMode.SaveLayouts, payload)
    if ok and added then ok = pcall(C_EditMode.OnLayoutAdded,index,true,false) end
    if not ok then busy=nil; print("DDM: The client rejected the percentage setting. No meter fields were overridden."); return end
    C_Timer.After(.2,function()
        busy=nil
        -- Read back from the engine; do not claim success from the request alone.
        local native = C_EditMode.GetLayouts()
        local found
        for _,layout in ipairs(native.layouts or {}) do
            if layout.layoutName == layoutName then found=FindNumbers(layout); break end
        end
        if not found or found.value ~= desired or native.activeLayout ~= index then
            print("DDM: The beta did not confirm the percentage layout. No success was recorded."); return
        end
        DDMDB = DDMDB or {}
        DDMDB.percentageLayoutCreated=true
        ReloadUI()
    end)
end
