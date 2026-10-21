--!strict
-- The server's economy API: the wallet, the inventory and the loadout, with every rule
-- checked here and every change logged to AnalyticsService:LogEconomyEvent. Other services
-- (ProgressService, LobbyService, Monetization, and later the pass / store / cosmetics parts)
-- call this instead of touching the profile's currencies or inventory directly.
--
--   Economy.grant(player, currency, amount, reason, kind?) -> boolean
--   Economy.spend(player, currency, amount, reason, sku?)  -> boolean
--   Economy.balance(player, currency)                      -> number
--   Economy.own(player, itemId, source)                    -> boolean   (adds to the inventory)
--   Economy.owns(player, itemId)                           -> boolean
--   Economy.buy(player, itemId, currency?)                 -> (boolean, string?)
--   Economy.equip(player, slot, itemId)                    -> boolean
--   Economy.equipped(player, slot)                         -> string   (an item id, "" = none)
--   Economy.unlocked(player, itemId)                       -> (boolean, have, need)
--   Economy.upgradeLine(player, lineId, gemWhetstones?)    -> (boolean, string?)
--   Economy.canTransact(player)                            -> boolean
--
-- Currencies: Coins, Gems, Whetstones (earn-only), Shards, PassXP (season hook), Draws
-- (Shrine Draw tokens). Spending is refused for a session whose profile didn't load.
--
-- Published per player (attributes; see StatsService for the profile fields):
--   UnlockProgress  JSON { [itemId] = { have, need } } for every ruled item not yet owned
--   InitiateEndsAt  epoch the Initiate's Bundle offer ends, 0 when it's not on offer
--   CanTransact     false when purchases are blocked this session
--   DailyNext / DailyClaimed  the streak day the Claim button pays / whether today is done
--   Trials          today's trial ids (comma separated)
-- And on ReplicatedStorage: ServerDay (UTC day number) and DayEndsAt (epoch), so the client
-- never computes days from its own clock.

local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Bosses = require(ReplicatedStorage.Shared.Bosses)
local Catalog = require(ReplicatedStorage.Shared.Catalog)
local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local Progression = require(ReplicatedStorage.Shared.Progression)
local StatsService = require(script.Parent.StatsService)

type Data = StatsService.Data
type Item = Catalog.Item
type Rule = Catalog.Rule

export type Currency = "Coins" | "Gems" | "Whetstones" | "Shards" | "PassXP" | "Draws"
-- Analytics transaction types (Enum.AnalyticsEconomyTransactionType names).
export type Kind = "Gameplay" | "TimedReward" | "Onboarding" | "IAP" | "Shop" | "ContextualPurchase"

local CURRENCIES: { [string]: boolean } = {
	Coins = true,
	Gems = true,
	Whetstones = true,
	Shards = true,
	PassXP = true,
	Draws = true,
}
-- PassXP is progression, not money: it isn't logged as an economy event.
local LOGGED: { [string]: boolean } = { Coins = true, Gems = true, Whetstones = true, Shards = true, Draws = true }
local FLUSH_INTERVAL = 60
local SECONDS_PER_DAY = 86400

local Economy = {}

-- Gameplay sources (kills, deflect-free coins, level-ups...) are frequent: they're summed per
-- player and currency and logged once a minute (and on leave) instead of one event each.
local pending: { [Player]: { [string]: number } } = {}

