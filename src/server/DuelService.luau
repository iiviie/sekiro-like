--!strict
-- 1v1 duels (一騎討) from the lobby's duel pads. Posture combat reads best one on one, and a
-- duel needs no queue: two players standing on a facing pair of pads start a duel at once,
-- and a lone player gets a bot (matched to their experience) after Config.Duel.BotWait.
--
-- A duel is first to Config.Duel.FirstTo rounds on the pair's fenced terrace, which floats
-- beside the island. Each round both fighters start on their marks, full and protected for
-- a short countdown; the first to fall loses the round (no resurrection), and a stalled
-- round goes to whoever has more vitality. Fallen players get a fresh body for the next
-- round. Afterwards both go back to the lobby with their rewards: XP, coins and trials as in
-- the royale (ProgressService), duel wins and losses, and between two humans an Elo result
-- on the ranked rating (StatsService.recordDuel).
--
-- Player attribute DuelState: "Waiting" on a pad, "Dueling" in a duel, nil otherwise
-- (RoundService leaves both out of the royale queue). DuelBotAt: server time a waiting
-- player's bot steps in. Duellists' characters carry InDuel (LobbyService.setInDuel).
--
-- Remote (server -> one client), ReplicatedStorage.Remotes.Duel, scores from that player's
-- side:
--   "Start" { opponent, firstTo, rated }
--   "Round" { round, mine, theirs, fightAt }
--   "Point" { you, name, mine, theirs, reason }   reason: "Fell" | "Time" | "Forfeit" | "Draw"
--   "End"   { won, mine, theirs, opponent, rating? }

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local BotService = require(script.Parent.BotService)
local CombatService = require(script.Parent.CombatService)
local LobbyService = require(script.Parent.LobbyService)
local ProgressService = require(script.Parent.ProgressService)
local StatsService = require(script.Parent.StatsService)

type Combatant = CombatService.Combatant

type Side = {
	player: Player?, -- nil for the bot
	c: Combatant?, -- this round's body
	name: string,
	wins: number,
}

type Ground = {
	index: number,
	pads: { Vector3 },
	arena: Vector3,
	status: TextLabel?,
	waiting: { [number]: Player }, -- pad index -> who stands on it
	loneSince: number?,
	busy: boolean,
}

local DUEL = Config.Duel
local TICK = 0.2
local WATCH_TICK = 0.1
local RESPAWN_TIMEOUT = 10

local DuelService = {}

local grounds: { Ground } = {}
local remote: RemoteEvent

local function now(): number
	return workspace:GetServerTimeNow()
end

local function alive(c: Combatant?): boolean
	return c ~= nil and CombatService.get(c.model) == c and c.state ~= "Dead"
end

local function setStatus(ground: Ground, text: string)
	local label = ground.status
	if label and label.Text ~= text then
		label.Text = text
	end
end

-- Each side's mark on the terrace, facing the other.
local function mark(ground: Ground, side: number): CFrame
	local offset = Vector3.new((if side == 1 then -1 else 1) * DUEL.StartDistance / 2, 3, 0)
	local position = ground.arena + offset
	return CFrame.lookAt(position, ground.arena + Vector3.new(0, 3, 0))
end

local function send(side: Side, kind: string, data: { [string]: any })
	local player = side.player
	if player and player.Parent then
		remote:FireClient(player, kind, data)
	end
end

-- A player who may take a pad: past the title card, alive in the lobby, and not already
-- waiting on another pad or fighting somewhere.
local function eligible(player: Player, ground: Ground): boolean
	local character = player.Character
	local c = character and CombatService.get(character)
	if not player:GetAttribute("Entered") or not alive(c) then
		return false
	end
	local model = (c :: Combatant).model
	if model:GetAttribute("InMatch") or model:GetAttribute("InDuel") then
		return false
	end
	local state = player:GetAttribute("DuelState")
	if state == "Dueling" then
		return false
	end
	if state == "Waiting" then
		return table.find(ground.waiting, player) ~= nil
	end
	return true
end

local function onPad(player: Player, pad: Vector3): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	local offset = root.Position - pad
	return Vector3.new(offset.X, 0, offset.Z).Magnitude <= DUEL.PadRadius and math.abs(offset.Y) < 6
end

-- This round's body for a player: the living one, or a fresh one if they fell last round.
-- Nil if they left.
local function bodyOf(player: Player): Combatant?
	local character = player.Character
	local c = character and CombatService.get(character)
	if alive(c) then
		return c
	end
	if not player.Parent then
		return nil
	end
	player:LoadCharacter()
	local deadline = os.clock() + RESPAWN_TIMEOUT
	while os.clock() < deadline and player.Parent do
		local fresh = player.Character and CombatService.get(player.Character)
		if alive(fresh) then
			return fresh
		end
		task.wait(0.1)
	end
	return nil
end

local function present(side: Side): boolean
	return side.player == nil or (side.player :: Player).Parent ~= nil
end

