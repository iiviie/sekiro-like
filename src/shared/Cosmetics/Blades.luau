--!strict
-- What a blade looks like, by catalogue id (`skin.<ref>` or `line.<ref>`), line level and
-- weapon Mastery: tint, edge, outline, smear colours, the motes it sheds, and for blade lines
-- the swing smear (L2), deflect spark and sound (L3) and finisher (L4) that unlock as it levels.
--
-- Base skins keep their colours in Shared/Progression.Skins (the Arsenal cards read them);
-- this module adds the extras (edge material, motes) and the premium lines' looks. Nothing here
-- may use the perilous warning's red (Animator PERIL_TRAIL, 255,90,70 -> 200,20,20) for a smear
-- or an edge: a red blade must never hide a 危 read.

local Assets = require(script.Parent.Parent.Assets)
local Progression = require(script.Parent.Parent.Progression)

local Blades = {}

-- Particles a blade sheds while held (all emit from the blade tip attachment, or along it).
export type Motes = {
	kind: "petals" | "feathers" | "sparks" | "embers" | "mist" | "snow" | "paper" | "foxfire" | "glints",
	color: Color3,
	rate: number,
}

-- L2: what the swing smear adds along its arc.
export type SmearStyle = {
	kind: "petals" | "bolts" | "feathers",
	color: Color3,
	every: number, -- emit at every Nth piece of the arc
	count: number, -- particles per emission
}

-- L3: the deflect's own spark and sound, layered over the steel clash.
export type DeflectStyle = {
	kind: "petals" | "bolts" | "feathers",
	spark: Color3,
	sound: string,
	volume: number,
}

