if not DXMCore then return end
DXMCraftingQueue = DXMCraftingQueue or {}

local Queue = DXMCraftingQueue
local panel, panelOwner, statusText, countText, startButton, stopButton
local rows, offset = {}, 0
local PAGE_SIZE = 10
local running, stopRequested, activeRecipeID, activeRemaining, activeStarted = false, false, nil, 0, false
local preferredRecipeID
local suspendedChildren, suspendedRegions = {}, {}
local refreshScheduled = false

local function suspendOwner()
    wipe(suspendedChildren)
    wipe(suspendedRegions)
    if not panelOwner then return end
    for _, child in ipairs({panelOwner:GetChildren()}) do
        if child ~= panel and child:IsShown() then
            suspendedChildren[#suspendedChildren + 1] = child
            child:Hide()
        end
    end
    for _, region in ipairs({panelOwner:GetRegions()}) do
        if region:IsShown() then
            suspendedRegions[#suspendedRegions + 1] = region
            region:Hide()
        end
    end
end

local function restoreOwner()
    for _, child in ipairs(suspendedChildren) do child:Show() end
    for _, region in ipairs(suspendedRegions) do region:Show() end
    wipe(suspendedChildren)
    wipe(suspendedRegions)
end

local function professionInfo()
    if not C_TradeSkillUI or not C_TradeSkillUI.GetBaseProfessionInfo then return end
    return C_TradeSkillUI.GetBaseProfessionInfo()
end

local function craftable(recipeID)
    if not C_TradeSkillUI or not C_TradeSkillUI.GetCraftableCount then return 0 end
    local ok, count = pcall(C_TradeSkillUI.GetCraftableCount, recipeID)
    return ok and math.max(0, math.floor(tonumber(count) or 0)) or 0
end

local function tradeSkillReady()
    if C_TradeSkillUI.IsDataSourceChanging and C_TradeSkillUI.IsDataSourceChanging() then return false end
    if C_TradeSkillUI.IsTradeSkillReady and not C_TradeSkillUI.IsTradeSkillReady() then return false end
    return true
end

local function scheduleRefresh()
    if refreshScheduled then return end
    refreshScheduled = true
    C_Timer.After(.25, function()
        refreshScheduled = false
        if panel and panel:IsShown() then Queue:Refresh() end
    end)
end

local function queueEntries()
    local list = {}
    for key, recipe in pairs(DXMShoppingList and DXMShoppingList.recipes or {}) do
        local recipeID = tonumber(recipe.recipeID or key)
        local crafts = math.max(0, math.floor(tonumber(recipe.crafts) or 0))
        if recipeID and crafts > 0 then
            list[#list + 1] = {
                recipeID=recipeID, name=recipe.name or ("Recipe "..recipeID), icon=recipe.icon or 134400,
                crafts=crafts, professionID=tonumber(recipe.professionID), professionName=recipe.professionName or "Unknown",
            }
        end
    end
    table.sort(list, function(a,b)
        local ap, bp = (a.professionName or ""):lower(), (b.professionName or ""):lower()
        if ap ~= bp then return ap < bp end
        local an, bn = (a.name or ""):lower(), (b.name or ""):lower()
        if an ~= bn then return an < bn end
        return a.recipeID < b.recipeID
    end)
    return list
end

local function setStatus(text)
    if statusText then statusText:SetText(text or "") end
end

local function stopQueue(message)
    running, stopRequested, activeRecipeID, activeRemaining, activeStarted = false, false, nil, 0, false
    if startButton then startButton:Enable() end
    if stopButton then stopButton:Disable() end
    Queue:Refresh()
    if message then setStatus(message) end
end

local function recipeForCurrentProfession()
    local current = professionInfo()
    if not current then return nil, "Open a profession before starting the queue." end
    local otherProfession
    local entries = queueEntries()
    if preferredRecipeID then
        for _, entry in ipairs(entries) do
            if entry.recipeID == preferredRecipeID then
                local sameProfession = not entry.professionID or entry.professionID == tonumber(current.professionID)
                local info = sameProfession and C_TradeSkillUI.GetRecipeInfo(entry.recipeID)
                if info and info.learned then return entry, nil, info end
            end
        end
        preferredRecipeID = nil
    end
    for _, entry in ipairs(entries) do
        local sameProfession = not entry.professionID or entry.professionID == tonumber(current.professionID)
        if sameProfession then
            local info = C_TradeSkillUI.GetRecipeInfo(entry.recipeID)
            if info and info.learned then return entry, nil, info end
        elseif not otherProfession then
            otherProfession = entry.professionName
        end
    end
    if otherProfession then return nil, "This profession is complete. Open "..otherProfession.." to continue." end
    return nil, "No craftable queued recipes are available in "..(current.professionName or "this profession").."." 
end

local prepareNext
prepareNext = function()
    if not running then return end
    if InCombatLockdown and InCombatLockdown() then stopQueue("Finish combat, then resume the crafting queue."); return end
    if not tradeSkillReady() then
        C_Timer.After(.25,prepareNext); return
    end

    local entry,reason,info=recipeForCurrentProfession()
    if not entry then stopQueue(reason); if print and reason then print("|cffffd100DXM:|r "..reason) end; return end
    if info.isDummyRecipe or info.isGatheringRecipe or info.isRecraft or info.isEnchantingRecipe then
        stopQueue(entry.name.." requires Blizzard's normal crafting controls."); return
    end
    local available=craftable(entry.recipeID)
    if available<1 then stopQueue("Not enough materials to craft "..entry.name.."."); return end
    local amount=math.min(entry.crafts,available)
    if info.canCreateMultiple==false then amount=1 end
    activeRecipeID,activeRemaining,activeStarted=entry.recipeID,amount,false
    local crafted,craftError=pcall(C_TradeSkillUI.CraftRecipe,entry.recipeID,amount)
    if not crafted then
        activeRecipeID,activeRemaining,activeStarted=nil,0,false
        stopQueue(tostring(craftError or "The recipe could not be crafted."))
        return
    end
    setStatus(("Crafting %d x %s. The queue will update as each item finishes."):format(amount,entry.name))
    if print then print(("|cffffd100DXM:|r Crafting %d x %s from the DXM queue."):format(amount,entry.name)) end
end

function Queue:Start()
    if running then return end
    running=true
    if startButton then startButton:Disable() end
    if stopButton then stopButton:Enable() end
    prepareNext()
end

function Queue:CraftMax(recipeID)
    if running then setStatus("Stop the current queue before using Craft Max."); return 0 end
    recipeID = tonumber(recipeID)
    local recipe = recipeID and DXMShoppingList and DXMShoppingList.recipes and DXMShoppingList.recipes[tostring(recipeID)]
    local current = professionInfo()
    if not recipe or not current then setStatus("Open the recipe's profession before using Craft Max."); return 0 end
    if recipe.professionID and tonumber(recipe.professionID) ~= tonumber(current.professionID) then
        setStatus("Open " .. (recipe.professionName or "the required profession") .. " before using Craft Max.")
        return 0
    end
    if not tradeSkillReady() then
        setStatus("Loading profession recipes...")
        scheduleRefresh()
        return 0
    end
    local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
    if not info or not info.learned then setStatus("That recipe is not available in the open profession."); return 0 end
    if info.isDummyRecipe or info.isGatheringRecipe or info.isRecraft or info.isEnchantingRecipe then
        setStatus((recipe.name or "That recipe") .. " requires Blizzard's normal crafting controls.")
        return 0
    end
    local available = craftable(recipeID)
    if available < 1 then setStatus("Your inventory does not contain enough materials to craft " .. (recipe.name or "this recipe") .. "."); return 0 end
    DXMShopping:SetRecipeCrafts(recipeID, available)
    preferredRecipeID = recipeID
    self:Start()
    return available
end

function Queue:Stop()
    if not running then return end
    running = false
    setStatus(activeRecipeID and "Queue stopped. The current recipe batch may finish." or "Queue stopped.")
    if startButton then startButton:Enable() end
    if stopButton then stopButton:Disable() end
end

function Queue:Refresh()
    if not panel or not panel:IsShown() then return end
    local list = queueEntries()
    offset = math.max(0, math.min(offset, math.max(0, #list - PAGE_SIZE)))
    local current = professionInfo()
    for index, row in ipairs(rows) do
        local entry = list[offset + index]
        row.entry = entry
        if entry then
            row.Icon:SetTexture(entry.icon)
            row.Name:SetText(entry.name)
            row.Profession:SetText(entry.professionName)
            row.Queued:SetText(entry.crafts)
            local same = current and (not entry.professionID or entry.professionID == tonumber(current.professionID))
            local ready = same and tradeSkillReady()
            local info = ready and C_TradeSkillUI.GetRecipeInfo(entry.recipeID) or nil
            local directCraft = info and info.learned and not info.isDummyRecipe and not info.isGatheringRecipe and not info.isRecraft and not info.isEnchantingRecipe
            local available = directCraft and craftable(entry.recipeID) or nil
            row.Available:SetText(same and not ready and "..." or available or "--")
            row.available = available
            row.Minus:SetEnabled(not running or activeRecipeID ~= entry.recipeID)
            row.Plus:SetEnabled(not running or activeRecipeID ~= entry.recipeID)
            row.Max:SetEnabled(not running and directCraft and available and available > 0)
            row.Remove:SetEnabled(not running or activeRecipeID ~= entry.recipeID)
            row:Show()
            if same and not ready then scheduleRefresh() end
        else row:Hide() end
    end
    countText:SetText(("Showing %d-%d of %d queued recipes"):format(#list == 0 and 0 or offset+1, math.min(offset+PAGE_SIZE,#list), #list))
    panel.Previous:SetEnabled(offset > 0)
    panel.Next:SetEnabled(offset + PAGE_SIZE < #list)
    if not running then
        startButton:SetEnabled(#list > 0)
        stopButton:Disable()
        if #list == 0 then setStatus("Queue is empty. Right-click recipes in DXM Craft Profit to add them.")
        elseif current and not tradeSkillReady() then setStatus("Loading profession recipes..."); scheduleRefresh()
        elseif current then setStatus("Open the required profession, then click Craft Next or Craft Max.")
        else setStatus("Open a profession to craft the queued recipes.") end
    end
end

local function adjust(row, delta)
    local entry = row and row.entry
    if not entry then return end
    DXMShopping:SetRecipeCrafts(entry.recipeID, entry.crafts + delta)
end

local function makeRow(parent, previous, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(34); row:SetPoint("LEFT", previous, "LEFT"); row:SetPoint("RIGHT", previous, "RIGHT"); row:SetPoint("TOP", previous, "BOTTOM")
    local bg=row:CreateTexture(nil,"BACKGROUND"); bg:SetAllPoints(); local shade=index%2==0 and .10 or .035; bg:SetColorTexture(shade,shade,shade,.9)
    row.Icon=row:CreateTexture(nil,"ARTWORK"); row.Icon:SetSize(27,27); row.Icon:SetPoint("LEFT",4,0)
    row.Name=row:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); row.Name:SetJustifyH("LEFT")
    row.Profession=row:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); row.Profession:SetJustifyH("CENTER")
    row.Queued=row:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); row.Queued:SetJustifyH("CENTER")
    row.Available=row:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); row.Available:SetJustifyH("CENTER")
    row.Minus=DXMTheme:CreateButton(row); row.Minus:SetSize(28,23); row.Minus:SetText("-"); row.Minus:SetScript("OnClick",function() adjust(row,-1) end)
    row.Plus=DXMTheme:CreateButton(row); row.Plus:SetSize(28,23); row.Plus:SetText("+"); row.Plus:SetScript("OnClick",function() adjust(row,1) end)
    row.Max=DXMTheme:CreateButton(row); row.Max:SetSize(72,23); row.Max:SetText("Craft Max"); row.Max:SetScript("OnClick",function() if row.entry then Queue:CraftMax(row.entry.recipeID) end end)
    row.Remove=DXMTheme:CreateButton(row); row.Remove:SetSize(65,23); row.Remove:SetText("Remove"); row.Remove:SetScript("OnClick",function() if row.entry then DXMShopping:RemoveRecipe(row.entry.recipeID) end end)
    return row
end

local function createPanel(owner)
    panelOwner=owner
    panel=DXMTheme:CreatePanel(owner,"DXMCraftingQueueFrame")
    panel:SetAllPoints(owner); panel:SetFrameStrata("FULLSCREEN_DIALOG"); panel:SetFrameLevel(1000); panel:SetToplevel(true); panel:EnableMouse(true)
    local fill=panel:CreateTexture(nil,"BACKGROUND"); fill:SetPoint("TOPLEFT",4,-4); fill:SetPoint("BOTTOMRIGHT",-4,4); fill:SetColorTexture(.025,.025,.025,1)
    local title=panel:CreateFontString(nil,"ARTWORK","GameFontNormalLarge"); title:SetPoint("TOPLEFT",18,-16); title:SetText("DXM Crafting Queue")
    local back=DXMTheme:CreateButton(panel); back:SetSize(125,25); back:SetPoint("TOPRIGHT",-16,-12); back:SetText("Back to Profit"); back:SetScript("OnClick",function() Queue:Stop(); panel:Hide() end)
    statusText=panel:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); statusText:SetPoint("TOPLEFT",title,"BOTTOMLEFT",0,-10); statusText:SetPoint("RIGHT",back,"LEFT",-12,0); statusText:SetJustifyH("LEFT")
    local header=CreateFrame("Frame",nil,panel); header:SetPoint("TOPLEFT",statusText,"BOTTOMLEFT",-6,-12); header:SetPoint("TOPRIGHT",-12,0); header:SetHeight(24)
    local bg=header:CreateTexture(nil,"BACKGROUND"); bg:SetAllPoints(); bg:SetColorTexture(.16,.12,.05,.95)
    local boundaries={0,.38,.54,.62,.72,1}
    local labels={}
    for index,text in ipairs({"Recipe","Profession","Queued","Can Craft","Adjust"}) do
        labels[index]=header:CreateFontString(nil,"ARTWORK","GameFontNormalSmall")
        labels[index]:SetJustifyH("CENTER"); labels[index]:SetText(text)
    end
    local previous=header
    for i=1,PAGE_SIZE do rows[i]=makeRow(panel,previous,i); previous=rows[i] end
    local function place(region,owner,left,right,leftInset,rightInset)
        region:ClearAllPoints(); region:SetPoint("LEFT",owner,"LEFT",left+(leftInset or 0),0)
        region:SetWidth(math.max(1,right-left-(leftInset or 0)-(rightInset or 0)))
    end
    local function layout(width)
        local pixels={}
        for index,value in ipairs(boundaries) do pixels[index]=math.floor(width*value) end
        for index,label in ipairs(labels) do place(label,header,pixels[index],pixels[index+1],2,2) end
        for _,row in ipairs(rows) do
            place(row.Name,row,pixels[1],pixels[2],36,5)
            place(row.Profession,row,pixels[2],pixels[3],3,3)
            place(row.Queued,row,pixels[3],pixels[4],3,3)
            place(row.Available,row,pixels[4],pixels[5],3,3)
            row.Remove:ClearAllPoints(); row.Remove:SetPoint("RIGHT",row,"RIGHT",-4,0)
            row.Max:ClearAllPoints(); row.Max:SetPoint("RIGHT",row.Remove,"LEFT",-4,0)
            row.Plus:ClearAllPoints(); row.Plus:SetPoint("RIGHT",row.Max,"LEFT",-4,0)
            row.Minus:ClearAllPoints(); row.Minus:SetPoint("RIGHT",row.Plus,"LEFT",-3,0)
        end
    end
    header:SetScript("OnSizeChanged",function(_,width) if width>0 then layout(width) end end)
    C_Timer.After(0,function() if header:GetWidth()>0 then layout(header:GetWidth()) end end)
    panel.Previous=DXMTheme:CreateButton(panel); panel.Previous:SetSize(30,23); panel.Previous:SetPoint("BOTTOMLEFT",18,15); panel.Previous:SetText("<"); panel.Previous:SetScript("OnClick",function() offset=math.max(0,offset-PAGE_SIZE); Queue:Refresh() end)
    panel.Next=DXMTheme:CreateButton(panel); panel.Next:SetSize(30,23); panel.Next:SetPoint("LEFT",panel.Previous,"RIGHT",5,0); panel.Next:SetText(">"); panel.Next:SetScript("OnClick",function() offset=offset+PAGE_SIZE; Queue:Refresh() end)
    countText=panel:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); countText:SetPoint("LEFT",panel.Next,"RIGHT",10,0)
    startButton=DXMTheme:CreateButton(panel); startButton:SetSize(120,26); startButton:SetPoint("BOTTOMRIGHT",-112,14); startButton:SetText("Craft Next"); startButton:SetScript("OnClick",function() Queue:Start() end)
    stopButton=DXMTheme:CreateButton(panel); stopButton:SetSize(90,26); stopButton:SetPoint("LEFT",startButton,"RIGHT",6,0); stopButton:SetText("Stop"); stopButton:SetScript("OnClick",function() Queue:Stop() end)
    panel:SetScript("OnShow",function() suspendOwner(); Queue:Refresh() end)
    panel:SetScript("OnHide",restoreOwner)
    panel:Hide()
end

function Queue:Show(owner)
    if not panel then createPanel(owner) end
    panel:Show()
    self:Refresh()
end

local events=CreateFrame("Frame")
for _,event in ipairs({"TRADE_SKILL_CRAFT_BEGIN","TRADE_SKILL_ITEM_CRAFTED_RESULT","UPDATE_TRADESKILL_CAST_STOPPED","TRADE_SKILL_CLOSE","TRADE_SKILL_LIST_UPDATE","TRADE_SKILL_DATA_SOURCE_CHANGED","BAG_UPDATE_DELAYED"}) do
    pcall(events.RegisterEvent,events,event)
end
events:SetScript("OnEvent",function(_,event,...)
    if event=="TRADE_SKILL_CRAFT_BEGIN" then
        local recipeID=tonumber(...)
        if running and recipeID==activeRecipeID then activeStarted=true end
    elseif event=="TRADE_SKILL_ITEM_CRAFTED_RESULT" then
        if running and activeRecipeID and activeRemaining>0 then
            local recipe=DXMShoppingList.recipes[tostring(activeRecipeID)]
            if recipe then DXMShopping:SetRecipeCrafts(activeRecipeID,(tonumber(recipe.crafts) or 0)-1) end
            activeRemaining=activeRemaining-1
            if activeRemaining<=0 then stopQueue("Batch complete. Click Craft Next to continue.") end
        end
    elseif event=="UPDATE_TRADESKILL_CAST_STOPPED" then
        if running and activeRecipeID then
            stopQueue("Crafting stopped before the current queued batch finished.")
        end
    elseif event=="TRADE_SKILL_CLOSE" then
        if running then stopQueue("Queue paused because the profession window closed.") end
    elseif event=="TRADE_SKILL_LIST_UPDATE" or event=="TRADE_SKILL_DATA_SOURCE_CHANGED" or event=="BAG_UPDATE_DELAYED" then Queue:Refresh() end
end)
