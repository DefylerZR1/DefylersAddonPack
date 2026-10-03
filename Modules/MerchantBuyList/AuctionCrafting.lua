if not DXMCore or not DXMShopping or not DXMExchange then return end

local page, status, pending, readyCommodity
local rows = {}
local offset, ROW_COUNT = 0, 8

local function message(text, alert)
    if status then status:SetText(text) end
    if alert and UIErrorsFrame and UIErrorsFrame.AddMessage then UIErrorsFrame:AddMessage(alert,1,.2,.2) end
end

local function finishCommodity(request)
    local quantity,total,maximum=0,0,0
    for index=1,(C_AuctionHouse.GetNumCommoditySearchResults(request.item.itemID) or 0) do
        local result=C_AuctionHouse.GetCommoditySearchResultInfo(request.item.itemID,index)
        local available=result and math.max(0,(tonumber(result.quantity) or 0)-(tonumber(result.numOwnerItems) or 0)) or 0
        local price=result and (tonumber(result.unitPrice) or 0) or 0
        if available>0 and price>0 then
            local take=math.min(request.item.remaining-quantity,available)
            quantity,total,maximum=quantity+take,total+take*price,price
            if quantity>=request.item.remaining then break end
        end
    end
    pending=nil
    if quantity<request.item.remaining then
        readyCommodity=nil
        message(("Only %d of %d %s are listed."):format(quantity,request.item.remaining,request.item.name),"DXM: not enough quantity is listed.")
    else
        local unitPrice=total/quantity
        if AuctionHouseUtil and AuctionHouseUtil.SanitizeAuctionHousePrice then unitPrice=AuctionHouseUtil.SanitizeAuctionHousePrice(unitPrice) end
        readyCommodity={itemID=request.item.itemID,quantity=request.item.remaining,unitPrice=unitPrice,totalPrice=total,maximum=maximum}
        DXMShopping:RefreshAuction()
        message(("Ready to buy %d x %s for %s. Click Buy to request Blizzard's quote."):format(request.item.remaining,request.item.name,GetMoneyString(total)))
    end
end

local function finishItem(request)
    local exact,partial
    for index=1,(C_AuctionHouse.GetNumItemSearchResults(request.itemKey) or 0) do
        local result=C_AuctionHouse.GetItemSearchResultInfo(request.itemKey,index)
        local price=result and (tonumber(result.buyoutAmount) or 0) or 0
        local quantity=result and math.max(1,tonumber(result.quantity) or 1) or 0
        if price>0 and result.auctionID then
            local candidate={auctionID=result.auctionID,price=price,quantity=quantity}
            if quantity==request.item.remaining and (not exact or price<exact.price) then exact=candidate
            elseif quantity<=request.item.remaining and (not partial or price/quantity<partial.price/partial.quantity) then partial=candidate end
        end
    end
    pending=nil
    local selected=exact or partial
    if not selected then
        message("No buyout stack fits the remaining quantity for "..request.item.name..".","DXM: no suitable buyout stack is listed.")
    else
        message(("Loaded %d x %s. Confirm it, then click again if more are needed."):format(selected.quantity,request.item.name))
        AuctionHouseFrame:StartItemBuyout(selected.auctionID,selected.price)
    end
end

local function search(item)
    if not item or item.remaining<=0 or not AuctionHouseFrame or not C_AuctionHouse then return end
    local quote=readyCommodity
    if quote and quote.itemID==item.itemID and quote.quantity==item.remaining then
        readyCommodity=nil
        DXMShopping:RefreshAuction()
        message(("Requesting Blizzard's quote for %d x %s..."):format(quote.quantity,item.name))
        AuctionHouseFrame:StartCommoditiesPurchase(quote.itemID,quote.quantity,quote.unitPrice,quote.totalPrice)
        return
    end
    readyCommodity=nil
    if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
        message("The Auction House is busy. Click the item again in a moment.","DXM: Auction House search is busy."); return
    end
    local itemKey=C_AuctionHouse.MakeItemKey(item.itemID)
    local info=itemKey and C_AuctionHouse.GetItemKeyInfo(itemKey)
    if not info then message("Item details are loading. Click the row again.","DXM: item details are loading."); return end
    pending={item=item,itemKey=itemKey,commodity=info.isCommodity}
    message(("Searching for %d x %s..."):format(item.remaining,item.name))
    AuctionHouseFrame:QueryItem(info.isCommodity and AuctionHouseSearchContext.BuyCommodities or AuctionHouseSearchContext.BuyItems,itemKey)
    local request=pending
    C_Timer.After(5,function() if pending==request then pending=nil; message("Search timed out. Click the item again.","DXM: Auction House search timed out.") end end)
