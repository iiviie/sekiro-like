--!strict
-- Server-authoritative combat: attack phases, deflect / guard / hit resolution, posture.
--
-- Timing model
--   When a windup starts, the server fixes the impact time `hitAt` on the shared server
--   clock and broadcasts it, so every client lands its swing visual on the same instant.
--   Defender inputs carry the client's synced clock stamp. The server clamps that stamp
--   to at most Net.CompensationCap in the past (dodges and jumps to one-way ping), and
--   waits a ping-scaled grace after hitAt before resolving, so a deflect pressed on time on
--   the defender's screen still counts while its packet is in flight. Targets are judged
--   where they stood at hitAt (a short position history), not where they are at resolve.
--   Clients only ever send intents; the server owns posture, health and every outcome.
--
-- Flow (modelled on Kannagi Usagi, see research_notes/Kannagi Usagi RE)
--   Slashes chain Light1 -> Light2 -> (Light3 | Overhead) while pressed inside Combo.Window.
--   A string speeds up only while it keeps landing. Deflecting an opener only knocks the
--   blade aside: the string goes on and has to be deflected in rhythm; deflecting a move
--   with `recoilOnDeflect` (enders, perilous thrusts) recoils the attacker and opens the
--   defender's Riposte counter-string. Dodges and Mikiris open their own follow-ups.
--   The third hit is a read: fast on rhythm, a delayed Overhead after a pause, a perilous
--   morph (E/C), or a feint (block) -- one morph or feint per string.
--   Every input pressed while busy is buffered (Combo.Buffer, last input wins) and retried
--   each frame until it becomes legal: a swing's recovery can be cancelled into each input
--   from that move's own cancel point. Holding block through any action re-raises guard
--   the moment it ends, with a fresh deflect window.

local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bosses = require(Shared.Bosses)
local Config = require(Shared.Config)
local Types = require(Shared.Types)
local Spacing = require(Shared.Spacing)
local Weapons = require(Shared.Weapons)
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
	weapon: string, -- Weapons id; every move is read through Weapons.spec(weapon, kind)
	postureProfile: string, -- Config.Posture.Profiles entry: how blows build this fighter's posture

	state: CombatState,
	stateEndsAt: number,
	attackToken: number, -- bumped to invalidate a pending windup
	windupHitAt: number,
	attackKind: AttackKind?, -- the latest attack started (its cancel points and stomp window)
	attackStartedAt: number,
	attackHitAt: number,
	cancelLockUntil: number, -- recovery can't be cancelled before this (a jumped sweep)
	nextAttackAt: { [AttackKind]: number },
	comboIndex: number,
	comboUntil: number,
	followKind: AttackKind?, -- the next slash of a counter-string (AttackSpec.follow)
	buffered: Action?,
	bufferedAt: number,
	bufferedFlag: boolean,

	posture: number,
	postureRegenAt: number, -- recovery restarts at this time (pushed back by each posture event)
	postureFrozenUntil: number, -- Mikiri and stomp freeze recovery outright
	stamina: number,
	lastStaminaSpendAt: number,

	blocking: boolean,
	blockHeld: boolean, -- the block key is down: guard re-raises whenever an action ends
	deflectStamp: number, -- when the latest press opened its deflect window
	deflectWindow: number, -- how long that window stays open
	lastBlockReleaseAt: number, -- for the re-press lockout
	lastContactAt: number, -- the last time any blow reached this fighter
	lastDefendAt: number, -- the last deflect or guarded hit (chained presses open instantly)
	deflectChain: number, -- deflects in quick succession, for the chain bonus
	lastDeflectAt: number,
	windupKind: AttackKind?, -- what this fighter is winding up, for hyper armour
	riposteUntil: number, -- a slash before this is a Riposte (set by a recoil deflect)
	mikiriUntil: number, -- a slash before this is a MikiriSlash
	lastDeflected: Combatant?, -- whose swing we last deflected, for the third-party guard
	groupReadyAt: { [string]: number }, -- shared cooldown groups (Config.Cooldowns)
	groupUses: { [string]: number },
	groupLastUseAt: { [string]: number },
	idleSince: number, -- when the fighter last became free to act (for the delayed ender)
	lastSlashLanded: boolean, -- the previous attack in the string hit cleanly
	stringTrickUsed: boolean, -- this string has already morphed or feinted
	justFeinted: boolean, -- the next slash comes out of a feint

	dodgeStamp: number,
	dodgeStartedAt: number, -- server time of the latest dodge (DodgeSlash window)
	dodgeForward: boolean, -- dashed toward the attacker (for Mikiri)
	nextDodgeAt: number,
	jumpStamp: number, -- the latest jump the server has seen happen
	pendingJumpStamp: number?, -- a reported jump waiting for the body to leave the ground
	pendingJumpUntil: number,
	lastJumpAt: number,
	lastStompAt: number,
	gourds: number,
	protectedUntil: number,

	lastAttacker: Combatant?, -- for kill credit
	brokenBy: Combatant?, -- who broke this fighter's posture (for the deathblow right)
	brokenAt: number,
	recentAttackers: { [Combatant]: number }, -- distinct strikers and when, for Resolve
	resolve: boolean, -- outnumbered right now
	lastAttackedAt: number,
	executed: boolean, -- killed by a deathblow
	resurrections: number, -- lethal blows this fighter can still rise from (Config.Resurrection)
	god: boolean, -- Studio tests (BossTest god): blows still land and flinch, but never take vitality

	-- Root positions over the last HISTORY_SECONDS, so hits are judged where targets stood at
	-- impact rather than where they are a resolve-grace later.
	history: { { t: number, p: Vector3 } },
	historyHead: number,
	pushToken: number, -- bots: the latest server-driven slide (lunge, knockback)

	-- Bosses (server/BossAI): driven by a script instead of perform(), with their own posture
	-- bar, break length and Kannagi's guard / parry flags.
	postureMax: number,
	brokenDuration: number?, -- the deathblow window when this fighter's posture breaks
	postureRegen: number?, -- recovery per second, over the posture profile's
	scripted: boolean, -- a boss: its AI reacts to deflects, Mikiris and stomps itself
	superArmor: number, -- Kannagi's SuperArmor_Flag: > 0, hits hurt but never flinch
	-- Kannagi's Guard_Flag / Hajiki_Flag / HajikiDisable_Flag as they stood at time `t`.
	bossGuard: ((t: number) -> (boolean, boolean, boolean))?,
	parryPosture: number?, -- posture an attacker takes when this fighter parries them
	stompKind: AttackKind?, -- the latest low hit (a boss string's sweep can be stomped late)
	stompHitAt: number,
	hooks: BossHooks?,
}

-- A boss's lives: a deathblow or a lethal blow goes to its AI instead of killing it.
export type BossHooks = {
	deathblow: (attacker: Combatant) -> boolean, -- returns whether it was the last life
	lethal: (by: Combatant?) -> (),
}

type WindupListener = (attacker: Combatant, kind: AttackKind, hitAt: number) -> ()
type DeflectListener = (attacker: Combatant, defender: Combatant, perfect: boolean) -> ()
type DiedListener = (victim: Combatant, killer: Combatant?, deathblow: boolean) -> ()
-- A fighter was cut down but will rise (a resurrection was spent). Kill credit still pays.
type CutDownListener = (victim: Combatant, killer: Combatant?, deathblow: boolean) -> ()

local CombatService = {}

local combatants: { [Model]: Combatant } = {}
local windupListeners: { WindupListener } = {}
local deflectListeners: { DeflectListener } = {}
local diedListeners: { DiedListener } = {}
local cutDownListeners: { CutDownListener } = {}

local dropWeapons: (model: Model) -> () -- defined below, with the character hooks

local KILL_CREDIT_WINDOW = 12 -- seconds a hit still counts toward a later death
local FIGHTERS = "Fighters" -- collision group shared by every combatant
local HISTORY_SIZE = 48 -- samples (one per Heartbeat): ~0.8 s at 60 Hz
local BODY_HALF_WIDTH = 1 -- studs a body reaches sideways from its root, for the hit box
local BODY_HALF_HEIGHT = 2.5
local PUSH_FORCE = 4e4 -- as client/Motion: enough to move a body, never to fling one
local actionBudgets: { [Player]: { windowStart: number, count: number } } = {}

