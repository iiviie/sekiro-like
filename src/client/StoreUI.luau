--!strict
-- Shared pieces of the Store and the Locker: reading the server-published player state
-- (inventory, loadout, passes, line levels), item thumbnails with their rarity frame, the
-- "how do I get this" line for anything not owned, Robux prices, and purchase requests with
-- a thank-you once the grant lands. Generic widgets (tabs, pills, sheets, confirmations)
-- live in UI.luau.

local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(ReplicatedStorage.Shared.Assets)
local Catalog = require(ReplicatedStorage.Shared.Catalog)
local Text = require(ReplicatedStorage.Shared.Text)
local Clothing = require(ReplicatedStorage.Shared.Clothing)
local Flair = require(ReplicatedStorage.Shared.Flair)
local Intros = require(ReplicatedStorage.Shared.Intros)
local Progression = require(ReplicatedStorage.Shared.Progression)
local Toasts = require(script.Parent.Toasts)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer
local ICONS = Assets.Icons :: any

local StoreUI = {}

local lobbyAction: RemoteEvent? = nil
local function remote(): RemoteEvent
	if not lobbyAction then
		lobbyAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("LobbyAction") :: RemoteEvent
	end
	return lobbyAction :: RemoteEvent
end

function StoreUI.fire(action: string, argument: any)
	remote():FireServer(action, argument)
end

---------------------------------------------------------------------------------------
-- Player state (all server-published attributes)

function StoreUI.attr(name: string, default: any): any
	local value = player:GetAttribute(name)
	return if value == nil then default else value
end

function StoreUI.json(name: string): { [string]: any }
	local raw = player:GetAttribute(name)
	if typeof(raw) ~= "string" or raw == "" then
		return {}
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	return if ok and typeof(decoded) == "table" then decoded else {}
end

local function set(raw: any): { [string]: boolean }
	local out = {}
	if typeof(raw) == "string" then
		for id in string.gmatch(raw, "[^,]+") do
			out[id] = true
		end
	end
	return out
end

function StoreUI.owned(): { [string]: boolean }
	return set(player:GetAttribute("Inventory"))
end

function StoreUI.passes(): { [string]: boolean }
	return set(player:GetAttribute("Passes"))
end

function StoreUI.loadout(): { [string]: string }
	return StoreUI.json("Loadout") :: any
end

function StoreUI.lineLevel(id: string): number
	local levels = StoreUI.json("LineLevels")
	return tonumber(levels[id]) or 1
end

-- An instance name for a catalogue id ("gems.440" -> "gems_440"): dots break instance paths.
function StoreUI.key(id: string): string
	return (string.gsub(id, "%.", "_"))
end

function StoreUI.now(): number
	return workspace:GetServerTimeNow()
end

-- The Initiate's Bundle is on offer (server-published end time, unowned).
function StoreUI.initiateOpen(): boolean
	local endsAt = StoreUI.attr("InitiateEndsAt", 0)
	return typeof(endsAt) == "number" and endsAt > StoreUI.now() and not StoreUI.owned()["bundle.Initiate"]
end

