--!strict
-- The shrine and the shop: the daily rotation, the earned Shrine Draw, the gem Shrine Capsule
-- (pity, duplicates to Shards, direct buy, the PolicyService gate), the Shard sink and the
-- ranked season-end rewards. Numbers live in Shared/EconomyConfig (Shrine, Capsule, Shards,
-- Shop, Ranked, SeasonEnds, PaidCapsule); every currency and item change goes through
-- server/Economy, so it's logged to AnalyticsService like the rest of the economy.
--
-- Client requests: Remotes.Shop (RemoteFunction) :InvokeServer(action, arg) -> Result
--   "Draw" count | "Capsule" 1|10 | "BuyShop" id | "BuyFeatured" | "ShardBuy" id |
--   "DirectBuy" id | "Odds" "draw"|"capsule" | "History"
-- Published: ReplicatedStorage ShopRotation, ShrineOdds, ShardPrices, DirectPrices,
-- RankedSeasonEndsAt (JSON / epoch); per player Capsule (JSON, absent when the capsule must
-- not be shown), ShopFeaturedPrice, SeasonPeakTier. Full contract:
-- research_notes/progression/part_D.md.
--
-- Rules kept here:
--   * Odds are published before anything is opened or bought, as percentages totalling 100,
--     with the pity effect stated and each player's pity counters shown.
--   * Server RNG only. Every open is logged (LogCustomEvent "ShrineDraw") and kept in a capped
--     per-player history in the profile (Ext.Shop) with all-time tallies, so odds can be audited.
--   * The capsule is off unless EconomyConfig.PaidCapsule allows it, and hidden and refused
--     for players whose PolicyService says ArePaidRandomItemsRestricted (Monetization's cache;
--     restricted while unknown). Every pool item can also be bought directly and for Shards.
--   * The rotation is a pure function of the UTC day (same on every server), never refreshed
--     for money, and every item comes back within Shop.ReturnWithinDays.
--   * Pools hold only priced, rule-free, on-sale cosmetics: earn-only items (achievements,
--     boss clears, ranked, pass, bundles, VIP) never appear in a draw or the shop.
--
-- Profile (Ext, kept as-is by StatsService):
--   Ext.Shop = { epicSince, legendarySince, history = { HistoryEntry } (newest first),
--                tally = { draw = { [outcome]: n }, capsule = { [tier]: n } },
--                opened = { draw = n, capsule = n }, pityHits = { epic = n, legendary = n } }
--   Ext.Ranked = { season, peak, last, games }      rating seen this ranked season
--   Ext.SeasonRewards = { [season]: { tier, t } }   season-end rewards paid (tier "" = none)

local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Catalog = require(ReplicatedStorage.Shared.Catalog)
local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local Ranks = require(ReplicatedStorage.Shared.Ranks)
local Economy = require(script.Parent.Economy)
local Monetization = require(script.Parent.Monetization)
local StatsService = require(script.Parent.StatsService)

type Item = Catalog.Item
type Data = StatsService.Data

export type Outcome = {
	kind: string, -- "Coins" | "Gems" | "Whetstones" | "Shards" | "item"
	amount: number?,
	id: string?,
	rarity: string,
	tier: string,
	dup: boolean?,
	shards: number?,
	pity: string?,
}
export type Result = { ok: boolean, reason: string?, text: string?, results: { Outcome }?, data: any? }
type OutcomeDef = { key: string, kind: string, amount: number?, weight: number }
type Pity = { epicSince: number, legendarySince: number }
type Pools = { [string]: { Item } } -- tier -> items
type CapsuleSetup = {
	banner: number,
	featured: Item,
	pools: Pools,
	tiers: { [string]: number }, -- tier -> probability (0..1), summing to 1
	effective: { [string]: number },
	odds: { [string]: any },
}

local ShopService = {}

local IS_STUDIO = RunService:IsStudio()
local DAY = 86400
local TIER_ORDER = { "legendary", "epic", "rare", "common" }
local COSMETIC: { [string]: boolean } = {
	bladeSkin = true,
	bladeLine = true,
	finisher = true,
	outfit = true,
	title = true,
	banner = true,
	nameplate = true,
}
local LABEL: { [string]: string } = {
	Coins = "Coins",
	Gems = "Gems",
	Whetstones = "Whetstones",
	Shards = "Shards",
}
local TEXT: { [string]: string } = {
	rate = "Slow down a moment.",
	unknown = "That isn't available.",
	none = "You have no Shrine Draws to open. Win royales and your first duel each day to earn them.",
	funds = "You don't have enough for that.",
	owned = "You already own this.",
	locked = "You haven't unlocked that yet.",
	["not for sale"] = "That isn't for sale.",
	expired = "That offer has rotated out. Here's today's shop.",
	unavailable = "Purchases are off this session because your progress couldn't load. Rejoin to try again.",
	off = "The Shrine Capsule isn't open.",
	restricted = "The Shrine Capsule isn't available in your region. Every item in it can be bought directly or with Shards.",
	closed = "The Shrine Capsule is closed until its next banner.",
}
local BURST = 6
local ANNOUNCE_GAP = 2.5 -- seconds between season-end unlock toasts
local RATE = 2

local rng = Random.new()
local buckets: { [Player]: { tokens: number, at: number } } = {}
local capsuleCache: { key: string, setup: CapsuleSetup? }? = nil
-- Studio test overrides: season end times, the capsule switch.
local seasonEndOverride: { [string]: number } = {}
local capsuleOverride: boolean? = nil

--------------------------------------------------------------------------------------------
-- Small helpers.

local function round(x: number, places: number): number
	local m = 10 ^ places
	return math.floor(x * m + 0.5) / m
end

local function round50(x: number): number
	return math.max(50, math.floor(x / 50 + 0.5) * 50)
end

-- A deterministic string hash (same on every server), for seeding the rotation.
local function hash(s: string): number
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % 2147483647
	end
	return h
end

local function shuffled<T>(list: { T }, seed: number): { T }
	local out = table.clone(list)
	local r = Random.new(seed)
	for i = #out, 2, -1 do
		local j = r:NextInteger(1, i)
		out[i], out[j] = out[j], out[i]
	end
	return out