export type Look = {
	id: string, -- catalogue id
	ref: string,
	name: string,
	tint: Vector3,
	outline: Color3,
	fill: Color3,
	edge: Color3,
	trail: { Color3 }, -- smear core (edge side), smear body
	dark: boolean, -- an ink-dark smear: alpha-blended, not additive
	glow: Color3?,
	motes: Motes?,
	smear: SmearStyle?,
	deflect: DeflectStyle?,
	finisher: string?, -- the line's finisher ref (L4)
	level: number, -- blade line level 1-4 (1 for skins)
	evolution: number, -- 0, or 1 ribbon (M10), 2 engraved edge (M25), 3 aura (M50)
	ribbon: Color3, -- the sageo ribbon / engraving / aura colour
}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- Extras for the base skins, by Progression skin id: motes and a darker smear where the skin
-- is dark. Bosses' skins are themed on the boss that drops them.
-- `trail`, `outline` and `glow` override Progression's where its colours sat on the perilous
-- red (the audit flagged Crimson and Obsidian): Crimson's smear is now a wine-rose lacquer and
-- Obsidian's burning edge is ember-gold over violet-black glass.
type Extra = {
	motes: Motes?,
	dark: boolean?,
	ribbon: Color3?,
	trail: { Color3 }?,
	outline: Color3?,
	glow: Color3?,
}
local EXTRAS: { [string]: Extra } = {
	Steel = { ribbon = rgb(150, 40, 40) },
	Crimson = {
		motes = { kind = "glints", color = rgb(255, 196, 170), rate = 3 },
		ribbon = rgb(230, 190, 110),
		trail = { rgb(255, 206, 196), rgb(156, 28, 92) },
	},
	Jade = { motes = { kind = "mist", color = rgb(170, 255, 215), rate = 2 } },
	Sakura = { motes = { kind = "petals", color = rgb(255, 180, 210), rate = 6 } },
	Gold = { motes = { kind = "glints", color = rgb(255, 222, 130), rate = 5 }, ribbon = rgb(150, 30, 34) },
	Obsidian = {
		motes = { kind = "embers", color = rgb(255, 176, 80), rate = 6 },
		ribbon = rgb(255, 170, 70),
		trail = { rgb(255, 204, 120), rgb(52, 16, 56) },
		outline = rgb(255, 150, 60),
		glow = rgb(255, 150, 60),
	},
	Moon = { motes = { kind = "glints", color = rgb(200, 220, 255), rate = 4 }, ribbon = rgb(170, 200, 255) },
	Aizome = { ribbon = rgb(235, 235, 245) },
	Bamboo = { motes = { kind = "petals", color = rgb(170, 220, 120), rate = 2 } },
	Amber = { motes = { kind = "embers", color = rgb(255, 200, 120), rate = 3 } },
	Fuji = { motes = { kind = "snow", color = rgb(250, 250, 255), rate = 6 } },
	Thunderhead = { motes = { kind = "sparks", color = rgb(200, 180, 255), rate = 5 }, ribbon = rgb(170, 140, 255) },
	Kintsugi = { motes = { kind = "glints", color = rgb(255, 210, 110), rate = 4 }, ribbon = rgb(255, 205, 90) },
	-- Boss trials.
	Washi = { motes = { kind = "paper", color = rgb(250, 244, 228), rate = 3 }, ribbon = rgb(190, 44, 40) }, -- Shikigami
	Nameless = { motes = { kind = "mist", color = rgb(140, 150, 200), rate = 3 }, ribbon = rgb(214, 206, 190) }, -- Nameless Warrior
	CatClaw = { motes = { kind = "embers", color = rgb(255, 196, 110), rate = 3 }, ribbon = rgb(214, 170, 60) }, -- Cat General
	Mistveil = { motes = { kind = "mist", color = rgb(225, 235, 240), rate = 5 }, ribbon = rgb(226, 230, 236) }, -- Guard of Mist
	DemonHorn = { motes = { kind = "embers", color = rgb(240, 190, 90), rate = 5 }, ribbon = rgb(132, 64, 46) }, -- Little Demon
	FoxFire = { motes = { kind = "foxfire", color = rgb(110, 175, 255), rate = 8 }, ribbon = rgb(210, 160, 70) }, -- Night Fox
	Niten = { motes = { kind = "glints", color = rgb(210, 220, 255), rate = 4 }, ribbon = rgb(66, 82, 128) }, -- Niten Usagi
	Initiate = { motes = { kind = "glints", color = rgb(170, 255, 245), rate = 3 }, ribbon = rgb(40, 170, 170) },
	-- Season 1 pass skins (Progression looks by part S).
	S1Cedar = { motes = { kind = "embers", color = rgb(250, 210, 160), rate = 2 } },
	S1Vermilion = {
		motes = { kind = "glints", color = rgb(255, 210, 160), rate = 3 },
		trail = { rgb(255, 214, 160), rgb(236, 128, 36) }, -- orange lacquer, kept off the peril red
	},
	S1Hanafubuki = { motes = { kind = "petals", color = rgb(255, 196, 220), rate = 9 } },
}

-- Premium blade lines: the L1 look, plus what L2-L4 add.
type Line = {
	name: string,
	tint: Vector3,
	outline: Color3,
	fill: Color3,
	edge: Color3,
	trail: { Color3 },
	dark: boolean?,
	glow: Color3,
	motes: Motes,
	smear: SmearStyle,
	deflect: DeflectStyle,
	ribbon: Color3,
}