local function analytics(
	player: Player,
	flow: Enum.AnalyticsEconomyFlowType,
	currency: string,
	amount: number,
	balance: number,
	kind: string,
	sku: string?,
	reason: string?
)
	if not LOGGED[currency] or amount <= 0 then
		return
	end
	pcall(function()
		AnalyticsService:LogEconomyEvent(
			player,
			flow,
			currency,
			amount,
			balance,
			kind,
			sku,
			if reason then { [Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = reason } else nil
		)
	end)
end

local function flush(player: Player)
	local sums = pending[player]
	local d = StatsService.get(player)
	pending[player] = nil
	if not sums or not d then
		return
	end
	for currency, amount in sums do
		analytics(
			player,
			Enum.AnalyticsEconomyFlowType.Source,
			currency,
			amount,
			(d :: any)[currency] or 0,
			Enum.AnalyticsEconomyTransactionType.Gameplay.Name,
			nil,
			"Gameplay"
		)
	end
end

local function remote(): RemoteEvent?
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local progress = remotes and remotes:FindFirstChild("Progress")
	return if progress and progress:IsA("RemoteEvent") then progress else nil
end

function Economy.canTransact(player: Player): boolean
	return StatsService.canTransact(player)
end

function Economy.balance(player: Player, currency: Currency): number
	local d = StatsService.get(player)
	return if d then (d :: any)[currency] or 0 else 0
end

-- Adds `amount` of a currency. `kind` is the analytics transaction type (Gameplay default).
-- Returns false for an unknown currency, a bad amount or no profile. Doesn't republish when
-- `quiet` (callers batching several changes commit once).
function Economy.grant(
	player: Player,
	currency: Currency,
	amount: number,
	reason: string,
	kind: Kind?,
	quiet: boolean?
): boolean
	local d = StatsService.get(player)
	if not d or not CURRENCIES[currency] or amount ~= amount or amount <= 0 then
		return false
	end
	amount = math.floor(amount)
	if amount <= 0 then
		return false
	end
	(d :: any)[currency] += amount
	local transaction = kind or "Gameplay"
	if transaction == "Gameplay" then
		local sums = pending[player] or {}
		pending[player] = sums
		sums[currency] = (sums[currency] or 0) + amount
	else
		analytics(
			player,
			Enum.AnalyticsEconomyFlowType.Source,
			currency,
			amount,
			(d :: any)[currency],
			transaction,
			nil,
			reason
		)
	end
	if not quiet then
		StatsService.commit(player)
	end
	return true
end

-- Takes `amount` of a currency if the player has it and this session may transact.
function Economy.spend(player: Player, currency: Currency, amount: number, reason: string, sku: string?): boolean
	local d = StatsService.get(player)
	if not d or not CURRENCIES[currency] or amount ~= amount or amount < 0 or not StatsService.canTransact(player) then
		return false
	end
	amount = math.floor(amount)
	if (d :: any)[currency] < amount then
		return false
	end
	(d :: any)[currency] -= amount
	analytics(
		player,
		Enum.AnalyticsEconomyFlowType.Sink,
		currency,
		amount,
		(d :: any)[currency],
		Enum.AnalyticsEconomyTransactionType.Shop.Name,
		sku,
		reason
	)
	StatsService.commit(player)
	return true
end

function Economy.owns(player: Player, id: string): boolean
	local d = StatsService.get(player)
	return d ~= nil and d.Inventory[id] ~= nil
end

-- Adds an item to the inventory (`source`: "coins", "gems", "robux", "achievement", "boss",
-- "pass", "ranked", "bundle", "vip", "grant"...). Blade lines start at L1.
function Economy.own(player: Player, id: string, source: string, quiet: boolean?): boolean
	local d = StatsService.get(player)
	local item = Catalog.get(id)
	if not d or not item or d.Inventory[id] ~= nil then
		return false
	end
	d.Inventory[id] = os.time()
	if item.category == "bladeLine" then
		d.LineLevels[id] = math.max(d.LineLevels[id] or 0, 1)
	end
	pcall(function()
		AnalyticsService:LogCustomEvent(player, "ItemOwned", 1, {
			[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = id,
			[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = source,
		})
	end)
	if not quiet then
		StatsService.commit(player)
	end
	return true
end

-- (have, need) toward an unlock rule, from the saved stats.
local function progress(d: Data, rule: Rule): (number, number)
	if rule.stat then
		return (d :: any)[rule.stat] or 0, rule.atLeast or 1
	elseif rule.boss then
		local clears = if rule.noHit then d.BossNoHit else d.BossClears
		return if (clears[rule.boss] or 0) > 0 then 1 else 0, 1
	elseif rule.stars then
		local have = 0
		for _, id in Bosses.List do
			local def = Bosses.def(id)
			if def and def.stars == rule.stars and (d.BossClears[id] or 0) > 0 then
				have += 1
			end
		end
		return have, rule.count or 1
	elseif rule.allBosses then
		local have = 0
		for _, id in Bosses.List do
			if (d.BossClears[id] or 0) > 0 then
				have += 1
			end
		end
		return have, #Bosses.List
	end
	return 0, 1
end

function Economy.unlocked(player: Player, id: string): (boolean, number, number)
	local d = StatsService.get(player)
	local item = Catalog.get(id)
	if not d or not item then
		return false, 0, 1
	end
	if not item.rule then
		return true, 1, 1
	end
	local have, need = progress(d, item.rule)
	return have >= need, have, need
end

-- Buys a priced item with coins or gems (the one it's priced in, or `currency` when it has
-- both). Robux items go through Monetization.prompt.
function Economy.buy(player: Player, id: string, currency: Currency?): (boolean, string?)
	local d = StatsService.get(player)
	local item = Catalog.get(id)
	if not d or not item then
		return false, "unknown"
	end
	if d.Inventory[id] ~= nil then
		return false, "owned"
	end
	local price = item.price
	if not price or not Catalog.isReady(item) then
		return false, "not for sale"
	end
	local pay: Currency, amount: number
	if price.coins and (currency == nil or currency == "Coins") then
		pay, amount = "Coins", price.coins
	elseif price.gems and (currency == nil or currency == "Gems") then
		pay, amount = "Gems", price.gems
	else
		return false, "not for sale"
	end
	local ok = Economy.unlocked(player, id)
	if not ok then
		return false, "locked"
	end
	if not StatsService.canTransact(player) then
		return false, "unavailable"
	end
	if not Economy.spend(player, pay, amount, `Buy {id}`, id) then
		return false, "funds"
	end
	Economy.own(player, id, string.lower(pay), true)
	if item.category == "bladeSkin" or item.category == "bladeLine" then
		d.Loadout.bladeSkin = id -- a new blade goes straight on
	end
	StatsService.commit(player)
	return true, nil
end

function Economy.equipped(player: Player, slot: Catalog.Slot): string
	local d = StatsService.get(player)
	return if d then d.Loadout[slot] or Catalog.Defaults[slot] else Catalog.Defaults[slot]
end

-- Puts an owned item in its slot. Only titles can be emptied (id "").
function Economy.equip(player: Player, slot: Catalog.Slot, id: string): boolean
	local d = StatsService.get(player)
	if not d or Catalog.Defaults[slot] == nil then
		return false
	end
	if id == "" then
		if slot ~= "title" then
			return false
		end
	else
		local item = Catalog.get(id)
		if not item or Catalog.slotOf(item) ~= slot or d.Inventory[id] == nil then
			return false
		end
	end
	if d.Loadout[slot] == id then
		return false
	end
	d.Loadout[slot] = id
	if slot == "title" and id ~= "" and d.Loadout.title2 == id then
		d.Loadout.title2 = "" -- one title can't fill both slots
	end
	StatsService.commit(player)
	return true
end

-- The second title slot (pass.TitleSlot, checked by the caller and passed as `hasSlot`):
-- any owned title other than the first one; "" clears it. Published in Loadout.title2.
function Economy.equipTitle2(player: Player, id: string, hasSlot: boolean): boolean
	local d = StatsService.get(player)
	if not d then
		return false
	end
	if id ~= "" then
		local item = Catalog.get(id)
		if not hasSlot or not item or item.category ~= "title" or d.Inventory[id] == nil then
			return false
		end
		if d.Loadout.title == id then
			return false
		end
	end
	if (d.Loadout.title2 or "") == id then
		return false
	end
	d.Loadout.title2 = id
	StatsService.commit(player)
	return true
end

-- Raises a blade line one level with Whetstones; up to LineUpgrade.GemShareMax of that
-- level's Whetstones may be paid with gems (`gemWhetstones` of them). L4 adds its finisher.
function Economy.upgradeLine(player: Player, id: string, gemWhetstones: number?): (boolean, string?)
	local d = StatsService.get(player)
	local item = Catalog.get(id)
	if not d or not item or item.category ~= "bladeLine" or not item.levels then
		return false, "unknown"
	end
	if d.Inventory[id] == nil then
		return false, "not owned"
	end
	local current = d.LineLevels[id] or 1
	local nextLevel = item.levels[current + 1]
	if not nextLevel then
		return false, "max"
	end
	local rules = EconomyConfig.LineUpgrade
	local cost = nextLevel.whetstones
	local viaGems = math.clamp(math.floor(gemWhetstones or 0), 0, math.floor(cost * rules.GemShareMax))
	local stones = cost - viaGems
	local gems = viaGems * rules.GemsPerWhetstone
	if not StatsService.canTransact(player) then
		return false, "unavailable"
	end
	if d.Whetstones < stones or d.Gems < gems then
		return false, "funds"
	end
	if stones > 0 then
		Economy.spend(player, "Whetstones", stones, `Upgrade {id} L{nextLevel.level}`, id)
	end
	if gems > 0 then
		Economy.spend(player, "Gems", gems, `Upgrade {id} L{nextLevel.level}`, id)
	end
	d.LineLevels[id] = nextLevel.level
	if nextLevel.level >= 4 and item.finisher then
		Economy.own(player, item.finisher, "line", true)
	end
	StatsService.commit(player)
	return true, nil
end

-- Grants every `auto` item whose rule is now met (achievements, boss-clear rewards) and tells
-- the player. Runs after every profile change.
local function checkAuto(player: Player)
	local d = StatsService.get(player)
	if not d then
		return
	end
	local granted = {}
	for _, item in Catalog.Items do
		local rule = item.rule
		if item.auto and rule and d.Inventory[item.id] == nil then
			local have, need = progress(d, rule)
			if have >= need then
				Economy.own(player, item.id, item.sources[1] or "achievement", true)
				table.insert(granted, item)
			end
		end
	end
	if #granted > 0 then
		StatsService.commit(player)
		local progressRemote = remote()
		if progressRemote then
			for _, item in granted do
				progressRemote:FireClient(
					player,
					"Unlock",
					{ id = item.id, name = item.name, category = item.category }
				)
			end
		end
	end
end

-- The Initiate's Bundle: on offer once per account, for EconomyConfig.InitiateWindow after
-- the first join. Returns whether it's on offer and when the offer ends.
function Economy.initiateOffer(player: Player): (boolean, number)
	local d = StatsService.get(player)
	if not d or d.Inventory["bundle.Initiate"] ~= nil then
		return false, 0
	end
	local ends = d.FirstJoin + EconomyConfig.InitiateWindow
	return os.time() < ends, ends
end

-- Next daily claim: which streak day it pays and whether today is already claimed. A missed
-- day pauses the streak; after the last day it starts again at 1.
function Economy.dailyNext(d: Data): (number, boolean)
	local today = EconomyConfig.day()
	local days = #EconomyConfig.Daily.Coins
	if d.LastDaily >= today then
		return math.max(d.Streak, 1), true
	end
	return if d.Streak >= days then 1 else d.Streak + 1, false
end

-- A per-day counter (caps on Whetstones from wins, draws...). Bumps it by `by` (default 0:
-- just read) and returns the value before.
function Economy.dayCount(player: Player, name: string, by: number?): number
	local d = StatsService.get(player)
	if not d then
		return 0
	end
	local today = EconomyConfig.day()
	if d.DayCounters.day ~= today then
		table.clear(d.DayCounters)
		d.DayCounters.day = today
	end
	local before = d.DayCounters[name] or 0
	if by and by ~= 0 then
		d.DayCounters[name] = before + by
	end
	return before
end

local function publishDerived(player: Player, d: Data)
	local unlocks = {}
	for _, item in Catalog.Items do
		local rule = item.rule
		if rule and d.Inventory[item.id] == nil then
			local have, need = progress(d, rule)
			unlocks[item.id] = { math.min(have, need), need }
		end
	end
	player:SetAttribute("UnlockProgress", HttpService:JSONEncode(unlocks))
	local onOffer, ends = Economy.initiateOffer(player)
	player:SetAttribute("InitiateEndsAt", if onOffer then ends else 0)
	player:SetAttribute("CanTransact", StatsService.canTransact(player))
	local nextDay, claimed = Economy.dailyNext(d)
	player:SetAttribute("DailyNext", nextDay)
	player:SetAttribute("DailyClaimed", claimed)
	player:SetAttribute("Trials", table.concat(Progression.dailyTrials(player.UserId, EconomyConfig.day()), ","))
end

local function publishDay()
	local now = os.time()
	ReplicatedStorage:SetAttribute("ServerDay", EconomyConfig.day(now))
	ReplicatedStorage:SetAttribute("DayEndsAt", (EconomyConfig.day(now) + 1) * SECONDS_PER_DAY)
end

function Economy.start()
	-- Every live blade skin needs a look in Shared/Progression.
	for _, item in Catalog.list("bladeSkin") do
		if Progression.skin(item.ref).id ~= item.ref then
			warn(`[Economy] {item.id} has no look in Shared/Progression.Skins`)
		end
	end
	StatsService.onPublish(publishDerived)
	StatsService.onChanged(checkAuto)
	Players.PlayerRemoving:Connect(flush)
	publishDay()
	task.spawn(function()
		local lastDay = EconomyConfig.day()
		while true do
			task.wait(FLUSH_INTERVAL)
			publishDay()
			for player in pending do
				flush(player)
			end
			-- A new UTC day: republish everyone so day-derived attributes roll over.
			local today = EconomyConfig.day()
			if today ~= lastDay then
				lastDay = today
				for _, player in Players:GetPlayers() do
					StatsService.commit(player)
				end
			end
		end
	end)
	for _, player in Players:GetPlayers() do
		if StatsService.get(player) then
			StatsService.commit(player)
		end
	end
end

return Economy
