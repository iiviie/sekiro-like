--!strict
-- Bot opponents for solo testing, and later the lobby-fillers for the round loop. Bots go
-- through the same CombatService.perform entry point as players, so they can't do
-- anything a player can't.
--
-- Behaviour: pick a target (spreading out so one fighter isn't mobbed), circle it at
-- StrafeDistance, step in to swing a short combo, back off to recover posture, and meet
-- incoming swings with Kannagi's defence ladder (per attacker: reflex guard when idle,
-- guard after a flinch, deflect after a guard, counter after a deflect), each rung
-- followed with the tier's probability and reaction time. Only perilous answers are dice.
-- Facing is a capped turn: free bots turn at TurnSpeed, a swinging bot only inside its
-- move's tracking window, so side-stepping a committed bot swing works.
--
-- Royale fillers are a numbered roster (setCount) in Workspace.Bots. Duel bots
-- (spawnDuelist) live outside it, in Workspace.DuelBots, fight only their one foe and keep
-- to their terrace.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Progression = require(ReplicatedStorage.Shared.Progression)
local Weapons = require(ReplicatedStorage.Shared.Weapons)
local CombatService = require(script.Parent.CombatService)
local Locomotion = require(script.Parent.Locomotion)
local Outfit = require(script.Parent.Outfit)
local Round = require(ReplicatedStorage.Shared.Round)
local Spacing = require(ReplicatedStorage.Shared.Spacing)

type Combatant = CombatService.Combatant
type AttackKind = Config.AttackKind
type AttackSpec = Config.AttackSpec

type Tier = { [string]: any }

type Brain = {
	c: Combatant,
	tier: Tier, -- skill multipliers, fixed when the bot spawns (Config.Bots.Tiers)
	foe: Combatant?, -- a duel bot only ever fights this one
	arena: { center: Vector3, radius: number }?, -- and stays inside this circle
	align: AlignOrientation,
	target: Combatant?,
	nextAttackAt: number,
	comboLeft: number,
	lastOpeningAt: number,
	readUntil: number, -- while set, the bot is on a deflect rung: hold ground, deflect, counter
	backstepUntil: number, -- after a flinch: back off with guard up
	strafeSign: number,
	strafeSwitchAt: number,
	-- This string's third hit (Kannagi's ender read, by the tier's Mix odds): nil on rhythm,
	-- or "Overhead" (held a beat), "Morph" (into `morph`) or "Feint".
	trick: string?,
	morph: "Perilous" | "Sweep",
}

local TARGET_SHARE_PENALTY = 30 -- studs added per other bot already on a target
-- Samurai and Kensei bots finish with a premium finisher, so players see one on the kill-cam
-- without owning it (Shared/Cosmetics.Finishers).
local BOT_FINISHERS = { "InkBrush", "CrowFeathers", "LightningSheath", "SakuraScatter", "MoonCrescent" }

-- What a bot looks like: its outfit and weapon (by roster index), blade skin and finisher.
-- A duel bot keeps one across rounds.
export type BotLook = { index: number, skin: string, finisher: string? }
local NAMES = {
	"Hayato",
	"Genji",
	"Ichiro",
	"Kaito",
	"Renjiro",
	"Sora",
	"Daichi",
	"Haruki",
	"Jinbei",
	"Kenta",
	"Masaru",
	"Ryota",
	"Shinji",
	"Takeru",
	"Yoshi",
	"Botan",
	"Kagero",
	"Tetsu",
	"Okami",
	"Raiden",
}

local BotService = {}

local brains: { [Combatant]: Brain } = {}
local botFolder: Folder
local duelFolder: Folder
local slots: { [number]: Model } = {} -- bot index -> its current body
local desiredCount = 0
local respawnEnabled = true
local tierName = "Adept"
local tier = Config.Bots.Tiers.Adept

local function now(): number
	return workspace:GetServerTimeNow()
end

local function randomRange(range: { number }): number
	return range[1] + math.random() * (range[2] - range[1])
end

-- Runs `fn` when the server clock reaches `time`.
local function at(time: number, fn: () -> ())
	task.delay(math.max(0, time - now()), fn)
end

