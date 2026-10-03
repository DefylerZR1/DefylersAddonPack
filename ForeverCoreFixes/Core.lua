-- Blizzard 1.60.1 now loads its native Camelot Who List. Do not create or
-- reparent LFGWhoListFrame here: injecting an addon-owned frame into the secure
-- Group Finder taints secret search-result values used by Blizzard's sorter.

-- Some Forever client builds return nil for an achievement's point value.
-- Blizzard_AchievementUI passes that value through this helper and then makes
-- two numeric comparisons with it while building the summary. Normalize the
-- helper's result so the summary can still open when the server omits points.
local achievementPointsGuardInstalled = false

local function InstallAchievementPointsGuard()
    if achievementPointsGuardInstalled or type(AchievementFrame_GetOverridePoints) ~= "function" then
        return
    end

    local originalGetOverridePoints = AchievementFrame_GetOverridePoints
    AchievementFrame_GetOverridePoints = function(points, achievementId)
        local resolvedPoints = originalGetOverridePoints(points, achievementId)
        return tonumber(resolvedPoints) or tonumber(points) or 0
    end

    achievementPointsGuardInstalled = true
end

local achievementPointsEventFrame = CreateFrame("Frame")
achievementPointsEventFrame:RegisterEvent("ADDON_LOADED")
achievementPointsEventFrame:SetScript("OnEvent", function(self, _, loadedAddon)
    if loadedAddon == "Blizzard_AchievementUI" then
        InstallAchievementPointsGuard()
        if achievementPointsGuardInstalled then
            self:UnregisterEvent("ADDON_LOADED")
        end
    end
end)

local achievementUIIsLoaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_AchievementUI")
if not achievementUIIsLoaded and IsAddOnLoaded then
    achievementUIIsLoaded = IsAddOnLoaded("Blizzard_AchievementUI")
end
if achievementUIIsLoaded then
    InstallAchievementPointsGuard()
    achievementPointsEventFrame:UnregisterEvent("ADDON_LOADED")
end

-- Blizzard routes REPLACE_ENCHANT through its own event handler after addon
-- event handlers, so accepting from a parallel event frame can still leave the
-- dialog visible. Post-hook the popup creation instead: the confirmation state
-- is active and the Blizzard dialog already exists when this callback runs.
-- This does not replace or mutate Blizzard's shared popup definition, and the
-- separate TRADE_REPLACE_ENCHANT prompt remains untouched.
local acceptingReplaceEnchant = false
hooksecurefunc("StaticPopup_Show", function(which)
    if which ~= "REPLACE_ENCHANT" or acceptingReplaceEnchant then return end
    acceptingReplaceEnchant = true

    if C_Item and type(C_Item.ReplaceEnchant) == "function" then
        C_Item.ReplaceEnchant()
    elseif type(ReplaceEnchant) == "function" then
        ReplaceEnchant()
    end

    if StaticPopup_Hide then StaticPopup_Hide("REPLACE_ENCHANT") end
    acceptingReplaceEnchant = false
end)
