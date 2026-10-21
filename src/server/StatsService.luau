--!strict
-- Persistent player data (the "profile"): match stats, the wallet, the inventory and loadout,
-- ranked rating, the purchase ledger and the daily counters. Saved per player with
-- DataStoreService under a session lock; published to clients as player attributes, so the
-- lobby UI reads everything without extra remotes. Wins and Kills also show in the player list.
--
-- Save safety:
--   * Session lock. Loading is an UpdateAsync that writes `Lock = { id, t }`; a profile locked
--     by another live server is retried with backoff and only taken over once its lock is
--     older than LOCK_STALE (that server stopped refreshing it). Every save refreshes the lock
--     and checks it is still ours; a lost lock stops saving for that session. Leaving and
--     shutdown release it.
--   * Schema `Version = 3`, migrated from v2 (Owned / OwnedSkins / Weapon / Skin become
--     Inventory and Loadout) and from the v1 legacy store. Unknown top-level fields and
--     inventory ids are kept, never dropped: a removed item stays saved, just hidden.
--   * A profile that fails to load leaves the player on session-only defaults with the
--     `DataFailed` attribute (the lobby shows a notice) and blocks every purchase and spend
--     (`StatsService.canTransact`). Nothing is ever written over the saved data.
--   * Studio uses an in-memory store unless ServerStorage has `UseRealDataStore = true`
--     before Play, and a session touched by test hooks or mock purchases never writes to a
--     real DataStore (`StatsService.markTest`).

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Catalog = require(ReplicatedStorage.Shared.Catalog)
local Config = require(ReplicatedStorage.Shared.Config)
local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local Progression = require(ReplicatedStorage.Shared.Progression)
local Text = require(ReplicatedStorage.Shared.Text)