-- Inputs that wait in the buffer when they can't happen yet.
local BUFFERED: { [string]: boolean } = {
	Attack = true,
	Perilous = true,
	Sweep = true,
	BlockDown = true,
	Dodge = true,
	Heal = true,
}
local ATTACKS: { [string]: boolean } = { Attack = true, Perilous = true, Sweep = true }

local validActions: { [string]: boolean } = {}
for _, action in Types.Actions do
	validActions[action] = true
end

local sequenceIndex: { [string]: number } = {}
for index, kind in Config.Combo.Sequence do
	sequenceIndex[kind] = index
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

local function pingOf(c: Combatant): number
	local player = c.player
	if not player then
		return 0
	end
	local ok, ping = pcall(function()
		return player:GetNetworkPing()
	end)
	return if ok and typeof(ping) == "number" then ping else 0
end

-- How far a dodge or jump stamp may claim to be in the past: one-way ping plus slack, so a
-- late press can't buy i-frames after the blow was already seen landing.
local function backdateCap(c: Combatant): number
	if not c.player then
		return Config.Net.CompensationCap
	end
	return math.min(Config.Net.CompensationCap, pingOf(c) / 2 + Config.Jump.BackdateSlack)
end

-- Bots only: a player's own client sets its WalkSpeed every frame (client/Movement), so
-- the slowdown for a swing or guard is instant on their screen.
local function refreshWalkSpeed(c: Combatant)
	if c.player then
		return
	end
	local speed = Config.WalkSpeed
	if c.state == "Windup" or c.state == "Recovery" then
		speed = Config.AttackWalkSpeed
	elseif c.state == "Staggered" then
		speed = Config.StaggerWalkSpeed
	elseif c.state == "Drinking" then
		speed = Config.DrinkWalkSpeed
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

local function clearAttackBuffer(c: Combatant)
	if c.buffered and ATTACKS[c.buffered :: string] then
		c.buffered = nil
	end
end

local function profileOf(c: Combatant)
	return Config.Posture.Profiles[c.postureProfile] or Config.Posture.Profiles.Fighter
end

-- The spec of a move this fighter performs: a boss hit kind, or a move of its weapon.
local function specOf(c: Combatant, kind: AttackKind): AttackSpec
	return Bosses.spec(kind :: any) or Weapons.spec(c.weapon, kind)
end

-- Builds (or, when `canBreak` is false, nearly builds) posture, and restarts the recovery
-- delay for this kind of event (Config.Posture.Delay). Kannagi's retriggerable delay: the
-- latest event sets it, so a deflect after a guarded hit lets recovery start sooner.
local function addPosture(c: Combatant, amount: number, by: Combatant?, canBreak: boolean, delayKind: string)
	if c.state == "Broken" or c.state == "Dead" or c.state == "Downed" then
		return
	end
	local rules = Config.Posture
	local t = now()
	c.postureRegenAt = t + (profileOf(c).RegenDelay or rules.Delay[delayKind] or rules.Delay.Other)
	if amount <= 0 then
		return
	end
	if by and workspace:GetAttribute("Omen") == "IronWill" then
		amount *= Config.Omens.IronWillPosture
	end
	if not canBreak then
		-- Clean hits fill the bar but can't break it: the guard that follows does.
		c.posture = math.max(c.posture, math.min(c.postureMax - 1, c.posture + amount))
		publishPosture(c)
		return
	end
	c.posture = math.min(c.postureMax, c.posture + amount)
	if c.posture >= c.postureMax then
		c.brokenBy = by
		c.brokenAt = t
		cancelAttack(c)
		setBlocking(c, false)
		c.buffered = nil
		setState(c, "Broken", c.brokenDuration or rules.BrokenDuration)
		broadcast("PostureBroken", { model = c.model })
	end
	publishPosture(c)
end

-- Bots only (a player's client moves its own body): a slide along the ground whose speed
-- eases out from `startSpeed` to `endSpeed` over `duration`, like client/Motion.surge.
local function surgeBot(c: Combatant, direction: Vector3, startSpeed: number, endSpeed: number, duration: number)
	if c.player or duration <= 0 then
		return
	end
	local flat = Vector3.new(direction.X, 0, direction.Z)
	local attachment = c.root:FindFirstChild("RootAttachment")
	if flat.Magnitude < 1e-3 or not attachment or not attachment:IsA("Attachment") then
		return
	end
	flat = flat.Unit
	local push = c.root:FindFirstChild("CombatPush") :: LinearVelocity?
	if not push then
		local created = Instance.new("LinearVelocity")
		created.Name = "CombatPush"
		created.Attachment0 = attachment
		created.RelativeTo = Enum.ActuatorRelativeTo.World
		created.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
		created.PrimaryTangentAxis = Vector3.xAxis
		created.SecondaryTangentAxis = Vector3.zAxis
		created.MaxForce = PUSH_FORCE
		created.Parent = c.root
		push = created
	end
	local active = push :: LinearVelocity
	c.pushToken += 1
	local token = c.pushToken
	local startedAt = os.clock()
	active.PlaneVelocity = Vector2.new(flat.X * startSpeed, flat.Z * startSpeed)
	active.Enabled = true
	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function(dt: number)
		if c.pushToken ~= token or not active.Parent then
			connection:Disconnect()
			return
		end
		local u = math.clamp((os.clock() - startedAt) / duration, 0, 1)
		local speed = endSpeed + (startSpeed - endSpeed) * (1 - u) * (1 - u)
		-- Never into a body (Shared/Spacing): the slide stops at contact, and a fast frame is
		-- shortened so it can't carry the body past it.
		local velocity = Spacing.limit(c.model, c.root.Position, flat * speed, dt)
		active.PlaneVelocity = Vector2.new(velocity.X, velocity.Z)
		if u >= 1 then
			active.Enabled = false
			connection:Disconnect()
		end
	end)
end

