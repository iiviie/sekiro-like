--!strict
-- Everything a player works toward between fights: Mastery levels (XP from every good
-- play), the old daily Trials entry points, and the blade skins' looks. Shared so the server awards and the client
-- shows the same numbers. Research: "Why it is not fun" notes; a level every one or two early
-- matches, three daily goals, and cosmetics with visible, odd unlock conditions.
--
-- Pacing numbers (rewards, XP curve, level coins) live in Shared/EconomyConfig; prices,
-- unlock rules and ownership in Shared/Catalog. This module keeps the old entry points.

local EconomyConfig = require(script.Parent.EconomyConfig)
local Season = require(script.Parent.Season)

local Progression = {}

-- XP and coins per match event (Shared/EconomyConfig.Match).
Progression.Rewards = EconomyConfig.Match

-- XP needed to go from `level` to `level + 1`.
function Progression.xpToNext(level: number): number
	return EconomyConfig.xpToNext(level)
end

-- Coins paid on reaching `level` (milestone levels pay EconomyConfig.Milestone on top).
function Progression.levelReward(level: number): number
	return EconomyConfig.levelCoins(level)
end

-- Blade skins' looks, by ref (Shared/Catalog `skin.<id>` holds the price and unlock rule). A
-- skin tints the blade (SpecialMesh.VertexColor multiplies the texture), recolours the outline
-- and swing trail, and may add a glow or drifting particles. Keep trails and outlines away
-- from the perilous red (Animator PERIL_TRAIL) so a red blade never hides a perilous read.
-- Bots wear entries 1-7 by index (BotService), so append new skins at the end.
export type Skin = {
	id: string,
	name: string,
	blurb: string,
	tint: Vector3, -- SpecialMesh.VertexColor
	outline: Color3,
	fill: Color3,
	trail: { Color3 }, -- start, end
	glow: Color3?,
	petals: Color3?,
	goldOf: string?, -- a boss no-hit gold variant: the skin it gilds (motes come from it)
}

