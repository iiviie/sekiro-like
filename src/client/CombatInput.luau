--!strict
-- Keyboard, gamepad and touch bindings (touch via TouchHUD), plus facing. The client only sends intents
-- stamped with the synced server clock; CombatService decides what happens. Inputs pressed
-- while busy are buffered by the server (Config.Combo.Buffer); dashes and jumps move your
-- own body, so those are buffered here and fire the frame you become free.
--
-- Facing (Kannagi's rule): free, the body turns toward its target at a constant
-- LockOn.TurnSpeed. A swing turns once at its start, then only inside the move's tracking
-- window (AttackSpec.trackRate / trackUntil), and recovery doesn't turn at all, so a
-- committed swing can be side-stepped. Without a lock, an attack or block briefly picks
-- the nearest enemy in front of the camera (a soft lock).

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local CombatVisuals = require(script.Parent.CombatVisuals)
local Config = require(ReplicatedStorage.Shared.Config)
local LocalCombat = require(script.Parent.LocalCombat)
local LockOn = require(script.Parent.LockOn)
local Motion = require(script.Parent.Motion)
local TouchHUD = require(script.Parent.TouchHUD)
local Types = require(ReplicatedStorage.Shared.Types)
local Weapons = require(ReplicatedStorage.Shared.Weapons)

local combatAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CombatAction") :: RemoteEvent
local player = Players.LocalPlayer

local SOFT_FACE_TIME = 0.35

-- Mirror of the server's combo counter, used only to guess which swing to animate early.
local comboIndex = 0
local comboUntil = 0

local CombatInput = {}

local blockHeld = false
local nextDashAt = 0
local dashBufferedAt = -math.huge
local jumpBufferedAt = -math.huge
local stompSent = false
local softTarget: Model? = nil
local softDirection: Vector3? = nil
local softFaceUntil = 0

local function now(): number
	return workspace:GetServerTimeNow()
end

local function getCharacter(): (Model?, BasePart?, Humanoid?)
	local character = player.Character
	if not character then
		return nil, nil, nil
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	return character, root, character:FindFirstChildOfClass("Humanoid")
end

local function send(action: Types.Action, flag: boolean?)
	combatAction:FireServer(action, now(), flag)
end

local function cameraFlatLook(): Vector3
	local look = workspace.CurrentCamera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	return if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
end

-- Turn toward the soft target (or along the camera) for a short moment.
local function softFace(duration: number?)
	softTarget = LockOn.findBest(Config.SoftLockRange)
	softDirection = if softTarget then nil else cameraFlatLook()
	softFaceUntil = os.clock() + (duration or SOFT_FACE_TIME)
end

local function facingGoal(root: BasePart): Vector3?
	local locked = LockOn.target()
	local focus = locked or (if os.clock() < softFaceUntil or blockHeld then softTarget else nil)
	local focusRoot = focus and focus:FindFirstChild("HumanoidRootPart")
	if focusRoot and focusRoot:IsA("BasePart") then
		local offset = focusRoot.Position - root.Position
		return Vector3.new(offset.X, 0, offset.Z)
	end
	if os.clock() < softFaceUntil then
		return softDirection
	end
	return nil
end

-- Turns the body's yaw toward `goal` by at most `maxStep` radians.
local function turnToward(root: BasePart, goal: Vector3, maxStep: number)
	local look = root.CFrame.LookVector
	local current = math.atan2(-look.X, -look.Z)
	local target = math.atan2(-goal.X, -goal.Z)
	local delta = (target - current + math.pi) % (2 * math.pi) - math.pi
	local step = math.clamp(delta, -maxStep, maxStep)
	root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, current + step, 0)
end

