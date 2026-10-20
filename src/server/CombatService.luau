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
--   Slashes chain Light1 -> Light2 -> (Light3 | Overhead) while pressed inside Combo.Window.
--   A string speeds up only while it keeps landing; a deflect ends it. The third hit is a
--   read: fast on rhythm, a delayed Overhead after a pause, a perilous morph (E/C), or a
--   feint (block) -- one morph or feint per string. Attacks pressed slightly early are
--   buffered (last input wins) and fire the moment the fighter is free; block or dodge
--   clears the buffer and can cut recovery short, so inputs never feel eaten.

local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
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
	deflectWindow: number, -- how long that press stays armed (shrinks when mashing)
	lastBlockPressAt: number,
	spamStacks: number,
	deflectChain: number, -- deflects in quick succession, for the chain bonus
	lastDeflectAt: number,
	windupKind: AttackKind?, -- what this fighter is winding up, for hyper armour
	riposteUntil: number, -- a slash before this is a Riposte (set by a successful deflect)
	lastDeflected: Combatant?, -- whose swing we last deflected, for the third-party guard
	groupReadyAt: { [string]: number }, -- shared cooldown groups (Config.Cooldowns)
	groupUses: { [string]: number },
	groupLastUseAt: { [string]: number },
	idleSince: number, -- when the fighter last became free to act (for the delayed ender)
	lastSlashLanded: boolean, -- the previous attack in the string hit cleanly
	stringTrickUsed: boolean, -- this string has already morphed or feinted
	justFeinted: boolean, -- the next slash comes out of a feint

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
local FIGHTERS = "Fighters" -- collision group shared by every combatant
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
	if state == "Idle" and c.state ~= "Idle" then
		c.idleSince = now()
	end
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
	-- Hyper armour covers only the end of a windup: hits then hurt but don't stop the
	-- swing. Earlier, a read windup can still be interrupted.
	local kind = c.windupKind
	local armorFrom = kind and Config.Attacks[kind].armorFrom
	if c.state == "Windup" and armorFrom and now() >= c.windupHitAt - armorFrom then
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

-- The hit area is a box in front of where the attacker stood and faced at the moment of
-- the strike (`strike`), so turning afterwards can't re-aim a committed swing.
local function findTargets(attacker: Combatant, spec: AttackSpec, strike: CFrame): { Combatant }
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { attacker.model }

	local box = strike * CFrame.new(0, 0, -spec.range / 2)
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

local specKinds: { [AttackSpec]: AttackKind } = {}
for kind, spec in Config.Attacks do
	specKinds[spec] = kind
