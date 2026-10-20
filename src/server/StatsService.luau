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
local Weapons = require(ReplicatedStorage.Shared.Weapons)
local CombatService = require(script.Parent.CombatService)

type Combatant = CombatService.Combatant

export type Data = {
	Wins: number,
	Losses: number,
	Kills: number,
	Deathblows: number,
	Played: number,
	Coins: number,
	Gems: number,
	Rating: number,
	PeakRating: number,
	Streak: number,
	LastDaily: number, -- UTC day number of the last claimed daily reward
	Weapon: string,
	Owned: { [string]: boolean },
	WeaponUses: { [string]: number },
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
	"Coins",
	"Gems",
	"Rating",
	"PeakRating",
	"Streak",
	"LastDaily",
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
		Coins = Config.Economy.StartCoins,
		Gems = Config.Economy.StartGems,
		Rating = Config.Rating.Start,
		PeakRating = Config.Rating.Start,
		Streak = 0,
		LastDaily = 0,
		Weapon = Weapons.Default,
		Owned = owned,
		WeaponUses = {},
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
	StatsService.add(player, "Coins", Config.Economy.Rewards.Win)
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
				local expected = 1 / (1 + 10 ^ ((db.Rating - da.Rating) / 400))
				local score = if i < j then 1 else 0
				deltas[a] += rules.K * (score - expected) / math.max(#placements - 1, 1)
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
			d.Coins += Config.Economy.Rewards.Played
			d.Rating = math.max(0, math.floor(d.Rating + deltas[player] + 0.5))
			d.PeakRating = math.max(d.PeakRating, d.Rating)
			local weapon = weapons[player]
			if weapon then
				d.WeaponUses[weapon] = (d.WeaponUses[weapon] or 0) + 1
			end
			publish(player)
		end
	end
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

	-- Kill credit and coins count in matches only, so sparring in the lobby can't farm them.
	CombatService.onDied(function(_victim: Combatant, killer: Combatant?, deathblow: boolean)
		if killer and killer.player and Round.phase() == "Match" then
			StatsService.add(killer.player, "Kills", 1)
			StatsService.add(killer.player, "Coins", Config.Economy.Rewards.Kill)
			if deathblow then
				StatsService.add(killer.player, "Deathblows", 1)
				StatsService.add(killer.player, "Coins", Config.Economy.Rewards.Deathblow)
			end
		end
	end)

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