local function runDuel(ground: Ground, players: { Player })
	ground.busy = true
	table.clear(ground.waiting)
	ground.loneSince = nil

	local sides: { Side } = {}
	local humans: { Player } = {}
	local weapons: { [Player]: string } = {}
	for _, player in players do
		player:SetAttribute("DuelState", "Dueling")
		player:SetAttribute("DuelBotAt", nil)
		table.insert(humans, player)
		table.insert(sides, { player = player, c = nil, name = player.DisplayName, wins = 0 })
		local c = player.Character and CombatService.get(player.Character)
		if c then
			weapons[player] = c.weapon
		end
	end
	-- A lone player's bot follows their experience, like the royale's fillers.
	local botTier = BotService.tierFor(humans)
	if #sides == 1 then
		table.insert(sides, { player = nil, c = nil, name = "", wins = 0 })
	end
	local rated = #humans == 2
	ProgressService.matchStarted(humans)

	local function other(i: number): Side
		return sides[3 - i]
	end
	local function score(i: number): (number, number)
		return sides[i].wins, other(i).wins
	end

	local forfeit: Side? = nil -- the side that left
	local round = 0
	while sides[1].wins < DUEL.FirstTo and sides[2].wins < DUEL.FirstTo do
		round += 1

		-- Bodies: humans first, so a bot (new or surviving) can be pointed at its foe. Last
		-- round's fallen bodies leave the terrace's hit rule.
		local previous = { sides[1].c, sides[2].c }
		for _, side in sides do
			if side.player then
				side.c = bodyOf(side.player :: Player)
				if not side.c then
					forfeit = side
				end
			end
		end
		if forfeit then
			break
		end
		for i, side in sides do
			if not side.player then
				local foe = other(i).c :: Combatant
				if alive(side.c) then
					BotService.setFoe(side.c :: Combatant, foe)
				else
					local name = if side.name ~= "" then side.name else nil
					side.c =
						BotService.spawnDuelist(botTier, mark(ground, i), foe, ground.arena, DUEL.ArenaRadius, name)
					if not side.c then
						forfeit = side
						break
					end
					side.name = (side.c :: Combatant).model.Name
				end
			end
		end
		for i, old in previous do
			if old and old ~= sides[i].c then
				LobbyService.setInDuel(old.model, nil)
			end
		end
		if forfeit then
			break
		end
		if round == 1 then
			for i, side in sides do
				send(side, "Start", { opponent = other(i).name, firstTo = DUEL.FirstTo, rated = rated })
			end
		end

		-- Both on their marks, fresh and protected through the countdown.
		local fightAt = now() + DUEL.RoundCountdown
		for i, side in sides do
			local c = side.c :: Combatant
			LobbyService.setInDuel(c.model, ground.index)
			c.root.AssemblyLinearVelocity = Vector3.zero
			c.model:PivotTo(mark(ground, i))
			CombatService.reset(c, DUEL.RoundCountdown) -- also clears resurrections: one life a round
			local mine, theirs = score(i)
			local foe = other(i).c
			send(side, "Round", {
				round = round,
				mine = mine,
				theirs = theirs,
				fightAt = fightAt,
				foe = if foe then foe.model else nil, -- the client locks on to them
			})
		end
		setStatus(ground, `{sides[1].name}  {sides[1].wins} - {sides[2].wins}  {sides[2].name}`)

		-- The round: until someone falls, leaves, or time runs out.
		local roundEnds = fightAt + DUEL.MaxRoundTime
		local winner: number? = nil
		local reason = "Fell"
		while true do
			task.wait(WATCH_TICK)
			for _, side in sides do
				if not present(side) then
					forfeit = side
				end
			end
			if forfeit then
				break
			end
			local up1, up2 = alive(sides[1].c), alive(sides[2].c)
			if not up1 or not up2 then
				winner = if up1 then 1 elseif up2 then 2 else nil
				reason = if winner then "Fell" else "Draw"
				break
			end
			if now() >= roundEnds then
				local function vitality(side: Side): number
					local humanoid = (side.c :: Combatant).humanoid
					return humanoid.Health / math.max(humanoid.MaxHealth, 1)
				end
				local v1, v2 = vitality(sides[1]), vitality(sides[2])
				winner = if v1 > v2 then 1 elseif v2 > v1 then 2 else nil
				reason = if winner then "Time" else "Draw"
				break
			end
			-- The fence should hold everyone, but a launch can still clear it.
			for i, side in sides do
				local c = side.c :: Combatant
				if c.root.Position.Y < ground.arena.Y - DUEL.FallDepth then
					c.root.AssemblyLinearVelocity = Vector3.zero
					c.model:PivotTo(mark(ground, i))
				end
			end
		end
		if forfeit then
			break
		end

		if winner then
			sides[winner].wins += 1
		end
		for i, side in sides do
			local mine, theirs = score(i)
			send(side, "Point", {
				you = winner == i,
				name = if winner then sides[winner].name else nil,
				mine = mine,
				theirs = theirs,
				reason = reason,
			})
		end
		setStatus(ground, `{sides[1].name}  {sides[1].wins} - {sides[2].wins}  {sides[2].name}`)
		-- Nobody can be hit while the point sinks in (the survivor stands, the fallen lies).
		for _, side in sides do
			if alive(side.c) then
				(side.c :: Combatant).protectedUntil = math.huge
			end
		end
		task.wait(DUEL.RoundGap)
	end

	-- The result. A side that left forfeits; a bot leaving (it can't) would void the duel.
	local winnerIndex: number? = nil
	if forfeit then
		winnerIndex = if forfeit == sides[1] then 2 else 1
	elseif sides[1].wins >= DUEL.FirstTo then
		winnerIndex = 1
	else
		winnerIndex = 2
	end
	local winnerSide = sides[winnerIndex]
	local loserSide = other(winnerIndex)
	local winnerPlayer = winnerSide.player
	local loserPlayer = if loserSide.player and (loserSide.player :: Player).Parent then loserSide.player else nil
	local changes = StatsService.recordDuel(winnerPlayer, loserPlayer, weapons)
	local results: { [Player]: ProgressService.DuelResult } = {}
	for i, side in sides do
		local player = side.player
		if player and player.Parent then
			local mine, theirs = score(i)
			local won = i == winnerIndex
			if forfeit then
				send(side, "Point", { you = true, name = side.name, mine = mine, theirs = theirs, reason = "Forfeit" })
			end
			results[player] = {
				won = won,
				rounds = mine,
				score = `{mine} - {theirs}`,
				opponent = other(i).name,
				rating = changes[player],
			}
			send(side, "End", {
				won = won,
				mine = mine,
				theirs = theirs,
				opponent = other(i).name,
				rating = changes[player],
			})
		end
	end
	ProgressService.duelEnded(results)
	setStatus(
		ground,
		`{winnerSide.name} wins  {math.max(sides[1].wins, sides[2].wins)} - {math.min(sides[1].wins, sides[2].wins)}`
	)
	for _, side in sides do
		if alive(side.c) then
			(side.c :: Combatant).protectedUntil = math.huge
		end
	end
	task.wait(DUEL.Results)

	-- Back to the lobby with a fresh body; the bot is cleared away.
	for _, side in sides do
		local c = side.c
		if c then
			LobbyService.setInDuel(c.model, nil)
		end
		local player = side.player
		if player then
			player:SetAttribute("DuelState", nil)
			if player.Parent then
				player:LoadCharacter()
			end
		elseif c and c.model.Parent then
			c.model:Destroy()
		end
	end
	ground.busy = false
end

-- Pads: who is standing where, and whether that starts a duel.
local function updateGround(ground: Ground)
	if ground.busy then
		return
	end
	local t = now()
	for slot, pad in ground.pads do
		local current = ground.waiting[slot]
		if current and not (current.Parent and eligible(current, ground) and onPad(current, pad)) then
			ground.waiting[slot] = nil
			if current.Parent and current:GetAttribute("DuelState") == "Waiting" then
				current:SetAttribute("DuelState", nil)
				current:SetAttribute("DuelBotAt", nil)
			end
		end
		if not ground.waiting[slot] then
			for _, player in Players:GetPlayers() do
				if player:GetAttribute("DuelState") == nil and eligible(player, ground) and onPad(player, pad) then
					ground.waiting[slot] = player
					player:SetAttribute("DuelState", "Waiting")
					break
				end
			end
		end
	end

	local a, b = ground.waiting[1], ground.waiting[2]
	if a and b then
		task.spawn(runDuel, ground, { a, b })
		return
	end
	local lone = a or b
	if not lone then
		ground.loneSince = nil
		setStatus(ground, `Step on a pad  ·  first to {DUEL.FirstTo}`)
		return
	end
	ground.loneSince = ground.loneSince or t
	local botAt = (ground.loneSince :: number) + DUEL.BotWait
	lone:SetAttribute("DuelBotAt", botAt)
	if t >= botAt then
		task.spawn(runDuel, ground, { lone })
		return
	end
	setStatus(ground, `{lone.DisplayName} awaits a challenger  ·  bot in {math.ceil(botAt - t)}`)
end

function DuelService.start()
	remote = Instance.new("RemoteEvent")
	remote.Name = "Duel"
	remote.Parent = ReplicatedStorage:WaitForChild("Remotes")

	local folder = workspace:WaitForChild("Lobby"):WaitForChild("DuelGrounds")
	for i = 1, #folder:GetChildren() do
		local holder = folder:FindFirstChild(`Ground{i}`)
		if holder then
			local sign = holder:FindFirstChild("Sign")
			local label = sign and sign:FindFirstChild("Label")
			local status = label and label:FindFirstChild("Status")
			table.insert(grounds, {
				index = i,
				pads = { holder:GetAttribute("PadA") :: Vector3, holder:GetAttribute("PadB") :: Vector3 },
				arena = holder:GetAttribute("Arena") :: Vector3,
				status = if status and status:IsA("TextLabel") then status else nil,
				waiting = {},
				loneSince = nil,
				busy = false,
			})
		end
	end

	task.spawn(function()
		while true do
			for _, ground in grounds do
				updateGround(ground)
			end
			task.wait(TICK)
		end
	end)
end

return DuelService
