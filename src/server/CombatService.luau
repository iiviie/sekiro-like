--!strict
-- Server-authoritative combat: attack phases, deflect / guard / hit resolution, posture.
--
-- Timing model
--   When a windup starts, the server fixes the impact time `hitAt` on the shared server
--   clock and broadcasts it, so every client lands its swing visual on the same instant.
--   Defender inputs carry the client's synced clock stamp. The server clamps that stamp
--   to at most Net.CompensationCap in the past, and waits Net.ResolveGrace after hitAt
--   before resolving, so a deflect pressed on time on the defender's screen still counts
--   while its packet is in flight. Clients only ever send intents; the server owns
--   posture, health and every outcome.
--
-- Flow
--   Slashes chain Light1 -> Light2 -> Light3 while pressed inside Combo.Window. Attacks
--   pressed slightly early are buffered and fire the moment the fighter is free, and a
--   block press shortly after impact cancels the rest of recovery, so inputs never feel
--   eaten. A deflected attacker recoils; after a perfect deflect, long enough to punish.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Types = require(Shared.Types)
local Locomotion = require(script.Parent.Locomotion)
local SwordRig = require(script.Parent.SwordRig)

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local combatAction = remotes:WaitForChild("CombatAction") :: RemoteEvent
local combatEvent = remotes:WaitForChild("CombatEvent") :: RemoteEvent

type AttackKind = Config.AttackKind
type AttackSpec = Config.AttackSpec
type CombatState = Types.CombatState
type Action = Types.Action

export type Combatant = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	player: Player?,

	state: CombatState,
	stateEndsAt: number,
	attackToken: number, -- bumped to invalidate a pending windup
	windupHitAt: number,
	cancelableAt: number, -- block may cut recovery short from this time
	nextAttackAt: { [AttackKind]: number },
	comboIndex: number,
	comboUntil: number,
	buffered: Action?,
	bufferedAt: number,

	posture: number,
	lastPostureDamageAt: number,
	stamina: number,
	lastStaminaSpendAt: number,

	blocking: boolean,
	deflectStamp: number, -- clamped stamp of the last press that armed a deflect
	lastBlockPressAt: number,

	dodgeStamp: number,
	dodgeForward: boolean, -- dashed toward the attacker (for Mikiri)
	nextDodgeAt: number,
	jumpStamp: number,
	gourds: number,
	protectedUntil: number,

	lastAttacker: Combatant?, -- for kill credit
	lastAttackedAt: number,
	executed: boolean, -- killed by a deathblow
}

type WindupListener = (attacker: Combatant, kind: AttackKind, hitAt: number) -> ()
type DeflectListener = (attacker: Combatant, defender: Combatant, perfect: boolean) -> ()
type DiedListener = (victim: Combatant, killer: Combatant?, deathblow: boolean) -> ()

local CombatService = {}

local combatants: { [Model]: Combatant } = {}
local windupListeners: { WindupListener } = {}
local deflectListeners: { DeflectListener } = {}
local diedListeners: { DiedListener } = {}

local KILL_CREDIT_WINDOW = 12 -- seconds a hit still counts toward a later death
local actionBudgets: { [Player]: { windowStart: number, count: number } } = {}

local validActions: { [string]: boolean } = {}
for _, action in Types.Actions do
	validActions[action] = true
end

local function now(): number
	return workspace:GetServerTimeNow()
end

local function broadcast(kind: string, data: { [string]: any })
	combatEvent:FireAllClients(kind, data)
end

local function isAlive(c: Combatant): boolean
	return combatants[c.model] == c and c.state ~= "Dead"
end

local function refreshWalkSpeed(c: Combatant)
	local speed = Config.WalkSpeed
	if c.state == "Windup" or c.state == "Recovery" or c.state == "Staggered" or c.state == "Drinking" then
		speed = Config.AttackWalkSpeed
	elseif c.state == "Broken" then
		speed = Config.BrokenWalkSpeed
	elseif c.blocking then
		speed = Config.BlockWalkSpeed
	end
	c.humanoid.WalkSpeed = speed