end

local function allow(player: Player): boolean
	local now = os.clock()
	local bucket = buckets[player]
	if not bucket then
		bucket = { tokens = BURST, at = now }
		buckets[player] = bucket
	end
	bucket.tokens = math.min(BURST, bucket.tokens + (now - bucket.at) * RATE)
	bucket.at = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

local function refuse(reason: string): Result
	return { ok = false, reason = reason, text = TEXT[reason] or TEXT.unknown }
end

local function progressRemote(): RemoteEvent?
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local progress = remotes and remotes:FindFirstChild("Progress")
	return if progress and progress:IsA("RemoteEvent") then progress else nil
end

local function tierOf(rarity: string): string
	return if rarity == "common" or rarity == "uncommon" then "common" else rarity
end

local function ext(d: Data): { [string]: any }
	local shop = d.Ext.Shop
	if typeof(shop) ~= "table" then
		shop = {}
		d.Ext.Shop = shop
	end
	shop.epicSince = tonumber(shop.epicSince) or 0
	shop.legendarySince = tonumber(shop.legendarySince) or 0
	shop.history = if typeof(shop.history) == "table" then shop.history else {}
	shop.tally = if typeof(shop.tally) == "table" then shop.tally else {}
	shop.tally.draw = shop.tally.draw or {}
	shop.tally.capsule = shop.tally.capsule or {}
	shop.opened = if typeof(shop.opened) == "table" then shop.opened else { draw = 0, capsule = 0 }
	shop.pityHits = if typeof(shop.pityHits) == "table" then shop.pityHits else { epic = 0, legendary = 0 }
	return shop
end

--------------------------------------------------------------------------------------------
-- Pools: priced, rule-free, on-sale cosmetics (never defaults, bundles or earn-only items).

local function inPool(item: Item): boolean
	local price = item.price
	return COSMETIC[item.category] == true
		and price ~= nil
		and (price.coins ~= nil or price.gems ~= nil)
		and price.product == nil
		and item.rule == nil
		and not item.default
		and not item.once
		and Catalog.isReady(item)
end

local function poolItems(): { Item }
	local out = {}
	for _, item in Catalog.Items do
		if inPool(item) then
			table.insert(out, item)
		end
	end
	return out
end

local function byTier(items: { Item }): Pools
	local pools: Pools = { common = {}, rare = {}, epic = {}, legendary = {} }
	for _, item in items do
		table.insert(pools[tierOf(item.rarity)], item)
	end
	return pools
end

function ShopService.inPool(id: string): boolean
	local item = Catalog.get(id)
	return item ~= nil and inPool(item)
end

local function dupShards(item: Item): number
	return EconomyConfig.Shards.Dup[item.rarity] or EconomyConfig.Shards.Dup.common
end

local function shardPrice(item: Item): number
	return EconomyConfig.Shards.Price[item.rarity] or EconomyConfig.Shards.Price.common
end

--------------------------------------------------------------------------------------------
-- The earned Shrine Draw: weights over EconomyConfig.Shrine.Outcomes; an item tier with no
-- item on sale is left out and the rest renormalised (the published odds say so).

local function drawTable(): ({ OutcomeDef }, number, Pools)
	local pools = byTier(poolItems())
	local defs: { OutcomeDef } = {}
	local total = 0
	for _, raw in (EconomyConfig.Shrine :: any).Outcomes do
		local def = raw :: OutcomeDef
		if def.kind ~= "item" or #pools[def.key] > 0 then
			table.insert(defs, def)
			total += def.weight
		end
	end
	return defs, total, pools
end

local function currencyLabel(def: OutcomeDef): string
	return `{def.amount} {LABEL[def.kind] or def.kind}`
end