end
local function kindOf(spec: AttackSpec): AttackKind?
	return specKinds[spec]
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
		-- Clearing a sweep up close means landing on the attacker's head, as in Sekiro.
		local close = (attacker.root.Position - target.root.Position).Magnitude <= Config.Jump.KickRange
		if close then
			addPosture(attacker, Config.Jump.KickPosture)
		end
		-- A jumped sweep leaves its owner stuck in a long recovery: the read is rewarded.
		if attacker.state == "Recovery" then
			attacker.stateEndsAt = math.max(attacker.stateEndsAt, now() + Config.PerilousCounter.JumpedRecovery)
			attacker.cancelableAt = attacker.stateEndsAt
		end
		broadcast("Jumped", { attacker = attacker.model, defender = target.model, kick = close })
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

	local deflectRules = Config.Deflect
	local canDeflect = not spec.unblockable and isFacing(target, attacker)
	local canGuard = canDeflect and not spec.noGuard
	-- Just after a deflect, swings from anyone else are auto-guarded.
	local thirdParty = target.lastDeflected ~= nil
		and target.lastDeflected ~= attacker
		and hitAt - target.lastDeflectAt <= deflectRules.ThirdPartyGuard
	if thirdParty and not spec.unblockable then
		addPosture(target, spec.postureDamage * Config.Deflect.GuardPostureMultiplier * 0.5)
		broadcast("Guard", { attacker = attacker.model, defender = target.model })
		return
	end
	local sinceDeflect = hitAt - target.deflectStamp
	local deflectArmed = sinceDeflect >= -deflectRules.LateTolerance and sinceDeflect <= target.deflectWindow

	if canDeflect and deflectArmed then
		local perfect = sinceDeflect <= math.min(deflectRules.PerfectWindow, target.deflectWindow)
		local recoil = if perfect then deflectRules.PerfectAttackerRecoil else deflectRules.AttackerRecoil
		-- Deflects in quick succession hit the attacker's posture harder each time.
		local t = now()
		target.deflectChain = if t - target.lastDeflectAt < deflectRules.ChainWindow then target.deflectChain + 1 else 0
		target.lastDeflectAt = t
		target.spamStacks = 0 -- a successful deflect clears the mashing penalty
		local multiplier = math.min(deflectRules.ChainMax, 1 + deflectRules.ChainBonus * target.deflectChain)
		if spec.perilous then
			-- A deflected perilous thrust is a big read: it costs its owner a posture chunk
			-- and a long recoil.
			recoil = math.max(recoil, Config.PerilousCounter.DeflectRecoil)
			addPosture(attacker, Config.PerilousCounter.DeflectPosture)
		end
		if perfect then
			addPosture(attacker, deflectRules.PerfectAttackerPosture * multiplier)
		else
			addPosture(attacker, deflectRules.AttackerPosture * multiplier)
			addPosture(target, deflectRules.DefenderPosture)
		end
		-- The payoff: a fast, uninterruptible counter-cut is available for a moment.
		target.riposteUntil = t + deflectRules.RiposteWindow
		target.lastDeflected = attacker
		if attacker.state ~= "Broken" then
			stagger(attacker, recoil)
		end
		broadcast("Deflect", {
			attacker = attacker.model,
			defender = target.model,
			perfect = perfect,
			chain = target.deflectChain,
		})
		for _, listener in deflectListeners do
			task.spawn(listener, attacker, target, perfect)
		end
	elseif canGuard and target.blocking then
		addPosture(target, spec.postureDamage * Config.Deflect.GuardPostureMultiplier)
		broadcast("Guard", { attacker = attacker.model, defender = target.model })
	else
		target.lastAttacker = attacker
		target.lastAttackedAt = now()
		attacker.lastSlashLanded = true
		target.humanoid:TakeDamage(spec.damage)
		addPosture(target, spec.postureDamage * Config.HitPostureMultiplier)
		stagger(target, Config.HitStagger)
		broadcast(
			"Hit",
			{ attacker = attacker.model, defender = target.model, damage = spec.damage, kind = kindOf(spec) }
		)
	end
end

local function resolveAttack(attacker: Combatant, spec: AttackSpec, hitAt: number, strike: CFrame)
	local targets = findTargets(attacker, spec, strike)
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
	if c.comboIndex == 1 then
		-- A new string, unless it is the slash right out of a feint: you can't feint
		-- again out of a feinted attack.
		c.stringTrickUsed = c.justFeinted
		c.lastSlashLanded = false
	end
	c.justFeinted = false
	local kind = sequence[c.comboIndex]
	if kind == "Light3" and t - c.idleSince >= Config.Combo.DelayAfter then
		return "Overhead" -- held back a beat: the delayed overhead
	end
	return kind
end

local function enemyWithinReach(c: Combatant, strike: CFrame): boolean
	for _, other in combatants do
		if other ~= c and other.state ~= "Dead" then
			local offset = other.root.Position - strike.Position
			local flat = Vector3.new(offset.X, 0, offset.Z)
			if flat.Magnitude < 5.5 and flat.Unit:Dot(strike.LookVector) > 0.5 then
				return true
			end
		end
	end
	return false
end

