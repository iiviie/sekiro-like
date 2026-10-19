--!strict
-- Keyboard, gamepad and touch bindings, plus facing. The client only sends intents
-- stamped with the synced server clock; CombatService decides what happens. Attacks
-- pressed early are buffered by the server, so mashing in rhythm chains the combo.
--
-- Facing: while locked on, the character turns smoothly to keep facing the target.
-- Without a lock, any attack or block briefly turns you toward the nearest enemy in
-- front of the camera (a soft lock), instead of snapping.

local ContextActionService = game:GetService("ContextActionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatVisuals = require(script.Parent.CombatVisuals)
local Config = require(ReplicatedStorage.Shared.Config)
local LockOn = require(script.Parent.LockOn)
local Types = require(ReplicatedStorage.Shared.Types)

local combatAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CombatAction") :: RemoteEvent
local player = Players.LocalPlayer

local SOFT_FACE_TIME = 0.35

-- Mirror of the server's combo counter, used only to guess which swing to animate early.
local comboIndex = 0
local comboUntil = 0

local CombatInput = {}

local blockHeld = false
local nextDashAt = 0
local softTarget: Model? = nil
local softDirection: Vector3? = nil
local softFaceUntil = 0

local function getCharacter(): (Model?, BasePart?, Humanoid?)
	local character = player.Character
	if not character then
		return nil, nil, nil
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	return character, root, character:FindFirstChildOfClass("Humanoid")
end

local function send(action: Types.Action, flag: boolean?)
	combatAction:FireServer(action, workspace:GetServerTimeNow(), flag)
end

local function cameraFlatLook(): Vector3
	local look = workspace.CurrentCamera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	return if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
end

-- Turn toward the soft target (or along the camera) for a short moment.
local function softFace()
	softTarget = LockOn.findBest(Config.SoftLockRange)
	softDirection = if softTarget then nil else cameraFlatLook()
	softFaceUntil = os.clock() + SOFT_FACE_TIME
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

local function updateFacing(dt: number)
	local _, root, humanoid = getCharacter()
	if not root or not humanoid or humanoid.Health <= 0 then
		return
	end
	local goal = facingGoal(root)
	if not goal or goal.Magnitude < 0.1 then
		humanoid.AutoRotate = true
		return
	end
	humanoid.AutoRotate = false
	local target = CFrame.lookAt(root.Position, root.Position + goal)
	local alpha = 1 - math.exp(-dt * Config.LockOn.TurnRate)
	root.CFrame = root.CFrame:Lerp(target, alpha)
end

-- If we're free to swing right now, start the animation without waiting for the server.
local function predictSlash()
	local character = player.Character
	if not character or character:GetAttribute("CombatState") ~= "Idle" then
		return
	end
	local t = os.clock()
	local sequence = Config.Combo.Sequence
	if t > comboUntil or comboIndex >= #sequence then
		comboIndex = 0
	end
	comboIndex += 1
	local kind = sequence[comboIndex]
	local spec = Config.Attacks[kind]
	comboUntil = t + spec.windup + Config.Net.ResolveGrace + spec.recovery + Config.Combo.Window
	CombatVisuals.predictAttack(character, kind)
end

local function setBlockHeld(held: boolean)
	if blockHeld == held then
		return
	end
	blockHeld = held
	if held then
		softFace()
	end
	send(if held then "BlockDown" else "BlockUp")
end

local function dash()
	local character, root, humanoid = getCharacter()
	if not character or not root or not humanoid then
		return
	end
	-- Mirror the server's checks so the dash movement and the i-frames line up.
	local state = character:GetAttribute("CombatState")
	if (state ~= "Idle" and state ~= "Recovery") or os.clock() < nextDashAt then
		return
	end
	local attachment = root:FindFirstChild("RootAttachment") :: Attachment?
	if not attachment then
		return
	end
	nextDashAt = os.clock() + Config.Dodge.Cooldown

	local direction = humanoid.MoveDirection
	-- Dashing toward the way you face is what turns a dodge into a Mikiri Counter.
	local forward = direction.Magnitude > 0.1 and direction.Unit:Dot(root.CFrame.LookVector) > 0.6
	if direction.Magnitude < 0.1 then
		direction = -root.CFrame.LookVector -- backstep
	end
	direction = Vector3.new(direction.X, 0, direction.Z).Unit

	local velocity = Instance.new("LinearVelocity")
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	velocity.PrimaryTangentAxis = Vector3.xAxis
	velocity.SecondaryTangentAxis = Vector3.zAxis
	velocity.PlaneVelocity = Vector2.new(direction.X, direction.Z) * Config.Dodge.Speed
	velocity.MaxForce = math.huge
	velocity.Parent = root
	Debris:AddItem(velocity, Config.Dodge.DashDuration)

	CombatVisuals.dash(character)
	send("Dodge", forward)
end

local function bind(name: string, title: string, position: UDim2, onBegin: () -> (), onEnd: (() -> ())?, ...: any)
	ContextActionService:BindAction(name, function(_, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin then
			onBegin()
		elseif onEnd and (inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel) then
			onEnd()
		end
		return Enum.ContextActionResult.Sink
	end, true, ...)
	ContextActionService:SetTitle(name, title)
	ContextActionService:SetPosition(name, position)
end

function CombatInput.start()
	LockOn.start()

	bind("Attack", "Slash", UDim2.new(1, -150, 1, -160), function()
		softFace()
		predictSlash()
		send("Attack")
	end, nil, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR1)

	bind("Block", "Block", UDim2.new(1, -230, 1, -110), function()
		setBlockHeld(true)
	end, function()
		setBlockHeld(false)
	end, Enum.KeyCode.F, Enum.KeyCode.ButtonL1)

	bind("Perilous", "Thrust", UDim2.new(1, -150, 1, -240), function()
		softFace()
		send("Perilous")
	end, nil, Enum.KeyCode.E, Enum.KeyCode.ButtonY)

	bind("Dodge", "Dodge", UDim2.new(1, -230, 1, -190), dash, nil, Enum.KeyCode.Q, Enum.KeyCode.ButtonB)

	bind("Sweep", "Sweep", UDim2.new(1, -70, 1, -200), function()
		softFace()
		send("Sweep")
	end, nil, Enum.KeyCode.C, Enum.KeyCode.ButtonX)

	bind("Heal", "Heal", UDim2.new(1, -310, 1, -70), function()
		send("Heal")
	end, nil, Enum.KeyCode.G, Enum.KeyCode.DPadUp)

	bind(
		"LockOn",
		"Lock",
		UDim2.new(1, -310, 1, -150),
		LockOn.toggle,
		nil,
		Enum.KeyCode.R,
		Enum.UserInputType.MouseButton3,
		Enum.KeyCode.ButtonR3
	)

	RunService.RenderStepped:Connect(updateFacing)

	-- Jumps are stamped so the server can tell whether you cleared a sweep.
	local function watchJumps(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
		if humanoid then
			humanoid.StateChanged:Connect(function(_, new)
				if new == Enum.HumanoidStateType.Jumping then
					send("Jump")
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
		task.spawn(watchJumps, character)
		task.spawn(announceReady, character)
	end)
	if player.Character then
		task.spawn(watchJumps, player.Character)
		task.spawn(announceReady, player.Character)
	end
end

return CombatInput
