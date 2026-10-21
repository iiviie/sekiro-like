--!strict
-- Part C's cosmetics, shared by the server (who dresses everyone) and the client (who draws
-- the effects and the Locker previews). Which cosmetic a fighter shows is read from the
-- fighter's model, so players, bots and preview rigs all work the same way:
--
--   blade:    model attributes BladeId ("skin.Jade" / "line.Raijin"), BladeLevel (line level 1-4),
--             BladeMastery (per-weapon Mastery), set by server/SwordRig.applySkin
--   finisher: model attribute Finisher (a finisher ref, e.g. "InkBrush"), set by
--             server/CosmeticService from the player's Loadout
--   outfit:   model attribute Outfit (a Shared/Clothing set name, "" for the avatar's own)
--
-- A client can override each one locally for a preview with PreviewBlade, PreviewBladeLevel,
-- PreviewMastery and PreviewFinisher on its own models (client/CosmeticPreview); the server
-- never sets those, so a preview never leaks to anyone else.

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local Catalog = require(script.Parent.Catalog)
local EconomyConfig = require(script.Parent.EconomyConfig)
local Blades = require(script.Blades)

local Cosmetics = {}

Cosmetics.Blades = Blades

-- Finishers, by ref: the stamp shown over the fallen and an accent colour (Locker cards,
-- preview chips). The effects themselves are in client/CosmeticFX.
export type FinisherInfo = { kanji: string?, accent: Color3 }
Cosmetics.Finishers = {
	Default = { kanji = nil, accent = Color3.fromRGB(235, 70, 55) },
	InkBrush = { kanji = "Ink", accent = Color3.fromRGB(40, 36, 40) },
	SakuraScatter = { kanji = "Sakura", accent = Color3.fromRGB(255, 170, 205) },
	CrowFeathers = { kanji = "Crow", accent = Color3.fromRGB(90, 80, 130) },
	LightningSheath = { kanji = "Thunder", accent = Color3.fromRGB(190, 170, 255) },
	MoonCrescent = { kanji = "Moon", accent = Color3.fromRGB(190, 210, 255) },
	Yozakura = { kanji = "Yozakura", accent = Color3.fromRGB(255, 160, 210) },
	Raijin = { kanji = "Raijin", accent = Color3.fromRGB(170, 150, 255) },
	Karasu = { kanji = "Karasu", accent = Color3.fromRGB(70, 60, 100) },
} :: { [string]: FinisherInfo }

local loadoutCache: { [string]: { [string]: string } } = {}

-- A player's Loadout attribute (slot -> catalogue id), decoded.
function Cosmetics.loadout(player: Player): { [string]: string }
	local raw = player:GetAttribute("Loadout")
	if typeof(raw) ~= "string" then
		return {}
	end
	local cached = loadoutCache[raw]
	if cached then
		return cached
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	local loadout = if ok and typeof(decoded) == "table" then decoded :: { [string]: string } else {}
	loadoutCache[raw] = loadout
	return loadout
end

-- The ref of the item a player wears in `slot`, or the slot's default's.
function Cosmetics.equippedRef(player: Player, slot: Catalog.Slot): string?
	local item = Catalog.get(Cosmetics.loadout(player)[slot]) or Catalog.get(Catalog.Defaults[slot])
	return if item then item.ref else nil
end

-- A weapon Mastery level from that weapon's XP (the same curve as the player's Mastery).
function Cosmetics.masteryLevel(xp: number): number
	local level = 1
	while level < 200 do
		local need = EconomyConfig.xpToNext(level)
		if xp < need then
			break
		end
		xp -= need
		level += 1
	end
	return level
end

local function attribute(model: Instance, preview: string, live: string): any
	local value = model:GetAttribute(preview)
	if value ~= nil then
		return value
	end
	return model:GetAttribute(live)
end

-- What a fighter's blade looks like now.
function Cosmetics.blade(model: Model): Blades.Look
	local id = attribute(model, "PreviewBlade", "BladeId")
	if typeof(id) ~= "string" then
		local skin = model:GetAttribute("Skin")
		id = if typeof(skin) == "string" then skin else nil
	end
	local level = attribute(model, "PreviewBladeLevel", "BladeLevel")
	local mastery = attribute(model, "PreviewMastery", "BladeMastery")
	return Blades.look(
		id,
		if typeof(level) == "number" then level else 1,
		if typeof(mastery) == "number" then mastery else 0
	)
end

-- The finisher a fighter's deathblows play (a Catalog finisher ref).
function Cosmetics.finisher(model: Model): string
	local ref = attribute(model, "PreviewFinisher", "Finisher")
	if typeof(ref) == "string" and Cosmetics.Finishers[ref] then
		return ref
	end
	local player = Players:GetPlayerFromCharacter(model)
	local fromLoadout = player and Cosmetics.equippedRef(player, "finisher")
	return if fromLoadout and Cosmetics.Finishers[fromLoadout] then fromLoadout else "Default"
end

-- What the server puts on a player's character for their equipped blade (see SwordRig).
-- `weapon` is the weapon in hand (its Mastery evolves the blade), else the equipped one.
function Cosmetics.bladeOf(player: Player, weapon: string?): (string, number, number)
	local loadout = Cosmetics.loadout(player)
	local id = loadout.bladeSkin or Catalog.Defaults.bladeSkin
	if not Catalog.get(id) then
		id = Catalog.Defaults.bladeSkin
	end
	local level = 1
	local rawLevels = player:GetAttribute("LineLevels")
	if typeof(rawLevels) == "string" then
		local ok, levels = pcall(HttpService.JSONDecode, HttpService, rawLevels)
		if ok and typeof(levels) == "table" and typeof(levels[id]) == "number" then
			level = levels[id]
		end
	end
	local mastery = 0
	local rawMastery = player:GetAttribute("WeaponMastery")
	local held = weapon or player:GetAttribute("Weapon")
	if typeof(rawMastery) == "string" and typeof(held) == "string" then
		local ok, levels = pcall(HttpService.JSONDecode, HttpService, rawMastery)
		if ok and typeof(levels) == "table" and typeof(levels[held]) == "number" then
			mastery = levels[held]
		end
	end
	return id, level, mastery
end

return Cosmetics