function ShopService.drawOdds(): { [string]: any }
	local defs, total, pools = drawTable()
	local outcomes, tiers = {}, {}
	for _, def in defs do
		local pct = def.weight / total * 100
		table.insert(tiers, { tier = def.key, pct = round(pct, 4) })
		if def.kind == "item" then
			local list = pools[def.key]
			for _, item in list do
				table.insert(outcomes, {
					label = item.name,
					kind = "item",
					id = item.id,
					rarity = item.rarity,
					tier = def.key,
					pct = round(pct / #list, 4),
				})
			end
		else
			table.insert(outcomes, {
				label = currencyLabel(def),
				kind = def.kind,
				amount = def.amount,
				rarity = "common",
				tier = def.key,
				pct = round(pct, 4),
			})
		end
	end
	return { pool = "draw", outcomes = outcomes, tiers = tiers, dupShards = EconomyConfig.Shards.Dup }
end

-- One earned draw: the outcome def and, for an item outcome, the item.
local function rollDraw(defs: { OutcomeDef }, total: number, pools: Pools, r: Random): (OutcomeDef, Item?)
	local x = r:NextNumber() * total
	local pick = defs[#defs]
	for _, def in defs do
		if x < def.weight then
			pick = def
			break
		end
		x -= def.weight
	end
	if pick.kind == "item" then
		local list = pools[pick.key]
		return pick, list[r:NextInteger(1, #list)]
	end
	return pick, nil
end

--------------------------------------------------------------------------------------------
-- The Shrine Capsule: tiers legendary (the banner's featured item only) / epic / rare /
-- common, with pity. A banner lasts Capsule.BannerDays and features the on-sale legendaries
-- in catalogue order, round robin.

local function bannerOf(time: number?): number
	return EconomyConfig.day(time) // EconomyConfig.Capsule.BannerDays
end

local function bannerEndsAt(banner: number): number
	return (banner + 1) * EconomyConfig.Capsule.BannerDays * DAY
end

-- The tier rolled from `state` (mutated: the pity counters after this draw) and which pity
-- forced it, if any.
local function rollTier(state: Pity, tiers: { [string]: number }, r: Random): (string, string?)
	local cfg = EconomyConfig.Capsule
	local tier: string, pity: string? = "common", nil
	if state.legendarySince + 1 >= cfg.LegendaryPity then
		tier, pity = "legendary", "legendary"
	elseif state.epicSince + 1 >= cfg.EpicPity then
		local l, e = tiers.legendary or 0, tiers.epic or 0
		tier = if r:NextNumber() * (l + e) < l then "legendary" else "epic"
		pity = "epic"
	else
		local x = r:NextNumber()
		tier = "common"
		for _, name in TIER_ORDER do
			local p = tiers[name] or 0
			if x < p then
				tier = name
				break
			end
			x -= p
		end
	end
	if tier == "legendary" then
		state.legendarySince, state.epicSince = 0, 0
	elseif tier == "epic" then
		state.legendarySince += 1
		state.epicSince = 0
	else
		state.legendarySince += 1
		state.epicSince += 1
	end
	return tier, pity
end

-- Long-run share of each tier with pity: the stationary distribution of the pity counters
-- (Cesaro-averaged power iteration over every (epicSince, legendarySince) state).
local function effectiveRates(tiers: { [string]: number }): { [string]: number }
	local cfg = EconomyConfig.Capsule
	local E, L = cfg.EpicPity, cfg.LegendaryPity
	local size = E * L
	local dist = table.create(size, 0)
	dist[1] = 1
	local acc = { legendary = 0, epic = 0, rare = 0, common = 0 }
	local warm, steps = 400, 1600
	for step = 1, warm + steps do
		local nextDist = table.create(size, 0)
		for e = 0, E - 1 do
			for l = 0, L - 1 do
				local p = dist[e * L + l + 1]
				if p > 0 then
					local probs: { [string]: number }
					if l + 1 >= L then
						probs = { legendary = 1 }
					elseif e + 1 >= E then
						local s = (tiers.legendary or 0) + (tiers.epic or 0)
						probs = { legendary = (tiers.legendary or 0) / s, epic = (tiers.epic or 0) / s }
					else
						probs = tiers
					end
					for tier, q in probs do
						if q > 0 then
							if step > warm then
								acc[tier] += p * q
							end
							local ne, nl
							if tier == "legendary" then
								ne, nl = 0, 0
							elseif tier == "epic" then
								ne, nl = 0, l + 1
							else
								ne, nl = e + 1, l + 1
							end
							local index = ne * L + nl + 1
							nextDist[index] += p * q
						end
					end
				end
			end
		end
		dist = nextDist
	end
	for tier, v in acc do
		acc[tier] = v / steps
	end
	return acc
end

local function capsuleEnabled(): boolean
	if capsuleOverride ~= nil then
		return capsuleOverride
	end
	local flag = EconomyConfig.PaidCapsule
	return flag == "on" or (flag == "studio" and IS_STUDIO)
end

-- The capsule for the current banner, or nil when it can't open (no featured legendary or no
-- epic on sale). Cached until the banner or what's on sale changes.
local function capsuleSetup(): CapsuleSetup?
	local banner = bannerOf()
	local items = poolItems()
	local ids = {}
	for _, item in items do
		table.insert(ids, item.id)
	end
	local key = `{banner}|{table.concat(ids, ",")}`
	if capsuleCache and capsuleCache.key == key then
		return capsuleCache.setup
	end
	local all = byTier(items)
	local legendaries = all.legendary
	local setup: CapsuleSetup? = nil
	if #legendaries > 0 and #all.epic > 0 and (#all.rare > 0 or #all.common > 0) then
		local featured = legendaries[banner % #legendaries + 1]
		local pools: Pools = { legendary = { featured }, epic = all.epic, rare = all.rare, common = all.common }
		local cfg = EconomyConfig.Capsule
		local total = 0
		for _, tier in TIER_ORDER do
			if #pools[tier] > 0 then
				total += cfg.Tiers[tier] or 0
			end
		end
		local tiers = {}
		for _, tier in TIER_ORDER do
			tiers[tier] = if #pools[tier] > 0 then (cfg.Tiers[tier] or 0) / total else 0
		end
		local effective = effectiveRates(tiers)
		local outcomes, tierRows, ev = {}, {}, {}
		for _, tier in TIER_ORDER do
			local list = pools[tier]
			if #list > 0 then
				table.insert(
					tierRows,
					{ tier = tier, pct = round(tiers[tier] * 100, 4), effective = round(effective[tier] * 100, 4) }
				)
				for _, item in list do
					table.insert(outcomes, {
						label = item.name,
						kind = "item",
						id = item.id,
						rarity = item.rarity,
						tier = tier,
						pct = round(tiers[tier] * 100 / #list, 4),
					})
					ev[item.id] = math.floor(cfg.Price1 / (effective[tier] / #list) + 0.5)
				end
			end
		end
		setup = {
			banner = banner,
			featured = featured,
			pools = pools,
			tiers = tiers,
			effective = effective,
			odds = {
				pool = "capsule",
				outcomes = outcomes,
				tiers = tierRows,
				dupShards = EconomyConfig.Shards.Dup,
				pity = {
					epicAt = cfg.EpicPity,
					legendaryAt = cfg.LegendaryPity,
					text = `An epic or better is guaranteed by draw {cfg.EpicPity} if none came sooner, and the featured {featured.name} by draw {cfg.LegendaryPity}. Counters carry over between banners. The base odds above apply to every other draw.`,
				},
				featured = featured.id,
				ev = ev,
			},
		}
	end
	capsuleCache = { key = key, setup = setup }
	return setup
end

-- Whether `player` may see the capsule now, and why not.
local function capsuleState(player: Player): (CapsuleSetup?, string?)
	if not capsuleEnabled() then
		return nil, "off"
	end
	if Monetization.paidRandomRestricted(player) then
		return nil, "restricted"
	end
	local setup = capsuleSetup()
	if not setup then
		return nil, "closed"
	end
	return setup, nil
end

--------------------------------------------------------------------------------------------
-- Granting outcomes (no yields: an open is atomic).

local function record(d: Data, pool: string, entry: { [string]: any })
	local shop = ext(d)
	entry.t = os.time()
	entry.pool = pool
	table.insert(shop.history, 1, entry)
	local max = EconomyConfig.Capsule.HistoryMax
	while #shop.history > max do
		table.remove(shop.history)
	end
end

local function logDraw(player: Player, pool: string, outcome: Outcome)
	local what = if outcome.id then outcome.id else `{outcome.amount} {outcome.kind}`
	local note =
		`{outcome.tier}{if outcome.dup then " dup" else ""}{if outcome.pity then ` pity:{outcome.pity}` else ""}`
	pcall(function()
		AnalyticsService:LogCustomEvent(player, "ShrineDraw", 1, {
			[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = pool,
			[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = what,
			[Enum.AnalyticsCustomFieldKeys.CustomField03.Name] = note,
		})
	end)
end

-- Owns `item`, or pays its duplicate Shards when it's already owned.
local function giveItem(player: Player, d: Data, item: Item, source: string, kind: Economy.Kind): (boolean, number?)
	if d.Inventory[item.id] ~= nil then
		local n = dupShards(item)
		Economy.grant(player, "Shards", n, `Duplicate {item.id}`, kind, true)
		return true, n
	end
	Economy.own(player, item.id, source, true)
	return false, nil
end

local function openDraws(player: Player, count: number): Result
	local d = StatsService.get(player)
	if not d then
		return refuse("unavailable")
	end
	if not StatsService.canTransact(player) then
		return refuse("unavailable")
	end
	local n = math.clamp(math.floor(count), 1, EconomyConfig.Shrine.MaxPerOpen)
	if d.Draws < 1 then
		return refuse("none")
	end
	n = math.min(n, d.Draws)
	if not Economy.spend(player, "Draws", n, "Shrine Draw", "shrine.draw") then
		return refuse("none")
	end
	local defs, total, pools = drawTable()
	local shop = ext(d)
	local results: { Outcome } = {}
	for _ = 1, n do
		local def, item = rollDraw(defs, total, pools, rng)
		local outcome: Outcome
		if item then
			local dup, shards = giveItem(player, d, item, "shrine", "Gameplay")
			outcome = { kind = "item", id = item.id, rarity = item.rarity, tier = def.key, dup = dup, shards = shards }
		else
			Economy.grant(player, def.kind :: Economy.Currency, def.amount or 0, "Shrine Draw", "Gameplay", true)
			outcome = { kind = def.kind, amount = def.amount, rarity = "common", tier = def.key }
		end
		table.insert(results, outcome)
		shop.tally.draw[def.key] = (shop.tally.draw[def.key] or 0) + 1
		shop.opened.draw = (shop.opened.draw or 0) + 1
		record(d, "draw", {
			kind = outcome.kind,
			id = outcome.id,
			amount = outcome.amount,
			tier = outcome.tier,
			dup = outcome.dup,
			shards = outcome.shards,
		})
		logDraw(player, "draw", outcome)
	end
	StatsService.commit(player)
	return { ok = true, results = results }
end

local function openCapsule(player: Player, count: number): Result
	local d = StatsService.get(player)
	if not d then
		return refuse("unavailable")
	end
	local setup, why = capsuleState(player)
	if not setup then
		return refuse(why or "closed")
	end
	local cfg = EconomyConfig.Capsule
	local price = if count == 10 then cfg.Price10 elseif count == 1 then cfg.Price1 else nil
	if not price then
		return refuse("unknown")
	end
	if not StatsService.canTransact(player) then
		return refuse("unavailable")
	end
	if d.Gems < price then
		return refuse("funds")
	end
	if not Economy.spend(player, "Gems", price, `Shrine Capsule x{count}`, `capsule.x{count}`) then
		return refuse("funds")
	end
	local shop = ext(d)
	local state: Pity = { epicSince = shop.epicSince, legendarySince = shop.legendarySince }
	local results: { Outcome } = {}
	for _ = 1, count do
		local tier, pity = rollTier(state, setup.tiers, rng)
		local list = setup.pools[tier]
		local item = list[rng:NextInteger(1, #list)]
		local dup, shards = giveItem(player, d, item, "capsule", "Shop")
		local outcome: Outcome = {
			kind = "item",
			id = item.id,
			rarity = item.rarity,
			tier = tier,
			dup = dup,
			shards = shards,
			pity = pity,
		}
		table.insert(results, outcome)
		shop.tally.capsule[tier] = (shop.tally.capsule[tier] or 0) + 1
		shop.opened.capsule = (shop.opened.capsule or 0) + 1
		if pity then
			shop.pityHits[pity] = (shop.pityHits[pity] or 0) + 1
		end
		record(d, "capsule", {
			kind = "item",
			id = item.id,
			tier = tier,
			dup = dup,
			shards = shards,
			pity = pity,
			banner = setup.banner,
		})
		logDraw(player, "capsule", outcome)
	end
	shop.epicSince, shop.legendarySince = state.epicSince, state.legendarySince
	StatsService.commit(player)
	return { ok = true, results = results }
end

--------------------------------------------------------------------------------------------
-- The daily shop. Each list (coin items, gem items) is split once into a first and a second
-- half (seeded by the list name); every cycle shows the first half's items in a fresh order,
-- then the second half's, a few slots a day. Every item shows once per cycle and returns
-- within two cycles, a cycle never ends on what the next one starts with, and the result is
-- a pure function of the day (the same on every server).

local function slotsFor(list: { Item }, perDay: number, period: number, salt: string): { string }
	local n = #list
	if n == 0 or perDay <= 0 then
		return {}
	end
	local per = math.min(perDay, n)
	local cycle = math.ceil(n / per)
	local k = period // cycle
	local halves = shuffled(list, hash(salt))
	local split = math.ceil(n / 2)
	local first = shuffled(table.move(halves, 1, split, 1, {}), hash(`{salt}:{k}:a`))
	local second = shuffled(table.move(halves, split + 1, n, 1, {}), hash(`{salt}:{k}:b`))
	local perm = table.move(second, 1, #second, #first + 1, first)
	local pos = period % cycle
	local out = {}
	for i = 1, per do
		local index = pos * per + i
		-- The last day of an uneven cycle tops up from the middle of the cycle (shown about
		-- half a cycle ago), never from the first half, which the next cycle opens with.
		table.insert(out, perm[if index <= n then index else math.min(split + index - n, n)].id)
	end
	return out
end

-- Longest gap (in periods) before an item returns: two cycles.
local function maxReturn(n: number, perDay: number): number
	if n == 0 or perDay <= 0 then
		return 0
	end
	return 2 * math.ceil(n / math.min(perDay, n)) - 1
end

local function shopLists(): ({ Item }, { Item })
	local coinItems, gemItems = {}, {}
	for _, item in poolItems() do
		local price = item.price :: Catalog.Price
		if price.coins then
			table.insert(coinItems, item)
		elseif price.gems then
			table.insert(gemItems, item)
		end
	end
	return coinItems, gemItems
end

local function weekOf(day: number): number
	return (day + 3) // 7 -- weeks start on Monday (UTC day 0 was a Thursday)
end

local function featuredFull(ids: { string }): number
	local sum = 0
	for _, id in ids do
		local item = Catalog.get(id)
		local price = item and item.price
		sum += (price and price.gems) or 0
	end
	return sum
end

-- The rotation for UTC `day` (pure: the same on every server).
function ShopService.rotation(day: number?): { [string]: any }
	local today = day or EconomyConfig.day()
	local cfg = EconomyConfig.Shop
	local coinItems, gemItems = shopLists()
	local week = weekOf(today)
	local featured = slotsFor(gemItems, cfg.FeaturedSize, week, "featured")
	local full = featuredFull(featured)
	return {
		day = today,
		endsAt = (today + 1) * DAY,
		coin = slotsFor(coinItems, cfg.CoinSlots, today, "coin"),
		gem = slotsFor(gemItems, cfg.GemSlots, today, "gem"),
		featured = {
			week = week,
			endsAt = ((week + 1) * 7 - 3) * DAY,
			items = featured,
			full = full,
			price = if full > 0 then round50(full * (1 - cfg.FeaturedDiscount)) else 0,
			discount = cfg.FeaturedDiscount,
		},
	}
end

-- What `player` pays for the featured set now: the unowned items at the set discount.
local function featuredFor(d: Data, rotation: { [string]: any }): ({ string }, number)
	local unowned = {}
	for _, id in rotation.featured.items do
		if d.Inventory[id] == nil then
			table.insert(unowned, id)
		end
	end
	if #unowned == 0 then
		return unowned, 0
	end
	return unowned, round50(featuredFull(unowned) * (1 - EconomyConfig.Shop.FeaturedDiscount))
end

local function buyShop(player: Player, id: string): Result
	local rotation = ShopService.rotation()
	local currency: Economy.Currency? = nil
	if table.find(rotation.coin, id) then
		currency = "Coins"
	elseif table.find(rotation.gem, id) then
		currency = "Gems"
	end
	if not currency then
		return refuse("expired")
	end
	local ok, why = Economy.buy(player, id, currency)
	if not ok then
		return refuse(why or "unknown")
	end
	return { ok = true }
end

local function buyFeatured(player: Player): Result
	local d = StatsService.get(player)
	if not d then
		return refuse("unavailable")
	end
	local rotation = ShopService.rotation()
	local unowned, price = featuredFor(d, rotation)
	if #unowned == 0 then
		return refuse("owned")
	end
	if not StatsService.canTransact(player) then
		return refuse("unavailable")
	end
	if d.Gems < price then
		return refuse("funds")
	end
	if not Economy.spend(player, "Gems", price, `Featured set week {rotation.featured.week}`, "shop.featured") then
		return refuse("funds")
	end
	for _, id in unowned do
		Economy.own(player, id, "gems", true)
	end
	StatsService.commit(player)
	return { ok = true, data = unowned }
end

local function shardBuy(player: Player, id: string): Result
	local d = StatsService.get(player)
	local item = Catalog.get(id)
	if not d or not item or not inPool(item) then
		return refuse("unknown")
	end
	if d.Inventory[id] ~= nil then
		return refuse("owned")
	end
	if not StatsService.canTransact(player) then
		return refuse("unavailable")
	end
	local price = shardPrice(item)
	if d.Shards < price then
		return refuse("funds")
	end
	if not Economy.spend(player, "Shards", price, `Shards {id}`, id) then
		return refuse("funds")
	end
	Economy.own(player, id, "shards", true)
	StatsService.commit(player)
	return { ok = true }
end

local function directBuy(player: Player, id: string): Result
	local item = Catalog.get(id)
	if not item or not inPool(item) then
		return refuse("unknown")
	end
	local ok, why = Economy.buy(player, id)
	if not ok then
		return refuse(why or "unknown")
	end
	return { ok = true }
end

--------------------------------------------------------------------------------------------
-- Ranked season end: rewards by the best tier reached in the season (peak, or final when
-- higher), once per season per player; offline players are paid on their next login.

local seasonModule: any = nil
do
	local found = ReplicatedStorage.Shared:FindFirstChild("Season")
	if found and found:IsA("ModuleScript") then
		local ok, result = pcall(require, found)
		if ok and typeof(result) == "table" then
			seasonModule = result
		end
	end
end

local function seasonNow(): number
	if seasonModule and typeof(seasonModule.now) == "function" then
		local ok, t = pcall(seasonModule.now)
		if ok and typeof(t) == "number" then
			return t
		end
	end
	return os.time()
end

-- Season id -> end epoch: Shared/Season's calendar, else EconomyConfig.SeasonEnds.
local function seasonEnds(): { [string]: number }
	local ends: { [string]: number } = table.clone(EconomyConfig.SeasonEnds)
	if seasonModule and typeof(seasonModule.List) == "table" then
		for _, def in seasonModule.List do
			if typeof(def) == "table" and typeof(def.id) == "string" and typeof(def.ends) == "number" then
				ends[def.id] = def.ends
			end
		end
	end
	for id, t in seasonEndOverride do
		ends[id] = t
	end
	return ends
end

-- The ranked season being played now (ratings count toward it), and when it ends.
local function liveSeason(now: number): (string?, number)
	local ends = seasonEnds()
	local listed: { [string]: boolean } = {}
	if seasonModule and typeof(seasonModule.List) == "table" then
		for _, def in seasonModule.List do
			if typeof(def) == "table" and typeof(def.id) == "string" and typeof(def.starts) == "number" then
				listed[def.id] = true
				local endsAt = ends[def.id]
				if now >= def.starts and endsAt and now < endsAt then
					return def.id, endsAt
				end
			end
		end
	end
	-- A season only EconomyConfig knows (no start date): live until it ends.
	local current = EconomyConfig.Season
	local endsAt = ends[current]
	if not listed[current] and endsAt and now < endsAt then
		return current, endsAt
	end
	return nil, 0
end

local function rewardsFor(season: string, tier: string): { string }
	local ids = {}
	for _, category in { "title", "banner", "nameplate" } :: { Catalog.Category } do
		local id = Catalog.idOf(category, `{season}{tier}`)
		if Catalog.get(id) then
			table.insert(ids, id)
		end
	end
	return ids
end

local function seasonTier(r: { [string]: any }?): string?
	if not r or (tonumber(r.games) or 0) < EconomyConfig.Ranked.MinGames then
		return nil
	end
	return Ranks.of(math.max(tonumber(r.peak) or 0, tonumber(r.last) or 0)).tier
end

-- Pays every ended season this player hasn't been paid for. Mutates the profile quietly and
-- returns what was granted (the caller commits and tells the player).
local function payEndedSeasons(player: Player, d: Data, now: number): { { [string]: any } }
	local paid = {}
	local done = d.Ext.SeasonRewards
	if typeof(done) ~= "table" then
		done = {}
		d.Ext.SeasonRewards = done
	end
	local ranked = d.Ext.Ranked
	for season, endsAt in seasonEnds() do
		if now >= endsAt and done[season] == nil then
			local r = if typeof(ranked) == "table" and ranked.season == season then ranked else nil
			local tier = seasonTier(r)
			done[season] = { tier = tier or "", t = os.time() }
			if tier then
				local items = rewardsFor(season, tier)
				for _, id in items do
					Economy.own(player, id, "ranked", true)
				end
				local gems = EconomyConfig.SeasonEndGems[tier] or 0
				if gems > 0 then
					Economy.grant(player, "Gems", gems, `Ranked {season} {tier}`, "TimedReward", true)
				end
				table.insert(paid, { season = season, tier = tier, items = items, gems = gems })
				pcall(function()
					AnalyticsService:LogCustomEvent(player, "RankedSeasonReward", 1, {
						[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = season,
						[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = tier,
					})
				end)
			end
		end
	end
	return paid
end

local function announce(player: Player, paid: { { [string]: any } })
	local remote = progressRemote()
	if not remote then
		return
	end
	-- One unlock toast at a time (they share a slot on screen); runs in its own thread.
	for _, reward in paid do
		remote:FireClient(player, "Notice", {
			text = `Season {reward.season} is over: you finished {reward.tier}. {reward.gems} gems and your season rewards are in your locker.`,
		})
		for _, id in reward.items do
			local item = Catalog.get(id)
			if item and player.Parent then
				remote:FireClient(player, "Unlock", { id = id, name = item.name, category = item.category })
				task.wait(ANNOUNCE_GAP)
			end
		end
	end
end

-- Tracks this season's rating and pays ended seasons. Runs inside every profile publish.
local function trackRanked(player: Player, d: Data)
	if not StatsService.isLoaded(player) then
		player:SetAttribute("SeasonPeakTier", "")
		return
	end
	local now = seasonNow()
	local paid = payEndedSeasons(player, d, now)
	local season = liveSeason(now)
	local r = d.Ext.Ranked
	if season then
		if typeof(r) ~= "table" or r.season ~= season then
			r = { season = season, peak = d.Rating, last = d.Rating, games = 0 }
			d.Ext.Ranked = r
		elseif d.Rating ~= r.last then
			r.games = (tonumber(r.games) or 0) + 1
			r.last = d.Rating
			r.peak = math.max(tonumber(r.peak) or 0, d.Rating)
		end
	end
	local tier = if season and typeof(r) == "table" and r.season == season then seasonTier(r) else nil
	player:SetAttribute("SeasonPeakTier", tier or "")
	if #paid > 0 then
		task.defer(function()
			if player.Parent then
				StatsService.commit(player)
				announce(player, paid)
			end
		end)
	end
end

--------------------------------------------------------------------------------------------
-- Publishing.

local function publishPlayer(player: Player, d: Data)
	local setup = capsuleState(player)
	if setup then
		local shop = ext(d)
		local cfg = EconomyConfig.Capsule
		player:SetAttribute(
			"Capsule",
			HttpService:JSONEncode({
				price1 = cfg.Price1,
				price10 = cfg.Price10,
				featured = setup.featured.id,
				banner = setup.banner,
				bannerEndsAt = bannerEndsAt(setup.banner),
				epicSince = shop.epicSince,
				legendarySince = shop.legendarySince,
				epicAt = cfg.EpicPity,
				legendaryAt = cfg.LegendaryPity,
				odds = setup.odds,
			})
		)
	else
		player:SetAttribute("Capsule", nil)
	end
	local _, price = featuredFor(d, ShopService.rotation())
	player:SetAttribute("ShopFeaturedPrice", price)
	trackRanked(player, d)
end

local published = ""

local function publishGlobal(force: boolean?)
	local items = poolItems()
	local shardPrices, directPrices = {}, {}
	local ids = {}
	for _, item in items do
		shardPrices[item.id] = shardPrice(item)
		local price = item.price :: Catalog.Price
		directPrices[item.id] = if price.gems then { gems = price.gems } else { coins = price.coins }
		table.insert(ids, item.id)
	end
	local _, endsAt = liveSeason(seasonNow())
	local key = `{EconomyConfig.day()}|{table.concat(ids, ",")}|{endsAt}`
	if key == published and not force then
		return false
	end
	published = key
	ReplicatedStorage:SetAttribute("ShopRotation", HttpService:JSONEncode(ShopService.rotation()))
	ReplicatedStorage:SetAttribute("ShrineOdds", HttpService:JSONEncode(ShopService.drawOdds()))
	ReplicatedStorage:SetAttribute("ShardPrices", HttpService:JSONEncode(shardPrices))
	ReplicatedStorage:SetAttribute("DirectPrices", HttpService:JSONEncode(directPrices))
	ReplicatedStorage:SetAttribute("RankedSeasonEndsAt", endsAt)
	return true
end

local function republishAll()
	publishGlobal(true)
	for _, player in Players:GetPlayers() do
		if StatsService.get(player) then
			StatsService.commit(player)
		end
	end
end

--------------------------------------------------------------------------------------------
-- Requests.

function ShopService.handle(player: Player, action: unknown, arg: unknown): Result
	if typeof(action) ~= "string" then
		return refuse("unknown")
	end
	if not allow(player) then
		return refuse("rate")
	end
	local id = if typeof(arg) == "string" and #arg <= 64 then arg else nil
	if action == "Draw" then
		return openDraws(player, if typeof(arg) == "number" and arg == arg then arg else 1)
	elseif action == "Capsule" then
		return openCapsule(player, if arg == 10 then 10 elseif arg == 1 or arg == nil then 1 else 0)
	elseif action == "BuyShop" and id then
		return buyShop(player, id)
	elseif action == "BuyFeatured" then
		return buyFeatured(player)
	elseif action == "ShardBuy" and id then
		return shardBuy(player, id)
	elseif action == "DirectBuy" and id then
		return directBuy(player, id)
	elseif action == "Odds" then
		if arg == "capsule" then
			local setup, why = capsuleState(player)
			if not setup then
				return refuse(why or "closed")
			end
			return { ok = true, data = setup.odds }
		end
		return { ok = true, data = ShopService.drawOdds() }
	elseif action == "History" then
		local d = StatsService.get(player)
		return { ok = true, data = if d then ext(d).history else {} }
	end
	return refuse("unknown")
end

--------------------------------------------------------------------------------------------
-- Studio test hooks (ServerStorage.ShopTest, a BindableFunction). Never created live.
--   simulate(pool, n, seed?)   n draws on the real roll functions with a fresh RNG: observed
--                              vs published rates, pity gaps (no profile touched)
--   invoke(action, arg)        ShopService.handle for the first player (rate limit bypassed)
--   policy(restricted)         stub PolicyService for the first player
--   capsule(on | nil)          override the PaidCapsule switch (nil = config)
--   ready(category, on)        flip Catalog.Ready for a category on the server, then republish
--   seasonEnd(season, epoch?)  pretend `season` ends at `epoch` (default now; false clears)
--   rotation(fromDay, days)    the rotation for a range of days + the longest return gap
--   state()                    the first player's Ext.Shop / Ext.Ranked / Ext.SeasonRewards
--   grantDraws(n, paid)        ShopService.grantDraws for the first player
--   republish()

local function simulate(pool: string, n: number, seed: number?): { [string]: any }
	local r = Random.new(seed or os.clock() * 1e6)
	local counts: { [string]: number } = {}
	local out: { [string]: any } = { pool = pool, n = n }
	if pool == "capsule" then
		local setup = capsuleSetup()
		if not setup then
			return { error = "capsule closed" }
		end
		local state: Pity = { epicSince = 0, legendarySince = 0 }
		local sinceEpic, sinceLegend, maxEpic, maxLegend = 0, 0, 0, 0
		local pityHits = { epic = 0, legendary = 0 }
		for _ = 1, n do
			local tier, pity = rollTier(state, setup.tiers, r)
			counts[tier] = (counts[tier] or 0) + 1
			if pity then
				pityHits[pity] += 1
			end
			sinceEpic += 1
			sinceLegend += 1
			if tier == "epic" or tier == "legendary" then
				maxEpic = math.max(maxEpic, sinceEpic)
				sinceEpic = 0
			end
			if tier == "legendary" then
				maxLegend = math.max(maxLegend, sinceLegend)
				sinceLegend = 0
			end
		end
		local rows = {}
		for _, tier in TIER_ORDER do
			local observed = (counts[tier] or 0) / n * 100
			table.insert(rows, {
				tier = tier,
				base = round(setup.tiers[tier] * 100, 3),
				effective = round(setup.effective[tier] * 100, 3),
				observed = round(observed, 3),
			})
		end
		out.tiers = rows
		out.maxEpicGap = maxEpic
		out.maxLegendaryGap = maxLegend
		out.pityHits = pityHits
		out.featured = setup.featured.id
	else
		local defs, total, pools = drawTable()
		local items: { [string]: number } = {}
		for _ = 1, n do
			local def, item = rollDraw(defs, total, pools, r)
			counts[def.key] = (counts[def.key] or 0) + 1
			if item then
				items[item.id] = (items[item.id] or 0) + 1
			end
		end
		local rows = {}
		for _, def in defs do
			table.insert(rows, {
				outcome = def.key,
				published = round(def.weight / total * 100, 3),
				observed = round((counts[def.key] or 0) / n * 100, 3),
			})
		end
		out.outcomes = rows
		out.items = items
	end
	return out
end

local function testHooks()
	local hook = Instance.new("BindableFunction")
	hook.Name = "ShopTest"
	hook.OnInvoke = function(command: string, ...: any): any
		local args = { ... }
		local player = Players:GetPlayers()[1]
		if command == "simulate" then
			return HttpService:JSONEncode(simulate(args[1] or "draw", args[2] or 10000, args[3]))
		elseif command == "invoke" then
			assert(player, "no player")
			buckets[player] = nil
			return HttpService:JSONEncode(ShopService.handle(player, args[1], args[2]))
		elseif command == "policy" then
			assert(player, "no player")
			Monetization.mockPolicy(player, args[1] == true)
			return player:GetAttribute("PaidRandomRestricted")
		elseif command == "capsule" then
			capsuleOverride = args[1]
			capsuleCache = nil
			republishAll()
			return capsuleEnabled()
		elseif command == "ready" then
			(Catalog.Ready :: any)[args[1]] = args[2] == true
			capsuleCache = nil
			republishAll()
			return #poolItems()
		elseif command == "seasonEnd" then
			seasonEndOverride[args[1]] = if args[2] == false then nil else (args[2] or seasonNow())
			republishAll()
			return HttpService:JSONEncode(seasonEnds())
		elseif command == "rotation" then
			local from, days = args[1] or EconomyConfig.day(), args[2] or 60
			local seen: { [string]: number } = {}
			local gaps: { [string]: number } = {}
			local nextDay = 0
			local list = {}
			for day = from, from + days - 1 do
				local rot = ShopService.rotation(day)
				table.insert(list, { day = day, coin = rot.coin, gem = rot.gem, featured = rot.featured.items })
				local shown = table.clone(rot.coin)
				for _, id in rot.gem do
					table.insert(shown, id)
				end
				for _, id in shown do
					if seen[id] then
						gaps[id] = math.max(gaps[id] or 0, day - seen[id])
						if day - seen[id] <= 1 then
							nextDay += 1
						end
					end
					seen[id] = day
				end
			end
			local worst = 0
			for _, gap in gaps do
				worst = math.max(worst, gap)
			end
			local coinItems, gemItems = shopLists()
			return HttpService:JSONEncode({
				days = list,
				worstGap = worst,
				repeatsNextDay = nextDay,
				coinItems = #coinItems,
				gemItems = #gemItems,
				bound = math.max(
					maxReturn(#coinItems, EconomyConfig.Shop.CoinSlots),
					maxReturn(#gemItems, EconomyConfig.Shop.GemSlots)
				),
			})
		elseif command == "state" then
			assert(player, "no player")
			local d = StatsService.get(player)
			if not d then
				return nil
			end
			return HttpService:JSONEncode({
				shop = ext(d),
				ranked = d.Ext.Ranked,
				seasonRewards = d.Ext.SeasonRewards,
				wallet = {
					Gems = d.Gems,
					Coins = d.Coins,
					Shards = d.Shards,
					Draws = d.Draws,
					Whetstones = d.Whetstones,
				},
				rating = d.Rating,
			})
		elseif command == "grantDraws" then
			assert(player, "no player")
			local granted = ShopService.grantDraws(player, args[1] or 1, "ShopTest", args[2] == true)
			return HttpService:JSONEncode({
				granted = granted,
				Draws = player:GetAttribute("Draws"),
				Coins = player:GetAttribute("Coins"),
				Gems = player:GetAttribute("Gems"),
				Whetstones = player:GetAttribute("Whetstones"),
			})
		elseif command == "republish" then
			republishAll()
			return true
		end
		error(`[ShopTest] unknown command {command}`)
	end
	hook.Parent = ServerStorage
end

--------------------------------------------------------------------------------------------
-- Grants for other parts.

-- Adds Shrine Draws. `paid` = they came from something bought with Robux (the premium pass
-- track): a player whose policy restricts paid random items gets Shrine.PaidFallback instead.
-- Returns whether Draws were granted (false = the fallback was paid). `quiet` skips the
-- republish, like Economy.grant's, for callers that commit once after several grants.
function ShopService.grantDraws(
	player: Player,
	amount: number,
	reason: string,
	paid: boolean?,
	quiet: boolean?
): boolean
	if paid and Monetization.paidRandomRestricted(player) then
		local fallback = EconomyConfig.Shrine.PaidFallback
		for currency, n in fallback :: { [string]: number } do
			Economy.grant(player, currency :: Economy.Currency, n * amount, `{reason} (fixed)`, "Gameplay", true)
		end
		if not quiet then
			StatsService.commit(player)
		end
		return false
	end
	Economy.grant(player, "Draws", amount, reason, "Gameplay", quiet)
	return true
end

function ShopService.start()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local remote = Instance.new("RemoteFunction")
	remote.Name = "Shop"
	remote.OnServerInvoke = function(player: Player, action: unknown, arg: unknown): Result
		local ok, result = pcall(ShopService.handle, player, action, arg)
		if not ok then
			warn(`[ShopService] {action}: {result}`)
			return refuse("unknown")
		end
		return result
	end
	remote.Parent = remotes

	-- Every pool can be bought outright for no more than drawing it would cost on average.
	local setup = capsuleSetup()
	if setup then
		for id, ev in setup.odds.ev do
			local item = Catalog.get(id) :: Item
			local gems = item.price and item.price.gems
			if gems and gems > ev then
				warn(`[ShopService] {id} costs {gems} gems, more than its capsule expected value {ev}`)
			end
		end
	end
	local coinItems, gemItems = shopLists()
	local cfg = EconomyConfig.Shop
	local worst = math.max(
		maxReturn(#coinItems, cfg.CoinSlots),
		maxReturn(#gemItems, cfg.GemSlots),
		maxReturn(#gemItems, cfg.FeaturedSize) * 7
	)
	if worst > cfg.ReturnWithinDays then
		warn(`[ShopService] shop items could take {worst} days to return (limit {cfg.ReturnWithinDays}): add slots`)
	end

	StatsService.onPublish(publishPlayer)
	Players.PlayerAdded:Connect(function(player)
		player:GetAttributeChangedSignal("PaidRandomRestricted"):Connect(function()
			if StatsService.get(player) then
				StatsService.commit(player)
			end
		end)
	end)
	for _, player in Players:GetPlayers() do
		player:GetAttributeChangedSignal("PaidRandomRestricted"):Connect(function()
			if StatsService.get(player) then
				StatsService.commit(player)
			end
		end)
	end
	Players.PlayerRemoving:Connect(function(player)
		buckets[player] = nil
	end)
	publishGlobal(true)
	-- Day, week and banner rollovers and season ends: republish when anything changes.
	task.spawn(function()
		local lastBanner = bannerOf()
		while true do
			task.wait(15)
			local banner = bannerOf()
			local changed = publishGlobal(false) or banner ~= lastBanner
			lastBanner = banner
			local now = seasonNow()
			for _, player in Players:GetPlayers() do
				local d = StatsService.get(player)
				if d and StatsService.isLoaded(player) then
					local due = false
					local done = d.Ext.SeasonRewards
					for season, endsAt in seasonEnds() do
						if now >= endsAt and (typeof(done) ~= "table" or done[season] == nil) then
							due = true
						end
					end
					if changed or due then
						StatsService.commit(player)
					end
				end
			end
		end
	end)
	if IS_STUDIO then
		testHooks()
	end
	for _, player in Players:GetPlayers() do
		if StatsService.get(player) then
			StatsService.commit(player)
		end
	end
end

return ShopService