local function updateFacing(dt: number)
	local character, root, humanoid = getCharacter()
	if not character or not root or not humanoid or humanoid.Health <= 0 then
		return
	end
	local state = character:GetAttribute("CombatState")
	if state == "Staggered" or state == "Broken" or state == "Downed" then
		humanoid.AutoRotate = false -- a flinch or a break holds the body where the blow left it
		return
	end
	local swing = LocalCombat.swing
	if swing and LocalCombat.swinging(character) then
		-- Committed: Roblox's own rotation must not turn us toward where we "walk".
		humanoid.AutoRotate = false
		local spec = Weapons.spec(Weapons.of(character), swing.kind)
		local t = now()
		local rate = Weapons.turnRate(spec, t - swing.startedAt, swing.hitAt - t)
		local goal = facingGoal(root)
		if rate > 0 and goal and goal.Magnitude >= 0.1 then
			turnToward(root, goal, math.rad(rate) * dt)
		end
		return
	end
	-- Free. With a target (lock-on, a soft target while attacking or guarding) the body turns
	-- toward it at a constant rate; otherwise Roblox's own rotation turns you toward where
	-- you walk, which stays in step with the physics and feels the most natural.
	local goal = facingGoal(root)
	if not goal or goal.Magnitude < 0.1 then
		humanoid.AutoRotate = true
		return
	end
	humanoid.AutoRotate = false
	turnToward(root, goal, math.rad(Config.LockOn.TurnSpeed) * dt)
end

local function canAfford(character: Model, action: string): boolean
	local cost = Weapons.staminaCost(Weapons.of(character), action)
	local stamina = character:GetAttribute("Stamina")
	return not cost or typeof(stamina) ~= "number" or stamina >= cost
end

-- If we're free to swing right now, start the animation without waiting for the server.
-- The server's Windup corrects the clip if this guessed the wrong move.
local function predictSlash()
	local character = player.Character
	if not character or character:GetAttribute("CombatState") ~= "Idle" or LocalCombat.swinging(character) then
		return
	end
	local t = os.clock()
	local serverNow = now()
	local weapon = Weapons.of(character)
	local kind: Config.AttackKind? = nil
	if serverNow <= LocalCombat.riposteUntil then
		kind = "Riposte"
		LocalCombat.riposteUntil = -math.huge
	elseif serverNow <= LocalCombat.mikiriUntil then
		kind = "MikiriSlash"
		LocalCombat.mikiriUntil = -math.huge
	elseif serverNow - LocalCombat.dodgeAt <= Config.Dodge.AttackWindow then
		kind = "DodgeSlash"
		LocalCombat.dodgeAt = -math.huge
	end
	if kind then
		comboIndex = 0
		local spec = Weapons.spec(weapon, kind)
		comboUntil = t + spec.windup + Config.Net.ResolveGrace + spec.recovery + Config.Combo.Window
		CombatVisuals.predictAttack(character, kind, spec.windup)
		return
	end
	local sequence = Config.Combo.Sequence
	if t > comboUntil or comboIndex >= #sequence then
		comboIndex = 0
	end
	comboIndex += 1
	local next: Config.AttackKind = sequence[comboIndex]
	if next == "Light3" and t - LocalCombat.idleSince >= Config.Combo.DelayAfter then
		next = "Overhead"
	end
	if not canAfford(character, next) then
		comboIndex -= 1
		return
	end
	-- Mirror the server: chained slashes speed up only after a clean hit.
	local spec = Weapons.spec(weapon, next)
	local windup = if spec.chainWindup
			and comboIndex >= 2
			and LocalCombat.lastSlashLanded
		then spec.chainWindup
		else spec.windup
	LocalCombat.lastSlashLanded = false
	comboUntil = t + windup + Config.Net.ResolveGrace + spec.recovery + Config.Combo.Window
	CombatVisuals.predictAttack(character, next, windup)
end

