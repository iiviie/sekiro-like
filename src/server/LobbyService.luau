--!strict
-- Lobby rules and actions. Players spawn on the lobby island, queue for the royale with the
-- PLAY button or by stepping on the glowing pad, equip and buy weapons, claim daily rewards,
-- and can opt into lobby sparring. Duel pads are DuelService's. A deflect trainer swings at whoever steps into its ring.
--
-- Client requests arrive on the LobbyAction remote as (action, argument):
--   "Queue" boolean   | "PvP" boolean | "Equip" weaponId | "Buy" weaponId | "ClaimDaily"
--   "BuySkin" skinId  | "EquipSkin" skinId
-- Everything is validated here; the client only ever asks.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Weapons = require(ReplicatedStorage.Shared.Weapons)
local CombatService = require(script.Parent.CombatService)
local ProgressService = require(script.Parent.ProgressService)
local StatsService = require(script.Parent.StatsService)
local SwordRig = require(script.Parent.SwordRig)

type Combatant = CombatService.Combatant

local LOBBY = Config.Lobby
local TRAINER_RANGE = 9
local TRAINER_INTERVAL = { 1.1, 1.9 }
local SECONDS_PER_DAY = 86400

local LobbyService = {}

-- Characters placed in a fight, and which one: "Royale", or "Duel<n>" for a duel terrace.
-- Hits only land between fighters in the same one.
local inMatch: { [Model]: string } = {}
local pvpPending: { [Player]: number } = {}

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

local function today(): number
	return math.floor(os.time() / SECONDS_PER_DAY)
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

local function claimDaily(player: Player)
	local data = StatsService.get(player)
	if not data then
		return
	end
	local day = today()
	if data.LastDaily >= day then
		return -- already claimed today
	end
	local streak = if data.LastDaily == day - 1 then data.Streak + 1 else 1
	if streak > #Config.Economy.Daily then
		streak = 1
	end
	StatsService.add(player, "Streak", streak - data.Streak)
	StatsService.add(player, "LastDaily", day - data.LastDaily)
	StatsService.add(player, "Coins", Config.Economy.Daily[streak])
	if streak == #Config.Economy.Daily then
		StatsService.add(player, "Gems", Config.Economy.DailyGems)
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
	Equip = function(player, id)
		if typeof(id) ~= "string" or not StatsService.equip(player, id) then
			return
		end
		-- Swap the blade right away if they're in the lobby.
		local character = player.Character
		local c = character and CombatService.get(character)
		if c and not inMatch[c.model] then
			CombatService.setWeapon(c, id)
		end
	end,
	Buy = function(player, id)
		if typeof(id) ~= "string" then
			return
		end
		local def = Weapons.get(id)
		local data = StatsService.get(player)
		if def.id ~= id or not data or data.Owned[id] then
			return
		end
		if StatsService.spend(player, "Coins", def.price) then
			StatsService.grantWeapon(player, id)
		end
	end,
	ClaimDaily = function(player)
		claimDaily(player)
	end,
	BuySkin = function(player, id)
		if typeof(id) == "string" and ProgressService.buySkin(player, id) and player.Character then
			SwordRig.applySkin(player.Character)
		end
	end,
	EquipSkin = function(player, id)
		if typeof(id) == "string" and ProgressService.equipSkin(player, id) and player.Character then
			SwordRig.applySkin(player.Character)
		end
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
		if handler then
			handler(player, argument)
		end
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
