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
	Milestone = { Every = 5, Coins = 100, Gems = 10, Whetstones = 2 },

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
		FirstClear = { XP = 150, Coins = 120, Whetstones = 2, Gems = 10, GemsPerStar = 10 },
	},

	-- Whetstones: earned only, never sold. They level premium blade lines (Catalog).
	Whetstones = {
		RoyaleWin = 1,
		DuelWin = 1,
		Trial = 1, -- per daily trial completed
		-- Wins (royale + duel) that pay Whetstones per UTC day. With the caps here a 40 min/day
		-- player earns a full line's L2-L4 (120) in about 12 days (04_pacing_sim.md).
		WinCapPerDay = 2,
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

	-- Shrine Draw (earned, server/ShopService): one open rolls one outcome by weight (percent).
	-- `item` outcomes pick evenly among the pool cosmetics of that tier (common = common and
	-- uncommon items); an owned item pays Shards.Dup instead.
	Shrine = {
		Outcomes = {
			{ key = "coins100", kind = "Coins", amount = 100, weight = 40 },
			{ key = "coins250", kind = "Coins", amount = 250, weight = 12 },
			{ key = "stones1", kind = "Whetstones", amount = 1, weight = 15 },
			{ key = "stones3", kind = "Whetstones", amount = 3, weight = 3 },
			{ key = "gems5", kind = "Gems", amount = 5, weight = 8 },
			{ key = "gems20", kind = "Gems", amount = 20, weight = 2 },
			{ key = "shards10", kind = "Shards", amount = 10, weight = 10 },
			{ key = "common", kind = "item", weight = 6 },
			{ key = "rare", kind = "item", weight = 3 },
			{ key = "epic", kind = "item", weight = 1 },
		},
		MaxPerOpen = 10,
		-- A Draw that came from something bought with Robux (the premium pass track) is a paid
		-- random item: players whose policy restricts those get this fixed reward instead.
		PaidFallback = { Coins = 100, Whetstones = 1, Gems = 5 },
	},

	-- Shrine Capsule (gems; behind EconomyConfig.PaidCapsule and PolicyService). Tier odds in
	-- percent; legendary is the banner's featured item only. Pity: an epic or better at the
	-- latest on draw EpicPity, the featured legendary at the latest on draw LegendaryPity,
	-- counters carried across banners. A banner lasts BannerDays.
	Capsule = {
		Price1 = 100,
		Price10 = 900,
		Tiers = { legendary = 2, epic = 10, rare = 28, common = 60 },
		EpicPity = 10,
		LegendaryPity = 40,
		BannerDays = 14,
		HistoryMax = 100,
	},

	-- Shards: an owned item rolled again pays Dup; any pool item costs Price (by Catalog rarity).
	Shards = {
		Dup = { common = 5, uncommon = 10, rare = 25, epic = 60, legendary = 150 },
		Price = { common = 25, uncommon = 50, rare = 125, epic = 300, legendary = 750 },
	},

	-- Daily shop: CoinSlots + GemSlots a day, a weekly featured set of FeaturedSize gem items at
	-- FeaturedDiscount off (rounded to 50 gems). Every item returns within ReturnWithinDays.
	Shop = { CoinSlots = 2, GemSlots = 2, FeaturedSize = 3, FeaturedDiscount = 0.2, ReturnWithinDays = 56 },

	-- Ranked season end: rewards need at least MinGames rated games in the season.
	Ranked = { MinGames = 5 },
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

EconomyConfig.Shrine = N.Shrine
EconomyConfig.Capsule = N.Capsule
EconomyConfig.Shards = N.Shards :: { Dup: { [string]: number }, Price: { [string]: number } }
EconomyConfig.Shop = N.Shop
EconomyConfig.Ranked = N.Ranked

-- The current season (pass premium and ranked rewards are keyed by it).
EconomyConfig.Season = "S1"

-- When each ranked season ends (epoch, UTC). server/ShopService pays the season-end rewards
-- once per player after this (on next login when offline). Shared/Season's calendar wins
-- when it has the season; this is the fallback. S1 ends 2026-11-30 00:00 UTC.
EconomyConfig.SeasonEnds = { S1 = 1795996800 } :: { [string]: number }

-- The gem Shrine Capsule switch: "studio" = on in Studio only (default), "on" = everywhere,
-- "off" = nowhere. PolicyService's ArePaidRandomItemsRestricted is enforced on top of it.
EconomyConfig.PaidCapsule = "studio" :: "off" | "studio" | "on"

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
