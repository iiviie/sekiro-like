--!strict
-- Bot opponents for solo testing, and later the lobby-fillers for the round loop. Bots go
-- through the same CombatService.perform entry point as players, so they can't do
-- anything a player can't.
--
-- Behaviour: pick a target (spreading out so one fighter isn't mobbed), circle it at
-- StrafeDistance, step in to swing a short combo, back off to recover posture, and
-- react to incoming windups with dice-rolled deflects, guards and dodges.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local CombatService = require(script.Parent.CombatService)
local Locomotion = require(script.Parent.Locomotion)
local Round = require(ReplicatedStorage.Shared.Round)

type Combatant = CombatService.Combatant
type AttackKind = Config.AttackKind
type AttackSpec = Config.AttackSpec

type Brain = {
	c: Combatant,
	align: AlignOrientation,
	target: Combatant?,
	nextAttackAt: number,
	comboLeft: number,
	strafeSign: number,
	strafeSwitchAt: number,
}

local BOT_CLOTH = Color3.fromRGB(70, 22, 26)
local BOT_SKIN = Color3.fromRGB(234, 184, 146)
local TARGET_SHARE_PENALTY = 30 -- studs added per other bot already on a target

local BotService = {}

local brains: { [Combatant]: Brain } = {}
local botFolder: Folder
local slots: { [number]: Model } = {} -- bot index -> its current body
local desiredCount = 0
local respawnEnabled = true

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

local function buildRig(index: number): Model
	local description = Instance.new("HumanoidDescription")
	description.HeadColor = BOT_SKIN
	description.LeftArmColor = BOT_SKIN
	description.RightArmColor = BOT_SKIN
	description.TorsoColor = BOT_CLOTH
	description.LeftLegColor = BOT_CLOTH
	description.RightLegColor = BOT_CLOTH

	local model = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	model.Name = `Ronin {index}`
	return model
end

local function chooseTarget(brain: Brain): Combatant?
	local self = brain.c
	local best: Combatant? = nil
	local bestScore = Config.Bots.AggroRange
	for _, other in CombatService.all() do
		if other ~= self and other.state ~= "Dead" and not CombatService.isProtected(other) then
			local score = (other.root.Position - self.root.Position).Magnitude
			if other.player then
				score *= Config.Bots.PlayerBias
			end
			for otherBrain in brains do
				if otherBrain ~= self and brains[otherBrain].target == other then
					score += TARGET_SHARE_PENALTY
				end
			end
			if score < bestScore then
				best, bestScore = other, score
			end
		end
	end
	return best
end

local function startCombo(brain: Brain, t: number)
	local c = brain.c
	local perilous = math.random() < Config.Bots.PerilousChance
	local action = if not perilous then "Attack" elseif math.random() < 0.5 then "Perilous" else "Sweep"
	if CombatService.perform(c, action, t) then
		brain.comboLeft = 0
		if not perilous then
			while brain.comboLeft < 2 and math.random() < Config.Bots.ComboContinueChance do
				brain.comboLeft += 1
			end
		end
		brain.nextAttackAt = t + randomRange(Config.Bots.AttackInterval)
	end
end

local function think(brain: Brain)
	local c = brain.c
	local humanoid, root = c.humanoid, c.root
	local t = now()

	brain.target = chooseTarget(brain)
	local target = brain.target
	if not target then
		brain.align.Enabled = false
		humanoid.AutoRotate = true
		humanoid:Move(Vector3.zero)
		return
	end

	local toTarget = flat(target.root.Position - root.Position)
	local distance = toTarget.Magnitude
	local forward = if distance > 0.01 then toTarget.Unit else flat(root.CFrame.LookVector).Unit
	local right = forward:Cross(Vector3.yAxis)

	-- Face the target smoothly.
	humanoid.AutoRotate = false
	brain.align.Enabled = true
	brain.align.CFrame = CFrame.lookAt(Vector3.zero, forward)

	-- Chain the next slash by buffering it in the last moments of recovery.
	if c.state == "Staggered" or c.state == "Broken" then
		brain.comboLeft = 0
	elseif brain.comboLeft > 0 and c.state == "Recovery" and c.stateEndsAt - t <= Config.Combo.Buffer then
		CombatService.perform(c, "Attack", t)
		brain.comboLeft -= 1
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
	elseif postureRatio > Config.Bots.RetreatPosture or hurt then
		move = -forward + right * brain.strafeSign * 0.6
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
	-- Stay inside the ring during a match, and inside the walls otherwise.
	local zoneCenter, zoneRadius = Round.zone(t)
	local fromCentre = flat(root.Position - zoneCenter)
	local limit = math.min(zoneRadius - 6, Config.Bots.ArenaRadius)
	if fromCentre.Magnitude > limit then
		move -= fromCentre.Unit * (if fromCentre.Magnitude > zoneRadius then 3 else 1)
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

local function tapBlock(bot: Combatant, pressAt: number, releaseAt: number)
	at(pressAt, function()
		if not alive(bot) then
			return
		end
		-- Blocking out of a windup is a feint; only do that on purpose, now and then.
		if bot.state == "Windup" and math.random() > Config.Bots.FeintChance then
			return
		end
		CombatService.perform(bot, "BlockDown", now())
	end)
	at(releaseAt, function()
		if alive(bot) then
			CombatService.perform(bot, "BlockUp", now())
		end
	end)
end

-- Bots are omniscient about hitAt, so their skill comes purely from these dice rolls.
local function react(bot: Combatant, attacker: Combatant, spec: AttackSpec, hitAt: number)
	local skill = Config.Bots
	local roll = math.random()

	if spec.unblockable then
		if roll >= skill.DodgePerilousChance then
			return -- reads it wrong and eats the perilous attack
		end
		if spec.low then
			at(hitAt - randomRange({ 0.15, 0.4 }), function()
				if alive(bot) then
					jumpOver(bot)
				end
			end)
			return
		end
		local mikiri = spec.thrust and math.random() < skill.MikiriChance
		local lead = randomRange({ 0.08, Config.Dodge.IFrames - 0.05 })
		at(hitAt - lead, function()
			if not alive(bot) then
				return
			end
			if mikiri then
				dashInto(bot, attacker)
			else
				dodgeAway(bot)
			end
		end)
		return
	end

	local perfect = Config.Deflect.PerfectWindow
	if roll < skill.PerfectChance then
		tapBlock(bot, hitAt - randomRange({ 0.02, perfect - 0.02 }), hitAt + 0.15)
	elseif roll < skill.DeflectChance then
		tapBlock(bot, hitAt - randomRange({ perfect + 0.02, Config.Deflect.Window - 0.03 }), hitAt + 0.15)
	elseif roll < skill.DeflectChance + skill.GuardChance then
		-- Raise guard well before the deflect window so it only guards.
		tapBlock(bot, hitAt - 0.5, hitAt + 0.3)
	end
end

local function onWindup(attacker: Combatant, kind: AttackKind, hitAt: number)
	local spec = Config.Attacks[kind]
	for bot in brains do
		if bot ~= attacker and alive(bot) then
			local distance = (bot.root.Position - attacker.root.Position).Magnitude
			if distance <= spec.range + 3 then
				react(bot, attacker, spec, hitAt)
			end
		end
	end
end

local function onDeflect(_attacker: Combatant, defender: Combatant, perfect: boolean)
	local brain = brains[defender]
	if not brain then
		return
	end
	local chance = if perfect then Config.Bots.PunishChance else Config.Bots.PunishChance * 0.4
	if math.random() < chance then
		task.delay(0.05, function()
			if alive(defender) then
				brain.nextAttackAt = 0
				CombatService.perform(defender, "Attack", now())
			end
		end)
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

local function spawnBot(index: number)
	local model = buildRig(index)
	model:PivotTo(spawnPoint())
	model.Parent = botFolder
	slots[index] = model

	local c = CombatService.register(model, nil)
	if not c then
		model:Destroy()
		slots[index] = nil
		return
	end
	c.root:SetNetworkOwner(nil)
	Locomotion.animateBot(c.humanoid)

	local brain: Brain = {
		c = c,
		align = makeAlign(c.root),
		target = nil,
		nextAttackAt = now() + 1,
		comboLeft = 0,
		strafeSign = 1,
		strafeSwitchAt = 0,
	}
	brains[c] = brain

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

	task.spawn(function()
		while alive(c) do
			think(brain)
			task.wait(Config.Bots.ThinkInterval)
		end
		brains[c] = nil
	end)
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

-- Whether dead bots come back on their own (off during a match).
function BotService.setRespawn(enabled: boolean)
	respawnEnabled = enabled
end

function BotService.start()
	botFolder = Instance.new("Folder")
	botFolder.Name = "Bots"
	botFolder.Parent = workspace

	CombatService.onWindup(onWindup)
	CombatService.onDeflect(onDeflect)
end

return BotService