end

local function setState(c: Combatant, state: CombatState, duration: number?)
	c.state = state
	c.stateEndsAt = if duration then now() + duration else math.huge
	c.model:SetAttribute("CombatState", state)
	refreshWalkSpeed(c)
end

local function setBlocking(c: Combatant, blocking: boolean)
	if c.blocking == blocking then
		return
	end
	c.blocking = blocking
	c.model:SetAttribute("Blocking", blocking)
	refreshWalkSpeed(c)
end

local function publishPosture(c: Combatant)
	local shown = math.floor(c.posture + 0.5)
	if c.model:GetAttribute("Posture") ~= shown then
		c.model:SetAttribute("Posture", shown)
	end
end

local function publishStamina(c: Combatant)
	local shown = math.floor(c.stamina + 0.5)
	if c.model:GetAttribute("Stamina") ~= shown then
		c.model:SetAttribute("Stamina", shown)
	end
end

-- Pays a stamina cost, or refuses the action if there isn't enough.
local function spendStamina(c: Combatant, cost: number?): boolean
	if not cost or cost <= 0 then
		return true
	end
	if c.stamina < cost then
		return false
	end
	c.stamina -= cost
	c.lastStaminaSpendAt = now()
	publishStamina(c)
	return true
end

local function cancelAttack(c: Combatant)
	c.attackToken += 1
end

local function addPosture(c: Combatant, amount: number)
	if c.state == "Broken" or c.state == "Dead" then
		return
	end
	c.posture = math.min(Config.Posture.Max, c.posture + amount)
	c.lastPostureDamageAt = now()
	if c.posture >= Config.Posture.Max then
		cancelAttack(c)
		setBlocking(c, false)
		c.buffered = nil
		setState(c, "Broken", Config.Posture.BrokenDuration)
		broadcast("PostureBroken", { model = c.model })
	end
	publishPosture(c)
end

local function stagger(c: Combatant, duration: number)
	if c.state == "Broken" or c.state == "Dead" then
		return
	end
	if c.state == "Windup" then
		broadcast("Interrupted", { model = c.model })
	end
	cancelAttack(c)
	c.buffered = nil
	c.comboIndex = 0
	setState(c, "Staggered", duration)
end

local function isFacing(defender: Combatant, attacker: Combatant): boolean
	local offset = attacker.root.Position - defender.root.Position
	local flat = Vector3.new(offset.X, 0, offset.Z)
	if flat.Magnitude < 0.01 then
		return true
	end
	return defender.root.CFrame.LookVector:Dot(flat.Unit) >= Config.Deflect.FacingDot
end

local function findTargets(attacker: Combatant, spec: AttackSpec): { Combatant }
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { attacker.model }

	local box = attacker.root.CFrame * CFrame.new(0, 0, -spec.range / 2)
	local parts = workspace:GetPartBoundsInBox(box, Vector3.new(spec.width, 6, spec.range), params)

	local seen: { [Combatant]: boolean } = {}
	local targets: { Combatant } = {}
	for _, part in parts do
		local model = part:FindFirstAncestorOfClass("Model")
		local target = model and combatants[model]
		if target and not seen[target] and target.state ~= "Dead" then
			seen[target] = true
			table.insert(targets, target)
		end
	end
	return targets
end