Progression.Skins = {
	{
		id = "Steel",
		name = "Tamahagane",
		blurb = "The forge's honest steel.",
		tint = Vector3.new(1, 1, 1),
		outline = Color3.fromRGB(20, 18, 22),
		fill = Color3.fromRGB(235, 240, 255),
		trail = { Color3.fromRGB(255, 255, 255), Color3.fromRGB(205, 220, 255) },
	},
	{
		id = "Crimson",
		name = "Crimson Lacquer",
		blurb = "Dipped in red lacquer, like the shrine gates.",
		tint = Vector3.new(1.4, 0.45, 0.4),
		outline = Color3.fromRGB(60, 6, 10),
		fill = Color3.fromRGB(255, 80, 70),
		-- A wine-rose lacquer smear, kept off the perilous red.
		trail = { Color3.fromRGB(255, 206, 196), Color3.fromRGB(156, 28, 92) },
	},
	{
		id = "Jade",
		name = "Jade River",
		blurb = "Cool as mountain water.",
		tint = Vector3.new(0.55, 1.25, 0.95),
		outline = Color3.fromRGB(8, 40, 30),
		fill = Color3.fromRGB(110, 230, 180),
		trail = { Color3.fromRGB(170, 255, 215), Color3.fromRGB(40, 170, 130) },
	},
	{
		id = "Sakura",
		name = "Sakura Storm",
		blurb = "Every cut sheds petals.",
		tint = Vector3.new(1.35, 0.85, 1.05),
		outline = Color3.fromRGB(70, 20, 45),
		fill = Color3.fromRGB(255, 170, 205),
		trail = { Color3.fromRGB(255, 205, 225), Color3.fromRGB(240, 110, 160) },
		petals = Color3.fromRGB(255, 180, 210),
	},
	{
		id = "Gold",
		name = "Gold Leaf",
		blurb = "For those who have won and want everyone to know.",
		tint = Vector3.new(1.5, 1.15, 0.45),
		outline = Color3.fromRGB(60, 40, 6),
		fill = Color3.fromRGB(255, 210, 110),
		trail = { Color3.fromRGB(255, 240, 170), Color3.fromRGB(220, 160, 40) },
		glow = Color3.fromRGB(255, 200, 90),
	},
	{
		id = "Obsidian",
		name = "Obsidian Oni",
		blurb = "Black glass with a burning edge. Earned in blood.",
		tint = Vector3.new(0.28, 0.25, 0.3),
		-- An ember-gold burning edge over violet-black glass, kept off the perilous red.
		outline = Color3.fromRGB(255, 150, 60),
		fill = Color3.fromRGB(30, 10, 14),
		trail = { Color3.fromRGB(255, 204, 120), Color3.fromRGB(52, 16, 56) },
		glow = Color3.fromRGB(255, 150, 60),
	},
	{
		id = "Moon",
		name = "Moonlit Edge",
		blurb = "Only the patient can hold it.",
		tint = Vector3.new(1.2, 1.25, 1.5),
		outline = Color3.fromRGB(150, 190, 255),
		fill = Color3.fromRGB(220, 235, 255),
		trail = { Color3.fromRGB(240, 248, 255), Color3.fromRGB(120, 160, 255) },
		glow = Color3.fromRGB(160, 200, 255),
	},
	-- Coin skins (Mastery-gated in Catalog).
	{
		id = "Aizome",
		name = "Aizome",
		blurb = "Indigo-dyed steel, deep as the night sea.",
		tint = Vector3.new(0.55, 0.7, 1.4),
		outline = Color3.fromRGB(10, 18, 60),
		fill = Color3.fromRGB(90, 120, 230),
		trail = { Color3.fromRGB(170, 195, 255), Color3.fromRGB(50, 80, 200) },
	},
	{
		id = "Bamboo",
		name = "Green Bamboo",
		blurb = "Bends in the wind, never breaks.",
		tint = Vector3.new(0.85, 1.3, 0.6),
		outline = Color3.fromRGB(20, 44, 10),
		fill = Color3.fromRGB(160, 220, 110),
		trail = { Color3.fromRGB(215, 250, 170), Color3.fromRGB(90, 160, 50) },
	},
	{
		id = "Amber",
		name = "Kohaku Amber",
		blurb = "Warm as resin in the sun.",
		tint = Vector3.new(1.45, 1.05, 0.55),
		outline = Color3.fromRGB(60, 34, 6),
		fill = Color3.fromRGB(255, 190, 100),
		trail = { Color3.fromRGB(255, 225, 160), Color3.fromRGB(225, 140, 40) },
		glow = Color3.fromRGB(255, 180, 90),
	},
	{
		id = "Fuji",
		name = "Fuji Snow",
		blurb = "The first snow on the far mountain.",
		tint = Vector3.new(1.3, 1.3, 1.45),
		outline = Color3.fromRGB(110, 100, 150),
		fill = Color3.fromRGB(240, 240, 255),
		trail = { Color3.fromRGB(255, 255, 255), Color3.fromRGB(190, 180, 240) },
		petals = Color3.fromRGB(245, 245, 255),
	},
	{
		id = "Thunderhead",
		name = "Thunderhead",
		blurb = "Storm-grey steel that hums before it strikes.",
		tint = Vector3.new(0.6, 0.6, 0.8),
		outline = Color3.fromRGB(170, 140, 255),
		fill = Color3.fromRGB(60, 60, 90),
		trail = { Color3.fromRGB(225, 210, 255), Color3.fromRGB(120, 90, 230) },
		glow = Color3.fromRGB(170, 140, 255),
	},
	{
		id = "Kintsugi",
		name = "Kintsugi",
		blurb = "Broken once, mended with gold.",
		tint = Vector3.new(0.35, 0.33, 0.36),
		outline = Color3.fromRGB(255, 205, 90),
		fill = Color3.fromRGB(40, 36, 40),
		trail = { Color3.fromRGB(255, 235, 160), Color3.fromRGB(200, 150, 40) },
		glow = Color3.fromRGB(255, 200, 90),
	},
	-- Boss-trial skins (earned, never sold).
	{
		id = "Washi",
		name = "Washi Talisman",
		blurb = "Paper charms bound to the blade by the shikigami.",
		tint = Vector3.new(1.35, 1.3, 1.15),
		outline = Color3.fromRGB(30, 26, 24),
		fill = Color3.fromRGB(245, 238, 220),
		trail = { Color3.fromRGB(255, 252, 240), Color3.fromRGB(70, 66, 60) },
	},
	{
		id = "Nameless",
		name = "Nameless Edge",
		blurb = "Worn plain by a warrior who gave no name.",
		tint = Vector3.new(0.75, 0.8, 0.95),
		outline = Color3.fromRGB(16, 20, 40),
		fill = Color3.fromRGB(150, 160, 200),
		trail = { Color3.fromRGB(220, 225, 245), Color3.fromRGB(90, 100, 150) },
	},
	{
		id = "CatClaw",
		name = "Cat's Claw",
		blurb = "Ginger lacquer and a hooked gleam.",
		tint = Vector3.new(1.4, 1.0, 0.6),
		outline = Color3.fromRGB(70, 40, 10),
		fill = Color3.fromRGB(240, 170, 90),
		trail = { Color3.fromRGB(255, 220, 160), Color3.fromRGB(210, 150, 60) },
	},
	{
		id = "Mistveil",
		name = "Mistveil",
		blurb = "Half there, like the guard in the fog.",
		tint = Vector3.new(1.05, 1.15, 1.2),
		outline = Color3.fromRGB(120, 140, 160),
		fill = Color3.fromRGB(200, 215, 225),
		trail = { Color3.fromRGB(240, 248, 250), Color3.fromRGB(140, 160, 175) },
		petals = Color3.fromRGB(225, 235, 240),
	},
	{
		id = "DemonHorn",
		name = "Demon Horn",
		blurb = "Bone and ochre, taken from the little demon.",
		tint = Vector3.new(1.3, 1.15, 0.7),
		outline = Color3.fromRGB(50, 36, 20),
		fill = Color3.fromRGB(225, 200, 140),
		trail = { Color3.fromRGB(250, 235, 190), Color3.fromRGB(180, 140, 60) },
	},
	{
		id = "FoxFire",
		name = "Fox Fire",
		blurb = "Kitsune-bi: cold blue flame that follows the cut.",
		tint = Vector3.new(0.7, 0.9, 1.5),
		outline = Color3.fromRGB(80, 140, 255),
		fill = Color3.fromRGB(30, 50, 110),
		trail = { Color3.fromRGB(190, 230, 255), Color3.fromRGB(60, 110, 255) },
		glow = Color3.fromRGB(90, 160, 255),
	},
	{
		id = "Niten",
		name = "Niten Twin",
		blurb = "Two heavens, one blade: proof of every three-star trial.",
		tint = Vector3.new(1.35, 1.35, 1.5),
		outline = Color3.fromRGB(40, 60, 130),
		fill = Color3.fromRGB(235, 240, 255),
		trail = { Color3.fromRGB(255, 255, 255), Color3.fromRGB(70, 100, 200) },
		glow = Color3.fromRGB(200, 215, 255),
	},
	-- The Initiate's Bundle exclusive.
	{
		id = "Initiate",
		name = "Initiate's Vow",
		blurb = "Teal silk on the grip, silver on the edge: a vow to the path.",
		tint = Vector3.new(0.75, 1.25, 1.25),
		outline = Color3.fromRGB(10, 50, 54),
		fill = Color3.fromRGB(130, 225, 220),
		trail = { Color3.fromRGB(210, 255, 250), Color3.fromRGB(40, 170, 170) },
		glow = Color3.fromRGB(120, 230, 220),
	},
	-- Path of the Blade, season 1 (pass rewards).
	{
		id = "S1Cedar",
		name = "Pilgrim's Cedar",
		blurb = "Warm cedar lacquer from the shrine stairs.",
		tint = Vector3.new(1.25, 0.9, 0.65),
		outline = Color3.fromRGB(48, 26, 12),
		fill = Color3.fromRGB(210, 150, 100),
		trail = { Color3.fromRGB(250, 220, 180), Color3.fromRGB(170, 100, 50) },
	},
	{
		id = "S1Vermilion",
		name = "Torii Vermilion",
		blurb = "The colour of a thousand gates up the mountain.",
		tint = Vector3.new(1.5, 0.7, 0.45),
		outline = Color3.fromRGB(60, 16, 6),
		fill = Color3.fromRGB(255, 120, 70),
		trail = { Color3.fromRGB(255, 214, 160), Color3.fromRGB(236, 128, 36) }, -- orange lacquer, off the peril red
		glow = Color3.fromRGB(255, 140, 80),
	},
	{
		id = "S1Hanafubuki",
		name = "Hanafubuki",
		blurb = "The season's blade: a storm of petals at the summit.",
		tint = Vector3.new(1.45, 1.05, 1.2),
		outline = Color3.fromRGB(255, 205, 120),
		fill = Color3.fromRGB(255, 200, 220),
		trail = { Color3.fromRGB(255, 240, 245), Color3.fromRGB(245, 150, 190) },
		glow = Color3.fromRGB(255, 190, 215),
		petals = Color3.fromRGB(255, 190, 215),
	},
} :: { Skin }

