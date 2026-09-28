-- Cache seller invoices while they are visible. A collection request alone is
-- not a sale receipt: wait for both money received and the invoice disappearing.
if not DXMCore then return end
local Const = DXMCore:Const()
local cache, requested = {}, {}
local credit, lastMoney, mailboxOpen = 0, nil, false
local session = 0
local refresh
local function state()
    DXMLocal = DXMLocal or {}
    DXMLocal.AuctionReceipts = DXMLocal.AuctionReceipts or {nextID=1,entries={}}
    return DXMLocal.AuctionReceipts
end
local function read(index)
    if not GetInboxInvoiceInfo then return end
    local invoiceType,name,_,bid,_,deposit,fee,_,_,_,quantity=GetInboxInvoiceInfo(index)
    if invoiceType~="seller" then return end
    local icon,_,_,subject,money,_,daysLeft,_,_,returned,_,_,_,headerQuantity,link=GetInboxHeaderInfo(index)
    money=tonumber(money) or 0
    if money<=0 or returned then return end
    return {itemName=name or subject,itemLink=link,subject=subject,icon=icon,money=money,
        itemQuantity=math.max(1,tonumber(quantity) or tonumber(headerQuantity) or 1),
        arrivalPoint=math.floor((GetServerTime()-(30-(tonumber(daysLeft) or 30))*86400)/5+.5),
        deposit=tonumber(deposit) or 0,consignment=tonumber(fee) or 0,bid=tonumber(bid) or 0}
end
local function same(a,b)
    return a.itemName==b.itemName and a.money==b.money and a.itemQuantity==b.itemQuantity
        and math.abs(a.arrivalPoint-b.arrivalPoint)<=2
end
local function confirm(seen)
    local saved=state()
    local ids={}
    for id in pairs(requested) do ids[#ids+1]=id end
    table.sort(ids)
    for _,id in ipairs(ids) do
        local receipt=saved.entries[id]
        if receipt and not receipt.collected and not seen[id] and credit>=receipt.money then
            credit=credit-receipt.money
            receipt.collected=true
            receipt.collectedAt=GetServerTime()
            if DXMLedger then DXMLedger:RecordMail("Sold",receipt) end
            DXMCore:Trigger(Const.AuctionHouseMail,"Sold",receipt)
            requested[id]=nil
        elseif GetTime()-requested[id]>30 then
            requested[id]=nil
        end
    end
    if not next(requested) then credit=0 end
end
refresh=function()
    if not mailboxOpen then return end
    local saved=state()
    local seen,newCache={},{}
    local count=GetInboxNumItems and GetInboxNumItems() or 0
    for index=1,(tonumber(count) or 0) do
        local mail=read(index)
        if mail then
            local chosen
            for id,receipt in pairs(saved.entries) do
                if not receipt.collected and not seen[id] and same(receipt,mail) then
                    -- Identical invoices are separate receipts. Prefer unrequested
                    -- copies so removal of a requested copy can be confirmed.
                    if not chosen or (requested[chosen] and not requested[id])
                        or ((not requested[chosen])==(not requested[id]) and id<chosen) then chosen=id end
                end
            end
            if not chosen then
                local name,realm=UnitFullName("player")
                chosen=tostring(saved.nextID); saved.nextID=saved.nextID+1
                mail.sig=("receipt:%s-%s:%s"):format(name or "?",realm or GetRealmName(),chosen)
                mail.earningsSig,mail.receiptID=mail.sig,chosen
                saved.entries[chosen]=mail
            else
                local receipt=saved.entries[chosen]
                receipt.itemLink=mail.itemLink or receipt.itemLink
            end
            seen[chosen]=true;newCache[index]=chosen
            if DXMLedger then DXMLedger:RecordMail("Sold",saved.entries[chosen]) end
        end
    end
    cache=newCache
    confirm(seen)
    for id,receipt in pairs(saved.entries) do
        if receipt.collected and (receipt.collectedAt or 0)<GetServerTime()-45*86400 then saved.entries[id]=nil end
    end
end
local function request(index)
    if not mailboxOpen then return end
    index=tonumber(index)
    local id=cache[index]
    if not id then refresh(); id=cache[index] end
    local receipt=id and state().entries[id]
    if receipt and not receipt.collected then
        requested[id]=requested[id] or GetTime()
        C_Timer.After(.1,refresh)
    end
end
if TakeInboxMoney then hooksecurefunc("TakeInboxMoney",request) end
if AutoLootMailItem then hooksecurefunc("AutoLootMailItem",request) end
local events=CreateFrame("Frame")
for _,event in ipairs({"MAIL_SHOW","MAIL_INBOX_UPDATE","MAIL_CLOSED","PLAYER_MONEY","PLAYER_ENTERING_WORLD"}) do events:RegisterEvent(event) end
events:SetScript("OnEvent",function(_,event)
    if event=="MAIL_SHOW" then
        session=session+1
        mailboxOpen=true; lastMoney=GetMoney(); credit=0; requested={}; refresh()
    elseif event=="MAIL_INBOX_UPDATE" then
        C_Timer.After(.1,refresh)
    elseif event=="MAIL_CLOSED" then
        -- Keep pending receipts briefly: the money event can follow closing.
        local closing=session
        C_Timer.After(.5,function()
            if closing~=session then return end
            refresh();mailboxOpen=false;cache={};requested={};credit=0
        end)
    elseif event=="PLAYER_ENTERING_WORLD" then
        lastMoney=GetMoney()
    elseif event=="PLAYER_MONEY" then
        local current=GetMoney()
        if mailboxOpen and lastMoney and next(requested) then credit=credit+math.max(0,current-lastMoney) end
        lastMoney=current
        if mailboxOpen then C_Timer.After(.1,refresh) end
    end
end)
