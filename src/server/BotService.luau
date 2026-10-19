--!strict
-- Greybox opponents so the duel loop can be tested solo. Bots go through the same
-- CombatService.perform entry point as players, so they can't do anything a player can't.
-- They also double as the lobby-fillers the round loop will need later.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local CombatService = require(script.Parent.CombatService)

type Combatant = CombatService.Combatant
type AttackKind = Config.AttackKind
type AttackSpec = Config.AttackSpec

-- Roblox's default R15 animations. Bots run on the server, where the stock Animate
-- LocalScript doesn't, so they play these directly.
local IDLE_ANIMATION = "rbxassetid://507766666"
local RUN_ANIMATION = "rbxassetid://507767714"

local BOT_CLOTH = Color3.fromRGB(110, 28, 32)
local BOT_SKIN = Color3.fromRGB(234, 184, 146)

local BotService = {}

local bots: { [Combatant]: boolean } = {}
local botFolder: Folder

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

local function animate(humanoid: Humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	local function load(id: string): AnimationTrack?
		local animation = Instance.new("Animation")
		animation.AnimationId = id
		local ok, track = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		return if ok then track else nil
	end

	local idle = load(IDLE_ANIMATION)
	local run = load(RUN_ANIMATION)
	if idle then
		idle.Looped = true
		idle:Play()
	end
	humanoid.Running:Connect(function(speed)
		if not run then
			return
		end
		if speed > 0.5 and not run.IsPlaying then
			run:Play(0.15)
		elseif speed <= 0.5 and run.IsPlaying then
			run:Stop(0.15)
		end
	end)
end

local function nearestEnemy(self: Combatant): Combatant?
	local best: Combatant? = nil
	local bestScore = Config.Bots.AggroRange
	for _, other in CombatService.all() do
		if other ~= self and other.state ~= "Dead" then
			local distance = (other.root.Position - self.root.Position).Magnitude
			local score = if other.player then distance * Config.Bots.PlayerBias else distance
			if score < bestScore then
				best, bestScore = other, score
			end
		end
	end
	return best
end

local function think(c: Combatant, nextAttackAt: number): number
	local humanoid, root = c.humanoid, c.root
	local target = nearestEnemy(c)
	if not target then
		humanoid.AutoRotate = true
		humanoid:MoveTo(root.Position)
		return nextAttackAt
	end

	local offset = target.root.Position - root.Position
	local flat = Vector3.new(offset.X, 0, offset.Z)
	local distance = flat.Magnitude

	if distance > Config.Bots.EngageDistance then
		humanoid.AutoRotate = true
		humanoid:MoveTo(target.root.Position - flat.Unit * (Config.Bots.EngageDistance - 0.5))
		return nextAttackAt
	end

	humanoid.AutoRotate = false
	humanoid:MoveTo(root.Position)
	if distance > 0.05 then
		root.CFrame = CFrame.lookAt(root.Position, root.Position + flat)
	end

	local t = now()
	if c.state == "Idle" and not c.blocking and t >= nextAttackAt then
		local action = if math.random() < Config.Bots.PerilousChance then "Perilous" else "Attack"
		if CombatService.perform(c, action, t) then
			return t + randomRange(Config.Bots.AttackInterval)
		end
	end
	return nextAttackAt
end

local function dodgeAway(bot: Combatant)
	if not CombatService.perform(bot, "Dodge", now()) then
		return
	end
	local side = if math.random() < 0.5 then 1 else -1
	bot.root.AssemblyLinearVelocity = bot.root.CFrame.RightVector * side * Config.Dodge.Speed
end

local function tapBlock(bot: Combatant, pressAt: number, releaseAt: number)
	at(pressAt, function()
		if alive(bot) then
			CombatService.perform(bot, "BlockDown", now())
		end
	end)
	at(releaseAt, function()
		if alive(bot) then
			CombatService.perform(bot, "BlockUp", now())
		end
	end)
end

-- Bots are omniscient about hitAt, so their skill comes purely from these dice rolls.
local function react(bot: Combatant, spec: AttackSpec, hitAt: number)
	local skill = Config.Bots
	local roll = math.random()

	if spec.unblockable then
		if roll < skill.DodgePerilousChance then
			local lead = randomRange({ 0.08, Config.Dodge.IFrames - 0.05 })
			at(hitAt - lead, function()
				if alive(bot) then
					dodgeAway(bot)
				end
			end)
		end
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
	for bot in bots do
		if bot ~= attacker and alive(bot) then
			local distance = (bot.root.Position - attacker.root.Position).Magnitude
			if distance <= spec.range + 3 then
				react(bot, spec, hitAt)
			end
		end
	end
end

local function spawnBot(index: number)
	local model = buildRig(index)
	model:PivotTo(spawnPoint())
	model.Parent = botFolder

	local c = CombatService.register(model, nil)
	if not c then
		model:Destroy()
		return
	end
	c.root:SetNetworkOwner(nil)
	animate(c.humanoid)
	bots[c] = true

	c.humanoid.Died:Once(function()
		bots[c] = nil
		task.delay(Config.Bots.RespawnDelay, function()
			model:Destroy()
			spawnBot(index)
		end)
	end)

	task.spawn(function()
		local nextAttackAt = now() + 1
		while alive(c) do
			nextAttackAt = think(c, nextAttackAt)
			task.wait(Config.Bots.ThinkInterval)
		end
	end)
end

function BotService.start()
	botFolder = Instance.new("Folder")
	botFolder.Name = "Bots"
	botFolder.Parent = workspace

	CombatService.onWindup(onWindup)
	for index = 1, Config.Bots.Count do
		task.spawn(spawnBot, index)
	end
end

return BotService
