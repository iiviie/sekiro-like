--!strict
-- The match loop: Intermission (spar with practice bots, instant respawns) -> Match
-- (everyone plus filler bots, a closing ring, no respawns, last one standing wins)
-- -> Results. Phase timing and the ring are published as attributes on
-- ReplicatedStorage.RoundState (see Shared/Round); eliminations and the winner go out
-- on the RoundEvent remote for the kill feed and banners.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Round = require(ReplicatedStorage.Shared.Round)
local BotService = require(script.Parent.BotService)
local CombatService = require(script.Parent.CombatService)
local StatsService = require(script.Parent.StatsService)

type Combatant = CombatService.Combatant
type Phase = Round.Phase

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

local roundEvent = remote("RoundEvent")

local RoundService = {}

local state = Round.state()
local participants: { [Model]: boolean } = {}
local eliminated: { [Player]: boolean } = {} -- players out of the current match

local function now(): number
	return workspace:GetServerTimeNow()
end

local function setPhase(phase: Phase, duration: number)
	state:SetAttribute("Phase", phase)
	state:SetAttribute("EndsAt", now() + duration)
end

local function displayName(model: Model?): string
	if not model then
		return "the ring"
	end
	local player = Players:GetPlayerFromCharacter(model)
	return if player then player.DisplayName else model.Name
end

local function aliveParticipants(): { Combatant }
	local alive = {}
	for model in participants do
		local c = CombatService.get(model)
		if c and c.state ~= "Dead" and c.humanoid.Health > 0 then
			table.insert(alive, c)
		end
	end
	return alive
end

local function spawnPlayer(player: Player)
	if player.Parent then
		player:LoadCharacter()
	end
end

local function onDied(victim: Combatant, killer: Combatant?, deathblow: boolean)
	local phase = Round.phase()
	if phase == "Match" and participants[victim.model] then
		roundEvent:FireAllClients("Eliminated", {
			victim = displayName(victim.model),
			killer = if killer then displayName(killer.model) else nil,
			deathblow = deathblow,
		})
		if victim.player then
			eliminated[victim.player] = true
		end
		state:SetAttribute("Alive", #aliveParticipants())
		return
	end
	-- Outside a match players come straight back.
	local player = victim.player
	if player then
		task.delay(Config.Round.RespawnDelay, function()
			if Round.phase() ~= "Match" and player.Character == victim.model then
				spawnPlayer(player)
			end
		end)
	end
end

local function waitUntil(t: number, stop: (() -> boolean)?)
	while now() < t do
		if stop and stop() then
			return
		end
		task.wait(0.25)
	end
end

local function intermission()
	setPhase("Intermission", Config.Round.Intermission)
	table.clear(participants)
	table.clear(eliminated)
	BotService.setRespawn(true)
	BotService.setCount(Config.Round.PracticeBots)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			spawnPlayer(player)
		end
	end
	waitUntil(Round.endsAt())
	-- Testing aid: set workspace attribute HoldIntermission = true (Studio command bar)
	-- to stay in intermission for practice or automated combat tests.
	while workspace:GetAttribute("HoldIntermission") do
		state:SetAttribute("EndsAt", now() + 5)
		task.wait(0.5)
	end
end

local function match()
	local players = Players:GetPlayers()
	BotService.setRespawn(false)
	BotService.setCount(math.max(0, Config.Round.MinFighters - #players))

	-- Everyone with a living character fights; place them evenly around the courtyard.
	local fighters: { Combatant } = {}
	for _, c in CombatService.all() do
		if c.state ~= "Dead" then
			table.insert(fighters, c)
		end
	end
	local zone = Config.Zone
	local spin = math.random() * math.pi * 2
	for i, c in fighters do
		local angle = spin + (i / #fighters) * math.pi * 2
		local position = Vector3.new(math.cos(angle), 0, math.sin(angle)) * Config.Round.SpawnRadius
			+ Vector3.new(0, 3, 0)
		c.model:PivotTo(CFrame.lookAt(position, Vector3.new(0, 3, 0)))
		CombatService.reset(c, 3)
		participants[c.model] = true
	end

	local t = now()
	local center = Vector3.new(
		math.random(-zone.CenterJitter, zone.CenterJitter),
		0,
		math.random(-zone.CenterJitter, zone.CenterJitter)
	)
	state:SetAttribute("ZoneCenter", center)
	state:SetAttribute("ZoneStartRadius", zone.StartRadius)
	state:SetAttribute("ZoneEndRadius", zone.EndRadius)
	state:SetAttribute("ZoneShrinkStart", t + zone.ShrinkDelay)
	state:SetAttribute("ZoneShrinkEnd", t + zone.ShrinkDelay + zone.ShrinkTime)
	state:SetAttribute("Alive", #fighters)
	setPhase("Match", Config.Round.MaxDuration)
	roundEvent:FireAllClients("MatchStart", { fighters = #fighters })

	-- Ring damage ticks until one fighter is left or time runs out.
	local tick = zone.TickInterval
	while now() < Round.endsAt() do
		local alive = aliveParticipants()
		if #alive <= 1 then
			break
		end
		local ringCenter, radius = Round.zone(now())
		for _, c in alive do
			local offset = c.root.Position - ringCenter
			if Vector3.new(offset.X, 0, offset.Z).Magnitude > radius then
				c.humanoid:TakeDamage(zone.DamagePerSecond * tick)
			end
		end
		task.wait(tick)
	end

	-- Last one standing wins; on a timeout, whoever has the most vitality.
	local winner: Combatant? = nil
	for _, c in aliveParticipants() do
		if not winner or c.humanoid.Health > (winner :: Combatant).humanoid.Health then
			winner = c
		end
	end
	return winner
end

local function results(winner: Combatant?)
	setPhase("Results", Config.Round.Results)
	if winner and winner.player then
		StatsService.addWin(winner.player)
	end
	roundEvent:FireAllClients("Victory", {
		winner = if winner then winner.model else nil,
		name = if winner then displayName(winner.model) else nil,
	})
	waitUntil(Round.endsAt())

	-- Fresh bodies for everyone before the next intermission.
	for _, player in Players:GetPlayers() do
		spawnPlayer(player)
	end
end

function RoundService.start()
	Players.CharacterAutoLoads = false
	CombatService.onDied(onDied)

	Players.PlayerAdded:Connect(function(player)
		-- Late joiners watch the current match and join the next one.
		if Round.phase() ~= "Match" then
			spawnPlayer(player)
		end
	end)
	for _, player in Players:GetPlayers() do
		if not player.Character then
			spawnPlayer(player)
		end
	end
	Players.PlayerRemoving:Connect(function(player)
		eliminated[player] = nil
	end)

	task.spawn(function()
		while true do
			intermission()
			if #Players:GetPlayers() == 0 then
				continue
			end
			local winner = match()
			results(winner)
		end
	end)
end

return RoundService