local function alive(c: Combatant): boolean
	return CombatService.get(c.model) == c and c.state ~= "Dead"
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function spawnPoint(): CFrame
	local angle = math.random() * math.pi * 2
	local radius = Config.Bots.SpawnRadius
	local position = Vector3.new(math.cos(angle) * radius, 4, math.sin(angle) * radius)
	return CFrame.lookAt(position, Vector3.new(0, 4, 0))
end

-- A fresh look for a bot of `rigTier` at roster `index`.
local function rollLook(index: number, rigTier: string): BotLook
	-- Stronger bots show off rarer blades: players see what's worth earning.
	local skins = Progression.Skins
	local skinIndex = if rigTier == "Master"
		then math.random(4, #skins)
		elseif rigTier == "Adept" then math.random(1, 3)
		else 1
	local finisher = if rigTier == "Master" or rigTier == "Adept"
		then BOT_FINISHERS[math.random(#BOT_FINISHERS)]
		else nil
	return { index = index, skin = skins[skinIndex].id, finisher = finisher }
end

local function buildRig(look: BotLook, rigTier: string): Model
	local description = Instance.new("HumanoidDescription")
	Outfit.describe(description, look.index)

	local model = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	model.Name = `{Config.Bots.Tiers[rigTier].Title} {NAMES[math.random(#NAMES)]}`
	model:SetAttribute("BotTier", rigTier)
	model:SetAttribute("Skin", look.skin)
	model:SetAttribute("Finisher", look.finisher)
	-- Mix the weapon roster so players meet every archetype.
	model:SetAttribute("Weapon", Weapons.Order[(look.index - 1) % #Weapons.Order + 1])
	-- Our EnemyBars carry the bars (and, from client/CombatHUD, the name): no Roblox name or
	-- health bar over a bot, in fights or in intros.
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	end
	Outfit.dress(model)
	return model
end

local function chooseTarget(brain: Brain): Combatant?
	local self = brain.c
	local foe = brain.foe
	if foe then
		return if alive(foe) and not CombatService.isProtected(foe) then foe else nil
	end
	local best: Combatant? = nil
	local bestScore = Config.Bots.AggroRange
	for _, other in CombatService.all() do
		if other ~= self and other.state ~= "Dead" and not CombatService.isProtected(other) then
			local score = (other.root.Position - self.root.Position).Magnitude
			if other.player then
				score *= Config.Bots.PlayerBias
			end
			local hunters = 0
			for otherBrain in brains do
				if otherBrain ~= self and brains[otherBrain].target == other then
					score += TARGET_SHARE_PENALTY
					hunters += 1
				end
			end
			-- A bot already fighting a human is left to that fight: swinging at it means swinging
			-- at the human beside it (CB-02).
			local otherTarget = brains[other] and brains[other].target
			if otherTarget and otherTarget.player and otherTarget ~= self then
				score += Config.Bots.HumanFoePenalty
			end
			-- Never gang up on a human: one bot at a time, the rest find someone else.
			if other.player and hunters >= Config.Bots.MaxBotsPerPlayer then
				score = math.huge
			end
			if score < bestScore then
				best, bestScore = other, score
			end
		end
	end
	return best
end

-- How a full string's third hit comes out, by the tier's Mix odds: on rhythm (nil), a
-- delayed Overhead, a perilous morph (only while the perilous cooldown is ready) or a feint.
local function rollTrick(brain: Brain): string?
	local mix = brain.tier.Mix
	if not mix then
		return nil
	end
	local c = brain.c
	local roll = math.random()
	if roll < mix.Overhead then
		return "Overhead"
	end
	roll -= mix.Overhead
	if roll < mix.Morph then
		brain.morph = if math.random() < 0.5 then "Perilous" else "Sweep"
		local group = Weapons.spec(c.weapon, brain.morph).cooldownGroup
		return if group and now() < (c.groupReadyAt[group] or 0) then nil else "Morph"
	end
	roll -= mix.Morph
	return if roll < mix.Feint then "Feint" else nil
end

local function startCombo(brain: Brain, t: number)
	local c = brain.c
	local skillTier = brain.tier
	if brain.comboLeft > 0 and brain.trick == "Overhead" and c.comboIndex == 2 then
		return -- holding the third press for the delayed Overhead
	end
	local perilous = math.random() < Config.Bots.PerilousChance * skillTier.Perilous
	local action = if not perilous then "Attack" elseif math.random() < 0.5 then "Perilous" else "Sweep"
	if CombatService.perform(c, action, t) then
		brain.comboLeft = 0
		brain.trick = nil
		if not perilous then
			while brain.comboLeft < 2 and math.random() < Config.Bots.ComboContinueChance do
				brain.comboLeft += 1
			end
			if brain.comboLeft == 2 then
				brain.trick = rollTrick(brain)
			end
		end
		brain.nextAttackAt = t + randomRange(Config.Bots.AttackInterval) * skillTier.AttackInterval
	end
end

local function think(brain: Brain)
	local c = brain.c
	local humanoid, root = c.humanoid, c.root
	local t = now()

	local was = brain.target
	brain.target = chooseTarget(brain)
	local target = brain.target
	-- Testing aid: workspace attribute DebugBotTargets = true publishes who each bot hunts.
	if target ~= was and workspace:GetAttribute("DebugBotTargets") then
		c.model:SetAttribute("DebugTarget", if target then target.model.Name else nil)
	end
	if not target then
		brain.align.Enabled = false
		humanoid.AutoRotate = true
		humanoid:Move(Vector3.zero)
		return
	end

	-- Safety net against physics launches.
	local velocity = root.AssemblyLinearVelocity
	if velocity.Y > 70 then
		root.AssemblyLinearVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	end

	local toTarget = flat(target.root.Position - root.Position)
	local distance = toTarget.Magnitude
	local forward = if distance > 0.01 then toTarget.Unit else flat(root.CFrame.LookVector).Unit
	local right = forward:Cross(Vector3.yAxis)

	-- Facing is applied every frame by updateFacing (capped by the move's tracking).
	humanoid.AutoRotate = false

	-- Chain the next slash by buffering it in the last moments of recovery. The third hit
	-- follows the string's trick: the Overhead holds the press past Combo.DelayAfter, a morph
	-- presses E/C in Light2's recovery (buffered until it may morph), a feint is set up below.
	local third = brain.comboLeft > 0 and c.comboIndex == 2
	if
		c.state == "Staggered"
		or c.state == "Broken"
		or (brain.comboLeft > 0 and c.state == "Idle" and t > c.comboUntil) -- the string's window closed
	then
		brain.comboLeft = 0
	elseif third and brain.trick == "Overhead" then
		if c.state == "Idle" and t - c.idleSince >= Config.Combo.DelayAfter + 0.05 then
			CombatService.perform(c, "Attack", t)
			brain.comboLeft = 0
		end
	elseif third and brain.trick == "Morph" and c.state == "Recovery" then
		CombatService.perform(c, brain.morph, t)
		brain.comboLeft = 0
	elseif brain.comboLeft > 0 and c.state == "Recovery" and c.stateEndsAt - t <= Config.Combo.Buffer then
		CombatService.perform(c, "Attack", t)
		brain.comboLeft -= 1
	end
	-- A feinted ender: cancel the third hit's windup just before the glint would be answered,
	-- then slash straight out of it once the defender has pressed.
	if brain.trick == "Feint" and c.state == "Windup" and (c.windupKind == "Light3" or c.windupKind == "Overhead") then
		brain.trick = nil
		local hitAt = c.windupHitAt
		at(hitAt - randomRange({ Config.Feint.Cutoff + 0.04, 0.26 }), function()
			if
				not alive(c)
				or c.state ~= "Windup"
				or c.windupHitAt ~= hitAt
				or c.stamina < (Weapons.staminaCost(c.weapon, "Feint") or 0)
			then
				return
			end
			CombatService.perform(c, "BlockDown", now())
			CombatService.perform(c, "BlockUp", now())
			at(now() + randomRange({ 0.15, 0.3 }), function()
				if alive(c) and c.state == "Idle" then
					CombatService.perform(c, "Attack", now())
				end
			end)
		end)
	end

	if t >= brain.strafeSwitchAt then
		brain.strafeSign = if math.random() < 0.5 then -1 else 1
		brain.strafeSwitchAt = t + 1 + math.random() * 2
	end

	local move = Vector3.zero
	local postureRatio = c.posture / Config.Posture.Max
	local hurt = humanoid.Health / humanoid.MaxHealth < Config.Bots.HealBelow and c.gourds > 0
	if c.state == "Broken" or c.state == "Staggered" or c.state == "Drinking" then
		move = Vector3.zero
	elseif hurt and distance > Config.Bots.StrafeDistance then
		-- Out of reach and hurting: back off and drink.
		move = -forward
		if c.state == "Idle" then
			CombatService.perform(c, "Heal", t)
		end
	elseif postureRatio > Config.Bots.RetreatPosture or hurt or t < brain.backstepUntil then
		move = -forward + right * brain.strafeSign * 0.6
	elseif target.state == "Broken" and distance <= Config.Bots.AttackDistance + 2 then
		-- A broken posture is the opening that matters most: go for the deathblow.
		move = if distance > Config.Bots.AttackDistance then forward else Vector3.zero
		if c.state == "Idle" and not c.blocking then
			CombatService.perform(c, "Attack", t)
		end
	elseif t < brain.readUntil then
		-- On the deflect rung: stop swinging into their rhythm, hold ground and wait to
		-- deflect. The counter comes from onOutcome.
		move = right * brain.strafeSign * 0.25
	elseif
		(target.state == "Recovery" or target.state == "Staggered" or target.state == "Drinking")
		and distance <= Config.Bots.AttackDistance + 1.5
		and c.state == "Idle"
		and not c.blocking
		and t - brain.lastOpeningAt > Config.Bots.OpeningCooldown
	then
		-- The target is stuck in recovery, recoil or a sip: that's the opening.
		brain.lastOpeningAt = t
		if math.random() < Config.Bots.OpeningChance * brain.tier.Opening then
			startCombo(brain, t)
		end
	elseif t >= brain.nextAttackAt then
		if distance > Config.Bots.AttackDistance then
			move = forward
		elseif c.state == "Idle" and not c.blocking then
			startCombo(brain, t)
		end
	else
		local radial = math.clamp(distance - Config.Bots.StrafeDistance, -1, 1)
		move = forward * radial + right * brain.strafeSign * 0.8
	end

	-- Keep some room from other fighters and stay inside the arena.
	for _, other in CombatService.all() do
		if other ~= c and other ~= target then
			local away = flat(root.Position - other.root.Position)
			local gap = away.Magnitude
			if gap > 0.01 and gap < Config.Bots.SeparationRadius then
				move += away.Unit * (1 - gap / Config.Bots.SeparationRadius) * 1.5
			end
		end
	end
	-- Stay inside the ring during a match, and inside the walls otherwise; duel bots stay on
	-- their terrace.
	local zoneCenter, zoneRadius = Round.zone(t)
	local limit = math.min(zoneRadius - 6, Config.Bots.ArenaRadius)
	local arena = brain.arena
	if arena then
		zoneCenter, zoneRadius, limit = arena.center, arena.radius, arena.radius - 3
	end
	local fromCentre = flat(root.Position - zoneCenter)
	if fromCentre.Magnitude > limit then
		move -= fromCentre.Unit * (if fromCentre.Magnitude > zoneRadius then 3 else 1)
	end

	-- Bodies don't overlap (Shared/Spacing): stop walking into anyone already at contact.
	if move.Magnitude > 0.05 then
		move = Spacing.clip(c.model, root.Position, move.Unit)
	end
	humanoid:Move(if move.Magnitude > 0.05 then move.Unit else Vector3.zero)
end

local function dodgeAway(bot: Combatant)
	if not CombatService.perform(bot, "Dodge", now()) then
		return
	end
	local side = if math.random() < 0.5 then 1 else -1
	local sideways = bot.root.CFrame.RightVector * side
	bot.root.AssemblyLinearVelocity = Vector3.new(sideways.X, 0, sideways.Z) * Config.Dodge.Speed
end

-- Dash straight into a thrust: a Mikiri Counter if it lands in the i-frames.
local function dashInto(bot: Combatant, attacker: Combatant)
	local toward = attacker.root.Position - bot.root.Position
	toward = Vector3.new(toward.X, 0, toward.Z)
	if toward.Magnitude < 0.1 or not CombatService.perform(bot, "Dodge", now(), true) then
		return
	end
	bot.root.AssemblyLinearVelocity = toward.Unit * Config.Dodge.Speed * 0.5
end

local function jumpOver(bot: Combatant)
	bot.humanoid.Jump = true
	CombatService.perform(bot, "Jump", now())
end

-- Guard is pressed and released through these, so overlapping holds (a reflex guard, then a
-- guard after a flinch) don't let go of each other early: the key comes up only once the
-- latest hold has run out.
local guardUntil: { [Combatant]: number } = {}

local function holdBlock(bot: Combatant, pressAt: number, releaseAt: number, repress: boolean)
	guardUntil[bot] = math.max(guardUntil[bot] or 0, releaseAt)
	if repress then
		-- A fresh press out of a held guard: let go early enough that the re-press isn't
		-- caught by the anti-mash lockout (Config.Deflect.RepressLockout).
		at(pressAt - Config.Deflect.RepressLockout - 0.02, function()
			if alive(bot) and bot.blockHeld and now() < pressAt then
				CombatService.perform(bot, "BlockUp", now())
			end
		end)
	end
	at(pressAt, function()
		if not alive(bot) then
			return
		end
		-- Blocking out of a windup is a feint; only do that on purpose, now and then.
		if bot.state == "Windup" and math.random() > Config.Bots.FeintChance then
			return
		end
		if bot.blockHeld and not repress then
			return -- already guarding
		end
		if bot.blockHeld then
			CombatService.perform(bot, "BlockUp", now()) -- a fresh press for the deflect
		end
		CombatService.perform(bot, "BlockDown", now())
	end)
	at(releaseAt, function()
		if alive(bot) and now() >= (guardUntil[bot] or 0) - 0.01 then
			CombatService.perform(bot, "BlockUp", now())
		end
	end)
end

-- Kannagi's defence ladder, per bot and attacker: 0 nothing yet, 1 guard, 2 deflect.
local GUARD, DEFLECT = 1, 2
local ladders: { [Combatant]: { [Combatant]: { level: number, at: number } } } = {}

local function rungOf(bot: Combatant, attacker: Combatant): number
	local byAttacker = ladders[bot]
	local rung = byAttacker and byAttacker[attacker]
	local brain = brains[bot]
	local memory = brain and brain.tier.Memory or Config.Bots.Ladder.Memory
	if not rung or now() - rung.at > memory then
		return 0
	end
	return rung.level
end

local function setRung(bot: Combatant, attacker: Combatant, level: number)
	local byAttacker = ladders[bot]
	if not byAttacker then
		byAttacker = {}
		ladders[bot] = byAttacker
	end
	byAttacker[attacker] = { level = level, at = now() }
end

local function tierOf(bot: Combatant): Tier
	local brain = brains[bot]
	return if brain then brain.tier else tier
end

-- Perilous attacks are still answered by dice (scaled by the tier's Defense).
local function reactPerilous(bot: Combatant, attacker: Combatant, spec: AttackSpec, hitAt: number, reactAt: number)
	local skill = Config.Bots
	local skillTier = tierOf(bot)
	local d = skillTier.Defense
	local dodgeChance = skill.DodgePerilousChance * d
	local roll = math.random()
	if spec.low then
		-- Sweeps can only be jumped; a good bot then stomps on the sweeper's head.
		if roll < dodgeChance then
			local jumpAt = math.max(hitAt - randomRange({ 0.15, 0.4 }), reactAt)
			at(jumpAt, function()
				if alive(bot) then
					jumpOver(bot)
				end
			end)
			if math.random() < (skillTier.Stomp or 0) then
				at(hitAt + randomRange({ 0.05, 0.2 }), function()
					if alive(bot) then
						CombatService.perform(bot, "Stomp", now())
					end
				end)
			end
		end
		return
	end
	-- A thrust: Mikiri it, deflect it, or sidestep it. Guarding does nothing.
	local window = Config.Mikiri.Window
	if roll < dodgeChance * skill.MikiriChance then
		at(math.max(hitAt - randomRange({ 0.06, window - 0.05 }), reactAt), function()
			if alive(bot) then
				dashInto(bot, attacker)
			end
		end)
	elseif roll < dodgeChance then
		local lead = randomRange(Config.Bots.Ladder.DeflectLead)
		holdBlock(bot, math.max(hitAt - lead, reactAt), hitAt + 0.15, true)
	elseif roll < dodgeChance + 0.2 * d then
		at(math.max(hitAt - randomRange({ 0.08, Config.Dodge.IFrames - 0.05 }), reactAt), function()
			if alive(bot) then
				dodgeAway(bot)
			end
		end)
	end
end

-- An incoming slash: climb the ladder. Bots know hitAt, so their limits are the tier's
-- reaction time and the chance of following each rung.
local function react(bot: Combatant, attacker: Combatant, spec: AttackSpec, hitAt: number)
	local skillTier = tierOf(bot)
	local ladder = Config.Bots.Ladder
	local t = now()
	local reactAt = t + skillTier.Reaction * (0.8 + math.random() * 0.4)
	if spec.perilous then
		reactPerilous(bot, attacker, spec, hitAt, reactAt)
		return
	end
	local level = rungOf(bot, attacker)
	if level == 0 and bot.state == "Idle" then
		level = GUARD -- an idle bot that sees the swing coming raises guard
	end
	if level > 0 and math.random() > skillTier.Follow then
		level -= 1 -- missed the rung
	end
	local brain = brains[bot]
	if brain and level > 0 then
		brain.comboLeft = 0 -- don't swing into it
	end
	if spec.kind == "Overhead" and level > 0 and math.random() > skillTier.Follow then
		-- Misjudged the delayed ender as the on-rhythm Light3: a tap on Light3's beat, which
		-- the held-back Overhead mostly catches (the player's mix-up works on bots too).
		local early = spec.windup - Weapons.spec(attacker.weapon, "Light3").windup
		local pressAt = math.max(hitAt - early - randomRange(ladder.DeflectLead), reactAt)
		holdBlock(bot, pressAt, pressAt + 0.05, true)
		return
	end
	if level >= DEFLECT then
		if brain then
			brain.readUntil = math.max(brain.readUntil, hitAt + 0.4)
		end
		local lead = randomRange(if math.random() < skillTier.Perfect then ladder.PerfectLead else ladder.DeflectLead)
		local rules = Config.Deflect
		local lockedOut = bot.blockHeld
			and hitAt - lead - rules.RepressLockout < reactAt
			and hitAt - bot.lastDefendAt > rules.ChainPress
		if lockedOut then
			lead += rules.RepressDelay -- too late to let go cleanly: press early for the late window
		end
		local pressAt = math.max(hitAt - lead, reactAt)
		if pressAt < hitAt - 0.01 then
			holdBlock(bot, pressAt, hitAt + 0.15, true)
		end
	elseif level == GUARD then
		if bot.blockHeld then
			guardUntil[bot] = math.max(guardUntil[bot] or 0, hitAt + ladder.GuardHold)
			holdBlock(bot, t, hitAt + ladder.GuardHold, false)
		elseif reactAt <= hitAt - ladder.GuardLead then
			-- Up before the deflect window would open, so it is a guard, not a deflect.
			holdBlock(bot, reactAt, hitAt + ladder.GuardHold, false)
		end
	end
end

local function onWindup(attacker: Combatant, kind: AttackKind, hitAt: number)
	local spec = Weapons.spec(attacker.weapon, kind)
	for bot in brains do
		if bot ~= attacker and alive(bot) then
			local distance = (bot.root.Position - attacker.root.Position).Magnitude
			if distance <= spec.range + 3 then
				react(bot, attacker, spec, hitAt)
			end
		end
	end
end

-- A counter-attack, if the tier takes it.
local function counter(bot: Combatant, chance: number, delay: number)
	local brain = brains[bot]
	if not brain or math.random() >= chance * brain.tier.Punish then
		return
	end
	task.delay(delay, function()
		if alive(bot) then
			brain.nextAttackAt = 0
			brain.readUntil = 0
			CombatService.perform(bot, "Attack", now())
		end
	end)
end

-- Climbs the ladder from what actually happened to each swing at a bot.
local function onOutcome(_kind: string, outcome: string, attacker: Combatant, target: Combatant?)
	if not target or not brains[target] then
		return
	end
	local bot = target
	local brain = brains[bot]
	local skillTier = brain.tier
	if outcome == "Hit" then
		setRung(bot, attacker, GUARD)
		-- Hit in a flinch: guard comes up for the next one (held through the stun), and the
		-- bot backs off.
		if math.random() < skillTier.Follow then
			local t = now()
			holdBlock(bot, t, t + 0.9, false)
			brain.backstepUntil = t + Config.Bots.Ladder.Backstep
		end
	elseif outcome == "Guarded" then
		setRung(bot, attacker, DEFLECT)
	elseif outcome == "Deflect" or outcome == "PerfectDeflect" then
		setRung(bot, attacker, DEFLECT)
		if attacker.state == "Staggered" or attacker.state == "Broken" then
			-- The deflect stopped them: counter now (a Riposte, or the deathblow).
			counter(
				bot,
				if outcome == "PerfectDeflect" then Config.Bots.PunishChance else Config.Bots.PunishChance * 0.65,
				0.05
			)
		else
			-- Knocked aside, the string goes on: counter once it stops.
			task.delay(0.3, function()
				if alive(bot) and alive(attacker) and attacker.state ~= "Windup" then
					counter(bot, Config.Bots.PunishChance * 0.65, 0)
				end
			end)
		end
	elseif outcome == "Mikiri" then
		counter(bot, Config.Bots.PunishChance, 0.05) -- the MikiriSlash follow-up
	end
end

local function makeAlign(root: BasePart): AlignOrientation
	local attachment = root:FindFirstChild("RootAttachment")
	if not attachment or not attachment:IsA("Attachment") then
		local created = Instance.new("Attachment")
		created.Name = "RootAttachment"
		created.Parent = root
		attachment = created
	end
	local align = Instance.new("AlignOrientation")
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment :: Attachment
	align.Responsiveness = Config.Bots.TurnResponsiveness
	align.MaxTorque = math.huge
	align.Enabled = false
	align.Parent = root
	return align
end

-- Facing, every frame: free bots turn toward their target at TurnSpeed; a swinging bot
-- turns once into the attack, then only inside its move's tracking window (Kannagi's
-- notify windows), and never in recovery or a flinch.
local function updateFacing()
	local t = now()
	for c, brain in brains do
		local target = brain.target
		local rate = Config.Bots.TurnSpeed
		local state = c.state
		if state == "Windup" or state == "Recovery" then
			local kind = c.attackKind
			if kind then
				rate = Weapons.turnRate(Weapons.spec(c.weapon, kind), t - c.attackStartedAt, c.attackHitAt - t)
			end
		elseif state == "Staggered" or state == "Broken" or state == "Downed" or state == "Dead" then
			rate = 0
		end
		local toTarget = if target then flat(target.root.Position - c.root.Position) else Vector3.zero
		if rate > 0 and toTarget.Magnitude > 0.1 then
			brain.align.CFrame = CFrame.lookAt(Vector3.zero, toTarget.Unit)
			brain.align.MaxAngularVelocity = math.rad(rate)
			brain.align.Enabled = true
		else
			brain.align.Enabled = false
		end
	end
end

-- Registers a built bot with the combat system and gives it a brain.
local function animate(model: Model, rigTier: string): Brain?
	local c = CombatService.register(model, nil)
	if not c then
		return nil
	end
	c.root:SetNetworkOwner(nil)
	Locomotion.animateBot(c.humanoid)

	local brain: Brain = {
		c = c,
		tier = Config.Bots.Tiers[rigTier],
		foe = nil,
		arena = nil,
		align = makeAlign(c.root),
		target = nil,
		nextAttackAt = now() + 1,
		comboLeft = 0,
		lastOpeningAt = 0,
		readUntil = 0,
		backstepUntil = 0,
		strafeSign = 1,
		strafeSwitchAt = 0,
		trick = nil,
		morph = "Perilous",
	}
	brains[c] = brain
	task.spawn(function()
		while alive(c) do
			think(brain)
			task.wait(Config.Bots.ThinkInterval)
		end
		brains[c] = nil
		-- Forget its defence ladders and guard holds, and every rung held against it (PERF-07).
		ladders[c], guardUntil[c] = nil, nil
		for _, byAttacker in ladders do
			byAttacker[c] = nil
		end
	end)
	return brain
end

local function spawnBot(index: number)
	local model = buildRig(rollLook(index, tierName), tierName)
	model:PivotTo(spawnPoint())
	model.Parent = botFolder
	slots[index] = model

	local brain = animate(model, tierName)
	if not brain then
		model:Destroy()
		slots[index] = nil
		return
	end
	local c = brain.c

	c.humanoid.Died:Once(function()
		brain.align.Enabled = false
		task.delay(Config.Bots.RespawnDelay, function()
			if slots[index] ~= model then
				return -- already replaced or removed by setCount
			end
			model:Destroy()
			slots[index] = nil
			if respawnEnabled and index <= desiredCount then
				spawnBot(index)
			end
		end)
	end)
end

-- A duel opponent of skill `rigTier` at `cframe`, fighting only `foe` and staying within
-- `radius` of `center`. `name` keeps the same bot across rounds; the body is cleared away a
-- few seconds after it falls. `look` (returned from the first round) keeps its outfit, weapon,
-- blade and finisher too. Not part of the royale roster, so setCount never touches it.
function BotService.spawnDuelist(
	rigTier: string,
	cframe: CFrame,
	foe: Combatant,
	center: Vector3,
	radius: number,
	name: string?,
	look: BotLook?
): (Combatant?, BotLook?)
	if not Config.Bots.Tiers[rigTier] then
		rigTier = "Adept"
	end
	local chosen = look or rollLook(math.random(1, 12), rigTier)
	local model = buildRig(chosen, rigTier)
	if name then
		model.Name = name
	end
	model:PivotTo(cframe)
	model.Parent = duelFolder
	local brain = animate(model, rigTier)
	if not brain then
		model:Destroy()
		return nil
	end
	brain.foe = foe
	brain.arena = { center = center, radius = radius }
	brain.c.humanoid.Died:Once(function()
		brain.align.Enabled = false
		task.delay(Config.Bots.RespawnDelay, function()
			model:Destroy()
		end)
	end)
	return brain.c, chosen
end

-- Points a duel bot at its foe for this round (a player's body is new after each death).
function BotService.setFoe(c: Combatant, foe: Combatant)
	local brain = brains[c]
	if brain then
		brain.foe = foe
	end
end

-- Grows or shrinks the bot roster to `count`, replacing dead bodies. Yields while new
-- bots are built, so callers can position them straight after.
function BotService.setCount(count: number)
	desiredCount = count
	for index, model in slots do
		if index > count then
			slots[index] = nil
			model:Destroy()
		end
	end
	for index = 1, count do
		local model = slots[index]
		local living = model and CombatService.get(model)
		if not living or living.state == "Dead" then
			if model then
				slots[index] = nil
				model:Destroy()
			end
			spawnBot(index)
		end
	end
end

-- Bot skill for the bots spawned from now on (Config.Bots.Tiers).
function BotService.setTier(name: string)
	local found = Config.Bots.Tiers[name]
	if found then
		tierName, tier = name, found
	end
end

-- A match's tier follows its least experienced human: easy wins for the first matches (and
-- until a first win, up to 8), then fair fights, and masters for proven players: a ranked
-- rating of 800, or a solo player winning 45% of their royales (the baseline is ~17%).
function BotService.tierFor(players: { Player }): string
	local name = "Master"
	for _, player in players do
		local played = player:GetAttribute("Played") or 0
		local wins = player:GetAttribute("Wins") or 0
		local rating = player:GetAttribute("Rating") or Config.Rating.Start
		local winRate = if played > 0 then wins / played else 0
		if played < 3 or (wins == 0 and played < 8) then
			return "Novice"
		elseif played < 15 or (rating < 800 and winRate < 0.45) then
			name = "Adept"
		end
	end
	return if #players == 0 then "Adept" else name
end

-- Whether dead bots come back on their own (off during a match).
function BotService.setRespawn(enabled: boolean)
	respawnEnabled = enabled
end

function BotService.start()
	botFolder = Instance.new("Folder")
	botFolder.Name = "Bots"
	botFolder.Parent = workspace
	duelFolder = Instance.new("Folder")
	duelFolder.Name = "DuelBots"
	duelFolder.Parent = workspace

	CombatService.onWindup(onWindup)
	CombatService.onOutcome(onOutcome)
	RunService.Heartbeat:Connect(updateFacing)
end

return BotService
