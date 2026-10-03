if not DXMCore then return end

local Module = DXMCore:Module("Crafting")
Module.bootType = DXMCore.Const().BootType.PlayerEnteringWorld
DXMShoppingList = DXMShoppingList or {}
DXMShoppingList.items = DXMShoppingList.items or {}
DXMShoppingList.recipes = DXMShoppingList.recipes or {}
DXMShopping = DXMShopping or {}

local panel, status, tab
local rows = {}
local ROWS = 9

local function itemCounts(itemID)
    local bags, total = 0, 0
    if C_Item and C_Item.GetItemCount then
        local okBags, bagCount = pcall(C_Item.GetItemCount, itemID, false, false, false, false)
        local okTotal, totalCount = pcall(C_Item.GetItemCount, itemID, true, false, true, false)
        if okBags then bags = tonumber(bagCount) or 0 end
        if okTotal then total = tonumber(totalCount) or bags end
    elseif GetItemCount then
        bags = tonumber(GetItemCount(itemID, false)) or 0
        total = tonumber(GetItemCount(itemID, true)) or bags
    end
    return bags, math.max(0, total - bags), total
end

local function owned(itemID)
    local _, _, total = itemCounts(itemID)
    return total
end
local function merchantMap()
    local map = {}
    if not MerchantFrame or not MerchantFrame:IsShown() then return map end
    for index = 1, (GetMerchantNumItems and GetMerchantNumItems() or 0) do
        local name, icon, price, bundle, available, purchasable, extended
        if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
            local info = C_MerchantFrame.GetItemInfo(index)
            if info then
                name, icon, price, bundle, available = info.name, info.texture, info.price, info.stackCount, info.numAvailable
                purchasable, extended = info.isPurchasable, info.hasExtendedCost
            end
        elseif GetMerchantItemInfo then
            local _, usable
            name, icon, price, bundle, available, purchasable, usable, extended = GetMerchantItemInfo(index)
        end
        local link = GetMerchantItemLink and GetMerchantItemLink(index)
        local itemID = link and C_Item and C_Item.GetItemInfoInstant and C_Item.GetItemInfoInstant(link)
        if itemID then
            map[tonumber(itemID)] = {
                index=index, name=name, icon=icon, price=tonumber(price) or 0,
                bundle=math.max(1, tonumber(bundle) or 1), available=tonumber(available) or -1,
                purchasable=purchasable ~= false and not extended,
            }
        end
    end
    return map
end

function DXMShopping:GetRows(withMerchant, sourceFilter)
    local vendors, list = withMerchant and merchantMap() or {}, {}
    for key, entry in pairs(DXMShoppingList.items) do
        local itemID = tonumber(entry.itemID or key)
        local needed = math.max(0, math.floor(tonumber(entry.needed) or 0))
        local source = entry.source == "vendor" or (not entry.source and tonumber(DXMVendorPrices and DXMVendorPrices[tostring(itemID)]) and tonumber(DXMVendorPrices[tostring(itemID)]) > 0)
            source = source and "vendor" or "AH"
        if itemID and needed > 0 and (not sourceFilter or source == sourceFilter) then
            local bags, bank, total = itemCounts(itemID)
            list[#list + 1] = {
                itemID=itemID,
                name=(C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)) or entry.name or ("Item "..itemID),
                source=source, needed=needed, bags=bags, bank=bank, owned=total,
                remaining=math.max(0, needed-total), withdraw=math.min(bank, math.max(0, needed-bags)), vendor=vendors[itemID],
            }
        end
    end
    table.sort(list, function(a,b)
        local av, bv = a.vendor and a.remaining > 0 or false, b.vendor and b.remaining > 0 or false
        if av ~= bv then return av end
        if a.remaining ~= b.remaining then return a.remaining > b.remaining end
        if a.name ~= b.name then return a.name < b.name end
        return a.itemID < b.itemID
    end)
    return list
end

function DXMShopping:GetRecipeCount()
    local count = 0
    for _, recipe in pairs(DXMShoppingList.recipes) do
        if (tonumber(recipe.crafts) or 0) > 0 then count = count + 1 end
    end
    return count
end

