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
--   server -> client: "Pick" { bosses = { { id, name, nameJP, stars, cleared, blurb } } }
--                     "Start" { boss, name, nameJP, stars, model, fightAt, lives }
--                     "Phase" { phase, lives, stage?, lesson? }
--                     "End" { won, boss, name, time, firstClear }
--                     "Busy" {}
--   client -> server: "Choose" bossId | "Close"

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")

local Bosses = require(ReplicatedStorage.Shared.Bosses)
local Config = require(ReplicatedStorage.Shared.Config)
local Weapons = require(ReplicatedStorage.Shared.Weapons)
local BossAI = require(script.Parent.BossAI)
local CombatService = require(script.Parent.CombatService)
local Locomotion = require(script.Parent.Locomotion)
local LobbyService = require(script.Parent.LobbyService)
local Outfit = require(script.Parent.Outfit)
local ProgressService = require(script.Parent.ProgressService)

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
	result: string?, -- "Won" | "Lost" | "Left"
	tally: { [string]: number }, -- outcomes of blows involving the boss (tests)
}

local RULES = Config.Bosses
local TICK = 0.1
local PICK_COOLDOWN = 2

local BossService = {}

local remote: RemoteEvent
local arena: Vector3 = Vector3.zero
local pad: Vector3 = Vector3.zero
local padRadius = 4
local status: TextLabel? = nil
local fight: Fight? = nil
local testGod: { [Player]: boolean } = {} -- Studio BossTest god(true), per player
local picking: { [Player]: number } = {} -- last time the picker was opened for a player
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
		lesson = stage.lesson,
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

local function eligible(player: Player): boolean
	local character = player.Character
	local c = character and CombatService.get(character)
	if not player:GetAttribute("Entered") or not alive(c) then
		return false
	end
	local model = (c :: Combatant).model
	if model:GetAttribute("InMatch") or model:GetAttribute("InDuel") then
		return false
	end
	return player:GetAttribute("DuelState") == nil
end

local function finish(f: Fight, result: string)
	if f.result then
		return
	end
	f.result = result
end

local function runFight(player: Player, id: string)
	local def = Bosses.def(id)
	local character = player.Character
	local pc = character and CombatService.get(character)
	if fight or not def or not pc or not eligible(player) then
		if fight then
			send(player, "Busy", {})
		end
		return
	end
	player:SetAttribute("DuelState", "Boss")
	unstash(id)

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
		result = nil,
		tally = {},
	}
	fight = f
	local boss, brain = spawnBoss(f, id)
	if not boss or not brain then
		fight = nil
		player:SetAttribute("DuelState", nil)
		return
	end
	f.boss, f.brain = boss, brain
	brain.target = pc

	-- Both on their marks, the player fresh, the boss untouchable until the countdown ends.
	pc.root.AssemblyLinearVelocity = Vector3.zero
	pc.model:PivotTo(mark(1))
	CombatService.reset(pc, RULES.Countdown)
	CombatService.setResurrections(pc, RULES.PlayerResurrections)
	pc.god = testGod[player] == true
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
	setStatus(`{player.DisplayName} faces the {def.name}`)
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
	if f.result ~= "Left" then
		first = ProgressService.bossEnded(player, {
			boss = id,
			name = def.name,
			stars = def.stars,
			won = won,
			lives = f.lives,
			time = time,
		})
		send(player, "End", { won = won, boss = id, name = def.name, time = time, firstClear = first })
	end
	setStatus(if won then `{player.DisplayName} defeated the {def.name}` else `The {def.name} stands`)
	task.wait(RULES.Results)

	if boss.model.Parent then
		boss.model:Destroy()
	end
	if f.pc.model.Parent then
		LobbyService.setInBoss(f.pc.model, nil)
	end
	player:SetAttribute("DuelState", nil)
	if player.Parent then
		player:LoadCharacter()
	end
	fight = nil
	setStatus("Step on the shrine to choose a boss")
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
	local clears = {}
	local raw = player:GetAttribute("BossClears")
	if typeof(raw) == "string" then
		local ok, decoded = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		if ok and typeof(decoded) == "table" then
			clears = decoded
		end
	end
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

-- Stepping onto the pad opens the picker (again after stepping off, or every few seconds).
local function watchPad()
	while true do
		task.wait(0.2)
		local t = os.clock()
		for _, player in Players:GetPlayers() do
			if onPad(player) and eligible(player) then
				if not picking[player] or t - picking[player] > 60 then
					send(player, "Pick", { bosses = pickList(player), busy = fight ~= nil })
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
		if action == "Choose" and typeof(argument) == "string" and Bosses.def(argument) then
			if onPad(player) or (RunService:IsStudio() and player:GetAttribute("BossAnywhere")) then
				task.spawn(runFight, player, argument)
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		picking[player] = nil
		testGod[player] = nil
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
