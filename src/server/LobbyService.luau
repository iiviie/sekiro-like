--!strict
-- Lobby rules and actions. Players spawn on the lobby island, queue for the royale with the
-- PLAY button or by stepping on the glowing pad, equip and buy weapons, claim daily rewards,
-- and can opt into lobby sparring. Duel pads are DuelService's. A deflect trainer swings at whoever steps into its ring.
--
-- Client requests arrive on the LobbyAction remote as (action, argument):
--   "Queue" boolean | "PvP" boolean | "ClaimDaily"
--   "BuyItem" catalogId    buy with coins or gems (server/Economy.buy)
--   "EquipItem" catalogId  put an owned item in its slot (a title: "title.X", or "title." for none)
--   "EquipTitle2" catalogId  the second title slot (pass.TitleSlot): "title.X", or "title." for none
--   "UpgradeLine" catalogId  raise an owned blade line one level with Whetstones
--                 (or { id, gems = n }: n of the level's Whetstones paid in gems, capped)
--   "Purchase" productKey  prompt a Robux purchase (server/Monetization.prompt)
-- Everything is validated here; the client only ever asks. Requests are rate-limited per
-- player (a token bucket), so spamming equips can't flood the rig or the attributes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Catalog = require(ReplicatedStorage.Shared.Catalog)
local Config = require(ReplicatedStorage.Shared.Config)
local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local CombatService = require(script.Parent.CombatService)
local Economy = require(script.Parent.Economy)
local Monetization = require(script.Parent.Monetization)
local StatsService = require(script.Parent.StatsService)
local SwordRig = require(script.Parent.SwordRig)

type Combatant = CombatService.Combatant

local LOBBY = Config.Lobby
local TRAINER_RANGE = 9
local TRAINER_INTERVAL = { 1.1, 1.9 }
-- LobbyAction rate limit: a bucket of BURST requests refilling at RATE per second.
local BURST = 8
local RATE = 3

local LobbyService = {}

-- Characters placed in a fight, and which one: "Royale", or "Duel<n>" for a duel terrace.
-- Hits only land between fighters in the same one.
local inMatch: { [Model]: string } = {}
local pvpPending: { [Player]: number } = {}
local buckets: { [Player]: { tokens: number, at: number } } = {}

local function remote(name: string): RemoteEvent
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local existing = remotes:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local created = Instance.new("RemoteEvent")
	created.Name = name
	created.Parent = remotes
	return created
end

-- Takes one request token; false when the player is over the rate limit.
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

-- Lobby characters with sparring off are "Safe": no one but the trainer can touch them,
-- and they can't hit other players either.
local function refreshSafe(player: Player)
	local character = player.Character
	if character then
		local safe = not inMatch[character] and player:GetAttribute("LobbyPvP") ~= true
		character:SetAttribute("Safe", safe)
	end
end

function LobbyService.isQueued(player: Player): boolean
	return player:GetAttribute("Queued") == true
end

local function setArena(model: Model, arena: string?)
	inMatch[model] = arena
	-- Replicated so every client can tell who shares its fight (Shared/Spacing).
	model:SetAttribute("Arena", arena)
	local player = Players:GetPlayerFromCharacter(model)
	if player then
		refreshSafe(player)
	end
end

function LobbyService.setInMatch(model: Model, value: boolean)
	model:SetAttribute("InMatch", value)
	setArena(model, if value then "Royale" else nil)
end

-- Puts a fighter on duel terrace `ground` (nil takes them off). Duellists carry the InDuel
-- attribute instead of InMatch, so the royale HUD and its ring leave them alone.
function LobbyService.setInDuel(model: Model, ground: number?)
	model:SetAttribute("InDuel", ground ~= nil)
	setArena(model, if ground then `Duel{ground}` else nil)
end

-- Puts a fighter (the player or the boss) in boss arena `arena` (nil takes them off). They
-- carry InDuel too, so everything that treats a duel as a real fight (the HUD, music, Coach,
-- kill credit) treats a boss fight the same way; InBoss tells the two apart.
function LobbyService.setInBoss(model: Model, arena: number?)
	model:SetAttribute("InDuel", arena ~= nil)
	model:SetAttribute("InBoss", arena ~= nil)
	setArena(model, if arena then `Boss{arena}` else nil)
end

-- Layout points published by LobbyBuilder on Workspace.Lobby.
local function point(name: string): Vector3
	local lobby = workspace:FindFirstChild("Lobby")
	local value = lobby and lobby:GetAttribute(name)
	return if typeof(value) == "Vector3" then value else LOBBY.Origin + Vector3.new(0, 2, 0)
end

function LobbyService.spawnCFrame(): CFrame
	local pad = point("QueuePad")
	local spawn = point("SpawnPoint")
	return CFrame.lookAt(spawn + Vector3.new(0, 3, 0), Vector3.new(pad.X, spawn.Y + 3, pad.Z))
end

-- One claim per UTC day. A missed day pauses the streak (no reset); after the last day the
-- week starts again at day 1. The last day also pays gems and Whetstones.
local function claimDaily(player: Player)
	local data = StatsService.get(player)
	if not data then
		return
	end
	local streak, claimed = Economy.dailyNext(data)
	if claimed then
		return -- already claimed today
	end
	local daily = EconomyConfig.Daily
	data.Streak = streak
	data.LastDaily = EconomyConfig.day()
	Economy.grant(player, "Coins", daily.Coins[streak], `Daily day {streak}`, "TimedReward", true)
	if streak == #daily.Coins then
		Economy.grant(player, "Gems", daily.LastDayGems, `Daily day {streak}`, "TimedReward", true)
		Economy.grant(player, "Whetstones", daily.LastDayWhetstones, `Daily day {streak}`, "TimedReward", true)
	end
	StatsService.commit(player)
end

-- Puts the equipped weapon and blade on the character when they're in the lobby.
local function dressInLobby(player: Player, slot: string)
	local character = player.Character
	if not character then
		return
	end
	if slot == "weapon" then
		local c = CombatService.get(character)
		local weapon = player:GetAttribute("Weapon")
		if c and not inMatch[c.model] and typeof(weapon) == "string" then
			CombatService.setWeapon(c, weapon)
		end
	elseif slot == "bladeSkin" then
		SwordRig.applySkin(character)
	end
end

local handlers: { [string]: (Player, unknown) -> () } = {
	Queue = function(player, value)
		player:SetAttribute("Queued", value == true)
	end,
	PvP = function(player, value)
		if value ~= true then
			pvpPending[player] = nil
			player:SetAttribute("LobbyPvP", false)
			refreshSafe(player)
			return
		end
		-- Turning sparring on takes a moment, so it can't be flicked on mid-ambush.
		local token = os.clock()
		pvpPending[player] = token
		player:SetAttribute("LobbyPvP", "Pending")
		task.delay(LOBBY.PvPToggleDelay, function()
			if pvpPending[player] == token then
				pvpPending[player] = nil
				player:SetAttribute("LobbyPvP", true)
				refreshSafe(player)
			end
		end)
	end,
	EquipItem = function(player, id)
		if typeof(id) ~= "string" then
			return
		end
		if id == "title." then
			Economy.equip(player, "title", "")
			return
		end
		local item = Catalog.get(id)
		local slot = item and Catalog.slotOf(item)
		if slot and Economy.equip(player, slot, id) then
			dressInLobby(player, slot)
		end
	end,
	EquipTitle2 = function(player, id)
		-- The second title slot: "title.X", or "title." to clear it. Needs pass.TitleSlot.
		if typeof(id) ~= "string" then
			return
		end
		Economy.equipTitle2(player, if id == "title." then "" else id, Monetization.ownsPass(player, "pass.TitleSlot"))
	end,
	BuyItem = function(player, id)
		if typeof(id) ~= "string" then
			return
		end
		local ok = Economy.buy(player, id)
		local item = Catalog.get(id)
		if ok and item and item.category == "bladeSkin" then
			dressInLobby(player, "bladeSkin")
		end
	end,
	UpgradeLine = function(player, arg)
		-- "line.X", or { id = "line.X", gems = n } to cover up to half the level with gems.
		if typeof(arg) == "string" then
			Economy.upgradeLine(player, arg)
		elseif typeof(arg) == "table" then
			local request = arg :: any
			if typeof(request.id) == "string" then
				Economy.upgradeLine(player, request.id, if typeof(request.gems) == "number" then request.gems else nil)
			end
		end
	end,
	Purchase = function(player, key)
		if typeof(key) == "string" then
			Monetization.prompt(player, key)
		end
	end,
	ClaimDaily = function(player)
		claimDaily(player)
	end,
}

-- The deflect trainer: a training dummy that faces whoever stands in its ring and swings
-- at them on an uneven rhythm, with the odd perilous thrust. It never deals damage.
local function trainer()
	local description = Instance.new("HumanoidDescription")
	description.HeadColor = Color3.fromRGB(140, 120, 96)
	description.TorsoColor = Color3.fromRGB(150, 128, 98)
	description.LeftArmColor = description.HeadColor
	description.RightArmColor = description.HeadColor
	description.LeftLegColor = Color3.fromRGB(110, 92, 72)
	description.RightLegColor = description.LeftLegColor
	local model = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	model.Name = "Deflect Trainer"
	model:SetAttribute("Trainer", true)
	local home = point("TrainerHome") + Vector3.new(0, 3, 0)
	model:PivotTo(CFrame.new(home))
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
	root.Anchored = true
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	humanoid.MaxHealth = 1e6
	humanoid.Health = 1e6
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	model.Parent = workspace:FindFirstChild("Lobby") or workspace
	local c = CombatService.register(model, nil)
	if not c then
		return
	end
	c.protectedUntil = 0

	task.spawn(function()
		local count = 0
		while model.Parent and humanoid.Health > 0 do
			task.wait(TRAINER_INTERVAL[1] + math.random() * (TRAINER_INTERVAL[2] - TRAINER_INTERVAL[1]))
			humanoid.Health = humanoid.MaxHealth
			local nearest: BasePart? = nil
			local best = TRAINER_RANGE
			for _, player in Players:GetPlayers() do
				local character = player.Character
				local other = character and character:FindFirstChild("HumanoidRootPart")
				if other and other:IsA("BasePart") and not inMatch[character :: Model] then
					local distance = (other.Position - root.Position).Magnitude
					if distance < best then
						best, nearest = distance, other
					end
				end
			end
			if nearest then
				local flat = Vector3.new(nearest.Position.X, root.Position.Y, nearest.Position.Z)
				root.CFrame = CFrame.lookAt(root.Position, flat)
				count += 1
				local action = if count % 6 == 0 then "Perilous" else "Attack"
				CombatService.perform(c, action, workspace:GetServerTimeNow())
			end
		end
	end)
	humanoid.Died:Once(function()
		task.delay(2, function()
			model:Destroy()
			trainer()
		end)
	end)
end

function LobbyService.start()
	local lobbyAction = remote("LobbyAction")
	lobbyAction.OnServerEvent:Connect(function(player, action: unknown, argument: unknown)
		local handler = typeof(action) == "string" and handlers[action :: string]
		if handler and allow(player) then
			handler(player, argument)
		end
	end)

	-- A profile can finish loading after the character spawned: put its weapon and blade on.
	StatsService.onLoaded(function(player)
		task.defer(function()
			dressInLobby(player, "weapon")
			dressInLobby(player, "bladeSkin")
		end)
	end)

	local function onPlayerAdded(player: Player)
		player:SetAttribute("Queued", LOBBY.AutoQueue)
		player:SetAttribute("LobbyPvP", false)
		player.CharacterAdded:Connect(function(character)
			inMatch[character] = nil
			refreshSafe(player)
		end)
		if player.Character then
			refreshSafe(player)
		end
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		pvpPending[player] = nil
		buckets[player] = nil
	end)

	-- The arena and the lobby never touch: hits only land between two fighters in the
	-- match, or between two lobby fighters who both opted into sparring, or to and from
	-- the trainer.
	CombatService.setHitFilter(function(attacker: Combatant, target: Combatant)
		if inMatch[attacker.model] or inMatch[target.model] then
			return inMatch[attacker.model] == inMatch[target.model]
		end
		if attacker.model:GetAttribute("Trainer") or target.model:GetAttribute("Trainer") then
			return true
		end
		local function sparring(c: Combatant): boolean
			-- Bots outside a match (none today) count as sparring partners.
			return c.player == nil or c.player:GetAttribute("LobbyPvP") == true
		end
		return sparring(attacker) and sparring(target)
	end)

	trainer()

	-- Stepping onto the glowing pad queues you; falling off the island puts you back.
	local padCenter = point("QueuePad")
	RunService.Heartbeat:Connect(function()
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") and not inMatch[character :: Model] then
				local offset = root.Position - padCenter
				if
					not LobbyService.isQueued(player)
					and Vector3.new(offset.X, 0, offset.Z).Magnitude <= LOBBY.QueuePadRadius
					and math.abs(offset.Y) < 6
				then
					player:SetAttribute("Queued", true)
				end
				if root.Position.Y < LOBBY.FallY then
					root.AssemblyLinearVelocity = Vector3.zero;
					(character :: Model):PivotTo(LobbyService.spawnCFrame())
				end
			end
		end
	end)
end

return LobbyService