function DXMShopping:RebuildItems()
    wipe(DXMShoppingList.items)
    for _, recipe in pairs(DXMShoppingList.recipes) do
        local crafts = math.max(0, math.floor(tonumber(recipe.crafts) or 0))
        for _, reagent in ipairs(recipe.reagents or {}) do
            local itemID = tonumber(reagent.itemID)
            local quantity = math.ceil((tonumber(reagent.quantity) or 0) * crafts)
            if itemID and quantity > 0 then
                local key = tostring(itemID)
                local entry = DXMShoppingList.items[key] or {itemID=itemID, needed=0}
                entry.itemID, entry.name = itemID, reagent.name or entry.name
                entry.source = reagent.source == "vendor" and "vendor" or (entry.source or "AH")
                entry.needed = math.max(0, math.floor(tonumber(entry.needed) or 0)) + quantity
                DXMShoppingList.items[key] = entry
            end
        end
    end
end

function DXMShopping:SetRecipeCrafts(recipeID, crafts)
    local key = tostring(tonumber(recipeID) or recipeID)
    local recipe = DXMShoppingList.recipes[key]
    if not recipe then return end
    recipe.crafts = math.max(0, math.floor(tonumber(crafts) or 0))
    if recipe.crafts == 0 then DXMShoppingList.recipes[key] = nil end
    self:RebuildItems()
    self:Refresh()
end

function DXMShopping:RemoveRecipe(recipeID)
    DXMShoppingList.recipes[tostring(tonumber(recipeID) or recipeID)] = nil
    self:RebuildItems()
    self:Refresh()
end

function DXMShopping:AddRecipe(result, crafts)
    crafts = math.max(1, math.floor(tonumber(crafts) or 1))
    local recipeID = tonumber(result and result.recipeID)
    if recipeID then
        local key = tostring(recipeID)
        local recipe = DXMShoppingList.recipes[key] or {recipeID=recipeID, name=result.name, icon=result.icon, crafts=0, reagents={}}
        recipe.name, recipe.icon = result.name or recipe.name, result.icon or recipe.icon
        recipe.crafts = math.max(0, math.floor(tonumber(recipe.crafts) or 0)) + crafts
        recipe.reagents = result.reagents or recipe.reagents
        local profession = C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo and C_TradeSkillUI.GetBaseProfessionInfo()
        recipe.professionID = result.professionID or recipe.professionID or (profession and profession.professionID)
        recipe.professionName = result.professionName or recipe.professionName or (profession and profession.professionName)
        DXMShoppingList.recipes[key] = recipe
    end
    local added = 0
    for _, reagent in ipairs(result and result.reagents or {}) do
        added = added + math.ceil((tonumber(reagent.quantity) or 0) * crafts)
    end
    DXMShopping:RebuildItems()
    DXMShopping:Refresh()
    return added
end
function DXMShopping:Remove(itemID)
    DXMShoppingList.items[tostring(itemID)] = nil
    self:Refresh()
end

function DXMShopping:ClearCompleted()
    for key, entry in pairs(DXMShoppingList.items) do
        local itemID = tonumber(entry.itemID or key)
        if itemID and owned(itemID) >= (tonumber(entry.needed) or 0) then DXMShoppingList.items[key] = nil end
    end
    self:Refresh()
end

function DXMShopping:ClearAll()
    wipe(DXMShoppingList.items)
    wipe(DXMShoppingList.recipes)
    self:Refresh()
end

function DXMShopping:Refresh()
    if panel and panel:IsShown() then self:RefreshMerchant() end
    if self.RefreshAuction then self:RefreshAuction() end
    if DXMCraftingQueue and DXMCraftingQueue.Refresh then DXMCraftingQueue:Refresh() end
end

local function buyItem(item)
    local vendor = item and item.vendor
    if not item or item.remaining <= 0 or not vendor or not vendor.purchasable then return end
    local bundles = math.ceil(item.remaining / vendor.bundle)
    if vendor.available >= 0 then bundles = math.min(bundles, math.floor(vendor.available / vendor.bundle)) end
    if vendor.price > 0 and GetMoney then bundles = math.min(bundles, math.floor(GetMoney() / vendor.price)) end
    local units = bundles * vendor.bundle
    if units <= 0 then status:SetText("Cannot buy "..item.name..": check stock and money."); return end
    local maxStack = GetMerchantItemMaxStack and tonumber(GetMerchantItemMaxStack(vendor.index)) or units
    maxStack = math.max(vendor.bundle, maxStack or units)
    local left = units
    while left > 0 do
        local chunk = math.min(left, maxStack)
        chunk = math.max(vendor.bundle, math.floor(chunk/vendor.bundle)*vendor.bundle)
        BuyMerchantItem(vendor.index, chunk)
        left = left-chunk
    end
    status:SetText(("Bought %d x %s."):format(units,item.name))
    C_Timer.After(.25,function() DXMShopping:Refresh() end)