local function resolveHit(attacker: Combatant, target: Combatant, spec: AttackSpec, hitAt: number)
	if hitAt < target.protectedUntil then
		return
	end

	if target.state == "Broken" then
		target.lastAttacker = attacker
		target.lastAttackedAt = now()
		target.executed = true
		target.humanoid:TakeDamage(Config.DeathblowDamage)
		broadcast("Deathblow", { attacker = attacker.model, defender = target.model })
		return
	end

	if spec.low and hitAt >= target.jumpStamp and hitAt <= target.jumpStamp + Config.Jump.EvadeWindow then
		broadcast("Jumped", { attacker = attacker.model, defender = target.model })
		return
	end

	if hitAt >= target.dodgeStamp and hitAt <= target.dodgeStamp + Config.Dodge.IFrames then
		if spec.thrust and target.dodgeForward and isFacing(target, attacker) then
			-- Mikiri Counter: dashing into a thrust pins the blade underfoot.
			addPosture(attacker, Config.Mikiri.AttackerPosture)
			if attacker.state ~= "Broken" then
				stagger(attacker, Config.Mikiri.AttackerStagger)
			end
			broadcast("Mikiri", { attacker = attacker.model, defender = target.model })
		else
			broadcast("Dodged", { attacker = attacker.model, defender = target.model })
		end
		return
	end

	local canDefend = not spec.unblockable and isFacing(target, attacker)
	local sinceDeflect = hitAt - target.deflectStamp
	local deflectArmed = sinceDeflect >= -Config.Deflect.LateTolerance

	if canDefend and deflectArmed and sinceDeflect <= Config.Deflect.Window then
		local perfect = sinceDeflect <= Config.Deflect.PerfectWindow
		local recoil = if perfect then Config.Deflect.PerfectAttackerRecoil else Config.Deflect.AttackerRecoil
		if perfect then
			addPosture(attacker, Config.Deflect.PerfectAttackerPosture)
		else
			addPosture(attacker, Config.Deflect.AttackerPosture)
			addPosture(target, Config.Deflect.DefenderPosture)
		end
		if attacker.state ~= "Broken" then
			stagger(attacker, recoil)
		end
		broadcast("Deflect", { attacker = attacker.model, defender = target.model, perfect = perfect })
		for _, listener in deflectListeners do
			task.spawn(listener, attacker, target, perfect)
		end
	elseif canDefend and target.blocking then
		addPosture(target, spec.postureDamage * Config.Deflect.GuardPostureMultiplier)
		broadcast("Guard", { attacker = attacker.model, defender = target.model })
	else
		target.lastAttacker = attacker
		target.lastAttackedAt = now()
		target.humanoid:TakeDamage(spec.damage)
		addPosture(target, spec.postureDamage * Config.HitPostureMultiplier)
		stagger(target, Config.HitStagger)
		broadcast("Hit", { attacker = attacker.model, defender = target.model, damage = spec.damage })
	end
end

local function resolveAttack(attacker: Combatant, spec: AttackSpec, hitAt: number)
	local targets = findTargets(attacker, spec)
	if #targets == 0 then
		broadcast("Whiff", { attacker = attacker.model })
		return
	end
	for _, target in targets do
		resolveHit(attacker, target, spec, hitAt)
	end
end

local function nextComboKind(c: Combatant, t: number): AttackKind
	local sequence = Config.Combo.Sequence
	if t > c.comboUntil or c.comboIndex >= #sequence then
		c.comboIndex = 0
	end
	c.comboIndex += 1
	return sequence[c.comboIndex]
end

local function startAttack(c: Combatant, kind: AttackKind): boolean
	local spec = Config.Attacks[kind]
	local t = now()
	if c.state ~= "Idle" or t < (c.nextAttackAt[kind] or 0) then
		return false
	end
	if not spendStamina(c, Config.Stamina.Costs[kind]) then
		return false
	end

	setBlocking(c, false)
	cancelAttack(c)
	c.protectedUntil = 0 -- attacking ends spawn protection
	local token = c.attackToken
	local hitAt = t + spec.windup
	c.windupHitAt = hitAt
	c.cancelableAt = hitAt + Config.Net.ResolveGrace + Config.Combo.RecoveryCancel
	c.nextAttackAt[kind] = t + spec.cooldown
	c.comboUntil = hitAt + Config.Net.ResolveGrace + spec.recovery + Config.Combo.Window
	setState(c, "Windup")

	broadcast("Windup", { attacker = c.model, kind = kind, hitAt = hitAt })
	for _, listener in windupListeners do
		task.spawn(listener, c, kind, hitAt)
	end

	task.delay(spec.windup, function()
		if c.attackToken ~= token or c.state ~= "Windup" then
			return -- interrupted, feinted or broken during the windup
		end
		-- The swing has landed visually; from here it is committed and can't be interrupted.
		setState(c, "Recovery", Config.Net.ResolveGrace + spec.recovery)
		if not c.player then
			-- Bots are simulated here; players lunge on their own client.
			local look = c.root.CFrame.LookVector
			c.root.AssemblyLinearVelocity += Vector3.new(look.X, 0, look.Z).Unit * spec.lunge
		end
		task.delay(Config.Net.ResolveGrace, function()
			if isAlive(c) then
				resolveAttack(c, spec, hitAt)
			end
		end)
	end)
	return true
