--!strict
-- Every pacing number in one place: XP curve, level and milestone rewards, match / duel / boss
-- payouts, the earn-only faucets (Whetstones, Shrine Draws, gems), the daily streak, anti-farm
-- rules and the season-pass XP hooks. Read by server/ProgressService, server/Economy and
-- LobbyService, and shown by the client panels; nothing here is enforced on the client.
--
-- The `N` table between the BEGIN/END markers is also parsed by the pacing simulation
-- (research_notes/progression/sim/pacing_sim.py), so keep it a plain table literal: numbers,
-- strings, nested tables, `--` comments. Formulas below it must match the sim's copies.
-- Tuning history and the targets they meet: research_notes/progression/04_pacing_sim.md.

local EconomyConfig = {}

-- BEGIN NUMBERS
local N = {
	StartCoins = 250,
	StartGems = 0,

	-- Mastery XP to go from level L to L+1: Early.Base + Early.Step * (L - 1) below
	-- Early.Until (a level every match or two, L10 in about an hour), then the last early
	-- value grown by Growth per level, capped at Cap (about 45 minutes of play).
	Curve = {
		Early = { Base = 160, Step = 95, Until = 10 },
		Growth = 1.08,
		Cap = 6000,
	},
	-- Coins on reaching level L: Base + PerLevel * L, never more than Max.
	LevelCoins = { Base = 50, PerLevel = 5, Max = 150 },
	-- Every Every-th level is a milestone: extra coins, gems and Whetstones on top.
	Milestone = { Every = 5, Coins = 100, Gems = 10, Whetstones = 3 },

	-- Match events (XP and coins). Coins for kills and deathblows are paid once per victim
	-- per match: finishing someone who already rose from a cut-down pays XP only.
	Match = {
		Deflect = { XP = 3 },
		PerfectDeflect = { XP = 6 },
		Mikiri = { XP = 15 },
		Kill = { XP = 30, Coins = 15 },
		Deathblow = { XP = 15, Coins = 5 },
		Played = { XP = 25, Coins = 10 },
		Outlasted = { XP = 6 },
		Win = { XP = 120, Coins = 60 },
		DuelWin = { XP = 60, Coins = 25 },
		DuelRound = { XP = 10 },
	},

	-- Boss trials: fought, per life taken, clear (x stars, min 1), and once per boss on top.
	Boss = {
		Fought = { XP = 25, Coins = 10 },
		Phase = { XP = 20 },
		Clear = { XP = 80, Coins = 30, Whetstones = 1 },
		FirstClear = { XP = 150, Coins = 120, Whetstones = 3, Gems = 10, GemsPerStar = 10 },
	},

	-- Whetstones: earned only, never sold. They level premium blade lines (Catalog).
	Whetstones = {
		RoyaleWin = 1,
		DuelWin = 1,
		Trial = 1, -- per daily trial completed
		WinCapPerDay = 3, -- wins (royale + duel) that pay Whetstones per UTC day
	},

	-- Shrine Draws: earned random rewards (no Robux), opened by the shrine (later part).
	Draws = {
		RoyaleWin = 1,
		RoyaleWinCapPerDay = 3,
		DuelWinPerDay = 1, -- the first duel win of the day
	},

	-- Daily login streak: day N pays Coins[N]; the last day also pays gems and Whetstones.
	-- A missed day pauses the streak instead of resetting it; after the last day it wraps.
	Daily = {
		Coins = { 50, 60, 70, 80, 100, 120, 150 },
		LastDayGems = 20,
		LastDayWhetstones = 5,
	},

	-- Ranked season end: gems by the tier reached (Shared/Ranks tiers).
	SeasonEndGems = { Bronze = 20, Silver = 40, Gold = 75, Jade = 120, Crimson = 180, Shogun = 250 },

	-- Season pass ("Path of the Blade") XP hooks; tiers, missions and tracks are part S's.
	Pass = {
		TierXP = 1000,
		Tiers = 30,
		Played = 30, -- per royale, duel or boss fight
		Win = 20, -- royale or duel win
		FinalWeekMultiplier = 2,
	},

	-- Anti-farm.
	AntiFarm = {
		-- Rewards for the Nth duel today against the same human (1-based); beyond the list: 0.
		RepeatOpponent = { 1, 1, 0.5, 0.25 },
	},

	-- Line upgrades: Whetstones per level are in Catalog; gems may pay for at most this share
	-- of each level's Whetstones, at GemsPerWhetstone each.
	LineUpgrade = { GemsPerWhetstone = 10, GemShareMax = 0.5 },

	-- The Initiate's Bundle is on offer for this long after a player's first join.
	InitiateWindowHours = 72,
}
-- END NUMBERS

EconomyConfig.N = N

EconomyConfig.StartCoins = N.StartCoins
EconomyConfig.StartGems = N.StartGems
EconomyConfig.Match = N.Match :: { [string]: { XP: number?, Coins: number? } }
EconomyConfig.Boss = N.Boss
EconomyConfig.Whetstones = N.Whetstones
EconomyConfig.Draws = N.Draws
EconomyConfig.Daily = N.Daily
EconomyConfig.SeasonEndGems = N.SeasonEndGems :: { [string]: number }
EconomyConfig.Pass = N.Pass
EconomyConfig.AntiFarm = N.AntiFarm
EconomyConfig.LineUpgrade = N.LineUpgrade
EconomyConfig.Milestone = N.Milestone
EconomyConfig.InitiateWindow = N.InitiateWindowHours * 3600

-- The current season (pass premium and ranked rewards are keyed by it).
EconomyConfig.Season = "S1"

local SECONDS_PER_DAY = 86400

-- UTC day number on the server clock. The client never computes days: the server publishes
-- `ServerDay` and `DayEndsAt` on ReplicatedStorage (see Economy).
function EconomyConfig.day(time: number?): number
	return math.floor((time or os.time()) / SECONDS_PER_DAY)
end

-- XP needed to go from `level` to `level + 1`.
function EconomyConfig.xpToNext(level: number): number
	local curve = N.Curve
	local early = curve.Early
	if level < early.Until then
		return early.Base + early.Step * (level - 1)
	end
	local last = early.Base + early.Step * (early.Until - 2)
	return math.min(curve.Cap, math.floor(last * curve.Growth ^ (level - early.Until + 1) / 10 + 0.5) * 10)
end

-- Coins paid on reaching `level` (milestones add Milestone.Coins).
function EconomyConfig.levelCoins(level: number): number
	local c = N.LevelCoins
	return math.min(c.Max, c.Base + c.PerLevel * level)
end

function EconomyConfig.isMilestone(level: number): boolean
	return level % N.Milestone.Every == 0
end

-- Reward multiplier for a duel against a human you have already fought `before` times today.
function EconomyConfig.repeatFactor(before: number): number
	return N.AntiFarm.RepeatOpponent[before + 1] or 0
end

return EconomyConfig