end

function DXMShopping:RefreshMerchant()
    if not panel then return end
    local list, available, remaining = self:GetRows(true, "vendor"), 0, 0
    for index,row in ipairs(rows) do
        local item=list[index]
        row.item=item
        if item then
            local icon=(item.vendor and item.vendor.icon) or (C_Item.GetItemIconByID and C_Item.GetItemIconByID(item.itemID)) or 134400
            row.Icon:SetTexture(icon); row.Name:SetText(item.name); row.Need:SetText(item.needed); row.Have:SetText(item.bags .. "/" .. item.bank)
            if item.remaining==0 then row.Buy:SetText("Complete"); row.Buy:Disable()
            elseif item.vendor and item.vendor.purchasable then row.Buy:SetText("Buy "..(math.ceil(item.remaining/item.vendor.bundle)*item.vendor.bundle)); row.Buy:Enable()
            elseif item.vendor then row.Buy:SetText("Unavailable"); row.Buy:Disable()
            else row.Buy:SetText("Not here"); row.Buy:Disable() end
            row:Show()
        else row:Hide() end
    end
    for _,item in ipairs(list) do
        remaining=remaining+item.remaining
        if item.vendor and item.vendor.purchasable and item.remaining>0 then available=available+1 end
    end
    status:SetText(#list==0 and "Buy list is empty. Right-click recipes in DXM Craft Profit." or
        ("%d vendor items, %d units still to buy; %d available here. Bags/Bank shown separately."):format(#list,remaining,available))
end

local function makeRow(previous,index)
    local row=CreateFrame("Button",nil,panel)
    row:SetHeight(29); row:SetPoint("LEFT",8,0); row:SetPoint("RIGHT",-8,0); row:SetPoint("TOP",previous,"BOTTOM")
    local bg=row:CreateTexture(nil,"BACKGROUND"); bg:SetAllPoints(); local shade=index%2==0 and .09 or .025; bg:SetColorTexture(shade,shade,shade,.96)
    local line=row:CreateTexture(nil,"BORDER"); line:SetPoint("BOTTOMLEFT"); line:SetPoint("BOTTOMRIGHT"); line:SetHeight(1); line:SetColorTexture(.31,.27,.19,.72)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight","ADD")
    row.Icon=row:CreateTexture(nil,"ARTWORK"); row.Icon:SetSize(24,24); row.Icon:SetPoint("LEFT",2,0)
    row.Name=row:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); row.Name:SetPoint("LEFT",30,0); row.Name:SetPoint("RIGHT",-154,0); row.Name:SetJustifyH("LEFT")
    row.Need=row:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); row.Need:SetPoint("RIGHT",-116,0); row.Need:SetWidth(34)
    row.Have=row:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); row.Have:SetPoint("RIGHT",-78,0); row.Have:SetWidth(34)
    row.Buy=DXMTheme:CreateButton(row); row.Buy:SetSize(76,22); row.Buy:SetPoint("RIGHT",-1,0); row.Buy:SetScript("OnClick",function() buyItem(row.item) end)
    row:RegisterForClicks("RightButtonUp"); row:SetScript("OnClick",function(self,button) if button=="RightButton" and self.item then DXMShopping:Remove(self.item.itemID) end end)
    row:SetScript("OnEnter",function(self) if not self.item then return end; GameTooltip:SetOwner(self,"ANCHOR_RIGHT"); if GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.item.itemID) end; GameTooltip:AddLine("Right-click to remove.",.35,.8,1); GameTooltip:Show() end)
    row:SetScript("OnLeave",function() GameTooltip:Hide() end)
    return row
end

local function raisePanel()
    if not panel then return end
    local parent = panel:GetParent()
    local parentLevel = parent and parent:GetFrameLevel() or 0
    panel:SetFrameStrata("DIALOG")
    panel:SetFrameLevel(math.max(parentLevel + 200, 500))
    if panel.Raise then panel:Raise() end
