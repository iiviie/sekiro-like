--!strict
-- "Path of the Blade": the season pass calendar, its reward track and the missions that feed
-- it. Data only (plus pure helpers), shared so the server pays exactly what the client shows.
-- server/PassService runs it; client/PassPanel draws it.
--
-- Calendar: each season runs `weeks` from `starts` (a Monday, 00:00 UTC), then a break of
-- `breakWeeks` with no Pass XP (claims stay open). The final week pays double Pass XP
-- (EconomyConfig.Pass.FinalWeekMultiplier). To add a season, append an entry whose `starts`
-- is on or after the previous one's break end, and set EconomyConfig.Season to its id when it
-- goes live (Monetization's premium check reads that). Rollover (archive + reset) is
-- automatic when the calendar reaches a new season.
--
-- Track: Tiers x TierXP Pass XP (EconomyConfig.Pass). Each tier has a premium reward (owners
-- of pass.Premium) and some have a free one (everyone). Rewards are Catalog ids or currencies.
--
-- Missions: three daily (one from each daily group, drawn per player per UTC day) and five
-- weekly bounties (one per weekly group, per UTC week starting Monday). They pay Pass XP plus
-- coins / Mastery XP / Whetstones, never cost anything, and one daily can be rerolled free
-- once a day. Blocks between BEGIN/END markers are parsed by the pacing sim
-- (research_notes/progression/sim/pacing_sim.py): keep them plain table literals.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local EconomyConfig = require(script.Parent.EconomyConfig)

local DAY = 86400
local WEEK = 7 * DAY

export type RewardKind = "coins" | "gems" | "whetstones" | "draws" | "item"
export type Reward = { kind: RewardKind, amount: number?, id: string? }
export type Tier = { free: { Reward }?, premium: { Reward } }
export type Def = {
	id: string,
	number: number,
	name: string,
	subtitle: string,
	starts: number, -- epoch
	ends: number, -- epoch: Pass XP stops
	breakEnds: number, -- epoch: the next season may start
	tiers: { Tier },
}
export type State = "live" | "break" | "off" -- off: before the first season or after the last break
export type Mission = {
	id: string,
	text: string,
	event: string, -- ProgressService event name
	goal: number,
	coins: number,
	xp: number, -- Mastery XP
	pass: number, -- Pass XP
	whetstones: number,
	group: string,
	weekly: boolean,
}

local Season = {}

Season.Name = "Path of the Blade"
Season.TierXP = EconomyConfig.Pass.TierXP
Season.Tiers = EconomyConfig.Pass.Tiers
Season.MaxXP = Season.TierXP * Season.Tiers
Season.FinalWeekMultiplier = EconomyConfig.Pass.FinalWeekMultiplier
Season.Products = { Premium = "pass.Premium", TierSkip = "pass.TierSkip", Tiers10 = "pass.Tiers10" }

local function utc(year: number, month: number, day: number): number
	return DateTime.fromUniversalTime(year, month, day).UnixTimestamp
end

local function coins(n: number): Reward
	return { kind = "coins", amount = n }
end
local function gems(n: number): Reward
	return { kind = "gems", amount = n }
end
local function stones(n: number): Reward
	return { kind = "whetstones", amount = n }
end
local function draws(n: number): Reward
	return { kind = "draws", amount = n }
end
local function item(id: string): Reward
	return { kind = "item", id = id }
end

-- Season 1 track. Premium pays back 500 gems (enough for the next pass), Whetstones, Shrine
-- Draws, two blades and a nameplate; the capstone is the season blade with its finisher and
-- title. Free pays 100 gems, the Pilgrim's Cedar blade and the Pilgrim title among 11 rewards.
local S1_TIERS: { Tier } = {
	{ free = { coins(200) }, premium = { item("skin.S1Vermilion") } }, -- 1
	{ premium = { gems(50) } },
	{ free = { draws(1) }, premium = { stones(3) } },
	{ premium = { coins(300) } },
	{ free = { gems(20) }, premium = { draws(1) } }, -- 5
	{ premium = { gems(50) } },
	{ premium = { stones(3) } },
	{ free = { stones(3) }, premium = { coins(400) } },
	{ premium = { draws(1) } },
	{ free = { item("skin.S1Cedar") }, premium = { gems(50) } }, -- 10
	{ premium = { stones(4) } },
	{ premium = { item("banner.S1Path") } },
	{ free = { gems(20) }, premium = { coins(500) } },
	{ premium = { gems(50) } },
	{ premium = { draws(2) } }, -- 15
	{ free = { coins(500) }, premium = { stones(4) } },
	{ premium = { gems(50) } },
	{ premium = { coins(600) } },
	{ premium = { stones(5) } },
	{ free = { item("title.S1Pilgrim") }, premium = { gems(50) } }, -- 20
	{ premium = { draws(2) } },
	{ premium = { coins(750) } },
	{ free = { gems(30) }, premium = { gems(50) } },
	{ premium = { stones(5) } },
	{ premium = { item("plate.S1Path") } }, -- 25
	{ free = { draws(2) }, premium = { gems(50) } },
	{ premium = { draws(2) } },
	{ premium = { stones(6) } },
	{ premium = { gems(50) } },
	{ -- 30: the capstone
		free = { gems(30) },
		premium = {
			item("skin.S1Hanafubuki"),
			item("finisher.SakuraScatter"),
			item("title.S1Wayfarer"),
			gems(50),
		},
	},
}

-- The calendar. Dates are configurable; S1 opens on a Monday and runs 6 weeks + a 1-week break.
local CALENDAR = {
	{
		id = "S1",
		name = "Path of the Blade",
		subtitle = "Season 1  ·  The Ascent",
		starts = utc(2026, 10, 19),
		weeks = 6,
		breakWeeks = 1,
		tiers = S1_TIERS,
	},
}

Season.List = {} :: { Def }
local byId: { [string]: Def } = {}
for i, entry in CALENDAR do
	assert(#entry.tiers == Season.Tiers, `[Season] {entry.id} needs {Season.Tiers} tiers`)
	local def: Def = {
		id = entry.id,
		number = i,
		name = entry.name,
		subtitle = entry.subtitle,
		starts = entry.starts,
		ends = entry.starts + entry.weeks * WEEK,
		breakEnds = entry.starts + (entry.weeks + entry.breakWeeks) * WEEK,
		tiers = entry.tiers,
	}
	local previous = Season.List[#Season.List]
	assert(not previous or def.starts >= previous.breakEnds, `[Season] {def.id} overlaps {previous and previous.id}`)
	table.insert(Season.List, def)
	byId[def.id] = def
end

function Season.get(id: string?): Def?
	return if id then byId[id] else nil
end

-- The season clock: server time (the client reads workspace:GetServerTimeNow, never its own
-- clock). In Studio, ReplicatedStorage.SeasonClockOffset (seconds) shifts it for tests.
function Season.now(): number
	local t = workspace:GetServerTimeNow()
	if RunService:IsStudio() then
		local offset = ReplicatedStorage:GetAttribute("SeasonClockOffset")
		if typeof(offset) == "number" then
			t += offset
		end
	end
	return t
end

-- The season at time `t` (default now) and its state. During a break the season returned is
-- the one that just ended; `until` is when the current state ends (season end, break end).
function Season.at(t: number?): (Def?, State, number)
	local time = t or Season.now()
	for _, def in Season.List do
		if time < def.starts then
			return nil, "off", def.starts -- before this season: the gap before it
		elseif time < def.ends then
			return def, "live", def.ends
		elseif time < def.breakEnds then
			return def, "break", def.breakEnds
		end
	end
	local last = Season.List[#Season.List]
	return last, "off", 0
end

-- Pass XP multiplier at `t`: double in a live season's final week, 0 outside a live season.
function Season.multiplier(t: number?): number
	local time = t or Season.now()
	local def, state = Season.at(time)
	if not def or state ~= "live" then
		return 0
	end
	return if time >= def.ends - WEEK then Season.FinalWeekMultiplier else 1
end

function Season.tierOf(xp: number): number
	return math.clamp(math.floor(xp / Season.TierXP), 0, Season.Tiers)
end

-- A reward's display name and the image key family it belongs to (client) / for logs.
function Season.rewardText(reward: Reward, nameOf: ((string) -> string?)?): string
	if reward.kind == "item" then
		return (nameOf and reward.id and nameOf(reward.id)) or reward.id or "?"
	end
	local amount = reward.amount or 0
	local label = if reward.kind == "coins"
		then "coins"
		elseif reward.kind == "gems" then "gems"
		elseif reward.kind == "whetstones" then (if amount == 1 then "Whetstone" else "Whetstones")
		else (if amount == 1 then "Shrine Draw" else "Shrine Draws")
	return `{amount} {label}`
end

--------------------------------------------------------------------------------------------
-- Missions. `pass` is Pass XP (x the final-week multiplier); coins / xp / whetstones as the
-- old daily Trials paid. Events come from server/ProgressService: Deflect, PerfectDeflect,
-- Mikiri, Jumped, Riposte, Kill, Deathblow, Played (any fight), Royale, Top3, Win (royale),
-- Duel, DuelWin, BossFought, BossClear.

-- BEGIN DAILY
local DAILY = {
	skill = {
		{
			id = "deflect25",
			text = "Deflect 25 attacks",
			event = "Deflect",
			goal = 25,
			coins = 120,
			xp = 80,
			pass = 50,
		},
		{
			id = "perfect6",
			text = "Land 6 perfect deflects",
			event = "PerfectDeflect",
			goal = 6,
			coins = 150,
			xp = 100,
			pass = 50,
		},
		{
			id = "mikiri1",
			text = "Mikiri Counter a thrust",
			event = "Mikiri",
			goal = 1,
			coins = 150,
			xp = 100,
			pass = 50,
		},
		{ id = "jump2", text = "Jump 2 sweeps", event = "Jumped", goal = 2, coins = 120, xp = 80, pass = 50 },
		{ id = "riposte5", text = "Land 5 ripostes", event = "Riposte", goal = 5, coins = 130, xp = 90, pass = 50 },
	},
	mode = {
		{ id = "duel2", text = "Fight 2 duels", event = "Duel", goal = 2, coins = 110, xp = 80, pass = 50 },
		{ id = "duelwin1", text = "Win a duel", event = "DuelWin", goal = 1, coins = 140, xp = 90, pass = 50 },
		{
			id = "boss1",
			text = "Take on a boss trial",
			event = "BossFought",
			goal = 1,
			coins = 120,
			xp = 80,
			pass = 50,
		},
		{ id = "royale2", text = "Fight 2 royales", event = "Royale", goal = 2, coins = 110, xp = 80, pass = 50 },
		{
			id = "top3",
			text = "Finish a royale in the top 3",
			event = "Top3",
			goal = 1,
			coins = 150,
			xp = 100,
			pass = 50,
		},
	},
	finish = {
		{ id = "kill3", text = "Cut down 3 fighters", event = "Kill", goal = 3, coins = 120, xp = 80, pass = 50 },
		{
			id = "deathblow2",
			text = "Land 2 deathblows",
			event = "Deathblow",
			goal = 2,
			coins = 140,
			xp = 90,
			pass = 50,
		},
		{ id = "play3", text = "Fight 3 times, any mode", event = "Played", goal = 3, coins = 100, xp = 80, pass = 50 },
	},
}
-- END DAILY

-- BEGIN WEEKLY
local WEEKLY = {
	skill = {
		{
			id = "w_deflect150",
			text = "Deflect 150 attacks",
			event = "Deflect",
			goal = 150,
			coins = 200,
			xp = 200,
			pass = 200,
		},
		{
			id = "w_perfect40",
			text = "Land 40 perfect deflects",
			event = "PerfectDeflect",
			goal = 40,
			coins = 200,
			xp = 200,
			pass = 200,
		},
		{
			id = "w_mikiri5",
			text = "Mikiri Counter 5 thrusts",
			event = "Mikiri",
			goal = 5,
			coins = 200,
			xp = 200,
			pass = 200,
		},
	},
	duel = {
		{ id = "w_duelwin6", text = "Win 6 duels", event = "DuelWin", goal = 6, coins = 200, xp = 200, pass = 200 },
		{ id = "w_duel12", text = "Fight 12 duels", event = "Duel", goal = 12, coins = 200, xp = 200, pass = 200 },
	},
	boss = {
		{
			id = "w_bossclear3",
			text = "Clear 3 boss trials",
			event = "BossClear",
			goal = 3,
			coins = 200,
			xp = 200,
			pass = 200,
		},
		{
			id = "w_boss6",
			text = "Take on 6 boss trials",
			event = "BossFought",
			goal = 6,
			coins = 200,
			xp = 200,
			pass = 200,
		},
	},
	royale = {
		{
			id = "w_top3x4",
			text = "Finish in the top 3 four times",
			event = "Top3",
			goal = 4,
			coins = 200,
			xp = 200,
			pass = 200,
		},
		{
			id = "w_royale10",
			text = "Fight 10 royales",
			event = "Royale",
			goal = 10,
			coins = 200,
			xp = 200,
			pass = 200,
		},
		{ id = "w_win1", text = "Win a royale", event = "Win", goal = 1, coins = 200, xp = 200, pass = 200 },
	},
	finish = {
		{
			id = "w_deathblow20",
			text = "Land 20 deathblows",
			event = "Deathblow",
			goal = 20,
			coins = 200,
			xp = 200,
			pass = 200,
		},
		{
			id = "w_kill25",
			text = "Cut down 25 fighters",
			event = "Kill",
			goal = 25,
			coins = 200,
			xp = 200,
			pass = 200,
		},
		{
			id = "w_play20",
			text = "Fight 20 times, any mode",
			event = "Played",
			goal = 20,
			coins = 200,
			xp = 200,
			pass = 200,
		},
	},
}
-- END WEEKLY

local DAILY_GROUPS = { "skill", "mode", "finish" }
local WEEKLY_GROUPS = { "skill", "duel", "boss", "royale", "finish" }
local WEEKLY_STONES = 1

Season.DailyCount = #DAILY_GROUPS
Season.WeeklyCount = #WEEKLY_GROUPS

local missions: { [string]: Mission } = {}
local function register(pools: { [string]: { any } }, weekly: boolean)
	for group, pool in pools do
		for _, raw in pool do
			assert(not missions[raw.id], `[Season] duplicate mission {raw.id}`)
			missions[raw.id] = {
				id = raw.id,
				text = raw.text,
				event = raw.event,
				goal = raw.goal,
				coins = raw.coins,
				xp = raw.xp,
				pass = raw.pass,
				whetstones = if weekly then WEEKLY_STONES else EconomyConfig.Whetstones.Trial,
				group = group,
				weekly = weekly,
			}
		end
	end
end
register(DAILY, false)
register(WEEKLY, true)

function Season.mission(id: string?): Mission?
	return if id then missions[id] else nil
end

-- The UTC week (weeks start Monday 00:00 UTC) and when it ends.
function Season.week(time: number?): number
	return math.floor((EconomyConfig.day(time) - 4) / 7) -- 1970-01-05 was a Monday (day 4)
end
function Season.weekEndsAt(week: number): number
	return ((week + 1) * 7 + 4) * DAY
end

local function pick(pools: { [string]: { any } }, groups: { string }, rng: Random): { string }
	local out = {}
	for _, group in groups do
		local pool = pools[group]
		table.insert(out, pool[rng:NextInteger(1, #pool)].id)
	end
	return out
end

-- Today's three daily missions for a player (stable through the day, different per player).
function Season.dailyMissions(userId: number, day: number): { string }
	return pick(DAILY, DAILY_GROUPS, Random.new(userId * 7919 + day * 104729))
end

-- This week's five bounties.
function Season.weeklyMissions(userId: number, week: number): { string }
	return pick(WEEKLY, WEEKLY_GROUPS, Random.new(userId * 6271 + week * 15485863))
end

-- A replacement for daily mission `id` from the same group that isn't in `current`.
function Season.rerollDaily(id: string, current: { string }, seed: number): string?
	local mission = missions[id]
	if not mission or mission.weekly then
		return nil
	end
	local options = {}
	for _, raw in DAILY[mission.group] do
		if not table.find(current, raw.id) then
			table.insert(options, raw.id)
		end
	end
	if #options == 0 then
		return nil
	end
	return options[Random.new(seed):NextInteger(1, #options)]
end

return Season