export type Purchase = { k: string, t: number } -- catalogue key, when granted
export type Data = {
	Version: number,
	-- Stats.
	Wins: number, -- royale wins, bots-only matches included
	HumanWins: number, -- royale wins with at least one other human in the match
	Losses: number,
	Kills: number,
	Deathblows: number,
	Played: number, -- royales and duels: how much fighting a player has seen
	DuelWins: number,
	DuelLosses: number,
	Mikiris: number,
	Deflects: number,
	Perfects: number,
	Rating: number,
	PeakRating: number,
	XP: number, -- toward the next level
	Level: number,
	WeaponUses: { [string]: number },
	WeaponXP: { [string]: number }, -- per-weapon Mastery (evolutions, part C)
	BossClears: { [string]: number }, -- boss id -> times cleared
	BossNoHit: { [string]: number }, -- boss id -> clears without taking a hit (gold skins)
	-- Wallet.
	Coins: number,
	Gems: number,
	Whetstones: number,
	Shards: number,
	PassXP: number,
	Draws: number, -- unopened Shrine Draws
	-- Things owned and worn (Shared/Catalog ids).
	Inventory: { [string]: number }, -- id -> time acquired (unknown ids are kept)
	Loadout: { [string]: string }, -- slot -> id
	LineLevels: { [string]: number }, -- blade line id -> 1..4
	-- Daily rhythm.
	Streak: number,
	LastDaily: number, -- UTC day of the last claimed daily reward
	TrialDay: number,
	TrialProgress: { [string]: number },
	DayCounters: { [string]: number }, -- per-UTC-day caps; `day` names the day they belong to
	Opponents: { [string]: number }, -- "<userId>" -> duels today (cleared when the day changes)
	OpponentsDay: number,
	-- Monetisation.
	Purchases: { [string]: Purchase }, -- PurchaseId ledger (ProcessReceipt idempotency)
	SeasonPremium: { [string]: number }, -- season id -> time bought
	PassTierSkips: number, -- bought tier skips not yet applied (part S consumes them)
	FirstJoin: number, -- os.time of the first visit (Initiate's Bundle window)
	-- Free space for other parts' state (e.g. Ext.Pass); kept as-is.
	Ext: { [string]: any },
}

local VERSION = 3
local STORE_NAME = "PlayerData_v2" -- same store; the payload carries its Version
local LEGACY_STORE_NAME = "PlayerStats_v1" -- Wins/Kills from before the lobby
local AUTOSAVE_INTERVAL = 60
local LOCK_STALE = 240 -- a lock not refreshed for this long belongs to a dead server
local LOAD_WAITS = { 1, 2, 4, 6, 8, 10 } -- backoff between load attempts (s)
local SAVE_RETRIES = 3
local LEDGER_MAX = 200
local CLOSE_TIMEOUT = 25

local NUMBERS = {
	"Wins",
	"HumanWins",
	"Losses",
	"Kills",
	"Deathblows",
	"Played",
	"DuelWins",
	"DuelLosses",
	"Mikiris",
	"Deflects",
	"Perfects",
	"Rating",
	"PeakRating",
	"XP",
	"Level",
	"Coins",
	"Gems",
	"Whetstones",
	"Shards",
	"PassXP",
	"Draws",
	"Streak",
	"LastDaily",
	"TrialDay",
	"OpponentsDay",
	"PassTierSkips",
	"FirstJoin",
}
-- Maps of string -> number, merged entry by entry.
local NUMBER_MAPS = {
	"WeaponUses",
	"WeaponXP",
	"BossClears",
	"BossNoHit",
	"Inventory",
	"LineLevels",
	"TrialProgress",
	"DayCounters",
	"Opponents",
	"SeasonPremium",
}
local KNOWN: { [string]: boolean } = {
	Version = true,
	Lock = true,
	Loadout = true,
	Purchases = true,
	Ext = true,
	Migrated = true,
}
for _, field in NUMBERS do
	KNOWN[field] = true
end
for _, field in NUMBER_MAPS do
	KNOWN[field] = true
end

-- Player settings (client/Panels' Settings window), saved in Ext.Settings so the schema and
-- older servers carry them untouched. Name -> kind: an on/off switch or a 0..1 level.
local SETTINGS: { [string]: "switch" | "level" } = {
	SettingCameraShake = "switch",
	SettingHitstop = "switch",
	SettingControlsHint = "switch",
	SettingReducedEffects = "switch",
	SettingReduceMotion = "switch",
	SettingUIVolume = "level",
	SettingMasterVolume = "level",
	SettingMusicVolume = "level",
	SettingSFXVolume = "level",
}

local StatsService = {}

-- A DataStore-shaped store: the real one, or an in-memory one in Studio.
type Store = {
	GetAsync: (any, string) -> any,
	UpdateAsync: (any, string, (any) -> any) -> any,
	SetAsync: (any, string, any) -> any,
}

local store: Store? = nil
local legacyStore: Store? = nil
local storeIsReal = false
local session = HttpService:GenerateGUID(false) -- game.JobId is "" in Studio
local data: { [Player]: Data } = {}
local loaded: { [Player]: boolean } = {}
local failed: { [Player]: string } = {} -- why this session can't save (load failed, lock lost)
local tainted: { [Player]: boolean } = {} -- test hooks touched it: never write to a real store
local saving: { [Player]: boolean } = {}
local changedListeners: { (Player) -> () } = {}
local publishHooks: { (Player, Data) -> () } = {}
local loadedListeners: { (Player, Data) -> () } = {}
local queued: { [Player]: boolean } = {} -- a deferred publish is pending (see `republish`)
local privateSent: { [Player]: { [string]: any } } = {} -- what `setPrivate` last sent the owner
local privateRemote: RemoteEvent? = nil

-- In-memory DataStore for Studio: values are JSON round-tripped like the real thing.
local function memoryStore(): Store
	local values: { [string]: string } = {}
	local self = {}
	function self.GetAsync(_: any, key: string): any
		local raw = values[key]
		return if raw then HttpService:JSONDecode(raw) else nil
	end
	function self.UpdateAsync(_: any, key: string, transform: (any) -> any): any
		local raw = values[key]
		local new = transform(if raw then HttpService:JSONDecode(raw) else nil)
		if new == nil then
			return nil
		end
		values[key] = HttpService:JSONEncode(new)
		return HttpService:JSONDecode(values[key])
	end
	function self.SetAsync(_: any, key: string, value: any): any
		values[key] = HttpService:JSONEncode(value)
		return nil
	end
	return self :: any
end

local function key(player: Player): string
	return `player_{player.UserId}`
end

local function deepCopy<T>(value: T): T
	if typeof(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value :: any do
		out[k] = deepCopy(v)
	end
	return out :: any
end

local function fresh(): Data
	local inventory: { [string]: number } = {}
	for _, item in Catalog.Items do
		if item.default then
			inventory[item.id] = 0
		end
	end
	local loadout: { [string]: string } = table.clone(Catalog.Defaults) :: any
	return {
		Version = VERSION,
		Wins = 0,
		HumanWins = 0,
		Losses = 0,
		Kills = 0,
		Deathblows = 0,
		Played = 0,
		DuelWins = 0,
		DuelLosses = 0,
		Mikiris = 0,
		Deflects = 0,
		Perfects = 0,
		Rating = Config.Rating.Start,
		PeakRating = Config.Rating.Start,
		XP = 0,
		Level = 1,
		WeaponUses = {},
		WeaponXP = {},
		BossClears = {},
		BossNoHit = {},
		Coins = EconomyConfig.StartCoins,
		Gems = EconomyConfig.StartGems,
		Whetstones = 0,
		Shards = 0,
		PassXP = 0,
		Draws = 0,
		Inventory = inventory,
		Loadout = loadout,
		LineLevels = {},
		Streak = 0,
		LastDaily = 0,
		TrialDay = 0,
		TrialProgress = {},
		DayCounters = {},
		Opponents = {},
		OpponentsDay = 0,
		Purchases = {},
		SeasonPremium = {},
		PassTierSkips = 0,
		FirstJoin = os.time(),
		Ext = {},
	}
end

-- v2 (no Version) -> v3: weapons and skins move into the one Inventory, the equipped weapon
-- and skin into the Loadout. Every v2 field is carried over; nothing is dropped.
local function migrate(t: { [string]: any }): { [string]: any }
	local version = tonumber(t.Version) or 2
	if version >= VERSION then
		return t
	end
	local now = os.time()
	local inventory = if typeof(t.Inventory) == "table" then t.Inventory else {}
	if typeof(t.Owned) == "table" then
		for ref, owned in t.Owned do
			if owned == true and typeof(ref) == "string" then
				inventory[Catalog.idOf("weapon", ref)] = now
			end
		end
	end
	if typeof(t.OwnedSkins) == "table" then
		for ref, owned in t.OwnedSkins do
			if owned == true and typeof(ref) == "string" then
				inventory[Catalog.idOf("bladeSkin", ref)] = now
			end
		end
	end
	t.Inventory = inventory
	local loadout = if typeof(t.Loadout) == "table" then t.Loadout else {}
	if typeof(t.Weapon) == "string" then
		loadout.weapon = Catalog.idOf("weapon", t.Weapon)
	end
	if typeof(t.Skin) == "string" then
		loadout.bladeSkin = Catalog.idOf("bladeSkin", t.Skin)
	end
	t.Loadout = loadout
	t.Owned, t.OwnedSkins, t.Weapon, t.Skin = nil, nil, nil, nil
	-- v2 didn't split bot wins from human wins; the split starts now.
	t.HumanWins = tonumber(t.HumanWins) or 0
	-- The Initiate's window counts from the first visit after the update.
	t.FirstJoin = tonumber(t.FirstJoin) or now
	t.Migrated = { from = version, at = now }
	t.Version = VERSION
	return t
end

-- Merges a saved table (any version) into fresh defaults. Malformed values fall back to the
-- defaults; unknown fields and ids are kept.
local function sanitize(saved: unknown): Data
	local d = fresh()
	if typeof(saved) ~= "table" then
		return d
	end
	local t = migrate(deepCopy(saved :: any))
	for _, field in NUMBERS do
		local value = tonumber(t[field])
		if value and value == value and math.abs(value) ~= math.huge then
			(d :: any)[field] = value
		end
	end
	for _, field in NUMBER_MAPS do
		local map = t[field]
		if typeof(map) == "table" then
			local target = (d :: any)[field]
			for id, value in map do
				local n = tonumber(value)
				if typeof(id) == "string" and n and n == n then
					target[id] = n
				end
			end
		end
	end
	if typeof(t.Loadout) == "table" then
		for slot, id in t.Loadout do
			if typeof(slot) == "string" and typeof(id) == "string" then
				d.Loadout[slot] = id
			end
		end
	end
	if typeof(t.Purchases) == "table" then
		for purchaseId, entry in t.Purchases do
			if typeof(purchaseId) == "string" and typeof(entry) == "table" then
				d.Purchases[purchaseId] = { k = tostring(entry.k or "?"), t = tonumber(entry.t) or 0 }
			end
		end
	end
	if typeof(t.Ext) == "table" then
		d.Ext = t.Ext
	end
	-- Unknown top-level fields ride along untouched (a newer server may have written them).
	for field, value in t do
		if typeof(field) == "string" and not KNOWN[field] then
			(d :: any)[field] = value
		end
	end
	if typeof(t.Migrated) == "table" then
		(d :: any).Migrated = t.Migrated
	end
	-- Defaults are always owned; a loadout slot pointing at something not owned (or no longer
	-- in the catalogue) falls back to the slot's default. The inventory keeps it either way.
	for _, item in Catalog.Items do
		if item.default and not d.Inventory[item.id] then
			d.Inventory[item.id] = 0
		end
	end
	for slot, default in Catalog.Defaults do
		local id = d.Loadout[slot]
		local item = Catalog.get(id)
		local fits = id == "" or (item ~= nil and Catalog.slotOf(item) == slot and d.Inventory[id :: string] ~= nil)
		if not fits then
			d.Loadout[slot] = default
		end
	end
	d.Level = math.max(1, math.floor(d.Level))
	d.Version = VERSION
	return d
end

StatsService.sanitize = sanitize -- exposed for the migration test hook

-- What a save writes: a deep copy, the ledger trimmed to its newest entries.
local function serialize(d: Data): { [string]: any }
	local copy = deepCopy(d) :: any
	local count = 0
	for _ in copy.Purchases do
		count += 1
	end
	if count > LEDGER_MAX then
		local list = {}
		for id, entry in copy.Purchases do
			table.insert(list, { id = id, t = entry.t })
		end
		table.sort(list, function(a, b)
			return a.t > b.t
		end)
		for i = LEDGER_MAX + 1, #list do
			copy.Purchases[list[i].id] = nil
		end
	end
	return copy
end

local function joinedRefs(d: Data, category: Catalog.Category): string
	local refs = {}
	for id in d.Inventory do
		local item = Catalog.get(id)
		if item and item.category == category then
			table.insert(refs, item.ref)
		end
	end
	table.sort(refs)
	return table.concat(refs, ",")
end

local function refOf(d: Data, slot: string): string
	local item = Catalog.get(d.Loadout[slot])
	return if item then item.ref else ""
end

-- Sets a replicated attribute only when it changed.
local function put(player: Player, name: string, value: any)
	if player:GetAttribute(name) ~= value then
		player:SetAttribute(name, value)
	end
end

-- Sends a profile field to its owner only (Remotes.ProfilePrivate; client/init sets it as a
-- local attribute on the LocalPlayer, so the panels read it like any other attribute). For the
-- large per-player blobs no other client needs: player attributes replicate to everyone.
local function setPrivate(player: Player, name: string, value: any)
	local remote = privateRemote
	if not remote then
		return
	end
	local sent = privateSent[player]
	if not sent then
		sent = {}
		privateSent[player] = sent
	end
	if sent[name] == value then
		return
	end
	sent[name] = value
	remote:FireClient(player, name, value)
end

-- The cheap public attributes other code reads straight after a change (Weapon, Skin, the
-- wallet): written at once.
local function publishCore(player: Player, d: Data)
	for _, field in NUMBERS do
		put(player, field, (d :: any)[field])
	end
	-- Owned catalogue items (unknown ids stay saved but aren't shown).
	local owned = {}
	for id in d.Inventory do
		if Catalog.get(id) then
			table.insert(owned, id)
		end
	end
	table.sort(owned)
	put(player, "Inventory", table.concat(owned, ","))
	put(player, "Loadout", HttpService:JSONEncode(d.Loadout))
	put(player, "LineLevels", HttpService:JSONEncode(d.LineLevels))
	-- The runtime keys the rig, combat and older panels read.
	put(player, "Weapon", refOf(d, "weapon"))
	put(player, "Skin", refOf(d, "bladeSkin"))
	put(player, "OwnedWeapons", joinedRefs(d, "weapon"))
	put(player, "OwnedSkins", joinedRefs(d, "bladeSkin"))
	put(player, "XPToNext", Progression.xpToNext(d.Level))
	put(player, "DataLoaded", loaded[player] == true)
	put(player, "DataFailed", failed[player] ~= nil)
	put(player, "DataError", failed[player])

	local stats = player:FindFirstChild("leaderstats")
	if stats then
		for _, name in { "Wins", "Kills" } do
			local v = stats:FindFirstChild(name)
			if v and v:IsA("IntValue") then
				v.Value = (d :: any)[name]
			end
		end
	end
end

local function validSetting(name: any, value: any): boolean
	local kind = typeof(name) == "string" and SETTINGS[name]
	if kind == "switch" then
		return typeof(value) == "boolean"
	end
	return kind == "level" and typeof(value) == "number" and value >= 0 and value <= 1
end

-- The saved settings that are valid (Ext is kept as saved, so it's checked on the way out).
local function savedSettings(d: Data): { [string]: boolean | number }
	local out = {}
	local raw = d.Ext.Settings
	if typeof(raw) ~= "table" then
		return out
	end
	for name, value in raw do
		if validSetting(name, value) then
			out[name] = value
		end
	end
	return out
end

-- The owner-only blobs, the publish hooks (unlock progress walks the whole catalogue) and the
-- change listeners.
local function publishRest(player: Player, d: Data)
	setPrivate(player, "WeaponUses", HttpService:JSONEncode(d.WeaponUses))
	setPrivate(player, "TrialProgress", HttpService:JSONEncode(d.TrialProgress))
	setPrivate(player, "BossClears", HttpService:JSONEncode(d.BossClears))
	setPrivate(player, "BossNoHit", HttpService:JSONEncode(d.BossNoHit))
	setPrivate(player, "Settings", HttpService:JSONEncode(savedSettings(d)))
	for _, hook in publishHooks do
		hook(player, d)
	end
	for _, listener in changedListeners do
		task.spawn(listener, player)
	end
end

local function publish(player: Player)
	local d = data[player]
	if not d then
		return
	end
	queued[player] = nil
	publishCore(player, d)
	publishRest(player, d)
end

-- A change: the core attributes now, the rest once per player at the end of this frame's
-- step, so a burst of grants (a round's end pays 8-10 of them) publishes once.
local function republish(player: Player)
	local d = data[player]
	if not d then
		return
	end
	publishCore(player, d)
	if queued[player] then
		return
	end
	queued[player] = true
	task.defer(function()
		if queued[player] then
			queued[player] = nil
			local now = data[player]
			if now and player.Parent then
				publishRest(player, now)
			end
		end
	end)
end

-- Writes the profile, refreshing the lock (or releasing it). Returns true once the write has
-- committed. Saves of one player never overlap.
local function save(player: Player, release: boolean?): boolean
	local dataStore = store
	local d = data[player]
	if not dataStore or not loaded[player] or failed[player] or not d then
		return false -- never overwrite saved data with a failed load's defaults
	end
	if tainted[player] and storeIsReal then
		return false -- a test session never touches a real save
	end
	while saving[player] do
		task.wait()
	end
	if not data[player] then
		return false
	end
	saving[player] = true
	local snapshot = serialize(d)
	local lostTo: string? = nil
	local committed = false
	for attempt = 1, SAVE_RETRIES do
		local ok, err = pcall(function()
			dataStore:UpdateAsync(key(player), function(old: any)
				local lock = typeof(old) == "table" and old.Lock or nil
				if typeof(lock) == "table" and lock.id ~= session then
					lostTo = tostring(lock.id)
					return nil -- another server took the profile: don't write
				end
				lostTo = nil
				snapshot.Lock = if release then nil else { id = session, t = os.time() }
				return snapshot
			end)
		end)
		if ok then
			committed = lostTo == nil
			break
		end
		warn(`[StatsService] save {player.UserId} attempt {attempt}: {err}`)
		if attempt < SAVE_RETRIES then
			task.wait(attempt)
		end
	end
	saving[player] = nil
	if lostTo then
		failed[player] = "Your progress was opened in another server, so this one stopped saving. Rejoin to continue."
		warn(`[StatsService] {player.UserId}: session lock lost to {lostTo}`)
		if player.Parent then
			publish(player)
		end
	end
	return committed
end

-- Releases a lock this session wrote for a player whose load didn't finish (they left).
local function releaseLock(player: Player)
	local dataStore = store
	if not dataStore then
		return
	end
	local ok, err = pcall(function()
		dataStore:UpdateAsync(key(player), function(old: any)
			local lock = typeof(old) == "table" and old.Lock or nil
			if typeof(lock) ~= "table" or lock.id ~= session then
				return nil -- not ours (or already released): leave it
			end
			old.Lock = nil
			return old
		end)
	end)
	if not ok then
		warn(`[StatsService] release {player.UserId}: {err}`)
	end
end

-- Loads (and locks) a profile. Returns the data and nil, or nil and why it failed.
local function load(player: Player): (Data?, string?)
	local dataStore = store :: Store
	local now = os.time()
	for attempt = 1, #LOAD_WAITS + 1 do
		local result: Data? = nil
		local lockedBy: number? = nil
		local isNew = false
		local ok, err = pcall(function()
			dataStore:UpdateAsync(key(player), function(old: any)
				result, lockedBy, isNew = nil, nil, old == nil
				local lock = typeof(old) == "table" and old.Lock or nil
				if typeof(lock) == "table" and lock.id ~= session and now - (tonumber(lock.t) or 0) < LOCK_STALE then
					lockedBy = tonumber(lock.t) or 0
					return nil -- held by a live session; try again shortly
				end
				local d = sanitize(old)
				result = d
				local out = serialize(d)
				out.Lock = { id = session, t = os.time() }
				return out
			end)
		end)
		if not player.Parent then
			if ok and result then
				releaseLock(player) -- we locked it: don't leave it locked for LOCK_STALE
			end
			return nil, "left"
		end
		if ok and result then
			local d = result :: Data
			if isNew and legacyStore then
				-- First visit since the lobby update: carry over old Wins and Kills.
				local legacy = legacyStore
				local legacyOk, old = pcall(function()
					return legacy:GetAsync(key(player))
				end)
				if legacyOk and typeof(old) == "table" then
					d.Wins += tonumber(old.Wins) or 0
					d.Kills += tonumber(old.Kills) or 0
				end
			end
			return d, nil
		end
		if not ok then
			warn(`[StatsService] load {player.UserId} attempt {attempt}: {err}`)
		end
		local wait = LOAD_WAITS[attempt]
		if not wait then
			break
		end
		task.wait(wait)
		now = os.time()
		if lockedBy then
			player:SetAttribute("DataWaiting", true) -- the lobby can say "waiting for your save"
		end
	end
	return nil, Text.ProgressFailed
end

local function onPlayerAdded(player: Player)
	if data[player] then
		return
	end
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	for _, name in { "Wins", "Kills" } do
		local v = Instance.new("IntValue")
		v.Name = name
		v.Parent = stats
	end
	stats.Parent = player

	local d: Data? = nil
	local reason: string? = nil
	if store then
		d, reason = load(player)
		if reason == "left" or not player.Parent then
			if d then
				releaseLock(player) -- left during the legacy read, after the lock was written
			end
			return
		end
	else
		reason = "Saving is unavailable in this server, so this session won't be saved and purchases are off."
	end
	if d then
		loaded[player] = true
	else
		failed[player] = reason
		d = fresh()
	end
	data[player] = d :: Data
	player:SetAttribute("DataWaiting", nil)
	for _, listener in loadedListeners do
		listener(player, d :: Data)
	end
	publish(player)
end

function StatsService.get(player: Player): Data?
	return data[player]
end

-- Republishes after a caller changed the table returned by `get` directly.
function StatsService.commit(player: Player)
	republish(player)
end

-- Sends `value` (a string or number) to `player`'s client only, as a local attribute `name` on
-- their Player. For per-player data no other client needs (unlock progress, missions).
function StatsService.setPrivate(player: Player, name: string, value: any)
	setPrivate(player, name, value)
end

-- Merges settings the player picked (`changes`: { [name] = value }, from LobbyAction
-- "Settings") into the profile. Unknown names and bad values are ignored. Nothing is sent
-- back: the client already shows them (an echo could undo a pick made since), and the next
-- save writes them.
function StatsService.setSettings(player: Player, changes: unknown)
	local d = data[player]
	if not d or typeof(changes) ~= "table" then
		return
	end
	local saved = savedSettings(d)
	for name, value in changes :: { [any]: any } do
		if validSetting(name, value) then
			saved[name] = value
		end
	end
	d.Ext.Settings = saved
	local sent = privateSent[player]
	if sent then
		sent.Settings = HttpService:JSONEncode(savedSettings(d))
	end
end

-- Saves now and returns true once the write has committed (Monetization grants on this).
function StatsService.saveNow(player: Player): boolean
	return save(player, false)
end

-- Whether this session may buy or spend: the profile loaded, its lock is ours, it saves.
function StatsService.canTransact(player: Player): boolean
	return data[player] ~= nil and loaded[player] == true and failed[player] == nil
end

function StatsService.isLoaded(player: Player): boolean
	return loaded[player] == true and failed[player] == nil
end

-- Marks a session as a test session (DevHooks grants, mock purchases): it keeps working,
-- but never writes to a real DataStore.
function StatsService.markTest(player: Player)
	tainted[player] = true
end

function StatsService.usingRealStore(): boolean
	return storeIsReal
end

-- Adds to a numeric stat (negative amounts allowed) and republishes. Currencies go through
-- server/Economy (grant / spend) so they're logged and checked.
function StatsService.add(player: Player, field: string, amount: number)
	local d = data[player]
	if d and typeof((d :: any)[field]) == "number" then
		(d :: any)[field] += amount
		republish(player)
	end
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

-- A boss cleared without taking a hit (server/BossService): counts toward that boss's gold
-- skin (Catalog rule { boss, noHit }), which Economy grants on the publish.
function StatsService.recordNoHit(player: Player, bossId: string)
	local d = data[player]
	if d then
		d.BossNoHit[bossId] = (d.BossNoHit[bossId] or 0) + 1
		republish(player)
	end
end

-- The ranked soft reset between seasons (server/ShopService calls it once per player per
-- ended season, after paying that season's rewards): the rating keeps EconomyConfig
-- Ranked.SoftReset.Keep of its distance from Toward. PeakRating (all-time) is kept.
function StatsService.softResetRating(d: Data): (number, number)
	local rule = EconomyConfig.Ranked.SoftReset
	local from = d.Rating
	d.Rating = math.max(0, math.floor(rule.Toward + (from - rule.Toward) * rule.Keep + 0.5))
	return from, d.Rating
end

-- Records a finished match. `placements` lists every human participant, best first.
-- Ranked rating moves by pairwise results against the other humans you placed above or
-- below (bots never count), Elo style. A win with another human in the match also counts
-- as a HumanWin (the Wins board, titles); a win against bots only doesn't.
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
			elseif #placements >= 2 then
				d.HumanWins += 1
			end
			applyRating(d, deltas[player])
			local weapon = weapons[player]
			if weapon then
				d.WeaponUses[weapon] = (d.WeaponUses[weapon] or 0) + 1
			end
			republish(player)
		end
	end
end

-- Duels between the same two humans today, before this one (anti-farm dampening).
local duelBefore: { [Player]: number } = {}

local function countOpponent(d: Data, opponent: Player): number
	local day = EconomyConfig.day()
	if d.OpponentsDay ~= day then
		d.OpponentsDay = day
		table.clear(d.Opponents)
	end
	local id = tostring(opponent.UserId)
	local before = d.Opponents[id] or 0
	d.Opponents[id] = before + 1
	return before
end

-- How many duels `player` had already fought today against `opponent` (live duels: kills
-- pay by it before the duel is recorded).
function StatsService.duelsToday(player: Player, opponent: Player): number
	local d = data[player]
	if not d or d.OpponentsDay ~= EconomyConfig.day() then
		return 0
	end
	return d.Opponents[tostring(opponent.UserId)] or 0
end

-- The reward multiplier for the duel `player` just finished (set by recordDuel).
function StatsService.lastDuelFactor(player: Player): number
	return EconomyConfig.repeatFactor(duelBefore[player] or 0)
end

-- Records a finished duel between `winner` and `loser` (either may be nil for a bot). Both
-- humans' Played and weapon use count; rating moves only when both sides are human, as one
-- full-weight Elo result. Returns each human's rating change.
function StatsService.recordDuel(winner: Player?, loser: Player?, weapons: { [Player]: string }): { [Player]: number }
	local changes: { [Player]: number } = {}
	local dw, dl = winner and data[winner], loser and data[loser]
	if winner then
		duelBefore[winner] = 0
	end
	if loser then
		duelBefore[loser] = 0
	end
	if winner and loser and dw and dl then
		local before = { dw.Rating, dl.Rating }
		local delta = Config.Rating.K * (1 - expected(dw, dl))
		applyRating(dw, delta)
		applyRating(dl, -delta)
		changes[winner] = dw.Rating - before[1]
		changes[loser] = dl.Rating - before[2]
		duelBefore[winner] = countOpponent(dw, loser)
		duelBefore[loser] = countOpponent(dl, winner)
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
		republish(player)
	end
	count(winner, dw, true)
	count(loser, dl, false)
	return changes
end

function StatsService.onChanged(listener: (Player) -> ())
	table.insert(changedListeners, listener)
end

-- Runs inside every publish, before change listeners: lets server/Economy add attributes
-- derived from the profile (unlock progress, offers) in the same frame.
function StatsService.onPublish(hook: (Player, Data) -> ())
	table.insert(publishHooks, hook)
end

-- Runs once per player when their profile is ready (loaded, or failed to session defaults).
function StatsService.onLoaded(listener: (Player, Data) -> ())
	table.insert(loadedListeners, listener)
end

-- Studio test hook: replaces the player's saved profile in the in-memory store with `raw`
-- (any version) and reloads it through the normal lock + migration path. Refuses on a real
-- DataStore. Returns the loaded profile.
function StatsService.debugReload(player: Player, raw: { [string]: any }?): Data?
	if not RunService:IsStudio() or storeIsReal or not store then
		return nil
	end
	local dataStore = store :: Store
	if data[player] then
		save(player, true)
	end
	if raw then
		dataStore:SetAsync(key(player), raw)
	end
	data[player] = nil
	loaded[player] = nil
	failed[player] = nil
	privateSent[player] = nil -- like a rejoin: the owner gets every private field again
	local stats = player:FindFirstChild("leaderstats")
	if stats then
		stats:Destroy()
	end
	onPlayerAdded(player)
	return data[player]
end

-- Studio test hook: overwrites the saved payload in the in-memory store without reloading
-- (e.g. to plant another server's lock and check the next save refuses to write).
function StatsService.debugWriteRaw(player: Player, raw: { [string]: any }): boolean
	if not RunService:IsStudio() or storeIsReal or not store then
		return false
	end
	(store :: Store):SetAsync(key(player), raw)
	return true
end

-- Studio test hook: the raw saved payload.
function StatsService.debugRaw(player: Player): any
	if not RunService:IsStudio() or storeIsReal or not store then
		return nil
	end
	return (store :: Store):GetAsync(key(player))
end

function StatsService.start()
	local useReal = not RunService:IsStudio() or ServerStorage:GetAttribute("UseRealDataStore") == true
	if useReal then
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(STORE_NAME)
		end)
		local legacyOk, legacy = pcall(function()
			return DataStoreService:GetDataStore(LEGACY_STORE_NAME)
		end)
		if ok and result then
			store = result :: any
			storeIsReal = true
			legacyStore = if legacyOk then legacy :: any else nil
		end
	else
		store = memoryStore()
		legacyStore = nil
	end
	ReplicatedStorage:SetAttribute("SaveMode", if storeIsReal then "DataStore" elseif store then "Memory" else "None")
	local remote = Instance.new("RemoteEvent")
	remote.Name = "ProfilePrivate"
	remote.Parent = ReplicatedStorage:WaitForChild("Remotes")
	privateRemote = remote

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		save(player, true)
		data[player] = nil
		loaded[player] = nil
		failed[player] = nil
		tainted[player] = nil
		duelBefore[player] = nil
		queued[player] = nil
		privateSent[player] = nil
	end)
	game:BindToClose(function()
		local pending = 0
		for _, player in Players:GetPlayers() do
			pending += 1
			task.spawn(function()
				save(player, true)
				pending -= 1
			end)
		end
		local deadline = os.clock() + CLOSE_TIMEOUT
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL)
			for _, player in Players:GetPlayers() do
				task.spawn(save, player, false)
			end
		end
	end)
end

return StatsService