end

local events=CreateFrame("Frame")
events:RegisterEvent("COMMODITY_SEARCH_RESULTS_RECEIVED")
events:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
events:SetScript("OnEvent",function(_,event,...)
    local request=pending
    if not request then return end
    if event=="COMMODITY_SEARCH_RESULTS_RECEIVED" and request.commodity then
        local itemID=...
        if not itemID or tonumber(itemID)==request.item.itemID then finishCommodity(request) end
    elseif event=="ITEM_SEARCH_RESULTS_UPDATED" and not request.commodity then
        local itemKey=...
        if not itemKey or DXMCore:ItemKeyKey(itemKey)==DXMCore:ItemKeyKey(request.itemKey) then finishItem(request) end
    end
end)

local function tooltip(row)
    if not row.item then return end
    GameTooltip:SetOwner(row,"ANCHOR_RIGHT")
    if GameTooltip.SetItemByID then GameTooltip:SetItemByID(row.item.itemID) end
    GameTooltip:AddLine("Right-click to remove from the crafting buy list.",.35,.8,1)
    GameTooltip:Show()
end

local function makeRow(parent,previous,index)
    local row=CreateFrame("Button",nil,parent)
    row:SetHeight(38); row:SetPoint("LEFT",4,0); row:SetPoint("RIGHT",-4,0); row:SetPoint("TOP",previous,"BOTTOM")
    local bg=row:CreateTexture(nil,"BACKGROUND"); bg:SetAllPoints(); local shade=index%2==0 and .10 or .025; bg:SetColorTexture(shade,shade,shade,.9)
    local line=row:CreateTexture(nil,"BORDER"); line:SetPoint("BOTTOMLEFT"); line:SetPoint("BOTTOMRIGHT"); line:SetHeight(1); line:SetColorTexture(.31,.27,.19,.72)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight","ADD")
    row.Icon=row:CreateTexture(nil,"ARTWORK"); row.Icon:SetSize(32,32); row.Icon:SetPoint("LEFT",5,0)
    row.Name=row:CreateFontString(nil,"ARTWORK","GameFontHighlight"); row.Name:SetPoint("LEFT",44,0); row.Name:SetPoint("RIGHT",-330,0); row.Name:SetJustifyH("LEFT")
    row.Need=row:CreateFontString(nil,"ARTWORK","GameFontHighlight"); row.Need:SetPoint("RIGHT",-252,0); row.Need:SetWidth(60)
    row.Owned=row:CreateFontString(nil,"ARTWORK","GameFontHighlight"); row.Owned:SetPoint("RIGHT",-190,0); row.Owned:SetWidth(60)
    row.Remaining=row:CreateFontString(nil,"ARTWORK","GameFontHighlight"); row.Remaining:SetPoint("RIGHT",-126,0); row.Remaining:SetWidth(64)
    row.Action=DXMTheme:CreateButton(row); row.Action:SetSize(118,26); row.Action:SetPoint("RIGHT",-4,0); row.Action:SetScript("OnClick",function() search(row.item) end)
    row:RegisterForClicks("RightButtonUp")
    row:SetScript("OnClick",function(self,button) if button=="RightButton" and self.item then DXMShopping:Remove(self.item.itemID) end end)
    row:SetScript("OnEnter",tooltip); row:SetScript("OnLeave",function() GameTooltip:Hide() end)
    return row
end

