--!strict
-- Persistent player data: match stats, coins and gems, ranked rating, owned and equipped
-- weapons, weapon usage and the daily-reward streak. Saved per player with
-- DataStoreService (on leave, every few minutes and on shutdown); published to clients as
-- player attributes, so the lobby UI reads everything without extra remotes. Wins and
-- Kills also show in the player list. If DataStores are unavailable (an unpublished place,
-- or Studio without API access) everything still works for the session.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Round = require(ReplicatedStorage.Shared.Round)
local Progression = require(ReplicatedStorage.Shared.Progression)
local Weapons = require(ReplicatedStorage.Shared.Weapons)
local CombatService = require(script.Parent.CombatService)

type Combatant = CombatService.Combatant

export type Data = {
	Wins: number,
	Losses: number,
	Kills: number,
	Deathblows: number,
	Played: number, -- royales and duels: how much fighting a player has seen
	DuelWins: number,
	DuelLosses: number,
	Coins: number,
	Gems: number,
	Rating: number,
	PeakRating: number,
	Streak: number,
	LastDaily: number, -- UTC day number of the last claimed daily reward
	Weapon: string,
	Owned: { [string]: boolean },
	WeaponUses: { [string]: number },
	-- Progression (see Shared/Progression and ProgressService).
	XP: number, -- toward the next level
	Level: number,
	Deflects: number,
	Perfects: number,
	Skin: string,
	OwnedSkins: { [string]: boolean },
	TrialDay: number, -- UTC day the trial progress below belongs to
	TrialProgress: { [string]: number },
	BossClears: { [string]: number }, -- boss id -> times cleared (boss duels)
}

local STORE_NAME = "PlayerData_v2"
local LEGACY_STORE_NAME = "PlayerStats_v1" -- Wins/Kills from before the lobby
local AUTOSAVE_INTERVAL = 120
local RETRIES = 3
local NUMBERS = {
	"Wins",
	"Losses",
	"Kills",
	"Deathblows",
	"Played",
	"DuelWins",
	"DuelLosses",
	"Coins",
	"Gems",
	"Rating",
	"PeakRating",
	"Streak",
	"LastDaily",
	"XP",
	"Level",
	"Deflects",
	"Perfects",
	"TrialDay",
}

local StatsService = {}

local store: DataStore? = nil
local legacyStore: DataStore? = nil
local data: { [Player]: Data } = {}
local loaded: { [Player]: boolean } = {}
local changedListeners: { (Player) -> () } = {}

local function withRetries<T>(fn: () -> T): (boolean, T?)
	for attempt = 1, RETRIES do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		if attempt < RETRIES then
			task.wait(attempt)
		else
			warn(`[StatsService] {result}`)
		end
	end
	return false, nil
end

local function key(player: Player): string
	return `player_{player.UserId}`
end

local function fresh(): Data
	local owned = {}
	for _, id in Weapons.Order do
		if Weapons.get(id).price == 0 then
			owned[id] = true
		end
	end
	return {
		Wins = 0,
		Losses = 0,
		Kills = 0,
		Deathblows = 0,
		Played = 0,
		DuelWins = 0,
		DuelLosses = 0,
		Coins = Config.Economy.StartCoins,
		Gems = Config.Economy.StartGems,
		Rating = Config.Rating.Start,
		PeakRating = Config.Rating.Start,
		Streak = 0,
		LastDaily = 0,
		Weapon = Weapons.Default,
		Owned = owned,
		WeaponUses = {},
		XP = 0,
		Level = 1,
		Deflects = 0,
		Perfects = 0,
		Skin = Progression.Skins[1].id,
		OwnedSkins = { [Progression.Skins[1].id] = true },
		TrialDay = 0,
		TrialProgress = {},
		BossClears = {},
	}
end

