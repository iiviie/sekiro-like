--!strict
-- Everything a player works toward between fights: Mastery levels (XP from every good
-- play), daily Trials, and blade skins. Shared so the server awards and the client shows the
-- same numbers. Research: "Why it is not fun" notes; a level every one or two early
-- matches, three daily goals, and cosmetics with visible, odd unlock conditions.

local Progression = {}

-- XP and coins per event. Coins here replace Config.Economy.Rewards for match events.
Progression.Rewards = {
	Deflect = { XP = 3 },
	PerfectDeflect = { XP = 6 },
	Mikiri = { XP = 15 },
	Kill = { XP = 30, Coins = 15 }, -- also paid for cutting down a fighter who will rise
	Deathblow = { XP = 15, Coins = 5 }, -- on top of the kill
	Played = { XP = 25, Coins = 10 },
	Outlasted = { XP = 6 }, -- per fighter you outlived
	Win = { XP = 120, Coins = 60 },
	-- A duel is one opponent, not five: about half a royale win.
	DuelWin = { XP = 60, Coins = 25 },
	DuelRound = { XP = 10 }, -- per round taken, so a 2-3 loss still pays for the fight
} :: { [string]: { XP: number?, Coins: number? } }

-- XP needed to go from `level` to `level + 1`: fast at first (a level per match or two),
-- slower later.
function Progression.xpToNext(level: number): number
	return 120 + (level - 1) * 45
end

-- Coins paid on reaching `level`.
function Progression.levelReward(level: number): number
	return 40 + level * 10
end

-- Blade skins. A skin tints the blade (SpecialMesh.VertexColor multiplies the texture),
-- recolours the outline and swing trail, and may add a glow or drifting particles.
-- `unlock` is shown as the condition; `price` is coins once the condition is met.
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
	price: number,
	unlock: { stat: string, amount: number, text: string }?,
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
		price = 0,
	},
	{
		id = "Crimson",
		name = "Crimson Lacquer",
		blurb = "Dipped in red lacquer, like the shrine gates.",
		tint = Vector3.new(1.4, 0.45, 0.4),
		outline = Color3.fromRGB(60, 6, 10),
		fill = Color3.fromRGB(255, 80, 70),
		trail = { Color3.fromRGB(255, 110, 90), Color3.fromRGB(190, 20, 30) },
		price = 400,
	},
	{
		id = "Jade",
		name = "Jade River",
		blurb = "Cool as mountain water.",
		tint = Vector3.new(0.55, 1.25, 0.95),
		outline = Color3.fromRGB(8, 40, 30),
		fill = Color3.fromRGB(110, 230, 180),
		trail = { Color3.fromRGB(170, 255, 215), Color3.fromRGB(40, 170, 130) },
		price = 600,
		unlock = { stat = "Level", amount = 3, text = "Reach Mastery 3" },
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
		price = 1200,
		unlock = { stat = "Level", amount = 6, text = "Reach Mastery 6" },
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
		price = 1500,
		unlock = { stat = "Wins", amount = 5, text = "Win 5 royales" },
	},
	{
		id = "Obsidian",
		name = "Obsidian Oni",
		blurb = "Black glass with a burning edge. Earned in blood.",
		tint = Vector3.new(0.28, 0.25, 0.3),
		outline = Color3.fromRGB(255, 50, 30),
		fill = Color3.fromRGB(30, 10, 14),
		trail = { Color3.fromRGB(255, 70, 40), Color3.fromRGB(40, 0, 0) },
		glow = Color3.fromRGB(255, 60, 30),
		price = 2000,
		unlock = { stat = "Deathblows", amount = 25, text = "Land 25 deathblows" },
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
		price = 2500,
		unlock = { stat = "Perfects", amount = 150, text = "150 perfect deflects" },
	},
} :: { Skin }

local byId: { [string]: Skin } = {}
for _, skin in Progression.Skins do
	byId[skin.id] = skin
end

function Progression.skin(id: string?): Skin
	return (id and byId[id]) or Progression.Skins[1]
end

-- Daily Trials: three a day, drawn per player from this pool by a seed of user id and day,
-- so everyone gets a different set and it is stable through the day. Completed trials pay
-- out at once.
export type Trial = { id: string, text: string, event: string, goal: number, coins: number, xp: number }

Progression.Trials = {
	{ id = "deflect20", text = "Deflect 20 attacks", event = "Deflect", goal = 20, coins = 120, xp = 80 },
	{ id = "perfect6", text = "Land 6 perfect deflects", event = "PerfectDeflect", goal = 6, coins = 150, xp = 100 },
	{ id = "kill3", text = "Cut down 3 fighters", event = "Kill", goal = 3, coins = 120, xp = 80 },
	{ id = "deathblow2", text = "Land 2 deathblows", event = "Deathblow", goal = 2, coins = 140, xp = 90 },
	{ id = "play3", text = "Fight 3 royales or duels", event = "Played", goal = 3, coins = 100, xp = 80 },
	{ id = "top3", text = "Finish in the top 3 twice", event = "Top3", goal = 2, coins = 150, xp = 100 },
	{ id = "win1", text = "Win a royale", event = "Win", goal = 1, coins = 200, xp = 150 },
	{ id = "mikiri1", text = "Mikiri Counter a thrust", event = "Mikiri", goal = 1, coins = 150, xp = 100 },
	{ id = "jump2", text = "Jump 2 sweeps", event = "Jumped", goal = 2, coins = 120, xp = 80 },
	{ id = "riposte5", text = "Land 5 ripostes", event = "Riposte", goal = 5, coins = 130, xp = 90 },
} :: { Trial }

Progression.TrialsPerDay = 3

local trialsById: { [string]: Trial } = {}
for _, trial in Progression.Trials do
	trialsById[trial.id] = trial
end

function Progression.trial(id: string): Trial?
	return trialsById[id]
end

function Progression.dailyTrials(userId: number, day: number): { string }
	local rng = Random.new(userId * 7919 + day * 104729)
	local pool = table.clone(Progression.Trials)
	local picked = {}
	for _ = 1, Progression.TrialsPerDay do
		local trial = table.remove(pool, rng:NextInteger(1, #pool)) :: Trial
		table.insert(picked, trial.id)
	end
	return picked
end

return Progression