function DXMShopping:RefreshAuction()
    if not page then return end
    local list=self:GetRows(false,"AH")
    offset=math.min(offset,math.max(0,#list-ROW_COUNT))
    for visible,row in ipairs(rows) do
        local item=list[offset+visible]; row.item=item
        if item then
            row.Icon:SetTexture((C_Item.GetItemIconByID and C_Item.GetItemIconByID(item.itemID)) or 134400)
            row.Name:SetText(item.name); row.Need:SetText(item.needed); row.Owned:SetText(item.bags.."/"..item.bank); row.Remaining:SetText(item.remaining)
            if item.remaining>0 then
                local quoteReady=readyCommodity and readyCommodity.itemID==item.itemID and readyCommodity.quantity==item.remaining
                row.Action:SetText((quoteReady and "Buy " or "Find ")..item.remaining); row.Action:Enable()
            else row.Action:SetText("Complete"); row.Action:Disable() end
            row:Show()
        else row:Hide() end
    end
    local first=#list==0 and 0 or offset+1
    page.Count:SetText(("Showing %d-%d of %d items"):format(first,math.min(#list,offset+ROW_COUNT),#list))
    page.Previous:SetEnabled(offset>0); page.Next:SetEnabled(offset+ROW_COUNT<#list)
    if not pending then
        local units=0; for _,item in ipairs(list) do units=units+item.remaining end
        status:SetText(#list==0 and "Buy list is empty. Right-click recipes in DXM Craft Profit to add reagents." or
            ("%d queued recipes; %d AH items and %d units remain. Click one item to load its purchase."):format(self:GetRecipeCount(),#list,units))
    end
end

local function build(parent)
    page=parent
    parent.Description:SetText("Buy exact Auction House quantities needed for planned crafts, one reagent at a time.")
    status=parent:CreateFontString(nil,"ARTWORK","GameFontHighlight")
    status:SetPoint("TOPLEFT",parent.Description,"BOTTOMLEFT",0,-12); status:SetPoint("RIGHT",-14,0); status:SetJustifyH("LEFT")
    local header=CreateFrame("Frame",nil,parent); header:SetPoint("TOPLEFT",status,"BOTTOMLEFT",0,-12); header:SetPoint("TOPRIGHT",-8,0); header:SetHeight(25)
    local bg=header:CreateTexture(nil,"BACKGROUND"); bg:SetAllPoints(); bg:SetColorTexture(.16,.12,.05,.95)
    local item=header:CreateFontString(nil,"ARTWORK","GameFontNormal"); item:SetPoint("LEFT",12,0); item:SetText("Item")
    for _,spec in ipairs({{"Need",-252,60},{"Bags/Bank",-190,60},{"To Buy",-126,64},{"Action",-4,118}}) do
        local label=header:CreateFontString(nil,"ARTWORK","GameFontNormal"); label:SetPoint("RIGHT",spec[2],0); label:SetWidth(spec[3]); label:SetText(spec[1])
    end
    local previous=header
    for index=1,ROW_COUNT do rows[index]=makeRow(parent,previous,index); previous=rows[index] end
    parent.Previous=DXMTheme:CreateButton(parent); parent.Previous:SetSize(34,24); parent.Previous:SetPoint("BOTTOMLEFT",4,4); parent.Previous:SetText("<")
    parent.Previous:SetScript("OnClick",function() offset=math.max(0,offset-ROW_COUNT); DXMShopping:RefreshAuction() end)
    parent.Next=DXMTheme:CreateButton(parent); parent.Next:SetSize(34,24); parent.Next:SetPoint("LEFT",parent.Previous,"RIGHT",4,0); parent.Next:SetText(">")
    parent.Next:SetScript("OnClick",function() offset=offset+ROW_COUNT; DXMShopping:RefreshAuction() end)
    parent.Count=parent:CreateFontString(nil,"ARTWORK","GameFontHighlightSmall"); parent.Count:SetPoint("LEFT",parent.Next,"RIGHT",8,0)
    local complete=DXMTheme:CreateButton(parent); complete:SetSize(125,24); complete:SetPoint("BOTTOMRIGHT",-88,4); complete:SetText("Clear Complete"); complete:SetScript("OnClick",function() DXMShopping:ClearCompleted() end)
    local clear=DXMTheme:CreateButton(parent); clear:SetSize(80,24); clear:SetPoint("LEFT",complete,"RIGHT",6,0); clear:SetText("Clear All"); clear:SetScript("OnClick",function() DXMShopping:ClearAll() end)
    parent:SetScript("OnShow",function() DXMShopping:RefreshAuction() end)
    DXMShopping:RefreshAuction()
end

DXMExchange:RegisterPageBuilder("crafting",build)