end

local function bufferAction(c: Combatant, action: Action)
	c.buffered = action
	c.bufferedAt = now()
end

local function attack(c: Combatant, action: Action): boolean
	if c.state ~= "Idle" then
		bufferAction(c, action)
		return false
	end
	local t = now()
	local kind: AttackKind = if action == "Perilous"
		then "Perilous"
		elseif action == "Sweep" then "Sweep"
		else nextComboKind(c, t)
	return startAttack(c, kind)
end

-- Recovery after impact can be cut short by defending, so a swing never locks you out
-- of answering the counter-attack.
local function cancelRecovery(c: Combatant): boolean
	if c.state == "Recovery" and now() >= c.cancelableAt then
		c.buffered = nil
		setState(c, "Idle")
		return true
	end
	return false
end

local function pressBlock(c: Combatant, stamp: number): boolean
	local t = now()
	if c.state == "Windup" then
		-- Blocking out of a windup is a feint: it baits deflects at a small posture cost.
		if t > c.windupHitAt - Config.Feint.Cutoff then
			return false
		end
		cancelAttack(c)
		c.comboIndex = 0
		addPosture(c, Config.Feint.PostureCost)
		if c.state == "Broken" then
			return false
		end
		setState(c, "Idle")
		broadcast("Feint", { model = c.model })
	end
	cancelRecovery(c)
	if c.state ~= "Idle" then
		return false
	end

	c.buffered = nil
	c.protectedUntil = 0
	setBlocking(c, true)
	-- Mashing keeps resetting the lockout, so spam never re-arms the deflect.
	if t - c.lastBlockPressAt >= Config.Deflect.SpamLockout then
		c.deflectStamp = stamp
	end
	c.lastBlockPressAt = t
	return true
end

local function dodge(c: Combatant, stamp: number, forward: boolean): boolean
	local t = now()
	cancelRecovery(c)
	if c.state ~= "Idle" or t < c.nextDodgeAt then
		return false
	end
	if not spendStamina(c, Config.Stamina.Costs.Dodge) then
		return false
	end
	c.buffered = nil
	setBlocking(c, false)
	c.dodgeStamp = stamp
	c.dodgeForward = forward
	c.nextDodgeAt = t + Config.Dodge.Cooldown
	broadcast("Dodge", { model = c.model })
	return true
end

-- A sip from the gourd: slow and committal. Getting hit mid-sip wastes it.
local function heal(c: Combatant): boolean
	cancelRecovery(c)
	if c.state ~= "Idle" or c.gourds <= 0 then
		return false
	end
	c.buffered = nil
	setBlocking(c, false)
	c.gourds -= 1
	c.model:SetAttribute("Gourds", c.gourds)
	cancelAttack(c)
	local token = c.attackToken
	setState(c, "Drinking", Config.Gourd.DrinkTime + 0.05)
	broadcast("Drink", { model = c.model })
	task.delay(Config.Gourd.DrinkTime, function()
		if c.attackToken == token and c.state == "Drinking" and isAlive(c) then
			c.humanoid.Health = math.min(c.humanoid.MaxHealth, c.humanoid.Health + Config.Gourd.Heal)
			broadcast("Healed", { model = c.model })
		end
	end)
	return true
end

local function clampStamp(raw: unknown): number
	local t = now()
	if typeof(raw) ~= "number" or raw ~= raw then
		return t
	end
	return math.clamp(raw :: number, t - Config.Net.CompensationCap, t)
