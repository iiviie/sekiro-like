--!strict
-- Boss trials (試練): Kannagi Usagi's nine bosses as one-on-one fights. Step on the shrine
-- pad on the back islet, pick a boss (BossHUD), and fight it on the boss terrace floating
-- behind the island. The boss's brain is server/BossAI (its decoded Kannagi deck and step
-- scripts); its stats, weapon and look are Shared/Bosses; every blow goes through
-- CombatService like any other.
--
-- A fight: both on their marks through a countdown; you have one resurrection (Kannagi's
-- player ZP 2) and your gourd; the boss has two lives: the first deathblow starts phase 2
-- (Kannagi's phase-2 vitality and posture, its phase-2 patterns, an opener), the second
-- ends it. Vitality 0 breaks its posture (a deathblow is always the finisher). The
-- tutorial trainer (Enemy03, Shikigami) runs Kannagi's staged lessons: attack, deflect,
-- double deflect, jump, Mikiri, then two real lives.
--
-- Player attribute DuelState = "Boss" while fighting (keeps you out of the royale queue).
-- Bodies in the fight carry InDuel + InBoss (LobbyService.setInBoss) and share the arena's
-- hit rule. Boss model attributes: Boss (id), BossLives, BossPhase.
--
-- Remote (ReplicatedStorage.Remotes.Boss):
--   server -> client: "Pick" { bosses = { { id, name, nameJP, stars, cleared, blurb } },
--                              busy = { player, boss }?, line = position? }
--                     "Start" { boss, name, nameJP, stars, model, fightAt, lives }
--                     "Phase" { phase, lives, stage?, lesson? }
--                     "End" { won, boss, name, stars, time, firstClear, noHit }  (or { left = true, ... } when a
--                              fight ends without a result: BossTest "stop", the player leaving)
--                     "Notice" { text, kind, line? }   kind: "Refused" | "Line" | "Turn" | "Failed"
--                              (every Choose gets a Start or a Notice; a "Line" notice carries
--                              your place in line, none when you're out of it)
--                     "Intro" { mode, at, endsAt, fighters = { { model, intro, name } }, skip } before
--                              the countdown: you and the boss frozen and protected while each
--                              plays its pre-fight intro (Shared/Intros); "IntroEnd" { } if skipped
--   client -> server: "Choose" bossId | "Cancel" (leave the line) | "SkipIntro" (only once
--                     you've seen that boss's intro: a clear, or earlier this session)
--
-- One arena, one fight at a time: choosing while it's taken puts you in line, and your
-- trial starts by itself when the fight before yours ends (wherever you are in the lobby).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Bosses = require(ReplicatedStorage.Shared.Bosses)
local Catalog = require(ReplicatedStorage.Shared.Catalog)
local Config = require(ReplicatedStorage.Shared.Config)
local Intros = require(ReplicatedStorage.Shared.Intros)
local Weapons = require(ReplicatedStorage.Shared.Weapons)
local BossAI = require(script.Parent.BossAI)
local CombatService = require(script.Parent.CombatService)
local Economy = require(script.Parent.Economy)
local Locomotion = require(script.Parent.Locomotion)
local LobbyService = require(script.Parent.LobbyService)
local Outfit = require(script.Parent.Outfit)
local ProgressService = require(script.Parent.ProgressService)
local StatsService = require(script.Parent.StatsService)

type Combatant = CombatService.Combatant

export type Fight = {
	id: string,
	def: Bosses.BossDef,
	player: Player,
	pc: Combatant, -- the player's body
	boss: Combatant,
	brain: BossAI.Brain,
	fightAt: number,
	lives: number, -- deathblows landed on the boss
	down: boolean, -- the player is cut down (will rise)
	placed: boolean, -- the player was moved to the arena (gets a fresh body afterwards)
	result: string?, -- "Won" | "Lost" | "Left"
	tally: { [string]: number }, -- outcomes of blows involving the boss (tests)
	hit: boolean?, -- the player lost health after the countdown (no gold skin this time)
	hitWatch: RBXScriptConnection?,
}

local RULES = Config.Bosses
local TICK = 0.1
local PICK_COOLDOWN = 2
-- The picker stays usable a few steps off the pad (players overshoot it): a Choose counts
-- from this far, if the picker was opened in the last PICK_GRACE seconds.
local PICK_REACH = 12
local PICK_GRACE = 90

local BossService = {}

local remote: RemoteEvent
local arena: Vector3 = Vector3.zero
local pad: Vector3 = Vector3.zero
local padRadius = 4
local status: TextLabel? = nil
local fight: Fight? = nil
local testGod: { [Player]: boolean } = {} -- Studio BossTest god(true), per player
local picking: { [Player]: number } = {} -- last time the player stood on the pad (picker up)
local offered: { [Player]: number } = {} -- last time the picker was sent to a player
local line: { { player: Player, id: string } } = {} -- waiting for the arena, first come first served
local folder: Folder
local stash: Folder

local function now(): number
	return workspace:GetServerTimeNow()
end

local function alive(c: Combatant?): boolean
	return c ~= nil and CombatService.get(c.model) == c and c.state ~= "Dead"
end

local function send(player: Player, kind: string, data: { [string]: any })
	if player.Parent then
		remote:FireClient(player, kind, data)
	end
end

-- Feedback for a request: every Choose ends in a Start or one of these.
local function notice(player: Player, kind: string, text: string, place: number?)
	send(player, "Notice", { kind = kind, text = text, line = place })
end

local function setStatus(text: string)
	local label = status
	if label and label.Text ~= text then
		label.Text = text
	end
end

local function mark(side: number): CFrame
	local offset = Vector3.new((if side == 1 then -1 else 1) * RULES.StartDistance / 2, 3, 0)
	return CFrame.lookAt(arena + offset, arena + Vector3.new(0, 3, 0))
end

---------------------------------------------------------------------------------------
-- Boss clips: ~3 MB of baked boss animation stays server-side until a fight needs it.

-- Moves Shared/Baked/Boss* out of ReplicatedStorage so joining clients don't download them.
-- Call before anything else at server start.
function BossService.stash()
	stash = Instance.new("Folder")
	stash.Name = "BossClips"
	stash.Parent = ServerStorage
	local baked = ReplicatedStorage:WaitForChild("Shared"):FindFirstChild("Baked")
	if not baked then
		return
	end
	for _, child in baked:GetChildren() do
		if child:IsA("ModuleScript") and string.match(child.Name, "^Boss%d%d_") then
			child.Parent = stash
		end
	end
end

-- Puts the clip modules a boss's animations live in back where BakedBoss finds them.
local function unstash(id: string)
	local baked = ReplicatedStorage.Shared:FindFirstChild("Baked")
	if not baked or not stash then
		return
	end
	for _, num in Bosses.bundles(id) do
		for _, child in stash:GetChildren() do
			if string.match(child.Name, "^Boss" .. num .. "_") and not baked:FindFirstChild(child.Name) then
				child:Clone().Parent = baked
			end
		end
	end
end

---------------------------------------------------------------------------------------
-- The boss body

-- A naginata from the katana: the blade rides a long haft, the hand far down it.
local function naginata(model: Model)
	local sword = model:FindFirstChild("Sword") :: BasePart?
	local grip = sword and sword:FindFirstChild("SwordGrip") :: Weld?
	if not sword or not grip then
		return
	end
	local look = Weapons.get("Katana").look
	local tipFromHand = 5.8 -- Kannagi's naginata blade runs 0.15-5.77 studs from the hand
	local gripZ = look.TipZ - tipFromHand
	grip.C1 = CFrame.new(0, 0, gripZ)
	local haftBack, haftFront = gripZ - 1.6, look.GuardZ
	local haft = Instance.new("Part")
	haft.Name = "Haft"
	haft.Shape = Enum.PartType.Cylinder
	haft.Size = Vector3.new(haftFront - haftBack, 0.22, 0.22)
	haft.Color = Color3.fromRGB(58, 36, 26)
	haft.Material = Enum.Material.Wood
	haft.CanCollide, haft.CanQuery, haft.CanTouch, haft.Massless = false, false, false, true
	haft.CastShadow = false
	local weld = Instance.new("Weld")
	weld.Part0 = sword
	weld.Part1 = haft
	weld.C0 = CFrame.new(0, 0, (haftBack + haftFront) / 2) * CFrame.Angles(0, math.rad(90), 0)
	weld.Parent = haft
	haft.Parent = model
end

-- Niten's second katana, in the left hand.
local function secondSword(model: Model)
	local sword = model:FindFirstChild("Sword") :: BasePart?
	local hand = model:FindFirstChild("LeftHand") :: BasePart?
	if not sword or not hand then
		return
	end
	local copy = sword:Clone()
	copy.Name = "Sword2"
	local grip = copy:FindFirstChild("SwordGrip") :: Weld?
	if grip then
		grip.Part0 = hand
		grip.Part1 = copy
	end
	copy.Parent = model
end

local function breakWindow(id: string): number
	local data = Bosses.data(id)
	local reaction = data and (data.deck.reactions :: any)["break"]
	local move = reaction and data and data.moves[reaction.move]
	local windows = move and (move.flags :: any).deathblowWindow
	if windows and windows[1] then
		return windows[1].to - windows[1].from
	end
	return 4
end

local function buildBoss(def: Bosses.BossDef): Model
	local description = Instance.new("HumanoidDescription")
	Outfit.describeBoss(description, def.look :: any)
	local model = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	model.Name = def.name
	model:SetAttribute("Boss", def.id)
	model:SetAttribute("BossNum", def.num)
	model:SetAttribute("Weapon", def.weaponLook)
	model:SetAttribute("PostureProfile", "Boss")
	model:SetAttribute("Skin", "Steel")
	-- Its capsule grows with it (Shared/Spacing).
	model:SetAttribute("BodyScale", def.look.height)
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.BreakJointsOnDeath = false
	Outfit.dressBoss(model, def.look :: any)
	return model
end

local function setStats(boss: Combatant, id: string, phase: number)
	local stats = Bosses.stats(id, phase, boss.postureMax)
	local humanoid = boss.humanoid
	humanoid.MaxHealth = stats.hp
	humanoid.Health = stats.hp
	CombatService.setPostureMax(boss, stats.posture, true)
	local extra = 0 -- one player today; Config.Bosses.ExtraPlayerRegen per extra fighter
	boss.postureRegen = stats.regen * (1 + extra * RULES.ExtraPlayerRegen)
end

-- The tutorial's stage DoOnce: the stage's posture, its lesson, and (after the first) a
-- self-revival backstep.
local function enterStage(f: Fight)
	local data = Bosses.data(f.id)
	local stages = data and data.deck.stages
	local stage = stages and stages.list[tostring(f.brain.zp)]
	if not stage then
		return
	end
	local boss = f.boss
	boss.humanoid.Health = boss.humanoid.MaxHealth
	if typeof(stage.posture) == "number" then
		CombatService.setPostureMax(boss, math.floor(stage.posture * Bosses.scale().posture + 0.5), true)
	end
	send(f.player, "Phase", {
		phase = f.brain.phase,
		lives = f.brain.zp,
		stage = tostring(f.brain.zp),
		lesson = Bosses.lesson(f.id, tostring(f.brain.zp)),
	})
	if stage.selfRevival then
		BossAI.targetRose(f.brain)
	end
end

local function onPhase(f: Fight)
	local boss = f.boss
	boss.protectedUntil = now() + 0.3
	if (Bosses.data(f.id) :: any).deck.stages then
		enterStage(f)
		return
	end
	setStats(boss, f.id, 2)
	boss.model:SetAttribute("BossPhase", 2)
	-- The puppet maiden's mask flies off.
	local mask = boss.model:FindFirstChild("Mask")
	if mask and mask:IsA("BasePart") then
		mask:ClearAllChildren()
		mask.Anchored = false
		mask.Parent = workspace
		mask.AssemblyLinearVelocity = boss.root.CFrame.LookVector * 18 + Vector3.new(0, 22, 0)
		task.delay(3, function()
			mask:Destroy()
		end)
	end
	send(f.player, "Phase", { phase = 2, lives = 1 })
end

local function spawnBoss(f: Fight, id: string): (Combatant?, BossAI.Brain?)
	local def = Bosses.def(id) :: Bosses.BossDef
	local model = buildBoss(def)
	model:PivotTo(mark(2))
	model.Parent = folder
	local boss = CombatService.register(model, nil)
	if not boss then
		model:Destroy()
		return nil, nil
	end
	boss.root:SetNetworkOwner(nil)
	Locomotion.animateBot(boss.humanoid)
	if def.weapon == "Naginata" then
		naginata(model)
	elseif def.weapon == "Dual" then
		secondSword(model)
	end
	boss.scripted = true
	boss.brokenDuration = breakWindow(id)
	local data = Bosses.data(id) :: any
	boss.parryPosture = data.stats.attackBaseTDamage
	setStats(boss, id, 1)
	model:SetAttribute("BossLives", data.stats.zp)
	model:SetAttribute("BossPhase", 1)

	local brain = BossAI.new(id, boss)
	brain.onPhase = function()
		onPhase(f)
	end
	boss.hooks = {
		deathblow = function(_attacker: Combatant): boolean
			f.lives += 1
			local last = BossAI.deathblow(brain)
			boss.protectedUntil = math.huge -- Kannagi turns the hitbox off through the anim
			CombatService.clearBreak(boss, "Idle")
			model:SetAttribute("BossLives", if last then 0 else brain.zp)
			return last
		end,
		lethal = function(by: Combatant?)
			CombatService.breakPosture(boss, by)
		end,
	}
	if data.deck.stages then
		-- Shikigami starts on its first lesson.
		local first = data.deck.stages.list["99"]
		if first and typeof(first.posture) == "number" then
			CombatService.setPostureMax(boss, math.floor(first.posture * Bosses.scale().posture + 0.5), true)
		end
		model:SetAttribute("BossLives", 7)
	end
	return boss, brain
end

---------------------------------------------------------------------------------------
-- The fight

-- Why a player can't start a trial right now, or nil if they can.
local function whyNot(player: Player): string?
	local character = player.Character
	local c = character and CombatService.get(character)
	if not player:GetAttribute("Entered") then
		return "Enter the game first"
	elseif not alive(c) then
		return "You can't start a trial while you're down"
	end
	local model = (c :: Combatant).model
	local state = player:GetAttribute("DuelState")
	if state == "Boss" then
		return "You're already in a trial"
	elseif model:GetAttribute("InMatch") then
		return "You're in the royale: finish it first"
	elseif state == "Waiting" then
		return "Step off the duel pad first"
	elseif state ~= nil or model:GetAttribute("InDuel") then
		return "Finish your duel first"
	end
	return nil
end

local function finish(f: Fight, result: string)
	if f.result then
		return
	end
	f.result = result
end

local serveLine: () -> ()

-- Pre-fight intros: which bosses' intros each player has watched this session (with a clear,
-- they may skip it), and the skip request of the intro playing now.
local introSeen: { [Player]: { [string]: boolean } } = {}
local introSkip: { [Player]: boolean } = {}

-- You and the boss on your marks, frozen (anchored; CombatService refuses a "Cinematic" body's
-- input) and protected while your intro and then the boss's play. Skippable once seen.
local function introPhase(f: Fight)
	local player, id, pc, boss = f.player, f.id, f.pc, f.boss
	local d = StatsService.get(player)
	local seen = (introSeen[player] and introSeen[player][id]) or (d and ((d :: any).BossClears or {})[id] or 0) > 0
	local item = Catalog.get(Economy.equipped(player, "intro"))
	local mine = Intros.resolve(if item and item.category == "intro" then item.ref else nil).ref
	local theirs = Intros.Bosses[id]
	local at = now() + Intros.Timing.Lead
	local endsAt = at + Intros.Timing.Full
	for _, c in { pc, boss } do
		c.root.AssemblyLinearVelocity = Vector3.zero
		c.protectedUntil = math.huge
		c.model:SetAttribute("Cinematic", true)
		c.root.Anchored = true
	end
	pc.model:PivotTo(mark(1))
	introSkip[player] = nil
	send(player, "Intro", {
		mode = "full",
		at = at,
		endsAt = endsAt,
		fighters = {
			{ model = pc.model, intro = mine, name = player.DisplayName },
			{ model = boss.model, intro = if theirs then theirs.clip else Intros.Default, name = f.def.name },
		},
		skip = seen == true,
		boss = id,
	})
	introSeen[player] = introSeen[player] or {}
	introSeen[player][id] = true
	while now() < endsAt and player.Parent and alive(pc) do
		if introSkip[player] and seen then
			send(player, "IntroEnd", {})
			break
		end
		task.wait(0.05)
	end
	introSkip[player] = nil
	for _, c in { pc, boss } do
		if c.model.Parent then
			c.model:SetAttribute("Cinematic", nil)
			c.root.Anchored = false
		end
	end
	if player.Parent and pc.model.Parent then
		pcall(function()
			pc.root:SetNetworkOwner(player)
		end)
	end
	if boss.model.Parent then
		pcall(function()
			boss.root:SetNetworkOwner(nil)
		end)
	end
end

-- The fight, from the boss's arrival to the end of the results pause. Anything that throws
-- in here ends the trial cleanly through runFight's cleanup instead of leaving the arena
-- taken and the player stuck as DuelState "Boss" (the shrine would ignore them for good).
local function fightBody(f: Fight)
	local player, id, def, pc = f.player, f.id, f.def, f.pc
	unstash(id)
	local boss, brain = spawnBoss(f, id)
	if not boss or not brain then
		error("the boss's body could not be made")
	end
	f.boss, f.brain = boss, brain
	brain.target = pc
	-- Building the boss's body can take a moment: the countdown starts once it's there.
	f.fightAt = now() + RULES.Countdown
	if not alive(pc) then
		error("the challenger fell before the trial began")
	end

	-- Both on their marks, the player fresh, the boss untouchable until the countdown ends.
	pc.root.AssemblyLinearVelocity = Vector3.zero
	pc.model:PivotTo(mark(1))
	f.placed = true
	introPhase(f) -- leaving or falling meanwhile is handled by the fight loop below
	f.fightAt = now() + RULES.Countdown
	CombatService.reset(pc, RULES.Countdown)
	CombatService.setResurrections(pc, RULES.PlayerResurrections)
	pc.god = testGod[player] == true
	-- A no-hit clear (the boss's gold skin): any loss of health from here on spoils it, a
	-- cut, chip damage or being cut down. Gourd heals only go up.
	local lastHealth = pc.humanoid.Health
	f.hitWatch = pc.humanoid.HealthChanged:Connect(function(health: number)
		if health < lastHealth - 0.01 then
			f.hit = true
		end
		lastHealth = health
	end)
	boss.protectedUntil = f.fightAt
	LobbyService.setInBoss(pc.model, 1)
	LobbyService.setInBoss(boss.model, 1)
	ProgressService.matchStarted({ player })
	send(player, "Start", {
		boss = id,
		name = def.name,
		nameJP = def.nameJP,
		stars = def.stars,
		model = boss.model,
		fightAt = f.fightAt,
		lives = boss.model:GetAttribute("BossLives"),
		tutorial = def.tutorial == true,
	})
	setStatus(`{player.DisplayName} faces {Bosses.the(def.name)}`)
	task.delay(math.max(f.fightAt - now(), 0), function()
		if fight == f and not f.result then
			BossAI.start(brain)
		end
	end)

	local endsAt = f.fightAt + RULES.MaxFightTime
	local diedAt: number? = nil
	while not f.result do
		task.wait(TICK)
		f.pc.god = testGod[player] == true
		local t = now()
		if not player.Parent then
			finish(f, "Left")
			break
		end
		local body = f.pc
		if not alive(body) then
			finish(f, "Lost")
			break
		end
		if body.state == "Downed" then
			if not f.down then
				f.down = true
				BossAI.targetDown(brain)
			end
		elseif f.down then
			f.down = false
			BossAI.targetRose(brain)
		end
		if brain.defeated then
			-- The death anim plays out, then the body falls.
			diedAt = diedAt or t
			local action = brain.action
			if t - (diedAt :: number) > 4 or (action == nil and t - (diedAt :: number) > 0.5) then
				finish(f, "Won")
				break
			end
		elseif not alive(boss) then
			finish(f, "Won")
			break
		end
		if t >= endsAt then
			finish(f, "Lost")
			break
		end
		for _, c in { body, boss } do
			if alive(c) and c.root.Position.Y < arena.Y - RULES.FallDepth then
				c.root.AssemblyLinearVelocity = Vector3.zero
				c.model:PivotTo(mark(if c == boss then 2 else 1))
			end
		end
	end

	BossAI.stop(brain)
	local won = f.result == "Won"
	if won and alive(boss) then
		boss.hooks = nil
		boss.humanoid.Health = 0
	end
	if alive(f.pc) then
		f.pc.protectedUntil = math.huge
	end
	if alive(boss) then
		boss.protectedUntil = math.huge
	end
	local time = math.max(now() - f.fightAt, 0)
	local first = false
	local noHit = won and not f.hit
	if f.hitWatch then
		f.hitWatch:Disconnect()
	end
	if f.result ~= "Left" then
		first = ProgressService.bossEnded(player, {
			boss = id,
			name = def.name,
			stars = def.stars,
			won = won,
			lives = f.lives,
			time = time,
		})
		if noHit then
			StatsService.recordNoHit(player, id) -- Economy grants the gold skin on this publish
		end
		send(player, "End", {
			won = won,
			boss = id,
			name = def.name,
			stars = def.stars,
			time = time,
			firstClear = first,
			noHit = noHit,
		})
	else
		-- Ended without a result (BossTest "stop", or the player left): still take the boss HUD down.
		send(player, "End", { left = true, boss = id, name = def.name, time = time })
	end
	setStatus(
		if won then `{player.DisplayName} defeated {Bosses.the(def.name)}` else `{Bosses.the(def.name, true)} stands`
	)
	task.wait(RULES.Results)
end

-- Puts everything back however the fight ended (or broke): the boss gone, the player out of
-- the arena with a fresh body, the arena free for whoever is next in line.
local function cleanup(f: Fight)
	local player = f.player
	if f.hitWatch then
		f.hitWatch:Disconnect()
	end
	local brain = f.brain :: BossAI.Brain?
	if brain then
		pcall(BossAI.stop, brain)
	end
	local boss = f.boss :: Combatant?
	if boss and boss.model.Parent then
		boss.model:Destroy()
	end
	if f.pc.model.Parent then
		LobbyService.setInBoss(f.pc.model, nil)
	end
	player:SetAttribute("DuelState", nil)
	if f.placed and player.Parent then
		player:LoadCharacter()
		-- Back beside the shrine pad (Sekiro's idol by the boss), not on the spawn plaza: one
		-- step onto it opens the picker for another try.
		local character = player.Character
		local away = LobbyService.spawnCFrame().Position - pad
		away = Vector3.new(away.X, 0, away.Z)
		if character and pad ~= Vector3.zero and away.Magnitude > 1 then
			local spot = pad + away.Unit * (padRadius + 3) + Vector3.new(0, 3, 0)
			character:PivotTo(CFrame.lookAt(spot, Vector3.new(pad.X, spot.Y, pad.Z)))
		end
	end
	if fight == f then
		fight = nil
	end
	setStatus("Step on the shrine to choose a boss")
	task.defer(serveLine)
end

local function runFight(player: Player, id: string)
	local def = Bosses.def(id)
	if not def then
		return
	end
	if fight then
		notice(player, "Refused", "A trial is already under way")
		return
	end
	local reason = whyNot(player)
	local pc = player.Character and CombatService.get(player.Character)
	if reason or not pc then
		notice(player, "Refused", reason or "You can't start a trial right now")
		return
	end
	player:SetAttribute("DuelState", "Boss")

	local f: Fight = {
		id = id,
		def = def,
		player = player,
		pc = pc,
		boss = nil :: any,
		brain = nil :: any,
		fightAt = now() + RULES.Countdown,
		lives = 0,
		down = false,
		placed = false,
		result = nil,
		tally = {},
	}
	fight = f
	local ok, err = xpcall(fightBody, debug.traceback, f)
	if not ok then
		warn(`[BossService] the {def.name} trial broke off: {err}`)
		notice(player, "Failed", "The trial broke off. Step on the shrine to try again.")
	end
	cleanup(f)
end

---------------------------------------------------------------------------------------
-- The line: one arena, so later challengers wait their turn.

local function linePosition(player: Player): number?
	for i, entry in line do
		if entry.player == player then
			return i
		end
	end
	return nil
end

local function leaveLine(player: Player)
	local i = linePosition(player)
	if i then
		table.remove(line, i)
	end
end

local function joinLine(player: Player, id: string)
	local i = linePosition(player)
	if i then
		line[i].id = id -- a different pick keeps the place in line
	else
		table.insert(line, { player = player, id = id })
		i = #line
	end
	local f = fight
	local holder = if f then `{f.player.DisplayName} is facing {Bosses.the(f.def.name)}` else "A trial is under way"
	local def = Bosses.def(id) :: Bosses.BossDef
	notice(
		player,
		"Line",
		`{holder}. You're {if i == 1 then "next" else `#{i} in line`} for {Bosses.the(def.name)}: it starts by itself.`,
		i
	)
end

-- The arena is free: start the first challenger in line who still can, telling anyone who
-- can't any more why their place went.
function serveLine()
	while not fight and #line > 0 do
		local entry = table.remove(line, 1) :: { player: Player, id: string }
		local player = entry.player
		if player.Parent then
			local reason = whyNot(player)
			if reason then
				notice(player, "Line", `Your turn at the shrine passed. {reason}.`)
			else
				notice(player, "Turn", "Your trial begins")
				task.spawn(runFight, player, entry.id)
				return
			end
		end
	end
end

-- A pick from the picker (or BossTest).
local function choose(player: Player, id: string)
	if fight and fight.player == player then
		return -- already fighting; a stray second click
	end
	local reason = whyNot(player)
	if reason then
		notice(player, "Refused", reason)
		return
	end
	if fight then
		joinLine(player, id)
		return
	end
	leaveLine(player)
	task.spawn(runFight, player, id)
end

-- Public for tests (DevHooks / BossTest).
function BossService.begin(player: Player, id: string)
	task.spawn(runFight, player, id)
end

function BossService.current(): Fight?
	return fight
end

---------------------------------------------------------------------------------------
-- The shrine pad and the picker

local function pickList(player: Player): { { [string]: any } }
	local d = StatsService.get(player)
	local clears: { [string]: number } = if d then d.BossClears else {} -- (an owner-only attribute now)
	local list = {}
	for _, id in Bosses.List do
		local def = Bosses.def(id) :: Bosses.BossDef
		table.insert(list, {
			id = id,
			name = def.name,
			nameJP = def.nameJP,
			stars = def.stars,
			blurb = def.blurb,
			tutorial = def.tutorial == true,
			cleared = (clears[id] or 0) > 0,
		})
	end
	return list
end

local function onPad(player: Player): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	local offset = root.Position - pad
	return Vector3.new(offset.X, 0, offset.Z).Magnitude <= padRadius and math.abs(offset.Y) < 6
end

-- Close enough to the shrine for a pick to count: on the pad, or a few steps off it with
-- the picker opened recently (it closes itself client-side beyond PICK_REACH).
local function nearShrine(player: Player): boolean
	if onPad(player) then
		return true
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local opened = offered[player]
	if not root or not root:IsA("BasePart") or not opened or os.clock() - opened > PICK_GRACE then
		return false
	end
	local offset = root.Position - pad
	return Vector3.new(offset.X, 0, offset.Z).Magnitude <= padRadius + PICK_REACH and math.abs(offset.Y) < 10
end

local function sendPick(player: Player)
	local f = fight
	offered[player] = os.clock()
	send(player, "Pick", {
		bosses = pickList(player),
		busy = if f then { player = f.player.DisplayName, boss = f.def.name } else nil,
		line = linePosition(player),
	})
end

-- Stepping onto the pad opens the picker (again after stepping off for a moment). Someone
-- who can't fight right now hears why once per visit instead of the pad doing nothing.
local function watchPad()
	while true do
		task.wait(0.2)
		local t = os.clock()
		for _, player in Players:GetPlayers() do
			if onPad(player) and (fight == nil or fight.player ~= player) then
				if not picking[player] then
					local reason = whyNot(player)
					if reason then
						notice(player, "Refused", reason)
					else
						sendPick(player)
					end
				end
				picking[player] = t
			elseif picking[player] and t - picking[player] > PICK_COOLDOWN then
				picking[player] = nil
			end
		end
	end
end

---------------------------------------------------------------------------------------
-- Wiring

local function onWindup(attacker: Combatant, kind: Config.AttackKind, hitAt: number)
	local f = fight
	if not f or attacker == f.boss or not f.brain then
		return
	end
	if attacker.model:GetAttribute("InBoss") ~= true then
		return
	end
	local spec = Weapons.spec(attacker.weapon, kind)
	-- The swing side as the boss sees it (Kannagi's HajikiReaction: 0 right, 2 left).
	local side = if spec.deflectSide == "Left" then 2 else 0
	BossAI.sign(f.brain, attacker, hitAt, side)
end

local function onOutcome(kind: string, outcome: string, attacker: Combatant, target: Combatant?)
	local f = fight
	if not f or not f.brain then
		return
	end
	if attacker == f.boss or target == f.boss then
		local key = (if attacker == f.boss then "boss:" else "player:") .. outcome
		f.tally[key] = (f.tally[key] or 0) + 1
		BossAI.outcome(f.brain, outcome, attacker, target, kind)
	end
end

function BossService.start()
	if not stash then
		BossService.stash()
	end
	remote = Instance.new("RemoteEvent")
	remote.Name = "Boss"
	remote.Parent = ReplicatedStorage:WaitForChild("Remotes")
	folder = Instance.new("Folder")
	folder.Name = "Bosses"
	folder.Parent = workspace

	local shrine = workspace:WaitForChild("Lobby"):WaitForChild("BossShrine", 10)
	if shrine then
		pad = shrine:GetAttribute("Pad") :: Vector3
		padRadius = (shrine:GetAttribute("PadRadius") :: number?) or padRadius
		arena = shrine:GetAttribute("Arena") :: Vector3
		local sign = shrine:FindFirstChild("Sign")
		local label = sign and sign:FindFirstChild("Label")
		local found = label and label:FindFirstChild("Status")
		status = if found and found:IsA("TextLabel") then found else nil
	end

	remote.OnServerEvent:Connect(function(player: Player, action: unknown, argument: unknown)
		if action ~= "SkipIntro" and not LobbyService.allowRequest(player) then
			return -- the lobby's request budget: each Choose or Cancel sends a notice
		end
		if action == "Choose" and typeof(argument) == "string" and Bosses.def(argument) then
			if nearShrine(player) or (RunService:IsStudio() and player:GetAttribute("BossAnywhere")) then
				choose(player, argument)
			else
				notice(player, "Refused", "Step back onto the shrine to begin a trial")
			end
		elseif action == "SkipIntro" then
			introSkip[player] = true
		elseif action == "Cancel" then
			if linePosition(player) then
				leaveLine(player)
				notice(player, "Line", "You left the line for the arena")
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		picking[player] = nil
		offered[player] = nil
		testGod[player] = nil
		introSeen[player] = nil
		introSkip[player] = nil
		leaveLine(player)
	end)

	CombatService.onWindup(onWindup)
	CombatService.onOutcome(onOutcome)
	task.spawn(watchPad)

	-- Studio only: ServerStorage.BossTest drives a fight for automated tests.
	--   start(id)        the first player fights boss `id` (no pad needed)
	--   state()          a snapshot of the fight
	--   log(n)           the boss's last n moves / reactions ("R:<name>")
	--   posture(v) / health(v)   set the boss's posture or vitality
	--   god(on)          the player's vitality can't drop (blows still land and flinch); works
	--                    before or during a fight and lasts through the countdown, attacking and
	--                    later fights until god(false)
	--   stop()           ends the fight as if the player left
	if RunService:IsStudio() then
		local hook = Instance.new("BindableFunction")
		hook.Name = "BossTest"
		hook.OnInvoke = function(command: string, value: any): any
			local f = fight
			if command == "god" then
				-- Kept per player and re-applied every tick of a fight, so it survives the
				-- countdown's reset, attacking (which ends spawn protection) and a new body.
				local player = Players:GetPlayers()[1]
				if player then
					testGod[player] = if value then true else nil
					local c = player.Character and CombatService.get(player.Character)
					if c then
						c.god = value == true
					end
				end
				return player ~= nil
			elseif command == "start" then
				local player = Players:GetPlayers()[1]
				if player then
					BossService.begin(player, value)
					return true
				end
				return false
			elseif not f then
				return nil
			elseif command == "state" then
				local brain = f.brain
				local boss = f.boss
				local action = brain.action
				return {
					boss = f.id,
					mode = brain.mode,
					zp = brain.zp,
					phase = brain.phase,
					action = action and action.key,
					state = boss.state,
					health = boss.humanoid.Health,
					maxHealth = boss.humanoid.MaxHealth,
					posture = boss.posture,
					postureMax = boss.postureMax,
					guard = brain.flags.guard,
					hajiki = brain.flags.hajiki,
					superArmor = brain.flags.superArmor,
					playerHealth = f.pc.humanoid.Health,
					playerState = f.pc.state,
					playerPosture = f.pc.posture,
					lives = f.lives,
					result = f.result,
					distance = (boss.root.Position - f.pc.root.Position).Magnitude,
					cool = table.concat(brain.cool, ","),
				}
			elseif command == "tally" then
				local parts = {}
				for key, count in f.tally do
					table.insert(parts, `{key}={count}`)
				end
				table.sort(parts)
				return table.concat(parts, " ")
			elseif command == "log" then
				local log = f.brain.log
				local n = math.min(value or 30, #log)
				return table.concat(log, " ", #log - n + 1, #log)
			elseif command == "posture" then
				f.boss.posture = value
				return true
			elseif command == "health" then
				f.boss.humanoid.Health = value
				return true
			elseif command == "stop" then
				finish(f, "Left")
				return true
			end
			return nil
		end
		hook.Parent = ServerStorage
	end
end

return BossService