local function setBlockHeld(held: boolean)
	if blockHeld == held then
		return
	end
	blockHeld = held
	local stamp = now()
	if held then
		softFace()
		dashBufferedAt = -math.huge -- last input wins
		-- Mirror the press locally so incoming deflects can be shown the instant they land,
		-- but only when the server will take it now: never in a windup (that's a feint), in
		-- recovery only past the move's block cancel point. Otherwise the server buffers
		-- the press and publishes the window when it opens (LocalCombat.confirm).
		local character = player.Character
		if character and LocalCombat.canAct(character, "Block") then
			LocalCombat.pressBlock(stamp)
		end
	else
		LocalCombat.releaseBlock(stamp)
	end
	send(if held then "BlockDown" else "BlockUp")
end

local function canDash(character: Model): boolean
	return os.clock() >= nextDashAt and canAfford(character, "Dodge") and LocalCombat.canAct(character, "Dodge")
end

local function performDash(character: Model, root: BasePart, humanoid: Humanoid)
	nextDashAt = os.clock() + Config.Dodge.Cooldown
	local direction = humanoid.MoveDirection
	-- Dashing toward the way you face is what turns a dodge into a Mikiri Counter.
	local forward = direction.Magnitude > 0.1 and direction.Unit:Dot(root.CFrame.LookVector) > 0.6
	if direction.Magnitude < 0.1 then
		direction = -root.CFrame.LookVector -- backstep
	end
	direction = Vector3.new(direction.X, 0, direction.Z).Unit

	local dodge = Config.Dodge
	-- A backstep covers less ground than a forward or side dash (Kannagi 8.6 vs 10.6 studs).
	local backstep = direction:Dot(root.CFrame.LookVector) < -0.7
	local scale = if backstep then 0.8 else 1
	-- A dodge passes through bodies (you can dash past or through someone).
	Motion.surge(direction, dodge.DashStartSpeed * scale, dodge.DashEndSpeed * scale, dodge.DashDuration, true)
	-- A brief widening of the view sells the burst of speed.
	local camera = workspace.CurrentCamera
	local base = LockOn.baseFov() -- locked or free (back-to-back dashes mustn't creep it up)
	camera.FieldOfView = base + dodge.DashFovKick
	TweenService:Create(camera, TweenInfo.new(dodge.DashDuration + 0.1, Enum.EasingStyle.Quad), {
		FieldOfView = base,
	}):Play()

	LocalCombat.dodgeAt = now()
	CombatVisuals.dash(character, direction)
	send("Dodge", forward)
end

-- A dash pressed while busy waits (Combo.Buffer) and fires the frame we're free, exactly
-- when the server will take it, so the movement and the i-frames line up.
local function dash()
	local character, root, humanoid = getCharacter()
	if not character or not root or not humanoid then
		return
	end
	if canDash(character) then
		dashBufferedAt = -math.huge
		performDash(character, root, humanoid)
	else
		dashBufferedAt = os.clock()
	end
end

local function airborne(humanoid: Humanoid): boolean
	local state = humanoid:GetState()
	return humanoid.FloorMaterial == Enum.Material.Air
		or state == Enum.HumanoidStateType.Jumping
		or state == Enum.HumanoidStateType.Freefall
end

-- Every jump press. In the air it's a stomp attempt (once per jump); on the ground while
-- committed it waits in the buffer, since Movement turns jumping off during swings.
local function jumpPressed(): boolean
	local character, _, humanoid = getCharacter()
	if not character or not humanoid or humanoid.Health <= 0 then
		return false
	end
	if airborne(humanoid) then
		if not stompSent then
			stompSent = true
			send("Stomp")
		end
		return false
	end
	if not LocalCombat.canAct(character, "Jump") then
		jumpBufferedAt = os.clock()
		return false
	end
	return true
end

-- Keyboard and gamepad go through ContextActionService; phones get TouchHUD's thumb
-- cluster instead of its grey on-screen buttons.
local function bind(name: string, onBegin: () -> (), onEnd: (() -> ())?, ...: any)
	ContextActionService:BindAction(name, function(_, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin then
			onBegin()
		elseif onEnd and (inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel) then
			onEnd()
		end
		return Enum.ContextActionResult.Sink
	end, false, ...)
end

-- Fires buffered dashes and jumps the frame they become legal.
local function replayBuffered()
	local character, root, humanoid = getCharacter()
	if not character or not root or not humanoid or humanoid.Health <= 0 then
		return
	end
	local t = os.clock()
	local buffer = Config.Combo.Buffer
	if t - dashBufferedAt <= buffer and canDash(character) then
		dashBufferedAt = -math.huge
		performDash(character, root, humanoid)
	end
	if t - jumpBufferedAt <= buffer and LocalCombat.canAct(character, "Jump") and not airborne(humanoid) then
		jumpBufferedAt = -math.huge
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	end
end

function CombatInput.start()
	LockOn.start()

	-- Track our character's state: when it last became free (for the delayed third slash),
	-- and the deflect windows the server opens for us (buffered presses, re-raised guards).
	local function watchState(character: Model)
		character:GetAttributeChangedSignal("CombatState"):Connect(function()
			local state = character:GetAttribute("CombatState")
			if state == "Idle" then
				LocalCombat.idleSince = os.clock()
			elseif state == "Staggered" or state == "Broken" or state == "Downed" then
				LocalCombat.attackingUntil = 0 -- a flinch ends any swing we predicted
			end
		end)
		character:GetAttributeChangedSignal("DeflectAt"):Connect(function()
			local at, window = character:GetAttribute("DeflectAt"), character:GetAttribute("DeflectWindow")
			if typeof(at) == "number" and typeof(window) == "number" then
				LocalCombat.confirm(at, window)
			end
		end)
		character:GetAttributeChangedSignal("Blocking"):Connect(function()
			if character:GetAttribute("Blocking") == true and blockHeld then
				LocalCombat.blocking = true -- the server raised our held guard again
			end
		end)
	end
	player.CharacterAdded:Connect(watchState)
	if player.Character then
		watchState(player.Character)
	end

	local function attack()
		dashBufferedAt = -math.huge
		-- The soft target lasts through the swing's tracking window.
		softFace(math.max(SOFT_FACE_TIME, 0.7))
		predictSlash()
		send("Attack")
	end
	local function blockDown()
		setBlockHeld(true)
	end
	local function blockUp()
		setBlockHeld(false)
	end
	local function perilous()
		dashBufferedAt = -math.huge
		softFace(1.1)
		send("Perilous")
	end
	local function sweep()
		dashBufferedAt = -math.huge
		softFace(1.1)
		send("Sweep")
	end
	local function heal()
		dashBufferedAt = -math.huge
		send("Heal")
	end

	bind("Attack", attack, nil, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR1)
	bind("Block", blockDown, blockUp, Enum.KeyCode.F, Enum.KeyCode.ButtonL1)
	bind("Perilous", perilous, nil, Enum.KeyCode.E, Enum.KeyCode.ButtonY)
	bind("Dodge", dash, nil, Enum.KeyCode.Q, Enum.KeyCode.ButtonB)
	bind("Sweep", sweep, nil, Enum.KeyCode.C, Enum.KeyCode.ButtonX)
	bind("Heal", heal, nil, Enum.KeyCode.G, Enum.KeyCode.DPadUp)
	bind("LockOn", LockOn.toggle, nil, Enum.KeyCode.R, Enum.UserInputType.MouseButton3, Enum.KeyCode.ButtonR3)

	-- Jump presses are watched, not bound, so Roblox's own jump keeps working.
	UserInputService.InputBegan:Connect(function(input)
		local key = input.KeyCode
		if (key == Enum.KeyCode.Space or key == Enum.KeyCode.ButtonA) and not UserInputService:GetFocusedTextBox() then
			jumpPressed()
		end
	end)

	TouchHUD.start({
		Attack = { began = attack },
		Block = { began = blockDown, ended = blockUp },
		Perilous = { began = perilous },
		Dodge = { began = dash },
		Sweep = { began = sweep },
		Heal = { began = heal },
		Jump = {
			began = function()
				local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
				if jumpPressed() and humanoid and humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping) then
					humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
				end
			end,
		},
	})

	RunService.RenderStepped:Connect(function(dt)
		updateFacing(dt)
		replayBuffered()
	end)

	-- Jumps are stamped so the server can tell whether you cleared a sweep (it checks that
	-- the body really left the ground).
	local function watchJumps(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
		if humanoid then
			humanoid.StateChanged:Connect(function(_, new)
				if new == Enum.HumanoidStateType.Jumping then
					stompSent = false
					send("Jump")
				elseif new == Enum.HumanoidStateType.Landed or new == Enum.HumanoidStateType.Running then
					stompSent = false
				end
			end)
		end
	end
	-- Tell the server we're in control once each body is registered, which ends the
	-- protection characters have while their player is still on the title screen.
	local function announceReady(character: Model)
		while character.Parent and character:GetAttribute("CombatState") == nil do
			character:GetAttributeChangedSignal("CombatState"):Wait()
		end
		send("Ready")
	end

	player.CharacterAdded:Connect(function(character)
		blockHeld = false
		softFaceUntil = 0
		LocalCombat.swing = nil
		task.spawn(watchJumps, character)
		task.spawn(announceReady, character)
	end)
	if player.Character then
		task.spawn(watchJumps, player.Character)
		task.spawn(announceReady, player.Character)
	end
end

return CombatInput