-- "2d 5h", "5h 12m", "12m 30s".
function StoreUI.duration(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local d, h, m = seconds // 86400, seconds % 86400 // 3600, seconds % 3600 // 60
	if d > 0 then
		return `{d}d {h}h`
	elseif h > 0 then
		return `{h}h {m}m`
	end
	return `{m}m {seconds % 60}s`
end

-- Keeps `label` reading format(time left until endsAt) once a second while it exists.
function StoreUI.countdown(label: TextLabel, endsAt: number, format: (string) -> string)
	local function tick()
		label.Text = format(StoreUI.duration(endsAt - StoreUI.now()))
	end
	tick()
	task.spawn(function()
		while label.Parent do
			task.wait(1)
			if label.Parent then
				tick()
			end
		end
	end)
end

---------------------------------------------------------------------------------------
-- How an item is shown

local SOURCE_TEXT: { [string]: string } = {
	ranked = "Ranked season reward",
	pass = "Path of the Blade reward",
	bundle = "Initiate's Bundle",
	vip = "Comes with Hatamoto VIP",
	line = "Blade line level 4",
	boss = "Boss trial reward",
	achievement = "Achievement",
	default = "Everyone has this",
}

-- The plain "how do I get it" text for an item the player doesn't own: its rule with the
-- server's progress, else its price, else where it comes from.
function StoreUI.howToGet(item: Catalog.Item, progress: { [string]: any }?): string
	local entry = progress and progress[item.id]
	local rule = item.rule
	if rule then
		local suffix = if typeof(entry) == "table" then `  ({UI.number(entry[1])}/{UI.number(entry[2])})` else ""
		if item.price and not (typeof(entry) == "table" and entry[1] >= entry[2]) then
			return `{rule.text}{suffix}, then {StoreUI.priceText(item)}`
		elseif not item.price then
			return `{rule.text}{suffix}`
		end
	end
	if item.price then
		return StoreUI.priceText(item)
	end
	local source = item.sources[1]
	local text = source and SOURCE_TEXT[source] or "Earned in play"
	if item.season then
		text ..= ` · Season {string.sub(item.season, 2)}`
	end
	return text
end

function StoreUI.priceText(item: Catalog.Item): string
	local price = item.price
	if not price then
		return ""
	elseif price.coins then
		return `{UI.number(price.coins)} coins`
	elseif price.gems then
		return `{UI.number(price.gems)} gems`
	elseif price.product then
		local robux = StoreUI.robux(price.product)
		return if robux then `R$ {UI.number(robux)}` else "See price"
	end
	return ""
end

local function icon(key: string?, fallback: string): string
	local value = key and ICONS[key]
	return if typeof(value) == "string" then value else fallback
end

local function nested(group: string, key: string, fallback: string): string
	local tbl = ICONS[group]
	local value = typeof(tbl) == "table" and tbl[key] or nil
	return if typeof(value) == "string" then value else fallback
end

local function tint(v: Vector3): Color3
	return Color3.new(math.min(v.X, 1), math.min(v.Y, 1), math.min(v.Z, 1))
end

-- A square thumbnail of `item` filling `parent` (frame, art and a lock if asked).
function StoreUI.thumb(parent: GuiObject, item: Catalog.Item, locked: boolean?)
	local category = item.category
	local holder = UI.new("Frame", {
		Name = "Thumb",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, parent)
	local function image(src: string, color: Color3?, scale: number?)
		local s = scale or 0.86
		UI.new("ImageLabel", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(s, s),
			BackgroundTransparency = 1,
			Image = src,
			ImageColor3 = color or Color3.new(1, 1, 1),
			ScaleType = Enum.ScaleType.Fit,
		}, holder)
	end
	if category == "weapon" then
		image(icon(item.icon or item.ref, ICONS.Weapons))
	elseif category == "bladeSkin" then
		image(ICONS.Katana, tint(Progression.skin(item.ref).tint))
	elseif category == "bladeLine" then
		image(nested("BladeLines", item.ref, ICONS.Skin))
	elseif category == "finisher" then
		-- A blade line's finale has no icon of its own: it shows the line's blade.
		image(nested("Finishers", item.ref, nested("BladeLines", item.ref, ICONS.Deathblow)))
	elseif category == "outfit" then
		local look = Clothing.get(item.ref)
		if look then
			-- A gi swatch: the jacket colour over the hakama, the obi between.
			local swatch = UI.new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(0.56, 0.66),
				BackgroundColor3 = look.gi,
				BorderSizePixel = 0,
			}, holder)
			UI.corner(swatch, UDim.new(0.12, 0))
			UI.new("Frame", {
				Position = UDim2.fromScale(0, 0.5),
				Size = UDim2.fromScale(1, 0.12),
				BackgroundColor3 = look.obi,
				BorderSizePixel = 0,
			}, swatch)
			local hakama = UI.new("Frame", {
				Position = UDim2.fromScale(0, 0.62),
				Size = UDim2.fromScale(1, 0.38),
				BackgroundColor3 = look.hakama,
				BorderSizePixel = 0,
			}, swatch)
			UI.corner(hakama, UDim.new(0.12, 0))
			UI.new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.fromScale(0.5, 0),
				Size = UDim2.fromScale(0.08, 0.5),
				BackgroundColor3 = look.gi:Lerp(Color3.new(), 0.35),
				BorderSizePixel = 0,
			}, swatch)
		else
			image(nested("Tabs", "Outfits", ICONS.Profile), nil, 0.8)
		end
	elseif category == "title" then
		image(nested("Tabs", "Titles", ICONS.Guide), nil, 0.62)
	elseif category == "banner" then
		StoreUI.bannerArt(holder, Flair.banner(item.ref), item.ref)
	elseif category == "nameplate" then
		local look = Flair.plate(item.ref)
		local strip = UI.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.8, 0.28),
			BackgroundColor3 = look.fill,
			BorderSizePixel = 0,
		}, holder)
		UI.corner(strip, UDim.new(0.3, 0))
		if not Flair.decoratePlate(strip, item.ref) then
			UI.stroke(strip, look.edge, 2, 0)
		end
		UI.text({
			Size = UDim2.fromScale(1, 1),
			Font = UI.Display,
			TextScaled = true,
			TextColor3 = look.text,
			Text = player.DisplayName,
		}, strip)
	elseif category == "intro" then
		-- the intro's brush kanji in its colour (no painted icons for intros yet)
		local intro = Intros.resolve(item.ref)
		local kanji = if intro.kanji == "Slay" then Assets.UI.KanjiSlay else Assets.Cosmetics.Kanji[intro.kanji]
		image(kanji or ICONS.Katana, intro.accent:Lerp(Color3.new(1, 1, 1), 0.15), 0.72)
	elseif category == "gemPack" then
		local packs = ICONS.GemPacks
		local tier = 1
		for i, pack in Catalog.list("gemPack") do
			if pack.id == item.id then
				tier = i
			end
		end
		image(if typeof(packs) == "table" and #packs > 0 then packs[math.min(tier, #packs)] else ICONS.Gem)
	elseif category == "bundle" and item.ref == "Stagecraft" then
		image(Assets.Cosmetics.Kanji.Sakura, Intros.resolve("Sakura").accent, 0.72)
	elseif category == "bundle" then
		image(icon("InitiateBundle", ICONS.Katana))
	elseif category == "pass" then
		local key = ({
			Premium = "SeasonPass",
			TierSkip = "TierSkip",
			Tiers10 = "TierSkip",
			VIP = "VIP",
			Loadouts = "LoadoutPresets",
			VictoryCry = "VictoryCry",
		} :: { [string]: string })[item.ref]
		if item.ref == "TitleSlot" then
			image(nested("Tabs", "Titles", ICONS.Guide))
			return holder
		end
		local fallback = ({
			Premium = (Assets.RankCrests :: any).Gold,
			TierSkip = ICONS.Level,
			Tiers10 = ICONS.Level,
			VIP = ICONS.Profile,
			Loadouts = ICONS.Weapons,
			TitleSlot = ICONS.Guide,
			VictoryCry = ICONS.Trophy,
		} :: { [string]: string })[item.ref] or ICONS.Store
		image(icon(key, fallback))
	else
		image(ICONS.Store)
	end
	if locked then
		UI.new("ImageLabel", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -2, 0, 2),
			Size = UDim2.fromScale(0.3, 0.3),
			BackgroundTransparency = 1,
			Image = ICONS.Lock,
			ZIndex = 3,
		}, holder)
	end
	return holder
