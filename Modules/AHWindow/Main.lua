if not DXMCore then return end

-- Create a new DXMCore module.
local Module = DXMCore:Module("AHWindow", "Scanner")
local Const = DXMCore.Const()

-- Hook our methods.
function Module:Boot(hook)
	hook(Const.AuctionHouseOpened, Module.AuctionHouseOpened)
end

local function OnMouseDown(frame)
	frame:StartMoving()
end

local function OnMouseUp(frame)
	frame:StopMovingOrSizing()
end

function Module:AuctionHouseOpened()
	if AuctionHouseFrame and not AuctionHouseFrame.DXMInitialized then
		AuctionHouseFrame.DXMInitialized = true
		AuctionHouseFrame:SetMovable(true)
		AuctionHouseFrame:SetClampedToScreen(true)
		AuctionHouseFrame:SetScript("OnMouseDown", OnMouseDown)
		AuctionHouseFrame:SetScript("OnMouseUp", OnMouseUp)
	end
end
