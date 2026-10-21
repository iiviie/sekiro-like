--!strict
-- The match loop: Intermission (everyone in the lobby; a countdown runs while anyone is
-- queued) -> Match (queued players plus filler bots are placed in the castle courtyard; a
-- closing ring, no respawns, last one standing wins) -> Results (rewards and rating, then
-- everyone back to the lobby). Players who aren't queued stay in the lobby throughout.
-- Phase timing and the ring are published as attributes on ReplicatedStorage.RoundState
-- (see Shared/Round); eliminations and the winner go out on the RoundEvent remote.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Round = require(ReplicatedStorage.Shared.Round)
local BotService = require(script.Parent.BotService)
local CombatService = require(script.Parent.CombatService)
local LobbyService = require(script.Parent.LobbyService)
local ProgressService = require(script.Parent.ProgressService)
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
local eliminationOrder: { Player } = {} -- humans, first out first
local matchWeapons: { [Player]: string } = {}
local places: { [Player]: number } = {} -- humans' finishing place among every fighter
local fighterCount = 0
local RETURN_DELAY = 5 -- eliminated players watch for a moment, then return to the lobby

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
	if victim.model:GetAttribute("InDuel") then
		return -- DuelService brings duellists back for the next round
	end
	local phase = Round.phase()
	if phase == "Match" and participants[victim.model] then
		roundEvent:FireAllClients("Eliminated", {
			victim = displayName(victim.model),
			killer = if killer then displayName(killer.model) else nil,
			deathblow = deathblow,
		})
		local player = victim.player
		if player then
			places[player] = #aliveParticipants() + 1
			eliminated[player] = true
			table.insert(eliminationOrder, player)
			task.delay(RETURN_DELAY, function()
				if player.Character == victim.model then
					spawnPlayer(player)
				end
			end)
		end
		state:SetAttribute("Alive", #aliveParticipants())
		return
	end
	-- Outside a match players come straight back.
	local player = victim.player
	if player then
		task.delay(Config.Round.RespawnDelay, function()
			if player.Character == victim.model then
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

local function queuedPlayers(): { Player }
	local queued = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local c = character and CombatService.get(character)
		-- Only players past the title card: nobody gets dropped into a fight unseen. Anyone
		-- on a duel pad or in a duel stays there; they rejoin the queue when it's over.
		if
			LobbyService.isQueued(player)
			and player:GetAttribute("Entered")
			and player:GetAttribute("DuelState") == nil
			and c
			and c.state ~= "Dead"
		then
			table.insert(queued, player)
		end
	end
	return queued
end

local function intermission()
	table.clear(participants)
	table.clear(eliminated)
	table.clear(eliminationOrder)
	table.clear(matchWeapons)
	table.clear(places)
	BotService.setRespawn(false)
	BotService.setCount(0)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if (not humanoid or humanoid.Health <= 0) and player:GetAttribute("DuelState") ~= "Dueling" then
			spawnPlayer(player)
		end
	end

	-- The countdown only runs while someone is queued; with nobody queued it holds.
	setPhase("Intermission", Config.Round.Intermission)
	while true do
		local queued = #queuedPlayers()
		state:SetAttribute("Queued", queued)
		if queued == 0 then
			state:SetAttribute("Waiting", true)
			state:SetAttribute("EndsAt", now() + Config.Round.Intermission)
		else
			state:SetAttribute("Waiting", false)
			-- Testing aid: set workspace attribute HoldIntermission = true (Studio command
			-- bar) to stay in the lobby for practice or automated combat tests.
			if workspace:GetAttribute("HoldIntermission") then
				state:SetAttribute("EndsAt", math.max(Round.endsAt(), now() + 5))
			elseif now() >= Round.endsAt() then
				return
			end
		end
		task.wait(0.25)
	end
end

local function match()
	local queued = queuedPlayers()
	BotService.setRespawn(false)
	BotService.setTier(BotService.tierFor(queued))
	BotService.setCount(math.max(0, Config.Round.MinFighters - #queued))

	-- Queued players and the filler bots fight; place them evenly around the courtyard.
	local fighters: { Combatant } = {}
	for _, player in queued do
		local c = player.Character and CombatService.get(player.Character)
		if c then
			table.insert(fighters, c)
			matchWeapons[player] = c.weapon
		end
	end
	local bots = workspace:FindFirstChild("Bots")
	for _, model in if bots then bots:GetChildren() else {} do
		local c = model:IsA("Model") and CombatService.get(model)
		if c and c.state ~= "Dead" then
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
		if c.player then
			CombatService.setResurrections(c, Config.Resurrection.Charges)
		end
		participants[c.model] = true
		LobbyService.setInMatch(c.model, true)
	end

	-- An omen for this match, now and then.
	local omen = nil
	local list = Config.Omens.List
	-- Testing aid: workspace attribute ForceOmen = "BloodMoon" (etc.) picks it every match.
	local forced = workspace:GetAttribute("ForceOmen")
	for _, candidate in list do
		if candidate.id == forced then
			omen = candidate
		end
	end
	if not omen and math.random() < Config.Omens.Chance then
		omen = list[math.random(#list)]
	end
	workspace:SetAttribute("Omen", omen and omen.id)
	state:SetAttribute("Omen", omen and omen.id)

	local t = now()
	local center = Vector3.new(
		math.random(-zone.CenterJitter, zone.CenterJitter),
		0,
		math.random(-zone.CenterJitter, zone.CenterJitter)
	)
	state:SetAttribute("ZoneCenter", center)
	state:SetAttribute("ZoneStartRadius", zone.StartRadius)
	state:SetAttribute("ZoneEndRadius", zone.EndRadius)
	local rush = if omen and omen.id == "RushingMist" then 0.5 else 1
	state:SetAttribute("ZoneShrinkStart", t + zone.ShrinkDelay * rush)
	state:SetAttribute("ZoneShrinkEnd", t + (zone.ShrinkDelay + zone.ShrinkTime) * rush)
	state:SetAttribute("Alive", #fighters)
	fighterCount = #fighters
	ProgressService.matchStarted(queued)
	setPhase("Match", Config.Round.MaxDuration)
	roundEvent:FireAllClients("MatchStart", { fighters = #fighters, omen = omen and omen.id })

	-- Ring damage ticks until one fighter is left or time runs out. Once every human is
	-- out, nobody is watching the bots finish: end it so players get straight back in.
	local humansStarted = #queued > 0
	local tick = zone.TickInterval
	while now() < Round.endsAt() do
		local alive = aliveParticipants()
		if #alive <= 1 then
			break
		end
		local humansAlive = false
		for _, c in alive do
			if c.player then
				humansAlive = true
				break
			end
		end
		if humansStarted and not humansAlive then
			break
		end
		local ringCenter, radius = Round.zone(now())
		for _, c in alive do
			local offset = c.root.Position - ringCenter
			if Vector3.new(offset.X, 0, offset.Z).Magnitude > radius then
				CombatService.damage(c, zone.DamagePerSecond * tick)
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
	workspace:SetAttribute("Omen", nil)
	state:SetAttribute("Omen", nil)
	setPhase("Results", Config.Round.Results)
	if winner and winner.player then
		StatsService.addWin(winner.player)
	end
	-- Placements, best first: the winner, then the rest in reverse order of elimination.
	local placements: { Player } = {}
	if winner and winner.player then
		table.insert(placements, winner.player)
	end
	for _, c in aliveParticipants() do
		if c ~= winner and c.player then
			table.insert(placements, c.player)
		end
	end
	for i = #eliminationOrder, 1, -1 do
		local player = eliminationOrder[i]
		if player.Parent and not table.find(placements, player) then
			table.insert(placements, player)
		end
	end
	StatsService.recordMatch(placements, matchWeapons, if winner then winner.player else nil)
	-- Survivors (only several on a timeout) place by vitality, so the winner is first.
	local survivors = aliveParticipants()
	table.sort(survivors, function(a, b)
		return a.humanoid.Health > b.humanoid.Health
	end)
	for index, c in survivors do
		if c.player then
			places[c.player] = index
		end
	end
	ProgressService.matchEnded(places, fighterCount, if winner then winner.player else nil)
	roundEvent:FireAllClients("Victory", {
		winner = if winner then winner.model else nil,
		name = if winner then displayName(winner.model) else nil,
	})
	waitUntil(Round.endsAt())

	-- Everyone who fought goes back to the lobby with a fresh body.
	for model in participants do
		LobbyService.setInMatch(model, false)
		local player = Players:GetPlayerFromCharacter(model)
		if player then
			spawnPlayer(player)
		end
	end
	BotService.setCount(0)
end

function RoundService.start()
	Players.CharacterAutoLoads = false
	CombatService.onDied(onDied)
	CombatService.onCutDown(function(victim: Combatant, killer: Combatant?, deathblow: boolean)
		if Round.phase() == "Match" and participants[victim.model] then
			roundEvent:FireAllClients("CutDown", {
				victim = displayName(victim.model),
				killer = if killer then displayName(killer.model) else nil,
				deathblow = deathblow,
			})
		end
	end)

	Players.PlayerAdded:Connect(function(player)
		-- Everyone arrives in the lobby, even mid-match.
		spawnPlayer(player)
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