end
local function createPanel()
    if panel or not MerchantFrame or not MerchantFrameTab2 then return end
    tab=CreateFrame("Button","DXMMerchantTab",MerchantFrame,"PanelTabButtonTemplate")
    tab:SetID(3); tab:SetText("DXM"); tab:SetPoint("LEFT",MerchantFrameTab2,"RIGHT",-16,0)
    if PanelTemplates_SetNumTabs then PanelTemplates_SetNumTabs(MerchantFrame,3) end
    if PanelTemplates_TabResize then PanelTemplates_TabResize(tab,0) end
    panel=DXMTheme:CreatePanel(MerchantFrame,"DXMMerchantCraftingFrame")
    panel:SetPoint("TOPLEFT",6,-58); panel:SetPoint("BOTTOMRIGHT",-6,35)
    panel:SetToplevel(true); panel:SetScript("OnShow",raisePanel); raisePanel(); panel:EnableMouse(true)
    local fill=panel:CreateTexture(nil,"BACKGROUND"); fill:SetPoint("TOPLEFT",4,-4); fill:SetPoint("BOTTOMRIGHT",-4,4); fill:SetColorTexture(.025,.025,.025,1)
    local title=panel:CreateFontString(nil,"ARTWORK","GameFontNormalLarge"); title:SetPoint("TOPLEFT",14,-12); title:SetText("DXM Crafting Buy List")
    status=panel:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); status:SetPoint("TOPLEFT",title,"BOTTOMLEFT",0,-6); status:SetPoint("RIGHT",-12,0); status:SetJustifyH("LEFT")
    local header=CreateFrame("Frame",nil,panel); header:SetPoint("TOPLEFT",8,-55); header:SetPoint("TOPRIGHT",-8,-55); header:SetHeight(22)
    local hbg=header:CreateTexture(nil,"BACKGROUND"); hbg:SetAllPoints(); hbg:SetColorTexture(.16,.12,.05,.95)
    local label=header:CreateFontString(nil,"ARTWORK","GameFontNormalSmall"); label:SetPoint("LEFT",8,0); label:SetText("Item")
    for _,spec in ipairs({{"Need",-116,34},{"B/B",-78,34},{"Action",-1,76}}) do local t=header:CreateFontString(nil,"ARTWORK","GameFontNormalSmall"); t:SetPoint("RIGHT",spec[2],0); t:SetWidth(spec[3]); t:SetText(spec[1]) end
    local previous=header
    for index=1,ROWS do rows[index]=makeRow(previous,index); previous=rows[index] end
    local complete=DXMTheme:CreateButton(panel); complete:SetSize(120,23); complete:SetPoint("BOTTOMLEFT",10,9); complete:SetText("Clear Complete"); complete:SetScript("OnClick",function() DXMShopping:ClearCompleted() end)
    local clear=DXMTheme:CreateButton(panel); clear:SetSize(76,23); clear:SetPoint("LEFT",complete,"RIGHT",5,0); clear:SetText("Clear All"); clear:SetScript("OnClick",function() DXMShopping:ClearAll() end)
    tab:SetScript("OnClick",function() MerchantFrame.selectedTab=3; if PanelTemplates_SetTab then PanelTemplates_SetTab(MerchantFrame,3) end; panel:Show(); raisePanel(); DXMShopping:RefreshMerchant() end)
    MerchantFrameTab1:HookScript("OnClick",function() panel:Hide() end); MerchantFrameTab2:HookScript("OnClick",function() panel:Hide() end)
    panel:Hide()
end

local events=CreateFrame("Frame")
for _,event in ipairs({"ADDON_LOADED","MERCHANT_SHOW","MERCHANT_CLOSED","MERCHANT_UPDATE","BAG_UPDATE_DELAYED"}) do events:RegisterEvent(event) end
events:SetScript("OnEvent",function(_,event)
    if event=="ADDON_LOADED" then createPanel(); return end
    if event=="MERCHANT_SHOW" then createPanel(); if panel then panel:Hide() end
    elseif event=="MERCHANT_CLOSED" then if panel then panel:Hide() end
    elseif event=="MERCHANT_UPDATE" and panel and panel:IsShown() then C_Timer.After(0,function() DXMShopping:RefreshMerchant() end)
    elseif event=="BAG_UPDATE_DELAYED" then DXMShopping:Refresh() end
end)

function Module:Boot()
    DXMShopping:RebuildItems()
    createPanel()
end