-- A knockback of `distance` studs over Knockback.Duration (Kannagi's 1 -> 0 curve).
local function slideBot(c: Combatant, direction: Vector3, distance: number)
	local duration = Config.Knockback.Duration
	if distance > 0 then
		surgeBot(c, direction, 3 * distance / duration, 0, duration)
	end
end

-- Bots only: turn to face `toward` at once (a flinch snaps the victim toward the blow).
local function faceBot(c: Combatant, toward: Vector3)
	if c.player then
		return
	end
	local offset = toward - c.root.Position
	local flat = Vector3.new(offset.X, 0, offset.Z)
	if flat.Magnitude > 0.1 then
		c.root.CFrame = CFrame.lookAt(c.root.Position, c.root.Position + flat)
	end
end

-- Hyper armour covers only the end of a windup: hits then hurt but don't stop the swing.
-- Earlier, a read windup can still be interrupted.
local function armoured(c: Combatant): boolean
	if c.superArmor > 0 then
		return true
	end
	local kind = c.windupKind
	local armorFrom = kind and specOf(c, kind).armorFrom
	return c.state == "Windup" and armorFrom ~= nil and now() >= c.windupHitAt - armorFrom
end

-- Returns whether the stagger took (hyper armour late in a windup shrugs it off).
local function stagger(c: Combatant, duration: number): boolean
	if c.state == "Broken" or c.state == "Dead" or c.state == "Downed" or armoured(c) then
		return false
	end
	if c.state == "Windup" then
		broadcast("Interrupted", { model = c.model })
	end
	cancelAttack(c)
	clearAttackBuffer(c)
	c.comboIndex = 0
	c.followKind = nil
	-- A flinch drops guard; a held key raises it again when the stagger ends.
	setBlocking(c, false)
	setState(c, "Staggered", duration)
	return true
end

-- Every hit goes through here. A blow that would kill a fighter with a resurrection left
-- cuts them down instead: they kneel, untouchable, then rise (see `rise`, called from step).
local function dealDamage(target: Combatant, amount: number, by: Combatant?, deathblow: boolean?)
	if target.god then
		return
	end
	local humanoid = target.humanoid
	local hooks = target.hooks
	if hooks and amount >= humanoid.Health and isAlive(target) then
		-- A boss never dies to a blow: vitality 0 breaks its posture (Kannagi's HPBreak), and
		-- only a deathblow takes a life.
		humanoid.Health = math.min(humanoid.Health, 1)
		hooks.lethal(by)
		return
	end
	if amount < humanoid.Health or target.resurrections <= 0 or not isAlive(target) then
		humanoid:TakeDamage(amount)
		return
	end
	target.resurrections -= 1
	target.model:SetAttribute("Resurrections", target.resurrections)
	humanoid.Health = 1
	cancelAttack(target)
	setBlocking(target, false)
	target.buffered = nil
	target.comboIndex = 0
	target.posture = 0
	target.brokenBy = nil
	target.executed = false
	publishPosture(target)
	local rules = Config.Resurrection
	target.protectedUntil = now() + rules.DownTime + rules.Protection
	setState(target, "Downed", rules.DownTime)
	local killer = by or target.lastAttacker
	broadcast("CutDown", { model = target.model, killer = killer and killer.model, deathblow = deathblow == true })
	for _, listener in cutDownListeners do
		task.spawn(listener, target, killer, deathblow == true)
	end
end

local function rise(c: Combatant)
	c.humanoid.Health = math.max(c.humanoid.Health, c.humanoid.MaxHealth * Config.Resurrection.Vitality)
	c.posture = 0
	c.stamina = Config.Stamina.Max
	c.lastAttacker = nil
	publishPosture(c)
	publishStamina(c)
	setState(c, "Idle")
	broadcast("Resurrected", { model = c.model })
end

local function isFacing(defender: Combatant, attacker: Combatant): boolean
	local offset = attacker.root.Position - defender.root.Position
	local flat = Vector3.new(offset.X, 0, offset.Z)
	if flat.Magnitude < 0.01 then
		return true
	end
	return defender.root.CFrame.LookVector:Dot(flat.Unit) >= Config.Deflect.FacingDot
end

local function recordPosition(c: Combatant, t: number)
	c.historyHead = c.historyHead % HISTORY_SIZE + 1
	local sample = c.history[c.historyHead]
	if sample then
		sample.t, sample.p = t, c.root.Position
	else
		c.history[c.historyHead] = { t = t, p = c.root.Position }
	end
end

-- Where this fighter's root was at server time `t` (interpolated from the history; the
-- current position if `t` is newer than every sample, the oldest if it is older).
local function positionAt(c: Combatant, t: number): Vector3
	local count = #c.history
	local newer: { t: number, p: Vector3 }? = nil
	for i = 0, count - 1 do
		local index = (c.historyHead - 1 - i) % count + 1
		local sample = c.history[index]
		if sample.t <= t then
			if not newer then
				return c.root.Position
			end
			local span = newer.t - sample.t
			local alpha = if span > 1e-4 then (t - sample.t) / span else 1
			return sample.p:Lerp(newer.p, alpha)
		end
		newer = sample
	end
	return if newer then newer.p else c.root.Position
end

-- The hit area is a box in front of where the attacker stood and faced at the moment of
-- the strike (`strike`), so turning afterwards can't re-aim a committed swing. Targets are
-- tested where they stood at `hitAt`, so stepping away after the blow landed (or into it
-- after it passed) changes nothing.
local function findTargets(attacker: Combatant, spec: AttackSpec, strike: CFrame, hitAt: number): { Combatant }
	local box = strike * CFrame.new(0, 0, -spec.range / 2)
	local halfX = spec.width / 2 + BODY_HALF_WIDTH
	local halfY = 3 + BODY_HALF_HEIGHT
	local halfZ = spec.range / 2 + 0.75
	local targets: { Combatant } = {}
	for _, other in combatants do
		if other ~= attacker and other.state ~= "Dead" then
			local p = box:PointToObjectSpace(positionAt(other, hitAt))
			if math.abs(p.X) <= halfX and math.abs(p.Y) <= halfY and math.abs(p.Z) <= halfZ then
				table.insert(targets, other)
			end
		end
	end
	return targets
end

-- Balance telemetry: every resolved strike reports (move, outcome). See Telemetry.
type OutcomeListener = (kind: string, outcome: string, attacker: Combatant, target: Combatant?) -> ()
local outcomeListeners: { OutcomeListener } = {}
local function report(spec: AttackSpec, outcome: string, attacker: Combatant, target: Combatant?)
	local kind = spec.kind or "?"
	for _, listener in outcomeListeners do
		task.spawn(listener, kind, outcome, attacker, target)
	end
end
function CombatService.onOutcome(listener: OutcomeListener)
	table.insert(outcomeListeners, listener)
end

-- How long to wait past impact before resolving: long enough for the slowest nearby
-- defender's block press to arrive, and no longer.
local function resolveGrace(attacker: Combatant, spec: AttackSpec, strike: CFrame): number
	local net = Config.Net
	local worstPing = 0
	for _, other in combatants do
		if
			other ~= attacker
			and other.player
			and (other.root.Position - strike.Position).Magnitude <= spec.range + 8
		then
			worstPing = math.max(worstPing, pingOf(other))
		end
	end
	return math.clamp(worstPing / 2 + net.GraceBase, net.GraceMin, net.GraceMax)
end

local assistMultiplier: (c: Combatant, field: "WindowMultiplier" | "PerfectMultiplier") -> number

local hitAllowed: (attacker: Combatant, target: Combatant) -> boolean = function(_attacker, _target)
	return true
end

local function flatDirection(from: Vector3, to: Vector3): Vector3
	local offset = to - from
	local flat = Vector3.new(offset.X, 0, offset.Z)
	return if flat.Magnitude > 1e-3 then flat.Unit else Vector3.zero
end

local function deathblow(attacker: Combatant, target: Combatant, spec: AttackSpec)
	report(spec, "Deathblow", attacker, target)
	target.lastAttacker = attacker
	target.lastAttackedAt = now()
	local hooks = target.hooks
	if hooks then
		local last = hooks.deathblow(attacker)
		target.executed = last
		broadcast("Deathblow", { attacker = attacker.model, defender = target.model, lethal = last, boss = true })
		return
	end
	local bloodMoon = workspace:GetAttribute("Omen") == "BloodMoon"
	local damage = if bloodMoon then target.humanoid.MaxHealth * 2 else Config.DeathblowDamage
	local lethal = target.humanoid.Health <= damage
	target.executed = lethal
	broadcast("Deathblow", { attacker = attacker.model, defender = target.model, lethal = lethal })
	dealDamage(target, damage, attacker, true)
	if not lethal and isAlive(target) and target.state ~= "Downed" then
		-- Survived the deathblow: knocked down hard, posture wiped (Kannagi resets it), back up.
		target.posture = 0
		target.brokenBy = nil
		setState(target, "Staggered", Config.Posture.SurvivedDeathblowStun)
		publishPosture(target)
	end
end

-- A clean hit: vitality, some posture (which can't break a Fighter), a flinch sized by
-- the move, a knockback slide and a snap to face the attacker.
local function landHit(attacker: Combatant, target: Combatant, spec: AttackSpec)
	report(spec, "Hit", attacker, target)
	target.lastAttacker = attacker
	target.lastAttackedAt = now()
	attacker.lastSlashLanded = true
	local profile = profileOf(target)
	-- Announced before the damage, so a cut-down that follows plays over the flinch.
	broadcast("Hit", {
		attacker = attacker.model,
		defender = target.model,
		damage = spec.damage,
		kind = spec.kind,
		flinch = not armoured(target) and target.state ~= "Broken",
	})
	dealDamage(target, spec.damage, attacker)
	if target.state ~= "Downed" and isAlive(target) then
		addPosture(target, spec.postureDamage * profile.Hit, attacker, profile.HitBreaks, "Hit")
		local stun = (Config.HitStun[spec.reaction] or Config.HitStun.Small)
			* (if target.resolve then Config.Resolve.StaggerMultiplier else 1)
		if stagger(target, stun) then
			faceBot(target, attacker.root.Position)
			slideBot(
				target,
				flatDirection(attacker.root.Position, target.root.Position),
				spec.knockback * Config.Knockback.Hit
			)
			local v = target.root.AssemblyLinearVelocity
			if not target.player and v.Y > 0 then
				target.root.AssemblyLinearVelocity = Vector3.new(v.X, 0, v.Z) -- no juggling
			end
		end
	end
end

-- A sweep that was jumped: the read is rewarded with a long recovery for its owner.
local function jumped(attacker: Combatant, target: Combatant, spec: AttackSpec)
	if attacker.state == "Recovery" then
		attacker.stateEndsAt = math.max(attacker.stateEndsAt, now() + Config.PerilousCounter.JumpedRecovery)
		attacker.cancelLockUntil = attacker.stateEndsAt
	end
	report(spec, "Jumped", attacker, target)
	broadcast("Jumped", { attacker = attacker.model, defender = target.model })
end

-- How far `mover` may close in on `toward` (a Mikiri slide, the pull up to a deathblow): to
-- 3 studs, or just outside the two bodies' contact if that is further (a big boss).
local function closeInGap(mover: Combatant, toward: Combatant): number
	local gap = flatDirection(mover.root.Position, toward.root.Position):Dot(toward.root.Position - mover.root.Position)
	local stop = math.max(3, Spacing.contact(mover.model, toward.model) + Config.Spacing.StopMargin)
	return gap - stop
end

-- Mikiri Counter: a forward dash into a thrust pins the blade underfoot, from the dash's
-- first frame (i-frames or not).
local function tryMikiri(attacker: Combatant, target: Combatant, spec: AttackSpec, hitAt: number): boolean
	local rules = Config.Mikiri
	local since = hitAt - target.dodgeStamp
	if not target.dodgeForward or since < 0 or since > rules.Window or not isFacing(target, attacker) then
		return false
	end
	local t = now()
	addPosture(attacker, spec.postureDamage * spec.deflectPosture * rules.PostureScale, target, true, "Deflected")
	attacker.postureFrozenUntil = math.max(attacker.postureFrozenUntil, t + rules.Freeze)
	if attacker.state ~= "Broken" then
		stagger(attacker, rules.AttackerStagger)
	end
	target.mikiriUntil = t + rules.FollowWindow
	target.lastContactAt = t
	local lunge = math.clamp(closeInGap(target, attacker), 0, rules.Lunge)
	surgeBot(target, flatDirection(target.root.Position, attacker.root.Position), 3 * lunge / 0.5, 0, 0.5)
	report(spec, "Mikiri", attacker, target)
	broadcast("Mikiri", { attacker = attacker.model, defender = target.model, lunge = lunge })
	return true
end

local function deflect(attacker: Combatant, target: Combatant, spec: AttackSpec, sinceDeflect: number)
	local rules = Config.Deflect
	local profile = profileOf(target)
	local perfect = sinceDeflect
		<= math.min(rules.PerfectWindow * assistMultiplier(target, "PerfectMultiplier"), target.deflectWindow)
	local t = now()
	-- Deflects in quick succession hit the attacker's posture harder each time.
	target.deflectChain = if t - target.lastDeflectAt < rules.ChainWindow then target.deflectChain + 1 else 0
	target.lastDeflectAt = t
	target.lastDefendAt = t
	target.lastDeflected = attacker
	local multiplier = math.min(rules.ChainMax, 1 + rules.ChainBonus * target.deflectChain)
		* (if perfect then rules.PerfectPosture else 1)
	local amount = spec.postureDamage * spec.deflectPosture * multiplier
	local recoil = if perfect then rules.PerfectAttackerRecoil else rules.AttackerRecoil
	if spec.perilous then
		-- A deflected perilous thrust is a big read: it costs its owner a posture chunk
		-- and a long recoil.
		recoil = math.max(recoil, Config.PerilousCounter.DeflectRecoil)
		amount += Config.PerilousCounter.DeflectPosture
	end
	addPosture(attacker, amount, target, true, "Deflected")
	-- Free for a Fighter (profile.Deflect = 0), but recovery restarts after Delay.Deflect.
	addPosture(target, spec.postureDamage * profile.Deflect, attacker, true, "Deflect")

	local broke = attacker.state == "Broken"
	local recoils = not broke and spec.recoilOnDeflect
	local pull = 0
	if broke then
		-- The deflect broke them: the defender is pulled up for the deathblow.
		target.riposteUntil = t + rules.RiposteWindow
		pull = math.clamp(closeInGap(target, attacker), 0, rules.BreakPull)
		surgeBot(target, flatDirection(target.root.Position, attacker.root.Position), 3 * pull / 0.35, 0, 0.35)
	elseif recoils then
		-- The payoff: the attacker recoils and a fast, uninterruptible counter-cut opens.
		target.riposteUntil = t + rules.RiposteWindow
		stagger(attacker, recoil)
	else
		-- Knocked aside: no stagger, the string goes on (at normal speed: it didn't land).
		attacker.lastSlashLanded = false
	end
	slideBot(
		target,
		flatDirection(attacker.root.Position, target.root.Position),
		spec.knockback * Config.Knockback.Deflect
	)
	report(spec, if perfect then "PerfectDeflect" else "Deflect", attacker, target)
	broadcast("Deflect", {
		attacker = attacker.model,
		defender = target.model,
		perfect = perfect,
		chain = target.deflectChain,
		recoil = recoils,
		broke = broke,
		pull = pull,
		kind = spec.kind,
	})
	for _, listener in deflectListeners do
		task.spawn(listener, attacker, target, perfect)
	end
end

-- A boss with Kannagi's Guard and Hajiki flags up deflects the blow: the attacker recoils
-- (Kannagi's player always does) and takes the boss's parry posture; the boss takes a share
-- of the blow's posture (its profile's Deflect column).
local function bossParry(attacker: Combatant, boss: Combatant, spec: AttackSpec)
	local t = now()
	boss.lastDefendAt = t
	boss.lastDeflectAt = t
	boss.lastDeflected = attacker
	report(spec, "Deflect", attacker, boss)
	addPosture(attacker, (boss.parryPosture or spec.postureDamage) * spec.deflectPosture, boss, true, "Deflected")
	addPosture(boss, spec.postureDamage * profileOf(boss).Deflect, attacker, true, "Deflect")
	local broke = attacker.state == "Broken"
	if not broke then
		stagger(attacker, Config.Bosses.PlayerRecoil)
	end
	broadcast("Deflect", {
		attacker = attacker.model,
		defender = boss.model,
		perfect = false,
		chain = 0,
		recoil = not broke,
		broke = broke,
		pull = 0,
		kind = spec.kind,
	})
	for _, listener in deflectListeners do
		task.spawn(listener, attacker, boss, false)
	end
end

local function resolveHit(attacker: Combatant, target: Combatant, spec: AttackSpec, hitAt: number)
	if hitAt < target.protectedUntil or not hitAllowed(attacker, target) then
		return
	end
	-- Training dummies build posture and teach timing, but never hurt anyone.
	if attacker.model:GetAttribute("Trainer") then
		spec = table.clone(spec)
		spec.damage = 0
	end

	-- Every strike that reaches a target counts toward its Resolve, whatever the outcome.
	target.recentAttackers[attacker] = now()
	target.lastContactAt = now()

	local breakerOnly = target.brokenBy ~= nil
		and target.brokenBy ~= attacker
		and isAlive(target.brokenBy :: Combatant)
		and now() - target.brokenAt < Config.BreakerOnlyDeathblow
	-- Kannagi's player has no deathblow vulnerability: a boss's blow on a broken guard is a hit.
	if
		target.state == "Broken"
		and not attacker.model:GetAttribute("Trainer")
		and not breakerOnly
		and not attacker.scripted
	then
		deathblow(attacker, target, spec)
		return
	end

	if spec.low then
		-- A sweep (Kannagi's Gedan) is avoided only by jumping: no deflect, guard or i-frames.
		if hitAt >= target.jumpStamp and hitAt <= target.jumpStamp + Config.Jump.EvadeWindow then
			jumped(attacker, target, spec)
		else
			landHit(attacker, target, spec)
		end
		return
	end

	-- Thrusts check Mikiri before deflects and i-frames.
	if spec.thrust and tryMikiri(attacker, target, spec, hitAt) then
		return
	end

	if hitAt >= target.dodgeStamp and hitAt <= target.dodgeStamp + Config.Dodge.IFrames then
		report(spec, "Dodged", attacker, target)
		broadcast("Dodged", { attacker = attacker.model, defender = target.model })
		return
	end

	local rules = Config.Deflect
	local profile = profileOf(target)

	-- A boss defends by its flags, not by key presses (Kannagi's ReceiveDamage switch): Guard
	-- and Hajiki deflect, Guard alone guards (not a thrust), neither takes the hit. Read as
	-- they stood at impact, not at resolve.
	local bossGuard = target.bossGuard
	if bossGuard then
		local guard, parry, noPosture = bossGuard(hitAt)
		if guard and parry and not spec.unblockable then
			bossParry(attacker, target, spec)
		elseif guard and not spec.unblockable and not spec.noGuard then
			addPosture(target, if noPosture then 0 else spec.postureDamage * profile.Guard, attacker, true, "Guard")
			target.lastDefendAt = now()
			report(spec, "Guarded", attacker, target)
			broadcast("Guard", { attacker = attacker.model, defender = target.model, kind = spec.kind })
		else
			landHit(attacker, target, spec)
		end
		return
	end

	local canDeflect = not spec.unblockable and isFacing(target, attacker)
	local canGuard = canDeflect and not spec.noGuard
	-- Just after a deflect, swings from anyone else are auto-guarded.
	local thirdParty = target.lastDeflected ~= nil
		and target.lastDeflected ~= attacker
		and hitAt - target.lastDeflectAt <= rules.ThirdPartyGuard
	if thirdParty and not spec.unblockable then
		addPosture(target, spec.postureDamage * profile.Guard * 0.5, attacker, true, "Guard")
		broadcast("Guard", { attacker = attacker.model, defender = target.model, kind = spec.kind })
		return
	end
	local sinceDeflect = hitAt - target.deflectStamp
	local deflectArmed = sinceDeflect >= -rules.LateTolerance and sinceDeflect <= target.deflectWindow

	if canDeflect and deflectArmed then
		deflect(attacker, target, spec, sinceDeflect)
	elseif canGuard and target.blocking then
		-- Guarding is what breaks you: the full posture value, and a long recovery delay.
		addPosture(target, spec.postureDamage * profile.Guard, attacker, true, "Guard")
		target.lastDefendAt = now()
		if target.state ~= "Broken" then
			slideBot(
				target,
				flatDirection(attacker.root.Position, target.root.Position),
				spec.knockback * Config.Knockback.Guard
			)
		end
		report(spec, "Guarded", attacker, target)
		broadcast("Guard", { attacker = attacker.model, defender = target.model, kind = spec.kind })
	else
		landHit(attacker, target, spec)
	end
end

local function resolveAttack(attacker: Combatant, spec: AttackSpec, hitAt: number, strike: CFrame)
	local targets = findTargets(attacker, spec, strike, hitAt)
	if #targets == 0 then
		report(spec, "Whiff", attacker, nil)
		broadcast("Whiff", { attacker = attacker.model })
		return
	end
	for _, target in targets do
		resolveHit(attacker, target, spec, hitAt)
	end
end

-- Whether `c` may act on `input` right now. Recovery ends early at the current move's
-- cancel point for that input; a dodge can be cut into an attack (the DodgeSlash).
-- Callers check their own preconditions first, since this may end the recovery.
local function free(c: Combatant, input: "Attack" | "Block" | "Dodge" | "Jump" | "Heal"): boolean
	if c.state == "Idle" then
		return true
	end
	local t = now()
	if c.state == "Recovery" and t >= c.cancelLockUntil and c.attackKind then
		local at = (specOf(c, c.attackKind).cancel :: any)[input] :: number?
		if at and t >= c.attackHitAt + at then
			setState(c, "Idle")
			return true
		end
	elseif c.state == "Dodging" and input == "Attack" and t >= c.dodgeStartedAt + Config.Dodge.AttackCancel then
		setState(c, "Idle")
		return true
	end
	return false
end

-- Whether `kind` may start now (cooldowns and stamina), without starting it.
local function canStart(c: Combatant, kind: AttackKind): boolean
	local spec = Weapons.spec(c.weapon, kind)
	local t = now()
	if t < (c.nextAttackAt[kind] or 0) then
		return false
	end
	local group = spec.cooldownGroup
	if group and t < (c.groupReadyAt[group] or 0) then
		return false
	end
	local cost = Weapons.staminaCost(c.weapon, kind)
	return not cost or c.stamina >= cost
end

local function startAttack(c: Combatant, kind: AttackKind, chained: boolean, windupOverride: number?): boolean
	local spec = Weapons.spec(c.weapon, kind)
	local t = now()
	if c.state ~= "Idle" or not canStart(c, kind) then
		return false
	end
	spendStamina(c, Weapons.staminaCost(c.weapon, kind))
	-- Strings speed up only while they keep landing.
	local windup = windupOverride
		or (if spec.chainWindup and chained and c.lastSlashLanded then spec.chainWindup else spec.windup)
	c.lastSlashLanded = false
	local group = spec.cooldownGroup
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

	setBlocking(c, false)
	cancelAttack(c)
	c.protectedUntil = 0 -- attacking ends spawn protection
	local token = c.attackToken
	local hitAt = t + windup
	c.windupHitAt = hitAt
	c.windupKind = kind
	c.attackKind = kind
	c.attackStartedAt = t
	c.attackHitAt = hitAt
	c.cancelLockUntil = 0
	c.followKind = spec.follow
	c.nextAttackAt[kind] = t + spec.cooldown
	c.comboUntil = hitAt + Config.Net.ResolveGrace + spec.recovery + Config.Combo.Window
	if spec.ender then
		-- The string is over: a short rest hands the turn to the defender.
		c.nextAttackAt.Light1 = hitAt + Config.Net.ResolveGrace + spec.recovery + Config.Combo.EnderRest
		c.followKind = nil
	end
	setState(c, "Windup")

	broadcast("Windup", { attacker = c.model, kind = kind, hitAt = hitAt })
	for _, listener in windupListeners do
		task.spawn(listener, c, kind, hitAt)
	end

	if not c.player then
		-- Bots are simulated here; players lunge on their own client. The lunge is shortened
		-- to stop just outside the body of anyone in front (Shared/Spacing), never skipped.
		task.delay(math.max(windup + spec.lungeAt, 0), function()
			if c.attackToken ~= token or (c.state ~= "Windup" and c.state ~= "Recovery") then
				return
			end
			local look = c.root.CFrame.LookVector
			local forward = Vector3.new(look.X, 0, look.Z)
			-- Motion.surge from 1.25x to 0.2x speed (quadratic ease) covers 0.55 x speed x time.
			local distance = 0.55 * spec.lunge * spec.lungeTime
			if forward.Magnitude < 1e-3 or distance <= 0 then
				return
			end
			forward = forward.Unit
			local room = Spacing.room(c.model, c.root.Position, forward, distance)
			if room > 0.1 then
				local scale = room / distance
				surgeBot(c, forward, spec.lunge * 1.25 * scale, spec.lunge * 0.2 * scale, spec.lungeTime)
			end
		end)
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
		task.delay(resolveGrace(c, spec, strike), function()
			if isAlive(c) then
				resolveAttack(c, spec, hitAt, strike)
			end
		end)
	end)
	return true
end

-- E or C late in a string turns its ender into a perilous attack with a shorter windup:
-- from Light2's recovery (once it has resolved) or early in the third slash's windup.
local function tryMorph(c: Combatant, action: Action): boolean
	if (action ~= "Perilous" and action ~= "Sweep") or c.stringTrickUsed then
		return false
	end
	local t = now()
	local fromRecovery = c.state == "Recovery"
		and c.comboIndex == 2
		and t >= c.attackHitAt + Config.Net.ResolveGrace
		and t >= c.cancelLockUntil
	local thirdKind = c.windupKind
	local fromWindup = c.state == "Windup"
		and (thirdKind == "Light3" or thirdKind == "Overhead")
		and t < c.windupHitAt - Config.Feint.Cutoff
	if not fromRecovery and not fromWindup then
		return false
	end
	local kind: AttackKind = if action == "Perilous" then "Perilous" else "Sweep"
	if not canStart(c, kind) then
		return false
	end
	cancelAttack(c)
	setState(c, "Idle")
	if startAttack(c, kind, false, Config.Combo.MorphWindup) then
		c.stringTrickUsed = true
		c.comboIndex = 0
		return true
	end
	return false
end

-- Which move an attack press makes right now, and the combo index to commit if it starts.
-- Counter windows come first (Riposte, MikiriSlash, DodgeSlash), then a counter-string's
-- next cut, then the normal string.
local function planAttack(c: Combatant, action: Action, t: number): (AttackKind, number?, boolean)
	if action == "Perilous" then
		return "Perilous", nil, false
	elseif action == "Sweep" then
		return "Sweep", nil, false
	elseif t <= c.riposteUntil then
		return "Riposte", nil, false
	elseif t <= c.mikiriUntil then
		return "MikiriSlash", nil, false
	elseif t - c.dodgeStartedAt <= Config.Dodge.AttackWindow then
		return "DodgeSlash", nil, false
	end
	local follow = c.followKind
	if follow and t <= c.comboUntil then
		return follow, sequenceIndex[follow] or 0, true
	end
	local sequence = Config.Combo.Sequence
	local index = c.comboIndex
	if t > c.comboUntil or index >= #sequence then
		index = 0
	end
	index += 1
	local kind = sequence[index]
	if kind == "Light3" and t - c.idleSince >= Config.Combo.DelayAfter then
		kind = "Overhead" -- held back a beat: the delayed overhead
	end
	return kind, index, index >= 2
end

local function attack(c: Combatant, action: Action): boolean
	if tryMorph(c, action) then
		return true
	end
	local t = now()
	if c.state ~= "Idle" and c.state ~= "Recovery" and c.state ~= "Dodging" then
		return false
	end
	local kind, index, chained = planAttack(c, action, t)
	if not canStart(c, kind) or not free(c, "Attack") then
		return false
	end
	if c.idleSince >= t then
		-- free() just ended a recovery or dodge: plan again from Idle (the delayed overhead
		-- counts from here).
		kind, index, chained = planAttack(c, action, t)
	end
	local counter = kind == "Riposte" or kind == "MikiriSlash" or kind == "DodgeSlash"
	local trickUsed, landed = c.stringTrickUsed, c.lastSlashLanded
	if counter or index == 1 then
		-- A new string, unless it is the slash right out of a feint: you can't feint
		-- again out of a feinted attack.
		c.stringTrickUsed = c.justFeinted and not counter
		c.lastSlashLanded = false
	end
	if not startAttack(c, kind, chained) then
		c.stringTrickUsed, c.lastSlashLanded = trickUsed, landed
		return false
	end
	c.justFeinted = false
	if counter then
		c.riposteUntil, c.mikiriUntil, c.dodgeStartedAt = 0, 0, -math.huge
		c.comboIndex = 0
	elseif index then
		c.comboIndex = index
	end
	return true
end

-- Newcomers get wider deflect windows, tapering to normal over their first matches.
assistMultiplier = function(c: Combatant, field: "WindowMultiplier" | "PerfectMultiplier"): number
	local player = c.player
	if not player then
		return 1
	end
	local rules = Config.NewcomerAssist
	local played = player:GetAttribute("Played")
	if typeof(played) ~= "number" or played >= rules.Matches then
		return 1
	end
	local taper = 1 - played / rules.Matches
	return 1 + (rules[field] - 1) * taper
end

-- Opens a deflect window from `stamp`. Kannagi's anti-mash: a re-press soon after lowering
-- guard (with nothing having struck you since) opens it late, because the guard is still
-- coming down; a press soon after your own deflect or guarded hit opens it at once. A guard
-- re-raised by a held key (`fresh`) always opens at once.
local function armDeflect(c: Combatant, stamp: number, fresh: boolean)
	local rules = Config.Deflect
	local delay = 0
	if
		not fresh
		and stamp - c.lastDefendAt > rules.ChainPress
		and stamp - c.lastBlockReleaseAt <= rules.RepressLockout
		and c.lastContactAt < c.lastBlockReleaseAt
	then
		delay = rules.RepressDelay
	end
	c.deflectStamp = stamp + delay
	c.deflectWindow = rules.Window * assistMultiplier(c, "WindowMultiplier")
	-- Clients mirror this to show their deflects the instant a blow lands.
	c.model:SetAttribute("DeflectAt", c.deflectStamp)
	c.model:SetAttribute("DeflectWindow", c.deflectWindow)
end

-- `retry` is a press replayed from the buffer: it never feints (it was pressed earlier,
-- when the windup may not even have started).
local function pressBlock(c: Combatant, stamp: number, retry: boolean): boolean
	local t = now()
	if c.state == "Windup" then
		-- Blocking out of a windup is a feint: it baits deflects at a small posture and
		-- stamina cost. Once per string, never out of a riposte, never right before impact.
		local kind = c.windupKind
		if
			retry
			or t > c.windupHitAt - Config.Feint.Cutoff
			or c.stringTrickUsed
			or (kind and specOf(c, kind).riposte)
			or not spendStamina(c, Config.Feint.StaminaCost)
		then
			return false
		end
		c.stringTrickUsed = true
		c.justFeinted = true
		cancelAttack(c)
		c.comboIndex = 0
		c.followKind = nil
		c.nextAttackAt.Light1 = 0 -- a feinted ender didn't finish the string: slash straight out of it
		addPosture(c, Config.Feint.PostureCost, nil, true, "Other")
		if c.state == "Broken" then
			return false
		end
		setState(c, "Idle")
		broadcast("Feint", { model = c.model })
	end
	if not free(c, "Block") then
		return false
	end
	c.protectedUntil = 0
	-- A tap still opens the window; only a held key keeps the guard up.
	setBlocking(c, c.blockHeld)
	armDeflect(c, if retry then t else stamp, false)
	return true
end

local function releaseBlock(c: Combatant, stamp: number)
	c.blockHeld = false
	if c.blocking then
		c.lastBlockReleaseAt = stamp
	end
	setBlocking(c, false)
end

local function dodge(c: Combatant, stamp: number, forward: boolean): boolean
	local t = now()
	if t < c.nextDodgeAt or c.stamina < (Config.Stamina.Costs.Dodge or 0) or not free(c, "Dodge") then
		return false
	end
	spendStamina(c, Config.Stamina.Costs.Dodge)
	setBlocking(c, false)
	c.dodgeStamp = stamp
	c.dodgeStartedAt = t
	c.dodgeForward = forward
	c.nextDodgeAt = t + Config.Dodge.Cooldown
	setState(c, "Dodging", Config.Dodge.Duration)
	broadcast("Dodge", { model = c.model })
	return true
end

-- A sip from the gourd: slow and committal. Getting hit mid-sip wastes it.
local function heal(c: Combatant): boolean
	if c.gourds <= 0 or not free(c, "Heal") then
		return false
	end
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

-- Whether the server can see this body off the ground.
local function airborne(c: Combatant): boolean
	local state = c.humanoid:GetState()
	return state == Enum.HumanoidStateType.Jumping
		or state == Enum.HumanoidStateType.Freefall
		or c.humanoid.FloorMaterial == Enum.Material.Air
		or c.root.AssemblyLinearVelocity.Y > 4
end

-- A reported jump only counts once the server sees the body leave the ground (see step),
-- so spamming the remote without jumping buys nothing. One per Jump.MinInterval.
local function jump(c: Combatant, stamp: number): boolean
	local t = now()
	local rules = Config.Jump
	if t - c.lastJumpAt < rules.MinInterval then
		return false
	end
	c.lastJumpAt = t
	c.pendingJumpStamp = stamp
	c.pendingJumpUntil = t + rules.VerifyTime + pingOf(c) / 2
	return true
end

-- A second jump press in the air over a sweeper lands on their head (Kannagi's Fumitsuke).
local function stomp(c: Combatant): boolean
	local t = now()
	if c.state ~= "Idle" or t - c.lastStompAt < Config.Jump.MinInterval or not airborne(c) then
		return false
	end
	local rules = Config.Stomp
	local victim: Combatant? = nil
	local best = rules.Range
	local victimKind: AttackKind? = nil
	for _, other in combatants do
		if other ~= c and isAlive(other) and (other.state == "Windup" or other.state == "Recovery") then
			-- The swing in progress, or (bosses) the latest sweep of its string.
			for _, candidate in { { other.attackKind, other.attackHitAt }, { other.stompKind, other.stompHitAt } } do
				local kind, hitAt = candidate[1] :: AttackKind?, candidate[2] :: number
				local spec = kind and specOf(other, kind)
				local offset = c.root.Position - other.root.Position
				local distance = Vector3.new(offset.X, 0, offset.Z).Magnitude
				if
					spec
					and spec.low
					and offset.Y > 0.5 -- coming down on them from above
					and t >= hitAt + spec.stompFrom
					and t <= hitAt + spec.stompUntil
					and distance <= best
					and hitAllowed(c, other)
					and t >= other.protectedUntil
				then
					victim, best, victimKind = other, distance, kind
				end
			end
		end
	end
	if not victim or not victimKind then
		return false
	end
	c.lastStompAt = t
	local spec = specOf(victim, victimKind)
	addPosture(victim, spec.postureDamage * spec.deflectPosture * rules.PostureScale, c, true, "Deflected")
	victim.postureFrozenUntil = math.max(victim.postureFrozenUntil, t + rules.Freeze)
	if victim.state ~= "Broken" then
		stagger(victim, rules.Stagger)
	end
	if not c.player then
		local v = c.root.AssemblyLinearVelocity
		c.root.AssemblyLinearVelocity = Vector3.new(v.X, rules.Launch, v.Z)
	end
	report(spec, "Stomped", victim, c)
	broadcast("Stomp", { attacker = victim.model, defender = c.model })
	return true
end

-- Runs one bufferable action. `retry` is true when it's being replayed from the buffer.
local function run(c: Combatant, action: Action, stamp: number, flag: boolean, retry: boolean): boolean
	if ATTACKS[action :: string] then
		return attack(c, action)
	elseif action == "BlockDown" then
		return pressBlock(c, stamp, retry)
	elseif action == "Dodge" then
		return dodge(c, if retry then now() else stamp, flag)
	elseif action == "Heal" then
		return heal(c)
	end
	return false
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
-- action took effect immediately (a refused bufferable action waits in the buffer).
-- `stamp` must already be a trusted or clamped server-clock time.
function CombatService.perform(c: Combatant, action: Action, stamp: number?, flag: boolean?): boolean
	if not isAlive(c) then
		return false
	end
	if c.model:GetAttribute("Cinematic") == true then
		return false -- a pre-fight intro is playing (DuelService / BossService): no moves start
	end
	local t = now()
	local at = stamp or t
	if action == "Dodge" or action == "Jump" then
		at = math.max(at, t - backdateCap(c))
	end
	if BUFFERED[action :: string] then
		if action == "BlockDown" then
			c.blockHeld = true
		end
		if run(c, action, at, flag == true, false) then
			c.buffered = nil -- last input wins
			return true
		end
		c.buffered = action
		c.bufferedAt = t
		c.bufferedFlag = flag == true
		return false
	elseif action == "BlockUp" then
		releaseBlock(c, at)
		return true
	elseif action == "Jump" then
		return jump(c, at)
	elseif action == "Stomp" then
		return stomp(c)
	elseif action == "Ready" then
		-- Players are untouchable until their client is actually in the game (past the
		-- title screen); spawn protection runs from here.
		if c.protectedUntil == math.huge then
			c.protectedUntil = now() + Config.SpawnProtection
		end
		if c.player then
			c.player:SetAttribute("Entered", true) -- past the title card: can be put in a match
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
	c.followKind = nil
	c.posture = 0
	c.postureFrozenUntil = 0
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
	c.resurrections = 0
	c.model:SetAttribute("Resurrections", 0)
end

-- How many lethal blows this fighter will rise from (RoundService grants them per match).
function CombatService.setResurrections(c: Combatant, count: number)
	c.resurrections = count
	c.model:SetAttribute("Resurrections", count)
end

-- Damage from outside a swing (the closing mist); resurrections still apply.
function CombatService.damage(c: Combatant, amount: number)
	dealDamage(c, amount, nil)
end

-- Bosses: a scripted attack, one animation with several hits (Kannagi's multi-hit moves).
-- Each hit lands at its own server time and resolves like any swing; the fighter stays in
-- Windup until the last impact and in Recovery until `endsAt`. Each hit's Windup broadcast
-- (with `boss = true`) goes out when the previous one lands, so a recoil or a stagger that
-- cancels the string never shows a glint or a predicted deflect for a hit that won't come.
-- `reach` adds to a hit's range. Returns the attack token (cancelAttack invalidates it).
export type ScriptedHit = { kind: string, at: number }
function CombatService.scriptedAttack(c: Combatant, hits: { ScriptedHit }, endsAt: number): number
	cancelAttack(c)
	local token = c.attackToken
	local t = now()
	c.attackStartedAt = t
	c.cancelLockUntil = 0
	c.stompKind = nil
	local function arm(i: number)
		local hit = hits[i]
		local kind = hit.kind :: AttackKind
		c.windupKind = kind
		c.windupHitAt = hit.at
		c.attackKind = kind
		c.attackHitAt = hit.at
		broadcast("Windup", { attacker = c.model, kind = hit.kind, hitAt = hit.at, boss = true })
	end
	if #hits == 0 then
		setState(c, "Recovery", math.max(endsAt - t, 0))
		return token
	end
	setState(c, "Windup")
	arm(1)
	for i, hit in hits do
		task.delay(math.max(hit.at - t, 0), function()
			if c.attackToken ~= token or c.state ~= "Windup" or not isAlive(c) then
				return
			end
			local spec = specOf(c, hit.kind :: AttackKind)
			if spec.low then
				c.stompKind, c.stompHitAt = hit.kind :: AttackKind, hit.at
			end
			local look = c.root.CFrame.LookVector
			local strike = CFrame.lookAt(c.root.Position, c.root.Position + Vector3.new(look.X, 0, look.Z))
			if i < #hits then
				arm(i + 1)
			else
				c.windupKind = nil
				setState(c, "Recovery", math.max(endsAt - now(), 0.05))
			end
			task.delay(resolveGrace(c, spec, strike), function()
				if isAlive(c) then
					resolveAttack(c, spec, hit.at, strike)
				end
			end)
		end)
	end
	return token
end

-- Bosses: stops whatever scripted attack is running (its later hits never land).
function CombatService.cancel(c: Combatant)
	cancelAttack(c)
	c.windupKind = nil
	if c.state == "Windup" or c.state == "Recovery" or c.state == "Staggered" then
		setState(c, "Idle")
	end
end

-- Bosses: fills posture to break it (vitality 0 forces Kannagi's HP break).
function CombatService.breakPosture(c: Combatant, by: Combatant?)
	addPosture(c, c.postureMax * 2, by, true, "Hit")
end

-- Bosses: a posture bar of `max` (published for the HUD), optionally emptied.
function CombatService.setPostureMax(c: Combatant, max: number, empty: boolean?)
	c.postureMax = max
	c.model:SetAttribute("PostureMax", max)
	if empty then
		c.posture = 0
		c.brokenBy = nil
	end
	c.posture = math.min(c.posture, max)
	publishPosture(c)
end

-- Bosses: ends a break early (the deathblow was taken) and wipes posture.
function CombatService.clearBreak(c: Combatant, state: CombatState?, duration: number?)
	c.posture = 0
	c.brokenBy = nil
	publishPosture(c)
	setState(c, state or "Idle", duration)
end

function CombatService.onCutDown(listener: CutDownListener)
	table.insert(cutDownListeners, listener)
end

function CombatService.isProtected(c: Combatant): boolean
	return now() < c.protectedUntil or c.model:GetAttribute("Safe") == true
end

-- Swaps the weapon a fighter is holding (equipping in the lobby).
function CombatService.setWeapon(c: Combatant, id: string)
	c.weapon = Weapons.get(id).id
	c.model:SetAttribute("Weapon", c.weapon)
	SwordRig.attach(c.model, c.weapon)
end

-- Who may hurt whom; RoundService installs the lobby/arena rule. Default: anyone.
function CombatService.setHitFilter(filter: (attacker: Combatant, target: Combatant) -> boolean)
	hitAllowed = filter
end

function CombatService.onWindup(listener: WindupListener)
	table.insert(windupListeners, listener)
end

function CombatService.onDeflect(listener: DeflectListener)
	table.insert(deflectListeners, listener)
end

-- The weapon a new fighter carries: the model's Weapon attribute (bots), else the
-- player's chosen weapon, else the default.
local function weaponFor(model: Model, player: Player?): string
	local chosen = model:GetAttribute("Weapon") or (player and player:GetAttribute("Weapon"))
	return Weapons.get(if typeof(chosen) == "string" then chosen else nil).id
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

	local profile = model:GetAttribute("PostureProfile")
	local c: Combatant = {
		model = model,
		humanoid = humanoid,
		root = root,
		player = player,
		weapon = weaponFor(model, player),
		postureProfile = if typeof(profile) == "string" and Config.Posture.Profiles[profile]
			then profile
			else "Fighter",
		state = "Idle",
		stateEndsAt = math.huge,
		attackToken = 0,
		windupHitAt = 0,
		attackKind = nil,
		attackStartedAt = 0,
		attackHitAt = 0,
		cancelLockUntil = 0,
		nextAttackAt = {},
		comboIndex = 0,
		comboUntil = 0,
		followKind = nil,
		buffered = nil,
		bufferedAt = 0,
		bufferedFlag = false,
		posture = 0,
		postureRegenAt = 0,
		postureFrozenUntil = 0,
		stamina = Config.Stamina.Max,
		lastStaminaSpendAt = 0,
		blocking = false,
		blockHeld = false,
		deflectStamp = -math.huge,
		deflectWindow = Config.Deflect.Window,
		lastBlockReleaseAt = -math.huge,
		lastContactAt = -math.huge,
		lastDefendAt = -math.huge,
		deflectChain = 0,
		lastDeflectAt = -math.huge,
		windupKind = nil,
		brokenBy = nil,
		brokenAt = 0,
		recentAttackers = {},
		resolve = false,
		riposteUntil = 0,
		mikiriUntil = 0,
		lastDeflected = nil,
		groupReadyAt = {},
		groupUses = {},
		groupLastUseAt = {},
		idleSince = 0,
		lastSlashLanded = false,
		stringTrickUsed = false,
		justFeinted = false,
		dodgeStamp = -math.huge,
		dodgeStartedAt = -math.huge,
		dodgeForward = false,
		nextDodgeAt = 0,
		jumpStamp = -math.huge,
		pendingJumpStamp = nil,
		pendingJumpUntil = 0,
		lastJumpAt = -math.huge,
		lastStompAt = -math.huge,
		gourds = Config.Gourd.Charges,
		protectedUntil = if player then math.huge else now() + Config.SpawnProtection,
		lastAttacker = nil,
		lastAttackedAt = 0,
		executed = false,
		resurrections = 0,
		god = false,
		history = {},
		historyHead = 0,
		pushToken = 0,
		postureMax = Config.Posture.Max,
		brokenDuration = nil,
		postureRegen = nil,
		scripted = false,
		superArmor = 0,
		bossGuard = nil,
		parryPosture = nil,
		stompKind = nil,
		stompHitAt = 0,
		hooks = nil,
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
	model:SetAttribute("Weapon", c.weapon)
	SwordRig.attach(model, c.weapon)
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
		dropWeapons(model)
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

-- The dead let go of their blades: once the collapse has landed, each sword leaves the hand
-- and falls to the ground beside the body (welded to a limp hand it stood up out of the
-- floor). Its haft or second blade comes along.
local DROP_DELAY = 0.45
function dropWeapons(model: Model)
	task.delay(DROP_DELAY, function()
		for _, name in { "Sword", "Sword2" } do
			local sword = model:FindFirstChild(name)
			local grip = sword and sword:FindFirstChild("SwordGrip")
			if sword and sword:IsA("BasePart") and grip then
				grip:Destroy()
				sword.Massless = false
				sword.CanCollide = true
				local trail = sword:FindFirstChildOfClass("Trail")
				if trail then
					trail.Enabled = false
				end
				sword.AssemblyLinearVelocity = Vector3.new(0, -2, 0)
			end
		end
	end)
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
		SwordRig.attach(character, combatants[character].weapon)
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

-- How much of an overlap a bot or boss resolves itself: all of it against a player (whose
-- client owns their body and keeps it out of ours), half against another server body.
local function npcShare(other: Model): number
	local them = combatants[other]
	return if them and them.player then 1 else 0.5
end

-- Kannagi's capsule push for the bodies the server simulates (Shared/Spacing): a bot or
-- boss that overlaps anyone in its arena is moved straight out, and loses the velocity that
-- carried it in.
local function separateBodies()
	for _, c in combatants do
		if not c.player and Spacing.solid(c.model) then
			local push = Spacing.separation(c.model, c.root.Position, npcShare)
			if push.Magnitude > 1e-3 then
				c.root.CFrame += push
				local v = c.root.AssemblyLinearVelocity
				local out = push.Unit
				local into = v:Dot(out)
				if into < 0 then
					c.root.AssemblyLinearVelocity = v - out * into
				end
			end
			-- Bots re-aim their walk only every ThinkInterval: between thinks, don't keep
			-- walking into a body they've reached.
			local walk = c.humanoid.MoveDirection
			if walk.Magnitude > 0.05 then
				local clipped = Spacing.clip(c.model, c.root.Position, walk)
				if (clipped - walk).Magnitude > 1e-3 then
					c.humanoid:Move(clipped, false)
				end
			end
		end
	end
end

local function step(dt: number)
	local t = now()
	separateBodies()
	for _, c in combatants do
		recordPosition(c, t)

		-- Windup ends via its own timer; every other timed state falls back to Idle.
		if c.state == "Downed" and t >= c.stateEndsAt then
			rise(c)
		elseif c.state ~= "Windup" and c.state ~= "Dead" and t >= c.stateEndsAt then
			if c.state == "Broken" then
				-- Unpunished: posture stays nearly full, so the next break-capable blow re-breaks.
				c.posture = c.postureMax * Config.Posture.AfterBreak
				c.postureRegenAt = t + Config.Posture.AfterBreakDelay
				c.brokenBy = nil
			end
			setState(c, "Idle")
		end

		-- Replay the buffered input every frame until it becomes legal or goes stale.
		local buffered = c.buffered
		if buffered then
			local stale = t - c.bufferedAt > Config.Combo.Buffer
			if (stale or run(c, buffered, t, c.bufferedFlag, true)) and c.buffered == buffered then
				c.buffered = nil
			end
		end

		-- A held block key re-raises guard the moment any action ends, with a fresh window.
		if c.state == "Idle" and c.blockHeld and not c.blocking and not c.buffered then
			setBlocking(c, true)
			armDeflect(c, t, true)
		end

		-- A reported jump counts once the body is seen off the ground.
		if c.pendingJumpStamp then
			if airborne(c) then
				c.jumpStamp = c.pendingJumpStamp :: number
				c.pendingJumpStamp = nil
			elseif t > c.pendingJumpUntil then
				c.pendingJumpStamp = nil
			end
		end

		-- Resolve: outnumbered by distinct recent attackers.
		local strikers = 0
		for attacker, at in c.recentAttackers do
			if t - at > Config.Resolve.Window or not isAlive(attacker) then
				c.recentAttackers[attacker] = nil
			else
				strikers += 1
			end
		end
		local outnumbered = strikers >= Config.Resolve.Attackers
		if outnumbered ~= c.resolve then
			c.resolve = outnumbered
			c.model:SetAttribute("Resolve", outnumbered)
		end

		-- Posture recovers at a flat rate once its delay has passed (Kannagi: no vitality
		-- scaling, no guard bonus); Resolve doubles it while outnumbered.
		if c.posture > 0 and c.state ~= "Broken" and t >= c.postureRegenAt and t >= c.postureFrozenUntil then
			local multiplier = if c.resolve then Config.Resolve.PostureRegenMultiplier else 1
			local rate = c.postureRegen or profileOf(c).Regen or Config.Posture.RegenPerSecond
			c.posture = math.max(0, c.posture - rate * multiplier * dt)
		end
		publishPosture(c)

		local stamina = Config.Stamina
		if c.stamina < stamina.Max and t - c.lastStaminaSpendAt >= stamina.RegenDelay then
			c.stamina = math.min(stamina.Max, c.stamina + stamina.RegenPerSecond * dt)
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
