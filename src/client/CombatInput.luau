--!strict
-- Keyboard, gamepad and touch bindings. The client only sends intents stamped with
-- the synced server clock; CombatService decides what actually happens.

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)

local combatAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CombatAction") :: RemoteEvent
local player = Players.LocalPlayer

local CombatInput = {}

local blockHeld = false
local nextDashAt = 0

local function getCharacter(): (Model?, BasePart?, Humanoid?)
	local character = player.Character
	if not character then
		return nil, nil, nil
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	return character, root, character:FindFirstChildOfClass("Humanoid")
end

local function send(action: Types.Action)
	combatAction:FireServer(action, workspace:GetServerTimeNow())
end

-- Soft lock: turn toward the nearby enemy closest to where the camera is looking,
-- or along the camera if nobody is in range.
local function faceTarget()
	local character, root = getCharacter()
	if not character or not root then
		return
	end

	local look = workspace.CurrentCamera.CFrame.LookVector
	local facing = Vector3.new(look.X, 0, look.Z)
	if facing.Magnitude < 1e-3 then
		facing = root.CFrame.LookVector
	end
	facing = facing.Unit

	local best: Vector3? = nil
	local bestScore = -math.huge
	for _, model in CollectionService:GetTagged(Types.Tag) do
		if model ~= character and model:IsA("Model") and model:GetAttribute("CombatState") ~= "Dead" then
			local other = model:FindFirstChild("HumanoidRootPart") :: BasePart?
			if other then
				local offset = other.Position - root.Position
				local flat = Vector3.new(offset.X, 0, offset.Z)
				local distance = flat.Magnitude
				if distance > 0.1 and distance <= Config.SoftLockRange then
					local score = flat.Unit:Dot(facing) - (distance / Config.SoftLockRange) * 0.5
					if score > bestScore then
						best, bestScore = flat, score
					end
				end
			end
		end
	end

	local direction = best or facing
	root.CFrame = CFrame.lookAt(root.Position, root.Position + direction)
end

local function setBlockHeld(held: boolean)
	if blockHeld == held then
		return
	end
	blockHeld = held
	local _, _, humanoid = getCharacter()
	if humanoid then
		-- Keep facing the target while guarding instead of turning toward movement.
		humanoid.AutoRotate = not held
	end
	if held then
		faceTarget()
	end
	send(if held then "BlockDown" else "BlockUp")
end

local function dash()
	local character, root, humanoid = getCharacter()
	if not character or not root or not humanoid then
		return
	end
	-- Mirror the server's checks so the dash movement and the i-frames line up.
	if character:GetAttribute("CombatState") ~= "Idle" or os.clock() < nextDashAt then
		return
	end
	local attachment = root:FindFirstChild("RootAttachment") :: Attachment?
	if not attachment then
		return
	end
	nextDashAt = os.clock() + Config.Dodge.Cooldown

	local direction = humanoid.MoveDirection
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

	send("Dodge")
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
	bind("Attack", "Slash", UDim2.new(1, -150, 1, -160), function()
		faceTarget()
		send("Attack")
	end, nil, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR1)

	bind("Block", "Block", UDim2.new(1, -230, 1, -110), function()
		setBlockHeld(true)
	end, function()
		setBlockHeld(false)
	end, Enum.KeyCode.F, Enum.KeyCode.ButtonL1)

	bind("Perilous", "Thrust", UDim2.new(1, -150, 1, -240), function()
		faceTarget()
		send("Perilous")
	end, nil, Enum.KeyCode.E, Enum.KeyCode.ButtonY)

	bind("Dodge", "Dodge", UDim2.new(1, -230, 1, -190), dash, nil, Enum.KeyCode.Q, Enum.KeyCode.ButtonB)

	RunService.RenderStepped:Connect(function()
		if blockHeld then
			faceTarget()
		end
	end)

	player.CharacterAdded:Connect(function()
		blockHeld = false
	end)
end

return CombatInput