-- Merge a saved table into fresh defaults, ignoring anything malformed.
local function sanitize(saved: unknown): Data
	local d = fresh()
	if typeof(saved) ~= "table" then
		return d
	end
	local t = saved :: { [string]: any }
	for _, field in NUMBERS do
		local value = tonumber(t[field])
		if value and value == value then
			(d :: any)[field] = value
		end
	end
	if typeof(t.Owned) == "table" then
		for id, owned in t.Owned do
			if owned == true and Weapons.get(id).id == id then
				d.Owned[id] = true
			end
		end
	end
	if typeof(t.WeaponUses) == "table" then
		for id, uses in t.WeaponUses do
			if typeof(id) == "string" and tonumber(uses) then
				d.WeaponUses[id] = tonumber(uses) :: number
			end
		end
	end
	if typeof(t.Weapon) == "string" and d.Owned[t.Weapon] then
		d.Weapon = t.Weapon
	end
	if typeof(t.OwnedSkins) == "table" then
		for id, owned in t.OwnedSkins do
			if owned == true and Progression.skin(id).id == id then
				d.OwnedSkins[id] = true
			end
		end
	end
	if typeof(t.Skin) == "string" and d.OwnedSkins[t.Skin] then
		d.Skin = t.Skin
	end
	if typeof(t.TrialProgress) == "table" then
		for id, progress in t.TrialProgress do
			if typeof(id) == "string" and tonumber(progress) then
				d.TrialProgress[id] = tonumber(progress) :: number
			end
		end
	end
	if typeof(t.BossClears) == "table" then
		for id, count in t.BossClears do
			if typeof(id) == "string" and tonumber(count) then
				d.BossClears[id] = tonumber(count) :: number
			end
		end
	end
	d.Level = math.max(1, math.floor(d.Level))
	return d
end

local function publish(player: Player)
	local d = data[player]
	if not d then
		return
	end
	for _, field in NUMBERS do
		player:SetAttribute(field, (d :: any)[field])
	end
	player:SetAttribute("Weapon", d.Weapon)
	local owned = {}
	for id in d.Owned do
		table.insert(owned, id)
	end
	table.sort(owned)
	player:SetAttribute("OwnedWeapons", table.concat(owned, ","))
	player:SetAttribute("WeaponUses", HttpService:JSONEncode(d.WeaponUses))
	player:SetAttribute("Skin", d.Skin)
	local skins = {}
	for id in d.OwnedSkins do
		table.insert(skins, id)
	end
	table.sort(skins)
	player:SetAttribute("OwnedSkins", table.concat(skins, ","))
	player:SetAttribute("XPToNext", Progression.xpToNext(d.Level))
	player:SetAttribute("TrialProgress", HttpService:JSONEncode(d.TrialProgress))
	player:SetAttribute("BossClears", HttpService:JSONEncode(d.BossClears))
	player:SetAttribute("DataLoaded", true)

	local stats = player:FindFirstChild("leaderstats")
	if stats then
		for _, name in { "Wins", "Kills" } do
			local v = stats:FindFirstChild(name)
			if v and v:IsA("IntValue") then
				v.Value = (d :: any)[name]
			end
		end
	end
	for _, listener in changedListeners do
		task.spawn(listener, player)
	end
end

local function save(player: Player)
	local dataStore = store
	local d = data[player]
	if not dataStore or not loaded[player] or not d then
		return -- never overwrite saved data with a failed load's defaults
	end
	local snapshot = table.clone(d)
	withRetries(function()
		return dataStore:UpdateAsync(key(player), function()
			return snapshot
		end)
	end)
end

local function onPlayerAdded(player: Player)
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	for _, name in { "Wins", "Kills" } do
		local v = Instance.new("IntValue")
		v.Name = name
		v.Parent = stats
	end
	stats.Parent = player

	data[player] = fresh()
	local dataStore = store
	if dataStore then
		local ok, saved = withRetries(function()
			return dataStore:GetAsync(key(player))
		end)
		if not player.Parent then
			return
		end
		if ok then
			if saved == nil and legacyStore then
				-- First visit since the lobby update: carry over old Wins and Kills.
				local legacy = legacyStore
				local legacyOk, old = withRetries(function()
					return legacy:GetAsync(key(player))
				end)
				saved = if legacyOk then old else nil
			end
			data[player] = sanitize(saved)
			loaded[player] = true
		end
	end
	publish(player)
end

function StatsService.get(player: Player): Data?
	return data[player]
end

-- Republishes after a caller changed the table returned by `get` directly.
function StatsService.commit(player: Player)
	publish(player)
end

-- Adds to a numeric field (negative amounts allowed) and republishes.
function StatsService.add(player: Player, field: string, amount: number)
	local d = data[player]
	if d and typeof((d :: any)[field]) == "number" then
		(d :: any)[field] += amount
		publish(player)
	end
end

-- Spends currency if the player has enough.
function StatsService.spend(player: Player, currency: "Coins" | "Gems", amount: number): boolean
	local d = data[player]
	if not d or amount < 0 or d[currency] < amount then
		return false
	end
	d[currency] -= amount
	publish(player)
	return true
