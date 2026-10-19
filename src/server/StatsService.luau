--!strict
-- Wins and Kills: shown in the player list (leaderstats) and saved per player with
-- DataStoreService. Saves on leave, every few minutes, and on shutdown, merging with
-- UpdateAsync. If DataStores are unavailable (an unpublished place, or Studio without
-- API access) stats still work for the session and nothing errors.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatService = require(script.Parent.CombatService)
local Round = require(ReplicatedStorage.Shared.Round)

type Combatant = CombatService.Combatant
type Stats = { Wins: number, Kills: number }

local STORE_NAME = "PlayerStats_v1"
local AUTOSAVE_INTERVAL = 120
local RETRIES = 3

local StatsService = {}

local store: DataStore? = nil
local loaded: { [Player]: boolean } = {}

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

local function folder(player: Player): Folder?
	local stats = player:FindFirstChild("leaderstats")
	return if stats and stats:IsA("Folder") then stats else nil
end

local function read(player: Player): Stats
	local stats = folder(player)
	local function value(name: string): number
		local v = stats and stats:FindFirstChild(name)
		return if v and v:IsA("IntValue") then v.Value else 0
	end
	return { Wins = value("Wins"), Kills = value("Kills") }
end

local function add(player: Player, name: string, amount: number)
	local stats = folder(player)
	local v = stats and stats:FindFirstChild(name)
	if v and v:IsA("IntValue") then
		v.Value += amount
	end
end

local function save(player: Player)
	local dataStore = store
	if not dataStore or not loaded[player] then
		return -- never overwrite saved stats with a failed load's zeros
	end
	local current = read(player)
	withRetries(function()
		return dataStore:UpdateAsync(key(player), function()
			return current
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

	local dataStore = store
	if not dataStore then
		return
	end
	local ok, saved = withRetries(function()
		return dataStore:GetAsync(key(player))
	end)
	if not ok or not player.Parent then
		return
	end
	if typeof(saved) == "table" then
		add(player, "Wins", tonumber(saved.Wins) or 0)
		add(player, "Kills", tonumber(saved.Kills) or 0)
	end
	loaded[player] = true
end

function StatsService.addWin(player: Player)
	add(player, "Wins", 1)
end

function StatsService.start()
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	store = if ok then result else nil

	-- Kill credit counts in matches only, so sparring in intermission can't farm it.
	CombatService.onDied(function(_victim: Combatant, killer: Combatant?)
		if killer and killer.player and Round.phase() == "Match" then
			add(killer.player, "Kills", 1)
		end
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		save(player)
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