end

-- The banner cloth: a hanging panel with a bronze rod and one brushed character.
function StoreUI.bannerArt(parent: GuiObject, look: Flair.Banner, ref: string?): Frame
	local cloth = UI.new("Frame", {
		Name = "Banner",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.52),
		Size = UDim2.fromScale(0.56, 0.8),
		BackgroundColor3 = look.cloth,
		BorderSizePixel = 0,
	}, parent)
	UI.stroke(cloth, look.edge, 2, 0)
	UI.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.new(1.2, 0, 0, 4),
		BackgroundColor3 = UI.Bronze,
		BorderSizePixel = 0,
	}, cloth)
	local motif = UI.text({
		Name = "Motif",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.48),
		Size = UDim2.fromScale(0.9, 0.6),
		Font = UI.Display,
		TextScaled = true,
		TextColor3 = look.ink,
		Text = look.motif,
	}, cloth)
	if ref and Flair.decorateBanner(cloth, ref) then
		motif.Visible = false -- the painted kanji replaces the text one
	end
	return cloth
end

-- The painted rarity frame (9-slice) around a card (UI.rarityFrame; uncommon is jade).
function StoreUI.frame(parent: GuiObject, rarity: string, z: number?)
	if not UI.rarityFrame(parent, rarity, z or 2, 0.14) then
		UI.stroke(parent, Flair.Rarity[rarity] or UI.Bronze, 2, 0.1)
	end
end

function StoreUI.rarityName(rarity: string): string
	return (string.gsub(rarity, "^%l", string.upper))
end

---------------------------------------------------------------------------------------
-- Robux prices and purchases

local robuxCache: { [string]: number } = {}
local fetching: { [string]: boolean } = {}

-- The Robux price of a product key: the live price once the product exists (Price
-- Optimization can change it), else the catalogue's planned price.
function StoreUI.robux(key: string): number?
	local product = Catalog.Products[key]
	if not product then
		return nil
	end
	if product.id ~= 0 and not robuxCache[key] and not fetching[key] then
		fetching[key] = true
		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(
					product.id,
					if product.kind == "gamepass" then Enum.InfoType.GamePass else Enum.InfoType.Product
				)
			end)
			if ok and typeof(info) == "table" and typeof(info.PriceInRobux) == "number" then
				robuxCache[key] = info.PriceInRobux
			end
		end)
	end
	return robuxCache[key] or product.robux
end

-- Asks the server to prompt a Robux purchase. The server tells this client what the purchase
-- granted (Progress "Purchased"), and StorePanel plays the thank-you reveal from that.
function StoreUI.purchase(key: string)
	if StoreUI.attr("CanTransact", true) == false or StoreUI.attr("DataFailed", false) == true then
		Toasts.notice(Text.ProgressFailed, UI.Parchment)
		return
	end
	StoreUI.fire("Purchase", key)
end

-- Whether `item` can be tried on: blades, lines, outfits, finishers (CosmeticPreview.present)
-- and pre-fight intros (IntroCinematic.preview).
function StoreUI.previewable(item: Catalog.Item?): boolean
	local category = item and item.category
	return category == "bladeSkin"
		or category == "bladeLine"
		or category == "outfit"
		or category == "finisher"
		or category == "intro"
end

-- The wishlist (LobbyAction "Wish"): shop items the player wants to hear about.
function StoreUI.wished(): { [string]: boolean }
	return set(player:GetAttribute("Wishlist"))
end

-- Whether `item` is something the shop sells (coins or gems, no Robux) that can be wished for.
function StoreUI.wishable(item: Catalog.Item): boolean
	local price = item.price
	return price ~= nil and price.product == nil and (price.coins ~= nil or price.gems ~= nil) and not item.default
end

return StoreUI