end

function StatsService.grantWeapon(player: Player, id: string)
	local d = data[player]
	if d then
		d.Owned[id] = true
		publish(player)
	end
end

function StatsService.equip(player: Player, id: string): boolean
	local d = data[player]
	if not d or not d.Owned[id] then
		return false
	end
	d.Weapon = id
	publish(player)
	return true
end

function StatsService.addWin(player: Player)
	StatsService.add(player, "Wins", 1)
end

-- Elo's expected score for `a` against `b`.
local function expected(a: Data, b: Data): number
	return 1 / (1 + 10 ^ ((b.Rating - a.Rating) / 400))
end

local function applyRating(d: Data, delta: number)
	d.Rating = math.max(0, math.floor(d.Rating + delta + 0.5))
	d.PeakRating = math.max(d.PeakRating, d.Rating)
end

-- Records a finished match. `placements` lists every human participant, best first.
-- Ranked rating moves by pairwise results against the other humans you placed above or
-- below (bots never count), Elo style.
function StatsService.recordMatch(placements: { Player }, weapons: { [Player]: string }, winner: Player?)
	local rules = Config.Rating
	local deltas: { [Player]: number } = {}
	for i, a in placements do
		deltas[a] = 0
		for j, b in placements do
			local da, db = data[a], data[b]
			if i ~= j and da and db then
				local score = if i < j then 1 else 0
				deltas[a] += rules.K * (score - expected(da, db)) / math.max(#placements - 1, 1)
			end
		end
	end
	for _, player in placements do
		local d = data[player]
		if d then
			d.Played += 1
			if player ~= winner then
				d.Losses += 1
			end
			applyRating(d, deltas[player])
			local weapon = weapons[player]
			if weapon then
				d.WeaponUses[weapon] = (d.WeaponUses[weapon] or 0) + 1
			end
			publish(player)
		end
	end
end

-- Records a finished duel between `winner` and `loser` (either may be nil for a bot). Both
-- humans' Played and weapon use count; rating moves only when both sides are human, as one
-- full-weight Elo result. Returns each human's rating change.
function StatsService.recordDuel(winner: Player?, loser: Player?, weapons: { [Player]: string }): { [Player]: number }
	local changes: { [Player]: number } = {}
	local dw, dl = winner and data[winner], loser and data[loser]
	if winner and loser and dw and dl then
		local before = { dw.Rating, dl.Rating }
		local delta = Config.Rating.K * (1 - expected(dw, dl))
		applyRating(dw, delta)
		applyRating(dl, -delta)
		changes[winner] = dw.Rating - before[1]
		changes[loser] = dl.Rating - before[2]
	end
	local function count(player: Player?, d: Data?, won: boolean)
		if not player or not d then
			return
		end
		d.Played += 1
		if won then
			d.DuelWins += 1
		else
			d.DuelLosses += 1
		end
		local weapon = weapons[player]
		if weapon then
			d.WeaponUses[weapon] = (d.WeaponUses[weapon] or 0) + 1
		end
		publish(player)
	end
	count(winner, dw, true)
	count(loser, dl, false)
	return changes
end

function StatsService.onChanged(listener: (Player) -> ())
	table.insert(changedListeners, listener)
end

function StatsService.start()
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	store = if ok then result else nil
	local legacyOk, legacy = pcall(function()
		return DataStoreService:GetDataStore(LEGACY_STORE_NAME)
	end)
	legacyStore = if legacyOk then legacy else nil

	-- Kill credit and coins count in matches and duels only, so sparring in the lobby can't
	-- farm them. Cutting down a fighter who will resurrect pays the same as a kill.
	local function credit(_victim: Combatant, killer: Combatant?, deathblow: boolean)
		local fighting = Round.phase() == "Match" or (killer and killer.model:GetAttribute("InDuel") == true)
		if killer and killer.player and fighting then
			StatsService.add(killer.player, "Kills", 1)
			if deathblow then
				StatsService.add(killer.player, "Deathblows", 1)
			end
		end
	end
	CombatService.onDied(credit)
	CombatService.onCutDown(credit)

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		save(player)
		data[player] = nil
		loaded[player] = nil
	end)
	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			task.spawn(save, player)
		end
		task.wait(3)
	end)
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL)
			for _, player in Players:GetPlayers() do
				task.spawn(save, player)
			end
		end
	end)
end

return StatsService
