--!strict
-- Sekiro-style lock-on: picks the enemy nearest the centre of the screen, keeps a
-- reticle on them, and drives an over-the-shoulder camera that frames both fighters.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)

local player = Players.LocalPlayer
local settings = Config.LockOn

local LockOn = {}

local target: Model? = nil
local PROBE_RADIUS = 0.4
-- Framing at contact (on top of Config.LockOn's Close* values, full at contact and eased in from
-- CloseRange). Kannagi's lens (60 deg, 9.3-stud arm, lag 7) is unchanged; what changes is where the
-- arm points. Straight behind you, a same-size opponent at contact hides behind your own back (46%
-- of their head, torso, arms and blade in view, the rest only with your body faded). Swinging the
-- arm 32 deg round the pair's midpoint toward your shoulder, a touch higher and tilted down onto
-- them, shows 78% standing, 75% while you swing and 88% while they swing, with no fade.
local FRAMING = {
	Orbit = 32, -- degrees the arm swings round the pair's midpoint toward your shoulder
	Shoulder = 0, -- studs further out to the side
	Raise = 0.5, -- studs higher (x the target's BodyScale)
	PivotRaise = 0.4, -- the pivot (and the arm's probe origin) rises too
	PullBack = 0,
	FocusDrop = 0.4, -- the look point drops toward the target's waist, so the view tilts down onto them
}
-- The camera keeps to one shoulder; it only crosses to the other when the fight has turned it
-- well over there (an opponent dashing past), and then swings across smoothly.
local SIDE_SWITCH = 1.5 -- studs past the pair line
local SIDE_RATE = 3
-- Thin set dressing (fence posts and rails, ropes, lantern poles) never pulls the camera in: the
-- probe passes through it and it fades on this screen while it's in the shot. Tag anything else
-- that should behave so with CameraIgnore.
local IGNORE_TAG = "CameraIgnore"
local THIN = 1.5 -- studs: a part whose two smaller sides are both under this may be thin (isThin)
local PROP_FADE = 0.75
local PROP_RATE = 12
local probeParams = RaycastParams.new()
probeParams.FilterType = Enum.RaycastFilterType.Exclude
probeParams.RespectCanCollide = true
local eye: Vector3? = nil -- the lagged camera position and look direction (Kannagi's spring arm)
local lookDir: Vector3? = nil
local side = 1 -- which shoulder the camera sits over (1 right, -1 left)
local sideBlend = 1
local fadedProps: { [BasePart]: number } = {}
local reticle: BillboardGui? = nil
local listeners: { (Model?) -> () } = {}

local function rootOf(model: Model?): BasePart?
	local root = model and model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function isValid(model: Model?, maxDistance: number): boolean
	if not model or not model.Parent or model:GetAttribute("CombatState") == "Dead" then
		return false
	end
	local mine, theirs = rootOf(player.Character), rootOf(model)
	return mine ~= nil and theirs ~= nil and (theirs.Position - mine.Position).Magnitude <= maxDistance
end

local function makeReticle(model: Model): BillboardGui?
	local torso = model:FindFirstChild("UpperTorso") or rootOf(model)
	if not torso or not torso:IsA("BasePart") then
		return nil
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "LockOnReticle"
	gui.Adornee = torso
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(16, 16)
	gui.LightInfluence = 0

	-- A small pale dot with a dark ring, like Sekiro's lock-on marker.
	local dot = Instance.new("Frame")
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromOffset(8, 8)
	dot.BackgroundColor3 = Color3.fromRGB(240, 232, 214)
	dot.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = dot
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(20, 16, 14)
	stroke.Thickness = 2
	stroke.Transparency = 0.2
	stroke.Parent = dot
	dot.Parent = gui

	gui.Parent = player:WaitForChild("PlayerGui")
	return gui
end

-- Best enemy for the camera direction: close to screen centre, then close in distance.
function LockOn.findBest(maxDistance: number): Model?
	local character = player.Character
	local mine = rootOf(character)
	if not mine then
		return nil
	end
	local look = workspace.CurrentCamera.CFrame.LookVector
	local facing = Vector3.new(look.X, 0, look.Z)
	facing = if facing.Magnitude > 1e-3 then facing.Unit else mine.CFrame.LookVector

	local best: Model? = nil
	local bestScore = -math.huge
	for _, instance in CollectionService:GetTagged(Types.Tag) do
		if instance ~= character and instance:IsA("Model") and isValid(instance, maxDistance) then
			local theirs = rootOf(instance) :: BasePart
			local offset = theirs.Position - mine.Position
			local flat = Vector3.new(offset.X, 0, offset.Z)
			local distance = flat.Magnitude
			if distance > 0.1 then
				local score = flat.Unit:Dot(facing) * 2 - distance / maxDistance
				if score > bestScore then
					best, bestScore = instance, score
				end
			end
		end
	end
	return best
end

-- Nearest enemy by distance alone (touch auto lock-on), among those `accept` allows.
function LockOn.nearest(maxDistance: number, accept: (Model) -> boolean): (Model?, number)
	local character = player.Character
	local mine = rootOf(character)
	if not mine then
		return nil, math.huge
	end
	local best: Model? = nil
	local bestDistance = math.huge
	for _, instance in CollectionService:GetTagged(Types.Tag) do
		if instance ~= character and instance:IsA("Model") and isValid(instance, maxDistance) and accept(instance) then
			local distance = ((rootOf(instance) :: BasePart).Position - mine.Position).Magnitude
			if distance < bestDistance then
				best, bestDistance = instance, distance
			end
		end
	end
	return best, bestDistance
end

-- Distance from us to `model` (math.huge when either body is missing).
function LockOn.distanceTo(model: Model): number
	local mine, theirs = rootOf(player.Character), rootOf(model)
	return if mine and theirs then (theirs.Position - mine.Position).Magnitude else math.huge
end

function LockOn.target(): Model?
	return target
end

function LockOn.set(model: Model?)
	if reticle then
		reticle:Destroy()
		reticle = nil
	end
	local was = target
	target = model
	local camera = workspace.CurrentCamera
	if model then
		reticle = makeReticle(model)
		camera.CameraType = Enum.CameraType.Scriptable
		if not was then
			eye, lookDir = camera.CFrame.Position, camera.CFrame.LookVector -- swing over from here
			side, sideBlend = 1, 1
		end
	else
		camera.CameraType = Enum.CameraType.Custom
	end
	if (was == nil) ~= (model == nil) then
		TweenService:Create(camera, TweenInfo.new(0.35, Enum.EasingStyle.Quad), { FieldOfView = LockOn.baseFov() })
			:Play()
	end
	for _, listener in listeners do
		task.spawn(listener, model)
	end
end

-- Locks on to `model` as a fight starts (Kannagi locks on to the boss): once both bodies
-- have arrived on their marks and are within lock range, or not at all after `timeout`.
local engageToken = 0
function LockOn.engage(model: Model, timeout: number?)
	engageToken += 1
	local token = engageToken
	local deadline = os.clock() + (timeout or 4)
	task.spawn(function()
		while engageToken == token and os.clock() < deadline do
			if target == model then
				return
			end
			if isValid(model, settings.Range) then
				LockOn.set(model)
				return
			end
			task.wait(0.1)
		end
	end)
end

-- Calls `listener(target)` whenever the lock-on target changes (nil when released).
function LockOn.changed(listener: (Model?) -> ())
	table.insert(listeners, listener)
end

function LockOn.toggle()
	if target then
		LockOn.set(nil)
	else
		LockOn.set(LockOn.findBest(settings.Range))
	end
end

-- The field of view the camera rests at right now (locked or free); FOV kicks (a dash, a
-- deathblow punch-in) tween back to this.
function LockOn.baseFov(): number
	return if target then settings.FieldOfView else settings.FreeFieldOfView
end

-- Studio tuning: a workspace attribute LockOn<Name> (e.g. LockOnShoulder) overrides FRAMING.
local function framing(name: string): number
	local value = FRAMING[name]
	if RunService:IsStudio() then
		local override = workspace:GetAttribute("LockOn" .. name)
		if typeof(override) == "number" then
			return override
		end
	end
	return value
end

local function isThin(part: BasePart): boolean
	if part:IsA("Terrain") then
		return false
	end
	if CollectionService:HasTag(part, IGNORE_TAG) then
		return true
	end
	-- Posts, poles, rails and ropes are thin in two directions with a roughly square section;
	-- planks and kerbs are thin too but flat (something to stand on), so they still count.
	local size = part.Size
	local a, b, c = size.X, size.Y, size.Z
	local smallest = math.min(a, b, c)
	local middle = math.max(math.min(a, b), math.min(math.max(a, b), c))
	return middle < THIN and smallest >= middle * 0.5
end

-- Fades the thin props in the shot (`inShot`) and restores the ones that left it.
local function fadeProps(inShot: { [BasePart]: boolean }, dt: number)
	local alpha = math.min(1, dt * PROP_RATE)
	for part in inShot do
		if not fadedProps[part] then
			fadedProps[part] = 0
		end
	end
	for part, amount in fadedProps do
		local goal = if inShot[part] then PROP_FADE else 0
		amount += (goal - amount) * alpha
		if goal == 0 and amount < 0.02 or not part.Parent then
			part.LocalTransparencyModifier = 0
			fadedProps[part] = nil
		else
			part.LocalTransparencyModifier = amount
			fadedProps[part] = amount
		end
	end
end

local function updateCamera(dt: number)
	if not target then
		eye, lookDir = nil, nil
		if next(fadedProps) then
			fadeProps({}, 1)
		end
		return
	end
	if not isValid(target, settings.BreakRange) then
		LockOn.set(nil)
		return
	end
	local character = player.Character
	local mine, theirs = rootOf(character), rootOf(target)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not mine or not theirs or not humanoid or humanoid.Health <= 0 then
		LockOn.set(nil) -- dead or gone: hand the camera back
		return
	end

	local offset = theirs.Position - mine.Position
	local flat = Vector3.new(offset.X, 0, offset.Z)
	local distance = flat.Magnitude
	local forward = if distance > 0.1 then flat.Unit else mine.CFrame.LookVector
	local right = forward:Cross(Vector3.yAxis)
	local scale = target:GetAttribute("BodyScale")
	scale = if typeof(scale) == "number" and scale > 0 then scale else 1

	-- How close the pair stands: 0 at CloseRange and beyond, 1 at contact (~3 studs).
	local close = math.clamp((settings.CloseRange - distance) / (settings.CloseRange - 3), 0, 1)
	close = close * close * (3 - 2 * close) -- smoothstep, so the framing eases in

	-- Keep to the shoulder the camera is already over unless the fight turned it well across.
	if eye then
		local across = (eye - mine.Position):Dot(right)
		if across * side < -SIDE_SWITCH then
			side = -side
		end
	end
	sideBlend += (side - sideBlend) * (1 - math.exp(-dt * SIDE_RATE))

	local pivot = mine.Position + Vector3.yAxis * (settings.PivotHeight + framing("PivotRaise") * close)
	local shoulder = settings.CameraShoulder + (settings.CloseShoulder + framing("Shoulder")) * close
	-- The arm behind you (back, out to the shoulder)...
	local back = -(settings.CameraDistance + (settings.ClosePullBack + framing("PullBack")) * close)
	local out = shoulder * sideBlend
	-- ...orbits around the pair's midpoint toward that shoulder at contact, so the line of sight
	-- to the opponent clears your own body instead of running through your back.
	local orbit = math.rad(framing("Orbit")) * close * sideBlend
	local centre = distance * 0.5 * close -- how far ahead of you the orbit centre sits
	local a, b = back - centre, out
	local cosO, sinO = math.cos(orbit), math.sin(orbit)
	a, b = a * cosO + b * sinO, -a * sinO + b * cosO
	local desiredEye = pivot
		+ forward * (a + centre)
		+ right * b
		+ Vector3.yAxis * (settings.CameraHeight + (settings.CloseRaise + framing("Raise")) * close * scale)
	-- Look at the pair, sliding toward the target's chest as they close in (a taller boss's
	-- chest sits higher), and down onto them at contact.
	local focus = mine.Position:Lerp(theirs.Position, 0.55 + 0.2 * close)
		+ Vector3.yAxis * (1.2 + (0.6 * scale - framing("FocusDrop")) * close)

	-- Kannagi's lag: the eye trails its arm at speed 7 (never more than MaxLag behind), and
	-- the view turns toward the target at speed 5.
	local current = eye or desiredEye
	current = current:Lerp(desiredEye, 1 - math.exp(-dt * settings.PositionLag))
	local lag = current - desiredEye
	if lag.Magnitude > settings.MaxLag then
		current = desiredEye + lag.Unit * settings.MaxLag
	end
	-- Kannagi's arm probes the world (ProbeChannel): a wall, rock or post between you and the
	-- eye pulls the camera in front of it at once (fighters never do).
	local reach = current - pivot
	local inShot: { [BasePart]: boolean } = {}
	if reach.Magnitude > 0.5 then
		local ignore: { Instance } = CollectionService:GetTagged(Types.Tag)
		for _ = 1, 8 do
			probeParams.FilterDescendantsInstances = ignore
			local hit = workspace:Spherecast(pivot, PROBE_RADIUS, reach, probeParams)
			if not hit then
				break
			end
			local part = hit.Instance
			if part:IsA("BasePart") and part.Transparency >= 0.9 then
				table.insert(ignore, part) -- invisible fence walls keep players in, not the camera
			elseif part:IsA("BasePart") and isThin(part) then
				table.insert(ignore, part) -- a post or rail: see through it instead of pulling in
				inShot[part] = true
			else
				current = pivot + reach.Unit * math.max(hit.Distance - 0.1, 1.5)
				break
			end
		end
	end
	-- Thin props between the eye and the target fade too (a post right in front of the lens).
	do
		local ignore: { Instance } = CollectionService:GetTagged(Types.Tag)
		local line = theirs.Position - current
		for _ = 1, 4 do
			probeParams.FilterDescendantsInstances = ignore
			local hit = workspace:Raycast(current, line, probeParams)
			local part = hit and hit.Instance
			if not part or not part:IsA("BasePart") or not (part.Transparency >= 0.9 or isThin(part)) then
				break
			end
			table.insert(ignore, part)
			if part.Transparency < 0.9 then
				inShot[part] = true
			end
		end
	end
	fadeProps(inShot, dt)
	eye = current
	local wantLook = (focus - current).Unit
	local look = lookDir or wantLook
	look = look:Lerp(wantLook, 1 - math.exp(-dt * settings.RotationLag))
	look = if look.Magnitude > 1e-3 then look.Unit else wantLook
	lookDir = look

	-- Camera shake (CombatVisuals) writes Humanoid.CameraOffset in the root's space, which only
	-- the default camera reads; apply it here too (it stays zero when shake is off in Settings).
	local shake = mine.CFrame:VectorToWorldSpace(humanoid.CameraOffset)
	workspace.CurrentCamera.CFrame = CFrame.lookAt(current + shake, current + shake + look)
end

function LockOn.start()
	RunService:BindToRenderStep("SekiroLockOn", Enum.RenderPriority.Camera.Value + 1, updateCamera)
	player.CharacterAdded:Connect(function()
		LockOn.set(nil)
	end)
end

return LockOn