end

local function withinBudget(player: Player): boolean
	local t = os.clock()
	local budget = actionBudgets[player]
	if not budget or t - budget.windowStart >= 1 then
		budget = { windowStart = t, count = 0 }
		actionBudgets[player] = budget
	end
	budget.count += 1
	return budget.count <= Config.Net.MaxActionsPerSecond
end

-- Single entry point for players (via the remote) and bots. Returns whether the
-- action took effect immediately. `stamp` must already be a trusted or clamped
-- server-clock time.
function CombatService.perform(c: Combatant, action: Action, stamp: number?, flag: boolean?): boolean
	if not isAlive(c) then
		return false
	end
	local at = stamp or now()
	if action == "Attack" or action == "Perilous" or action == "Sweep" then
		return attack(c, action)
	elseif action == "BlockDown" then
		return pressBlock(c, at)
	elseif action == "BlockUp" then
		setBlocking(c, false)
		return true
	elseif action == "Dodge" then
		return dodge(c, at, flag == true)
	elseif action == "Jump" then
		c.jumpStamp = at
		return true
	elseif action == "Heal" then
		return heal(c)
	elseif action == "Ready" then
		-- Players are untouchable until their client is actually in the game (past the
		-- title screen); spawn protection runs from here.
		if c.protectedUntil == math.huge then
			c.protectedUntil = now() + Config.SpawnProtection
		end
		return true
	end
	return false
end

function CombatService.get(model: Model): Combatant?
	return combatants[model]
end

-- Read-only view of every live combatant, keyed by model.
function CombatService.all(): { [Model]: Combatant }
	return combatants
end

function CombatService.onDied(listener: DiedListener)
	table.insert(diedListeners, listener)
end

-- Full health, empty posture, idle, and briefly protected: used when a round starts.
function CombatService.reset(c: Combatant, protection: number)
	cancelAttack(c)
	c.buffered = nil
	c.comboIndex = 0
	c.posture = 0
	c.lastAttacker = nil
	c.executed = false
	setBlocking(c, false)
	setState(c, "Idle")
	publishPosture(c)
	c.humanoid.Health = c.humanoid.MaxHealth
	c.gourds = Config.Gourd.Charges
	c.model:SetAttribute("Gourds", c.gourds)
	c.stamina = Config.Stamina.Max
	publishStamina(c)
	c.protectedUntil = now() + protection
end

function CombatService.isProtected(c: Combatant): boolean
	return now() < c.protectedUntil
end

function CombatService.onWindup(listener: WindupListener)
	table.insert(windupListeners, listener)
end

function CombatService.onDeflect(listener: DeflectListener)
	table.insert(deflectListeners, listener)
end

function CombatService.register(model: Model, player: Player?): Combatant?
	local existing = combatants[model]
	if existing then
		return existing
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		warn(`[CombatService] {model.Name} is missing a Humanoid or HumanoidRootPart`)
		return nil
	end

	local c: Combatant = {
		model = model,
		humanoid = humanoid,
		root = root,
		player = player,
		state = "Idle",
		stateEndsAt = math.huge,
		attackToken = 0,
		windupHitAt = 0,
		cancelableAt = 0,
		nextAttackAt = {},
		comboIndex = 0,
		comboUntil = 0,
		buffered = nil,
		bufferedAt = 0,
		posture = 0,
		lastPostureDamageAt = 0,
		stamina = Config.Stamina.Max,
		lastStaminaSpendAt = 0,
		blocking = false,
		deflectStamp = -math.huge,
		lastBlockPressAt = -math.huge,
		dodgeStamp = -math.huge,
		dodgeForward = false,
		nextDodgeAt = 0,
		jumpStamp = -math.huge,
		gourds = Config.Gourd.Charges,
		protectedUntil = if player then math.huge else now() + Config.SpawnProtection,
		lastAttacker = nil,
		lastAttackedAt = 0,
		executed = false,
	}
	combatants[model] = c

	-- Keep the body together on death so the client can play the collapse.
	humanoid.BreakJointsOnDeath = false
	SwordRig.attach(model)
	model:SetAttribute("PostureMax", Config.Posture.Max)
	model:SetAttribute("Posture", 0)
	model:SetAttribute("Blocking", false)
	model:SetAttribute("Gourds", c.gourds)
	model:SetAttribute("StaminaMax", Config.Stamina.Max)
	model:SetAttribute("Stamina", Config.Stamina.Max)
	setState(c, "Idle")
	CollectionService:AddTag(model, Types.Tag)

	humanoid.Died:Once(function()
		cancelAttack(c)
		setBlocking(c, false)
		setState(c, "Dead")
		combatants[model] = nil
		broadcast("Died", { model = model })
		local killer = c.lastAttacker
		if killer and now() - c.lastAttackedAt > KILL_CREDIT_WINDOW then
			killer = nil
		end
		for _, listener in diedListeners do
			task.spawn(listener, c, killer, c.executed)
		end
	end)
	model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(game) and combatants[model] == c then
			combatants[model] = nil
		end
	end)

	return c
