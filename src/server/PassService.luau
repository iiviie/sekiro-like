--!strict
-- "Path of the Blade", the season pass (Shared/Season): Pass XP, tiers, the free and premium
-- reward tracks, claims, premium and tier-skip purchases, daily missions and weekly bounties,
-- and the rollover from one season to the next. State lives in the profile's `Ext.Pass`
-- (StatsService), currencies and items move through server/Economy, Robux through
-- server/Monetization.
--
--   PassService.addXP(player, amount, reason, quiet?) -> number      Pass XP actually added
--   PassService.missionEvent(player, event, amount?) -> { Payout }   missions it completed
--   PassService.tier(player) -> number
--
-- Pass XP comes from missions (Season) and a trickle from every fight (ProgressService, per
-- EconomyConfig.Pass), x2 in a season's final week and none outside a live season. Rewards are
-- claimed by hand (free: anyone; premium: owners of this season's pass.Premium, including
-- every tier reached before buying). Unclaimed rewards a player earned are paid when the
-- season rolls over. Missions never cost anything; one daily mission may be rerolled free
-- once a day, and there is no paid reroll.
--
-- Client requests: ReplicatedStorage.Remotes.PassAction (rate-limited)
--   "Claim" track ("free" | "premium") tier     "ClaimAll"     "Reroll" missionId
--   "Buy" productKey ("pass.Premium" | "pass.TierSkip" | "pass.Tiers10")
-- Feedback: Remotes.Progress "Mission" { id, text, weekly, pass, coins, xp }, "PassTier"
--   { tier, claimable }, "PassPremium" { claimable }, "Notice" { text }.
--
-- Published per player: PassSeason, PassXP, PassTier, PassPremium, PassClaimed (JSON
--   { free = {tiers}, premium = {tiers} }), PassClaimable, PassTierSkips, Missions (JSON
--   { daily = {{id, have}}, weekly = {{id, have}}, reroll, weekEndsAt }); the legacy Trials,
--   TrialDay, TrialProgress describe today's daily missions.
-- On ReplicatedStorage: SeasonId, SeasonState ("live" | "break" | "off"), SeasonEndsAt (when
--   that state ends, epoch on Season.now's clock; 0 = unknown), SeasonMultiplier.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Catalog = require(ReplicatedStorage.Shared.Catalog)
local Text = require(ReplicatedStorage.Shared.Text)
local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local Season = require(ReplicatedStorage.Shared.Season)
local Economy = require(script.Parent.Economy)
local Monetization = require(script.Parent.Monetization)
local ShopService = require(script.Parent.ShopService)
local StatsService = require(script.Parent.StatsService)

type Data = StatsService.Data
type Reward = Season.Reward

export type Payout = { coins: number, xp: number, whetstones: number }

type PassState = {
	season: string,
	free: { [string]: boolean },
	premium: { [string]: boolean },
	lastTier: number,
	premiumSeen: boolean,
	daily: { day: number, ids: { string }, rerolled: boolean },
	weekly: { week: number, ids: { string }, progress: { [string]: number } },
	archive: { [string]: { xp: number, tier: number, premium: boolean, at: number } },
}

local PassService = {}

local BURST, RATE = 6, 2
local buckets: { [Player]: { tokens: number, at: number } } = {}

local function progressRemote(): RemoteEvent?
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local remote = remotes and remotes:FindFirstChild("Progress")
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function tell(player: Player, kind: string, payload: { [string]: any })
	local remote = progressRemote()
	if remote then
		remote:FireClient(player, kind, payload)
	end
end

local function notice(player: Player, text: string)
	tell(player, "Notice", { text = text })
end

local function itemName(id: string): string?
	local item = Catalog.get(id)
	return item and item.name
end

-- The profile's pass state, repaired into shape (it's saved data).
local function stateOf(d: Data): PassState
	local raw = d.Ext.Pass
	if typeof(raw) ~= "table" then
		raw = {}
		d.Ext.Pass = raw
	end
	local st = raw :: any
	if typeof(st.season) ~= "string" then
		st.season = ""
	end
	if typeof(st.free) ~= "table" then
		st.free = {}
	end
	if typeof(st.premium) ~= "table" then
		st.premium = {}
	end
	if typeof(st.lastTier) ~= "number" then
		st.lastTier = 0
	end
	st.premiumSeen = st.premiumSeen == true
	if typeof(st.daily) ~= "table" or typeof(st.daily.ids) ~= "table" then
		st.daily = { day = -1, ids = {}, rerolled = false }
	end
	if typeof(st.weekly) ~= "table" or typeof(st.weekly.ids) ~= "table" or typeof(st.weekly.progress) ~= "table" then
		st.weekly = { week = -1, ids = {}, progress = {} }
	end
	if typeof(st.archive) ~= "table" then
		st.archive = {}
	end
	return st :: PassState