local function startAttack(c: Combatant, kind: AttackKind, windupOverride: number?): boolean
	local spec = Config.Attacks[kind]
	local t = now()
	if c.state ~= "Idle" or t < (c.nextAttackAt[kind] or 0) then
		return false
	end
	local group = spec.cooldownGroup
	if group and t < (c.groupReadyAt[group] or 0) then
		return false
	end
	if not spendStamina(c, Config.Stamina.Costs[kind]) then
		return false
	end
	-- Strings speed up only while they keep landing.
	local windup = windupOverride
		or (if spec.chainWindup and c.comboIndex >= 2 and c.lastSlashLanded then spec.chainWindup else spec.windup)
	c.lastSlashLanded = false
	if group then
		-- Escalating shared cooldown: each use soon after the last makes the next wait longer.
		local rules = Config.Cooldowns[group]
		local uses = if t - (c.groupLastUseAt[group] or -math.huge) <= rules.Memory
			then (c.groupUses[group] or 0) + 1
			else 0
		c.groupUses[group] = uses
		c.groupLastUseAt[group] = t
		c.groupReadyAt[group] = t + rules.Base * rules.Escalation ^ uses
		c.model:SetAttribute(group .. "ReadyAt", c.groupReadyAt[group])
	end
	if spec.riposte then
		c.riposteUntil = 0
		c.comboIndex = 1 -- the riposte stands in for the first slash: chain on into Light2
		c.comboUntil = t + windup + Config.Net.ResolveGrace + spec.recovery + Config.Combo.Window
	end

	setBlocking(c, false)
	cancelAttack(c)
	c.protectedUntil = 0 -- attacking ends spawn protection
	local token = c.attackToken
	local hitAt = t + windup
	c.windupHitAt = hitAt
	c.windupKind = kind
	c.cancelableAt = hitAt + Config.Net.ResolveGrace + Config.Combo.RecoveryCancel
	c.nextAttackAt[kind] = t + spec.cooldown
	c.comboUntil = hitAt + Config.Net.ResolveGrace + spec.recovery + Config.Combo.Window
	if spec.ender then
		-- The string is over: a short rest hands the turn to the defender.
		c.nextAttackAt.Light1 = hitAt + Config.Net.ResolveGrace + spec.recovery + Config.Combo.EnderRest
	end
	setState(c, "Windup")

	broadcast("Windup", { attacker = c.model, kind = kind, hitAt = hitAt })
	for _, listener in windupListeners do
		task.spawn(listener, c, kind, hitAt)
	end

	task.delay(windup, function()
		if c.attackToken ~= token or c.state ~= "Windup" then
			return -- interrupted, feinted or broken during the windup
		end
		-- The swing has landed visually; from here it is committed and can't be interrupted.
		c.windupKind = nil
		local look = c.root.CFrame.LookVector
		local strike = CFrame.lookAt(c.root.Position, c.root.Position + Vector3.new(look.X, 0, look.Z))
		setState(c, "Recovery", Config.Net.ResolveGrace + spec.recovery)
		if not c.player and not enemyWithinReach(c, strike) then
			-- Bots are simulated here; players lunge on their own client. Fighters don't
			-- collide, so don't lunge through someone already within reach.
			c.root.AssemblyLinearVelocity += strike.LookVector * spec.lunge
		end
		task.delay(Config.Net.ResolveGrace, function()
			if isAlive(c) then
				resolveAttack(c, spec, hitAt, strike)
			end
		end)
	end)
	return true
end

local function bufferAction(c: Combatant, action: Action)
	c.buffered = action
	c.bufferedAt = now()
end

-- E or C late in a string turns its ender into a perilous attack with a shorter windup:
-- from Light2's recovery (once it has resolved) or early in the third slash's windup.
local function tryMorph(c: Combatant, action: Action): boolean
	if (action ~= "Perilous" and action ~= "Sweep") or c.stringTrickUsed then
		return false
	end
	local t = now()
	local fromRecovery = c.state == "Recovery" and c.comboIndex == 2 and t >= c.cancelableAt
	local thirdKind = c.windupKind
	local fromWindup = c.state == "Windup"
		and (thirdKind == "Light3" or thirdKind == "Overhead")
		and t < c.windupHitAt - Config.Feint.Cutoff
	if not fromRecovery and not fromWindup then
		return false
	end
	local kind: AttackKind = if action == "Perilous" then "Perilous" else "Sweep"
	local group = Config.Attacks[kind].cooldownGroup
	if group and t < (c.groupReadyAt[group] or 0) then
		return false
	end
	cancelAttack(c)
	setState(c, "Idle")
	if startAttack(c, kind, Config.Combo.MorphWindup) then
		c.stringTrickUsed = true
		c.comboIndex = 0
		return true
	end
	return false