-- Boss no-hit gold variants (Shared/Catalog `skin.Gold<...>`, earned by clearing that boss
-- without taking a hit): the boss skin with a gold edge, outline and glow. Crimson Shadow
-- and the Puppet Maiden have no boss skin, so theirs are gilded from a look of their own.
do
	local GOLD = Color3.fromRGB(255, 206, 96)
	local WHITE_GOLD = Color3.fromRGB(255, 240, 186)
	local function find(id: string): Skin
		for _, skin in Progression.Skins do
			if skin.id == id then
				return skin
			end
		end
		error(`[Progression] no skin {id} to gild`)
	end
	local own: { [string]: Skin } = {
		Shadow = {
			id = "Shadow",
			name = "Shadow",
			blurb = "",
			tint = Vector3.new(0.3, 0.27, 0.32),
			outline = GOLD,
			fill = Color3.fromRGB(26, 20, 28),
			trail = { WHITE_GOLD, Color3.fromRGB(60, 40, 70) },
		},
		Puppet = {
			id = "Puppet",
			name = "Puppet",
			blurb = "",
			tint = Vector3.new(1.4, 1.3, 1.25),
			outline = GOLD,
			fill = Color3.fromRGB(245, 236, 228),
			trail = { WHITE_GOLD, Color3.fromRGB(150, 120, 140) },
		},
	}
	for _, g in
		{
			{ "Washi", "Gilded Talisman", "The shikigami's charms, untouched and edged in gold." },
			{ "Nameless", "Gilded Nameless", "The nameless warrior never landed a cut." },
			{ "CatClaw", "Gilded Claw", "The cat general's claws met only air." },
			{ "Mistveil", "Gilded Mist", "Through the fog without a scratch." },
			{ "DemonHorn", "Gilded Horn", "The little demon's horn, gilded for a clean fight." },
			{ "FoxFire", "Gilded Fox Fire", "Gold flame for outlasting the night fox untouched." },
			{ "Niten", "Gilded Twin", "Both heavens, and not one blow taken." },
			{ "Shadow", "Gilded Shadow", "Black glass with a gold edge: the crimson shadow never touched you." },
			{ "Puppet", "Gilded Strings", "Porcelain and gold: the puppet maiden's strings never caught you." },
		}
	do
		local base = own[g[1]] or find(g[1])
		table.insert(Progression.Skins, {
			id = `Gold{g[1]}`,
			name = g[2],
			blurb = g[3],
			tint = base.tint:Lerp(Vector3.new(1.5, 1.2, 0.55), 0.3),
			outline = GOLD,
			fill = base.fill,
			trail = { WHITE_GOLD, base.trail[2] },
			glow = GOLD,
			petals = base.petals,
			goldOf = if own[g[1]] then nil else g[1],
		})
	end
end

local byId: { [string]: Skin } = {}
for _, skin in Progression.Skins do
	byId[skin.id] = skin
end

function Progression.skin(id: string?): Skin
	return (id and byId[id]) or Progression.Skins[1]
end

-- The daily Trials are now the season pass's daily missions (Shared/Season, run by
-- server/PassService). These keep the old entry points for older panels: a mission has the
-- Trial fields (id, text, event, goal, coins, xp) plus its Pass XP.
export type Trial = Season.Mission

Progression.TrialsPerDay = Season.DailyCount

function Progression.trial(id: string): Trial?
	return Season.mission(id)
end

-- The day's missions as first drawn (PassService publishes the live list, after any reroll,
-- in the `Trials` attribute).
function Progression.dailyTrials(userId: number, day: number): { string }
	return Season.dailyMissions(userId, day)
end

return Progression