end

local function premiumOwned(d: Data, st: PassState): boolean
	return st.season ~= "" and d.SeasonPremium[st.season] ~= nil
end

-- Grants a list of rewards (quietly: the caller commits). Returns their display texts.
-- `paid`: the premium track, bought with Robux, so its Shrine Draws are paid random items
-- (a policy-restricted player gets ShopService's fixed reward instead).
local function grantRewards(player: Player, rewards: { Reward }, label: string, paid: boolean): { string }
	local texts = {}
	for _, reward in rewards do
		local amount = reward.amount or 0
		if reward.kind == "coins" then
			Economy.grant(player, "Coins", amount, label, "Gameplay", true)
		elseif reward.kind == "gems" then
			Economy.grant(player, "Gems", amount, label, "Gameplay", true)
		elseif reward.kind == "whetstones" then
			Economy.grant(player, "Whetstones", amount, label, "Gameplay", true)
		elseif reward.kind == "draws" then
			ShopService.grantDraws(player, amount, label, paid, true)
		elseif reward.kind == "item" and reward.id then
			Economy.own(player, reward.id, "pass", true)
		end
		table.insert(texts, Season.rewardText(reward, itemName))
	end
	return texts
end

-- The rewards at `tier` on `track` that this player may claim now (nil when they can't).
local function claimableRewards(d: Data, st: PassState, track: string, tier: number): { Reward }?
	local def = Season.get(st.season)
	local entry = def and def.tiers[tier]
	if not entry or tier > Season.tierOf(d.PassXP) then
		return nil
	end
	local key = tostring(tier)
	if track == "free" then
		return if entry.free and not st.free[key] then entry.free else nil
	elseif track == "premium" then
		return if premiumOwned(d, st) and not st.premium[key] then entry.premium else nil
	end
	return nil
end

local function countClaimable(d: Data, st: PassState): number
	local n = 0
	for tier = 1, Season.tierOf(d.PassXP) do
		if claimableRewards(d, st, "free", tier) then
			n += 1
		end
		if claimableRewards(d, st, "premium", tier) then
			n += 1
		end
	end
	return n
end

-- Claims one cell (quietly). Returns the reward texts, or nil.
local function claim(player: Player, d: Data, st: PassState, track: string, tier: number): { string }?
	local rewards = claimableRewards(d, st, track, tier)
	if not rewards then
		return nil
	end
	local key = tostring(tier)
	if track == "free" then
		st.free[key] = true
	else
		st.premium[key] = true
	end
	return grantRewards(player, rewards, `Pass {st.season} T{tier} {track}`, track ~= "free")
end

local function claimAll(player: Player, d: Data, st: PassState): { string }
	local texts = {}
	for tier = 1, Season.tierOf(d.PassXP) do
		for _, track in { "free", "premium" } do
			for _, text in claim(player, d, st, track, tier) or {} do
				table.insert(texts, text)
			end
		end
	end
	return texts
end

-- Tier skips: +TierXP each in a live season, or kept for the next live one.
local function applySkips(d: Data, count: number)
	local _, state = Season.at()
	if state == "live" then
		d.PassXP = math.min(Season.MaxXP, d.PassXP + count * Season.TierXP)
	else
		d.PassTierSkips += count
	end
end

-- A new season: pay what the player earned and never claimed, archive the old one, reset.
local function rollover(player: Player, d: Data, st: PassState, newId: string)
	local old = Season.get(st.season)
	if old then
		claimAll(player, d, st)
		st.archive[old.id] = {
			xp = d.PassXP,
			tier = Season.tierOf(d.PassXP),
			premium = premiumOwned(d, st),
			at = os.time(),
		}
	end
	st.season = newId
	st.free = {}
	st.premium = {}
	st.lastTier = 0
	st.premiumSeen = false
	d.PassXP = 0
end

-- Brings the state up to date: season rollover, pending tier skips, today's missions, this
-- week's bounties. Never commits (it runs inside StatsService's publish).
local function ensure(player: Player, d: Data, st: PassState)
	local def, state = Season.at()
	if def and state ~= "off" and st.season ~= def.id then
		if st.season == "" then
			st.season = def.id -- first visit with a pass: Pass XP so far counts toward this one
		else
			rollover(player, d, st, def.id)
		end
	end
	if state == "live" and d.PassTierSkips > 0 then
		local skips = d.PassTierSkips
		d.PassTierSkips = 0
		applySkips(d, skips)
	end
	d.PassXP = math.min(d.PassXP, Season.MaxXP)
	local day = EconomyConfig.day()
	if st.daily.day ~= day then
		st.daily = { day = day, ids = Season.dailyMissions(player.UserId, day), rerolled = false }
		d.TrialDay = day
		table.clear(d.TrialProgress)
	end
	local week = Season.week()
	if st.weekly.week ~= week then
		st.weekly = { week = week, ids = Season.weeklyMissions(player.UserId, week), progress = {} }
	end
end

local function stateFor(player: Player): (Data?, PassState?)
	local d = StatsService.get(player)
	if not d then
		return nil, nil
	end
	local st = stateOf(d)
	ensure(player, d, st)
	return d, st
end

-- Adds Pass XP (x the season multiplier, capped at the last tier). Returns what was added.
function PassService.addXP(player: Player, amount: number, reason: string, quiet: boolean?): number
	local d = stateFor(player)
	if not d or amount <= 0 then
		return 0
	end
	local gained = math.min(math.floor(amount * Season.multiplier()), Season.MaxXP - d.PassXP)
	if gained <= 0 then
		return 0
	end
	Economy.grant(player, "PassXP", gained, reason, "Gameplay", quiet)
	return gained
end

function PassService.tier(player: Player): number
	local d = StatsService.get(player)
	return if d then Season.tierOf(d.PassXP) else 0
end

-- Advances every daily mission and weekly bounty listening for `event`. Completed ones pay
-- their Pass XP here and are returned so ProgressService pays coins, Mastery XP and
-- Whetstones through its own levelling path.
function PassService.missionEvent(player: Player, event: string, amount: number?): { Payout }
	local d, st = stateFor(player)
	local out: { Payout } = {}
	if not d or not st or event == "" then
		return out
	end
	local step = amount or 1
	local changed = false
	local function advance(ids: { string }, progress: { [string]: number })
		for _, id in ids do
			local mission = Season.mission(id)
			if mission and mission.event == event then
				local before = progress[id] or 0
				if before < mission.goal then
					local after = math.min(mission.goal, before + step)
					progress[id] = after
					changed = true
					if after >= mission.goal then
						local gained = PassService.addXP(
							player,
							mission.pass,
							if mission.weekly then "Bounty" else "Mission",
							true
						)
						tell(player, "Mission", {
							id = id,
							text = mission.text,
							weekly = mission.weekly,
							pass = gained,
							coins = mission.coins,
							xp = mission.xp,
						})
						table.insert(out, { coins = mission.coins, xp = mission.xp, whetstones = mission.whetstones })
					end
				end
			end
		end
	end
	advance(st.daily.ids, d.TrialProgress)
	advance(st.weekly.ids, st.weekly.progress)
	if changed then
		StatsService.commit(player)
	end
	return out
end

local function listOf(set: { [string]: boolean }): { number }
	local out = {}
	for key, has in set do
		local n = tonumber(key)
		if has and n then
			table.insert(out, n)
		end
	end
	table.sort(out)
	return out
end

local function publish(player: Player, d: Data)
	local st = stateOf(d)
	ensure(player, d, st)
	local tier = Season.tierOf(d.PassXP)
	local premium = premiumOwned(d, st)
	local claimable = countClaimable(d, st)
	if tier > st.lastTier then
		st.lastTier = tier
		tell(player, "PassTier", { tier = tier, claimable = claimable })
	elseif tier < st.lastTier then
		st.lastTier = tier
	end
	if premium and not st.premiumSeen then
		st.premiumSeen = true
		if claimable > 0 then
			tell(player, "PassPremium", { claimable = claimable })
		else
			-- Bought before tier 1: nothing to claim yet, so say what comes first and how far.
			local def = Season.get(st.season)
			local entry = def and def.tiers[tier + 1]
			local first = entry and entry.premium[1]
			local away = (tier + 1) * Season.TierXP - d.PassXP
			notice(
				player,
				if first
					then `Premium unlocked  ·  {Season.rewardText(first, itemName)} waits at tier {tier + 1}, {away} Pass XP away`
					else "Premium unlocked"
			)
		end
	end
	local function missions(ids: { string }, progress: { [string]: number })
		local out = {}
		for _, id in ids do
			table.insert(out, { id = id, have = progress[id] or 0 })
		end
		return out
	end
	player:SetAttribute("PassSeason", st.season)
	player:SetAttribute("PassXP", d.PassXP)
	player:SetAttribute("PassTier", tier)
	player:SetAttribute("PassPremium", premium)
	player:SetAttribute("PassClaimable", claimable)
	player:SetAttribute("PassTierSkips", d.PassTierSkips)
	-- Owner-only blobs (StatsService.setPrivate): no other client reads them.
	StatsService.setPrivate(
		player,
		"PassClaimed",
		HttpService:JSONEncode({ free = listOf(st.free), premium = listOf(st.premium) })
	)
	StatsService.setPrivate(
		player,
		"Missions",
		HttpService:JSONEncode({
			daily = missions(st.daily.ids, d.TrialProgress),
			weekly = missions(st.weekly.ids, st.weekly.progress),
			reroll = not st.daily.rerolled,
			weekEndsAt = Season.weekEndsAt(st.weekly.week),
		})
	)
	-- The legacy daily-Trials attributes, now today's daily missions.
	player:SetAttribute("Trials", table.concat(st.daily.ids, ","))
	player:SetAttribute("TrialDay", d.TrialDay)
	StatsService.setPrivate(player, "TrialProgress", HttpService:JSONEncode(d.TrialProgress))
end

--------------------------------------------------------------------------------------------
-- Client requests.

local function allowed(player: Player): boolean
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

local function claimedNotice(player: Player, texts: { string })
	if #texts == 0 then
		return
	end
	local shown = table.concat(texts, "  ·  ", 1, math.min(#texts, 4))
	if #texts > 4 then
		shown ..= `  ·  +{#texts - 4} more`
	end
	tell(player, "PassClaim", { text = shown, count = #texts })
end

local function duration(seconds: number): string
	local days = math.floor(seconds / 86400)
	local hours = math.floor(seconds % 86400 / 3600)
	return if days > 0 then `{days}d {hours}h` else `{hours}h {math.floor(seconds % 3600 / 60)}m`
end

local function buy(player: Player, d: Data, st: PassState, key: string)
	local _, state, untilAt = Season.at()
	if state ~= "live" then
		notice(
			player,
			if state == "break" and untilAt > 0
				then `The next season opens in {duration(untilAt - Season.now())}.`
				else "No season is running right now."
		)
		return
	end
	local tier = Season.tierOf(d.PassXP)
	local left = Season.Tiers - tier
	if key == Season.Products.Premium then
		if premiumOwned(d, st) then
			notice(player, "You already have this season's premium pass.")
			return
		end
	elseif key == Season.Products.TierSkip then
		if left < 1 then
			notice(player, "You've reached the last tier.")
			return
		end
	elseif key == Season.Products.Tiers10 then
		if left < 10 then
			notice(player, `Only {Text.count(left, "tier")} left: use single tier skips instead.`)
			return
		end
	else
		return
	end
	Monetization.prompt(player, key)
end

local function onAction(player: Player, verb: unknown, a: unknown, b: unknown)
	if typeof(verb) ~= "string" or not allowed(player) then
		return
	end
	local d, st = stateFor(player)
	if not d or not st then
		return
	end
	if verb == "Claim" then
		if (a ~= "free" and a ~= "premium") or typeof(b) ~= "number" or b ~= b then
			return
		end
		local texts = claim(player, d, st, a :: string, math.floor(b :: number))
		if texts then
			StatsService.commit(player)
			claimedNotice(player, texts)
		end
	elseif verb == "ClaimAll" then
		local texts = claimAll(player, d, st)
		if #texts > 0 then
			StatsService.commit(player)
			claimedNotice(player, texts)
		end
	elseif verb == "Reroll" then
		if typeof(a) ~= "string" then
			return
		end
		local index = table.find(st.daily.ids, a)
		local mission = Season.mission(a)
		if not index or not mission then
			return
		end
		if st.daily.rerolled then
			notice(player, "You've used today's free reroll.")
			return
		end
		if (d.TrialProgress[a] or 0) >= mission.goal then
			return
		end
		local replacement = Season.rerollDaily(a, st.daily.ids, player.UserId * 31 + st.daily.day * 977 + index)
		if not replacement then
			return
		end
		st.daily.ids[index] = replacement
		st.daily.rerolled = true
		d.TrialProgress[a] = nil
		StatsService.commit(player)
	elseif verb == "Buy" then
		if typeof(a) == "string" then
			buy(player, d, st, a)
		end
	end
end

--------------------------------------------------------------------------------------------

local function publishSeason()
	local def, state, untilAt = Season.at()
	ReplicatedStorage:SetAttribute("SeasonId", if def then def.id else "")
	ReplicatedStorage:SetAttribute("SeasonState", state)
	ReplicatedStorage:SetAttribute("SeasonEndsAt", untilAt)
	ReplicatedStorage:SetAttribute("SeasonMultiplier", Season.multiplier())
end

-- Studio only: ServerStorage.PassTest (BindableFunction) for playtests.
--   "state" -> JSON     "xp" n     "event" name n     "clock" offsetSeconds     "reset"
--   "buy" productKey (mock receipt)     "claimAll"     "rollover" (archive + reset this season,
--   paying what's unclaimed, as a calendar rollover does)
local function testHook()
	if not RunService:IsStudio() then
		return
	end
	local hook = Instance.new("BindableFunction")
	hook.Name = "PassTest"
	hook.OnInvoke = function(cmd: string, a: any, b: any): any
		local player = Players:GetPlayers()[1]
		if not player then
			return "no player"
		end
		local d, st = stateFor(player)
		if not d or not st then
			return "no profile"
		end
		if cmd == "xp" then
			StatsService.markTest(player)
			return PassService.addXP(player, tonumber(a) or 0, "Test")
		elseif cmd == "event" then
			StatsService.markTest(player)
			return #PassService.missionEvent(player, tostring(a), tonumber(b))
		elseif cmd == "clock" then
			ReplicatedStorage:SetAttribute("SeasonClockOffset", tonumber(a) or 0)
			publishSeason()
			StatsService.commit(player)
			return Season.now()
		elseif cmd == "reset" then
			StatsService.markTest(player)
			d.Ext.Pass = nil
			d.PassXP = 0
			d.PassTierSkips = 0
			table.clear(d.SeasonPremium)
			StatsService.commit(player)
			return "reset"
		elseif cmd == "buy" then
			return tostring(Monetization.mockReceipt(player, tostring(a)))
		elseif cmd == "rollover" then
			StatsService.markTest(player)
			local before = { Coins = d.Coins, Gems = d.Gems, Whetstones = d.Whetstones, Draws = d.Draws }
			rollover(player, d, st, st.season)
			StatsService.commit(player)
			return HttpService:JSONEncode({
				paid = {
					coins = d.Coins - before.Coins,
					gems = d.Gems - before.Gems,
					whetstones = d.Whetstones - before.Whetstones,
					draws = d.Draws - before.Draws,
				},
				archive = st.archive,
				xp = d.PassXP,
			})
		elseif cmd == "claimAll" then
			local texts = claimAll(player, d, st)
			StatsService.commit(player)
			return table.concat(texts, ", ")
		end
		return HttpService:JSONEncode({
			season = st.season,
			xp = d.PassXP,
			tier = Season.tierOf(d.PassXP),
			premium = premiumOwned(d, st),
			skips = d.PassTierSkips,
			claimable = countClaimable(d, st),
			state = st,
			trialProgress = d.TrialProgress,
			wallet = { coins = d.Coins, gems = d.Gems, whetstones = d.Whetstones, draws = d.Draws },
			multiplier = Season.multiplier(),
		})
	end
	hook.Parent = ServerStorage
end

function PassService.start()
	-- Every reward must be a real catalogue item.
	for _, def in Season.List do
		for tier, entry in def.tiers do
			for _, reward in (entry.free or {}) :: { Reward } do
				assert(reward.kind ~= "item" or Catalog.get(reward.id), `[Season] {def.id} T{tier} free: {reward.id}`)
			end
			for _, reward in entry.premium do
				assert(reward.kind ~= "item" or Catalog.get(reward.id), `[Season] {def.id} T{tier}: {reward.id}`)
			end
		end
	end

	Monetization.setGrant(Season.Products.Premium, function(_player, d, _key)
		local def = Season.at()
		d.SeasonPremium[if def then def.id else EconomyConfig.Season] = os.time()
	end)
	Monetization.setGrant(Season.Products.TierSkip, function(_player, d, _key)
		applySkips(d, 1)
	end)
	Monetization.setGrant(Season.Products.Tiers10, function(_player, d, _key)
		applySkips(d, 10)
	end)

	local remote = Instance.new("RemoteEvent")
	remote.Name = "PassAction"
	remote.Parent = ReplicatedStorage:WaitForChild("Remotes")
	remote.OnServerEvent:Connect(onAction)

	StatsService.onPublish(publish)
	Players.PlayerRemoving:Connect(function(player)
		buckets[player] = nil
	end)

	publishSeason()
	ReplicatedStorage:GetAttributeChangedSignal("SeasonClockOffset"):Connect(publishSeason)
	task.spawn(function()
		local last = ReplicatedStorage:GetAttribute("SeasonState")
		local lastId = ReplicatedStorage:GetAttribute("SeasonId")
		while true do
			task.wait(15)
			publishSeason()
			local now, nowId = ReplicatedStorage:GetAttribute("SeasonState"), ReplicatedStorage:GetAttribute("SeasonId")
			if now ~= last or nowId ~= lastId then
				last, lastId = now, nowId
				for _, player in Players:GetPlayers() do
					StatsService.commit(player) -- rollover / break for everyone online
				end
			end
		end
	end)
	testHook()
end

return PassService