end

local function onCharacterAdded(player: Player, character: Model)
	-- Wait for the parts the combat system and sword rig need.
	if not character:WaitForChild("HumanoidRootPart", 10) or not character:WaitForChild("Humanoid", 10) then
		return
	end
	character:WaitForChild("RightHand", 5)
	if player.Character ~= character then
		return
	end
	CombatService.register(character, player)

	-- Once the avatar has fully loaded and is in the world, swap in the Ninja animation
	-- pack, then re-grip the sword, since avatar loading can replace body parts.
	local deadline = os.clock() + 15
	while not (player:HasAppearanceLoaded() and character:IsDescendantOf(workspace)) do
		if os.clock() > deadline or player.Character ~= character then
			return
		end
		task.wait(0.1)
	end
	Locomotion.applyToPlayer(character)
	if combatants[character] then
		SwordRig.attach(character)
	end
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

local function step(dt: number)
	local t = now()
	for _, c in combatants do
		-- Windup ends via its own timer; every other timed state falls back to Idle.
		if c.state ~= "Windup" and c.state ~= "Dead" and t >= c.stateEndsAt then
			if c.state == "Broken" then
				c.posture = Config.Posture.Max * Config.Posture.ResetAfterBreak
				c.lastPostureDamageAt = t
			end
			setState(c, "Idle")
		end

		-- Fire a buffered attack the moment the fighter is free.
		if c.state == "Idle" and c.buffered then
			local action = c.buffered :: Action
			c.buffered = nil
			if t - c.bufferedAt <= Config.Combo.Buffer then
				attack(c, action)
			end
		end

		if c.posture > 0 and c.state ~= "Broken" and t - c.lastPostureDamageAt >= Config.Posture.RegenDelay then
			local multiplier = if c.blocking then Config.Posture.GuardRegenMultiplier else 1
			c.posture = math.max(0, c.posture - Config.Posture.RegenPerSecond * multiplier * dt)
		end
		publishPosture(c)

		local stamina = Config.Stamina
		if c.stamina < stamina.Max and t - c.lastStaminaSpendAt >= stamina.RegenDelay then
			local multiplier = if c.blocking then stamina.GuardRegenMultiplier else 1
			c.stamina = math.min(stamina.Max, c.stamina + stamina.RegenPerSecond * multiplier * dt)
			publishStamina(c)
		end
	end
end

function CombatService.start()
	combatAction.OnServerEvent:Connect(function(player: Player, action: unknown, stamp: unknown, flag: unknown)
		if typeof(action) ~= "string" or not validActions[action :: string] then
			return
		end
		if not withinBudget(player) then
			return
		end
		local character = player.Character
		local c = character and combatants[character]
		if c then
			CombatService.perform(c, action :: Action, clampStamp(stamp), flag == true)
		end
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		actionBudgets[player] = nil
	end)

	RunService.Heartbeat:Connect(step)
end

return CombatService
