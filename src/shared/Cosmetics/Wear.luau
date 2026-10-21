--!strict
-- Puts a Shared/Clothing set (gi Shirt + hakama Pants) on a player's character over their
-- avatar, and takes it off again. Only the classic Shirt/Pants templates change, the T-shirt
-- decal is blanked and layered (3D) clothing is set aside, so the body, its joints and the
-- procedural client/Animator are untouched; hair, hats and faces stay the player's own.
-- The avatar's own clothes are remembered on the character (attributes) and restored when the
-- outfit comes off. The server calls this for everyone (server/Outfit.wearPlayer); the
-- client calls it on its own character for a Locker preview (a local change).

local Clothing = require(script.Parent.Parent.Clothing)

local Wear = {}

local SHIRT, PANTS, GRAPHIC = "AvatarShirt", "AvatarPants", "AvatarGraphic"

-- Layered clothing that would cover the gi or hakama.
local COVERING: { [Enum.AccessoryType]: boolean } = {
	[Enum.AccessoryType.TShirt] = true,
	[Enum.AccessoryType.Shirt] = true,
	[Enum.AccessoryType.Pants] = true,
	[Enum.AccessoryType.Jacket] = true,
	[Enum.AccessoryType.Sweater] = true,
	[Enum.AccessoryType.Shorts] = true,
	[Enum.AccessoryType.DressSkirt] = true,
}

local function covers(child: Instance): boolean
	if not child:IsA("Accessory") then
		return false
	end
	local handle = child:FindFirstChild("Handle")
	local layered = handle ~= nil and handle:FindFirstChildOfClass("WrapLayer") ~= nil
	return layered and COVERING[child.AccessoryType] == true
end

-- Whether `child` (added to a character later, e.g. by avatar loading) is something an
-- outfit has to cover again.
function Wear.isClothing(child: Instance): boolean
	return child:IsA("Shirt") or child:IsA("Pants") or child:IsA("ShirtGraphic") or covers(child)
end

-- While an outfit is on, a piece of the avatar's clothing that arrives late (avatar loading) is
-- folded into what gets restored later, and kept off the body now.
function Wear.cover(character: Model, child: Instance, stash: Instance)
	local set = Clothing.get(Wear.current(character))
	if not set or not child.Parent then
		return
	end
	if child:IsA("Shirt") and child.ShirtTemplate ~= set.shirt then
		character:SetAttribute(SHIRT, child.ShirtTemplate)
		child:Destroy()
		Wear.apply(character, Wear.current(character), stash)
	elseif child:IsA("Pants") and child.PantsTemplate ~= set.pants then
		character:SetAttribute(PANTS, child.PantsTemplate)
		child:Destroy()
		Wear.apply(character, Wear.current(character), stash)
	elseif child:IsA("ShirtGraphic") and child.Graphic ~= "" then
		character:SetAttribute(GRAPHIC, child.Graphic)
		child.Graphic = ""
	elseif covers(child) then
		child:SetAttribute("OutfitStashedFrom", character.Name)
		child.Parent = stash
	end
end

-- The set worn now ("" = the avatar's own clothes).
function Wear.current(character: Model): string
	local set = character:GetAttribute("Outfit")
	return if typeof(set) == "string" then set else ""
end

-- Wears set `name` (a Clothing.Sets key); nil, "" or an unknown name restores the avatar.
-- `stash` keeps set-aside layered clothing (the server uses a ServerStorage folder; a client
-- preview, a local folder).
function Wear.apply(character: Model, name: string?, stash: Instance)
	local set = Clothing.get(name)
	if set then
		if character:GetAttribute(SHIRT) == nil then
			-- First time on: remember the avatar's own clothes.
			local shirt = character:FindFirstChildOfClass("Shirt")
			local pants = character:FindFirstChildOfClass("Pants")
			local graphic = character:FindFirstChildOfClass("ShirtGraphic")
			character:SetAttribute(SHIRT, if shirt then shirt.ShirtTemplate else "")
			character:SetAttribute(PANTS, if pants then pants.PantsTemplate else "")
			character:SetAttribute(GRAPHIC, if graphic then graphic.Graphic else "")
		end
		local shirt = character:FindFirstChildOfClass("Shirt")
		if not shirt then
			shirt = Instance.new("Shirt")
			shirt.Name = "Shirt"
			shirt.Parent = character
		end
		(shirt :: Shirt).ShirtTemplate = set.shirt
		local pants = character:FindFirstChildOfClass("Pants")
		if not pants then
			pants = Instance.new("Pants")
			pants.Name = "Pants"
			pants.Parent = character
		end
		(pants :: Pants).PantsTemplate = set.pants
		local graphic = character:FindFirstChildOfClass("ShirtGraphic")
		if graphic then
			graphic.Graphic = ""
		end
		for _, child in character:GetChildren() do
			if covers(child) then
				child:SetAttribute("OutfitStashedFrom", character.Name)
				child.Parent = stash
			end
		end
		character:SetAttribute("Outfit", name)
		return
	end

	-- Back to the avatar.
	local savedShirt = character:GetAttribute(SHIRT)
	if typeof(savedShirt) == "string" then
		local shirt = character:FindFirstChildOfClass("Shirt")
		if savedShirt == "" then
			if shirt then
				shirt:Destroy()
			end
		elseif shirt then
			shirt.ShirtTemplate = savedShirt
		end
	end
	local savedPants = character:GetAttribute(PANTS)
	if typeof(savedPants) == "string" then
		local pants = character:FindFirstChildOfClass("Pants")
		if savedPants == "" then
			if pants then
				pants:Destroy()
			end
		elseif pants then
			pants.PantsTemplate = savedPants
		end
	end
	local savedGraphic = character:GetAttribute(GRAPHIC)
	local graphic = character:FindFirstChildOfClass("ShirtGraphic")
	if typeof(savedGraphic) == "string" and graphic then
		graphic.Graphic = savedGraphic
	end
	for _, child in stash:GetChildren() do
		if child:GetAttribute("OutfitStashedFrom") == character.Name then
			child:SetAttribute("OutfitStashedFrom", nil)
			child.Parent = character
		end
	end
	character:SetAttribute(SHIRT, nil)
	character:SetAttribute(PANTS, nil)
	character:SetAttribute(GRAPHIC, nil)
	character:SetAttribute("Outfit", "")
end

return Wear