end

local function attack(c: Combatant, action: Action): boolean
	if tryMorph(c, action) then
		return true
	end
	if c.state ~= "Idle" then
		bufferAction(c, action)
		return false
	end
	local t = now()
	local kind: AttackKind = if action == "Perilous"
		then "Perilous"
		elseif action == "Sweep" then "Sweep"
		elseif t <= c.riposteUntil then "Riposte"
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
	c.buffered = nil -- defending overrides any queued attack
	if c.state == "Windup" then
		-- Blocking out of a windup is a feint: it baits deflects at a small posture and
		-- stamina cost. Once per string, never out of a riposte, never right before impact.
		local kind = c.windupKind
		if
			t > c.windupHitAt - Config.Feint.Cutoff
			or c.stringTrickUsed
			or (kind and Config.Attacks[kind].riposte)
			or not spendStamina(c, Config.Feint.StaminaCost)
		then
			return false
		end
		c.stringTrickUsed = true
		c.justFeinted = true
		cancelAttack(c)
		c.comboIndex = 0
		c.nextAttackAt.Light1 = 0 -- a feinted ender didn't finish the string: slash straight out of it
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
	-- Every press arms a deflect, but pressing again soon after the last one shrinks the
	-- window (Sekiro's mashing penalty), down to a floor. It clears with time or a deflect.
	local rules = Config.Deflect
	c.spamStacks = if t - c.lastBlockPressAt <= rules.SpamMemory then c.spamStacks + 1 else 0
	c.lastBlockPressAt = t
	c.deflectStamp = stamp
	c.deflectWindow = math.max(rules.MinWindow, rules.Window - c.spamStacks * rules.SpamPenaltyPerPress)
	return true
end

local function dodge(c: Combatant, stamp: number, forward: boolean): boolean
	local t = now()
	c.buffered = nil
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
		deflectWindow = Config.Deflect.Window,
		lastBlockPressAt = -math.huge,
		spamStacks = 0,
		deflectChain = 0,
		lastDeflectAt = -math.huge,
		windupKind = nil,
		riposteUntil = 0,
		lastDeflected = nil,
		groupReadyAt = {},
		groupUses = {},
		groupLastUseAt = {},
		idleSince = 0,
		lastSlashLanded = false,
		stringTrickUsed = false,
		justFeinted = false,
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

	-- Fighters pass through each other: no body-blocking, and no collisions for the
	-- physics solver to "resolve" by launching someone into the sky.
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = FIGHTERS
		end
	end
	model.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = FIGHTERS
		end
	end)

	-- No passive regeneration: Roblox's default "Health" script would quietly undercut the
	-- healing gourd. Vitality comes back only by drinking.
	local regen = model:FindFirstChild("Health")
	if regen and regen:IsA("Script") then
		regen:Destroy()
	end

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
			local rules = Config.Posture
			local vitality = math.clamp(c.humanoid.Health / math.max(c.humanoid.MaxHealth, 1), 0, 1)
			local multiplier = (if c.blocking then rules.GuardRegenMultiplier else 1)
				* (rules.VitalityRegenFloor + (1 - rules.VitalityRegenFloor) * vitality)
			c.posture = math.max(0, c.posture - rules.RegenPerSecond * multiplier * dt)
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
	pcall(function()
		PhysicsService:RegisterCollisionGroup(FIGHTERS)
	end)
	PhysicsService:CollisionGroupSetCollidable(FIGHTERS, FIGHTERS, false)

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