local LINES: { [string]: Line } = {
	-- Night cherry: plum-black steel, an edge of pale pink light, petals that glow in the dark.
	Yozakura = {
		name = "Yozakura",
		tint = Vector3.new(0.55, 0.38, 0.6),
		outline = rgb(255, 150, 200),
		fill = rgb(70, 24, 60),
		edge = rgb(255, 205, 228),
		trail = { rgb(255, 222, 238), rgb(214, 92, 170) },
		glow = rgb(255, 150, 205),
		motes = { kind = "petals", color = rgb(255, 176, 214), rate = 7 },
		smear = { kind = "petals", color = rgb(255, 186, 220), every = 2, count = 2 },
		deflect = { kind = "petals", spark = rgb(255, 170, 215), sound = "LineChime", volume = 0.7 },
		ribbon = rgb(255, 196, 225),
	},
	-- The thunder god's blade: storm steel, a violet-white edge, sparks that crawl along it.
	Raijin = {
		name = "Raijin",
		tint = Vector3.new(0.72, 0.76, 1.1),
		outline = rgb(150, 120, 255),
		fill = rgb(40, 40, 90),
		edge = rgb(228, 218, 255),
		trail = { rgb(244, 240, 255), rgb(124, 96, 255) },
		glow = rgb(170, 150, 255),
		motes = { kind = "sparks", color = rgb(210, 195, 255), rate = 9 },
		smear = { kind = "bolts", color = rgb(220, 205, 255), every = 3, count = 1 },
		deflect = { kind = "bolts", spark = rgb(200, 180, 255), sound = "LineZap", volume = 0.75 },
		ribbon = rgb(255, 214, 90),
	},
	-- Crow-black steel with a cold silver edge that sheds feathers; its smear is ink, not light.
	Karasu = {
		name = "Karasu",
		tint = Vector3.new(0.2, 0.19, 0.25),
		outline = rgb(12, 10, 18),
		fill = rgb(24, 20, 36),
		edge = rgb(200, 208, 236),
		trail = { rgb(205, 210, 238), rgb(26, 20, 42) },
		dark = true,
		glow = rgb(120, 110, 200),
		motes = { kind = "feathers", color = rgb(30, 26, 40), rate = 3 },
		smear = { kind = "feathers", color = rgb(28, 24, 38), every = 2, count = 1 },
		deflect = { kind = "feathers", spark = rgb(190, 200, 235), sound = "LineWings", volume = 0.8 },
		ribbon = rgb(180, 30, 40),
	},
}

Blades.Lines = LINES

-- Weapon Mastery evolutions: the per-weapon Mastery level each one appears at.
Blades.Evolutions = { 10, 25, 50 }

function Blades.evolution(mastery: number): number
	local n = 0
	for i, at in Blades.Evolutions do
		if mastery >= at then
			n = i
		end
	end
	return n
end

-- The look of blade `id` (a catalogue id: "skin.Jade", "line.Raijin"; a bare skin ref works too)
-- at line `level` and weapon Mastery `mastery`.
function Blades.look(id: string?, level: number?, mastery: number?): Look
	local prefix, ref = string.match(id or "", "^(%a+)%.(.+)$")
	if not prefix then
		prefix, ref = "skin", id
	end
	local evolution = Blades.evolution(mastery or 0)
	local line = if prefix == "line" and ref then LINES[ref] else nil
	if line then
		local lv = math.clamp(level or 1, 1, 4)
		return {
			id = `line.{ref}`,
			ref = ref :: string,
			name = line.name,
			tint = line.tint,
			outline = line.outline,
			fill = line.fill,
			edge = line.edge,
			trail = line.trail,
			dark = line.dark == true,
			glow = line.glow,
			motes = line.motes,
			smear = if lv >= 2 then line.smear else nil,
			deflect = if lv >= 3 then line.deflect else nil,
			finisher = if lv >= 4 then ref else nil,
			level = lv,
			evolution = evolution,
			ribbon = line.ribbon,
		}
	end
	local skin = Progression.skin(ref)
	local extra: Extra = EXTRAS[skin.id] or {}
	local trail = extra.trail or skin.trail
	return {
		id = `skin.{skin.id}`,
		ref = skin.id,
		name = skin.name,
		tint = skin.tint,
		outline = extra.outline or skin.outline,
		fill = skin.fill,
		edge = trail[1],
		trail = trail,
		dark = extra.dark == true,
		glow = extra.glow or skin.glow,
		motes = extra.motes or (if skin.petals then { kind = "petals", color = skin.petals, rate = 6 } else nil),
		smear = nil,
		deflect = nil,
		finisher = nil,
		level = 1,
		evolution = evolution,
		ribbon = extra.ribbon or trail[2],
	}
end

-- The sound ids the line styles name (Shared/Assets.Cosmetics.Sounds).
function Blades.sound(key: string): string?
	return Assets.Cosmetics.Sounds[key]
end

return Blades
