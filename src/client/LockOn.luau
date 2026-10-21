--!strict
-- Sekiro-style lock-on: picks the enemy nearest the centre of the screen, keeps a
-- reticle on them, and drives an over-the-shoulder camera that frames both fighters.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local Tagged = require(ReplicatedStorage.Shared.Tagged)
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
-- probe passes through it, and Occlusion fades it while it's in the shot (as it does canopies and
-- other non-colliding props the lens enters). Tag anything else that should behave so with
-- CameraIgnore.
local IGNORE_TAG = "CameraIgnore"
local THIN = 1.5 -- studs: a part whose two smaller sides are both under this may be thin (isThin)
-- When a wall, rock, roof post or the arena's edge shortens the arm, the lens doesn't slide down
-- the arm into your head: it cranes up over you as the arm shortens (CRANE studs at a fully
-- pulled-in arm), and never comes within MIN_HEAD studs of your head, looking down past it.
local CRANE = 2.5
local MIN_HEAD = 4.2
-- Fenced terraces (duel and boss): the lens keeps EDGE_IN studs inside the rope instead of
-- riding outside the ring over the drop, behind the rope, posts and rim rocks. Only when you're
-- backed onto the rope may it go past it (never more than EDGE_OUT, over the terrace's own rim),
-- so it still stays MIN_BACK studs behind you and you stay in the shot.
local EDGE_IN = 1.2
local EDGE_OUT = 4
-- Near the rope the arm first swings round you along it (up to EDGE_SWING, tested in
-- EDGE_SWING_STEPS steps each way, settling at EDGE_YAW_RATE) until EDGE_ENOUGH of its length
-- fits; only what still doesn't fit is shortened, never below MIN_BACK studs behind you.
local EDGE_SWING = math.rad(70)
local EDGE_SWING_STEPS = 14
local EDGE_ENOUGH = 0.8
local EDGE_YAW_RATE = 3
local MIN_BACK = 7
-- As the arm is shortened, the look point slides up to FOCUS_SELF of the way to your head, so
-- you stay in the bottom of the shot.
local FOCUS_SELF = 0.4
local probeParams = RaycastParams.new()
probeParams.FilterType = Enum.RaycastFilterType.Exclude
probeParams.RespectCanCollide = true
local eye: Vector3? = nil -- the lagged camera position and look direction (Kannagi's spring arm)
local lookDir: Vector3? = nil
-- How far along the arm the lens may sit: a wall, rock or post pulls it in at once, and it eases
-- back out at ARM_OUT_RATE (a post edging in and out of the probe doesn't pop the view each frame).
local armLength: number? = nil
local ARM_OUT_RATE = 4
local side = 1 -- which shoulder the camera sits over (1 right, -1 left)
local sideBlend = 1
local edgeYaw = 0 -- radians the arm is swung round you along an arena's rope
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
	for _, instance in Tagged.list(Types.Tag) do
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
	for _, instance in Tagged.list(Types.Tag) do
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

-- Whether `part` is thin set dressing the camera looks through (Occlusion fades these too).
function LockOn.isThin(part: BasePart): boolean
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
local isThin = LockOn.isThin

-- The fenced terraces (LobbyBuilder publishes each one's walk-surface centre as an Arena
-- attribute): duel grounds at Config.Duel.ArenaRadius, the boss terrace at Config.Bosses'.
type Arena = { centre: Vector3, radius: number }
local arenas: { Arena } = {}
local arenasAt = -math.huge
local function findArenas()
	arenasAt = os.clock()
	table.clear(arenas)
	local lobby = workspace:FindFirstChild("Lobby")
	if not lobby then
		return
	end
	local function add(holder: Instance, radius: number)
		local centre = holder:GetAttribute("Arena")
		if typeof(centre) == "Vector3" then
			table.insert(arenas, { centre = centre, radius = radius })
		end
	end
	local grounds = lobby:FindFirstChild("DuelGrounds")
	if grounds then
		for _, ground in grounds:GetChildren() do
			add(ground, Config.Duel.ArenaRadius)
		end
	end
	local shrine = lobby:FindFirstChild("BossShrine")
	if shrine then
		add(shrine, Config.Bosses.ArenaRadius)
	end
end

-- The fenced terrace `position` stands on, if any.
local function arenaAround(position: Vector3): Arena?
	if #arenas == 0 and os.clock() - arenasAt > 2 then
		findArenas()
	end
	for _, arena in arenas do
		local d = position - arena.centre
		if math.abs(d.Y) < 14 and Vector2.new(d.X, d.Z).Magnitude < arena.radius + 2 then
			return arena
		end
	end
	return nil
end

-- How far (0-1) along `arm` from `from` the lens may go before leaving the arena's circle
-- grown by `margin` (negative: inside the rope), measured on the ground plane; 0 when `from` is
-- already past it.
local function insideFraction(arena: Arena, from: Vector3, arm: Vector3, margin: number): number
	local px, pz = from.X - arena.centre.X, from.Z - arena.centre.Z
	local dx, dz = arm.X, arm.Z
	local r = arena.radius + margin
	local a = dx * dx + dz * dz
	local c = px * px + pz * pz - r * r
	if c >= 0 then
		return 0
	end
	if a < 1e-6 then
		return 1
	end
	local b = 2 * (px * dx + pz * dz)
	local t = (-b + math.sqrt(b * b - 4 * a * c)) / (2 * a)
	return math.clamp(t, 0, 1)
end

-- The lens `length` studs along `arm` (unit `dir`, full length `full`), craned up over your head
-- as the arm shortens and kept MIN_HEAD studs from it; a roof caps the rise.
local function crane(pivot: Vector3, dir: Vector3, full: number, length: number, head: Vector3): Vector3
	local lens = pivot + dir * length
	local lift = CRANE * math.clamp(1 - length / math.max(full, 1e-3), 0, 1)
	local rel = lens + Vector3.yAxis * lift - head
	if rel.Magnitude < MIN_HEAD then
		local flat = Vector2.new(rel.X, rel.Z).Magnitude
		local rise = math.sqrt(math.max(MIN_HEAD * MIN_HEAD - flat * flat, 0))
		lift = math.max(lift, head.Y + rise - lens.Y)
	end
	if lift > 0.05 then
		local hit = workspace:Raycast(lens, Vector3.yAxis * (lift + 0.4), probeParams)
		if hit then
			lift = math.max(hit.Distance - 0.4, 0)
		end
	end
	return lens + Vector3.yAxis * lift
end

-- `lens` (on the arm from `pivot`) kept inside the arena: shortened to EDGE_IN inside the rope,
-- or as far as MIN_BACK behind you allows (EDGE_OUT past it at most), and craned.
local function fitArena(arena: Arena, pivot: Vector3, lens: Vector3, head: Vector3): Vector3
	local arm = lens - pivot
	local soft = insideFraction(arena, pivot, arm, -EDGE_IN)
	if soft >= 1 or arm.Magnitude < 0.5 then
		return lens
	end
	local ground = Vector2.new(arm.X, arm.Z).Magnitude
	local keep = math.min(MIN_BACK / math.max(ground, 1e-3), 1)
	local fraction = math.max(soft, math.min(keep, insideFraction(arena, pivot, arm, EDGE_OUT)))
	if fraction >= 1 then
		return lens
	end
	return crane(pivot, arm.Unit, arm.Magnitude, arm.Magnitude * fraction, head)
end

local function updateCamera(dt: number)
	if not target then
		eye, lookDir, armLength = nil, nil, nil
		edgeYaw = 0
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

	-- Keep to the shoulder the camera is already over unless the fight turned it well across
	-- (not while the arm is swung along a rope: that swing moves the eye across on purpose).
	if eye and math.abs(edgeYaw) < 0.1 then
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

	-- Fighters are always ignored by the probes; what they see through is added as they meet it
	-- (one filter for every probe, set once a frame).
	probeParams.FilterDescendantsInstances = Tagged.list(Types.Tag)
	local headPart = character and character:FindFirstChild("Head")
	local head = if headPart and headPart:IsA("BasePart")
		then headPart.Position
		else mine.Position + Vector3.yAxis * 1.5
	-- On a fenced terrace the arm stops short of the rope and cranes up over you instead. This
	-- shapes where the arm wants to be (before the lag), so backing toward the rope eases the
	-- lens in and up rather than popping it.
	local fullArm = Vector2.new(desiredEye.X - pivot.X, desiredEye.Z - pivot.Z).Magnitude
	local arena = arenaAround(mine.Position)
	local wantYaw = 0
	if arena then
		local arm = desiredEye - pivot
		if insideFraction(arena, pivot, arm, -EDGE_IN) < 1 then
			-- First swing the arm round you along the rope (the smallest turn that keeps most of its
			-- length inside, staying on the side it already swung to unless the other is much
			-- nearer), then shorten and crane what's still past the edge.
			local best, bestFraction = 0, insideFraction(arena, pivot, arm, -EDGE_IN)
			local preferred = if edgeYaw ~= 0 then math.sign(edgeYaw) else sideBlend >= 0 and 1 or -1
			local found: { [number]: number } = {}
			for step = 1, EDGE_SWING_STEPS do
				for _, sign in { preferred, -preferred } do
					if not found[sign] then
						local yaw = sign * step * EDGE_SWING / EDGE_SWING_STEPS
						local fraction =
							insideFraction(arena, pivot, CFrame.Angles(0, yaw, 0):VectorToWorldSpace(arm), -EDGE_IN)
						if fraction >= EDGE_ENOUGH then
							found[sign] = yaw
						elseif fraction > bestFraction + 0.02 then
							best, bestFraction = yaw, fraction
						end
					end
				end
			end
			local mineYaw, otherYaw = found[preferred], found[-preferred]
			if mineYaw and (not otherYaw or math.abs(mineYaw) <= math.abs(otherYaw) + math.rad(20)) then
				wantYaw = mineYaw
			elseif otherYaw then
				wantYaw = otherYaw
			else
				wantYaw = best
			end
		end
	end
	edgeYaw += (wantYaw - edgeYaw) * (1 - math.exp(-dt * EDGE_YAW_RATE))
	if math.abs(edgeYaw) < 1e-3 and wantYaw == 0 then
		edgeYaw = 0
	end
	if edgeYaw ~= 0 then
		desiredEye = pivot + CFrame.Angles(0, edgeYaw, 0):VectorToWorldSpace(desiredEye - pivot)
	end
	if arena then
		desiredEye = fitArena(arena, pivot, desiredEye, head)
	end

	-- Kannagi's lag: the eye trails its arm at speed 7 (never more than MaxLag behind), and
	-- the view turns toward the target at speed 5.
	local current = eye or desiredEye
	current = current:Lerp(desiredEye, 1 - math.exp(-dt * settings.PositionLag))
	local lag = current - desiredEye
	if lag.Magnitude > settings.MaxLag then
		current = desiredEye + lag.Unit * settings.MaxLag
	end
	eye = current -- (the spring arm's end; the probe below only shortens what's shown)
	-- Kannagi's arm probes the world (ProbeChannel): a wall, rock or post between you and the
	-- eye pulls the camera in front of it at once (fighters never do), and it eases back out.
	local reach = current - pivot
	local allowed = reach.Magnitude
	if reach.Magnitude > 0.5 then
		for _ = 1, 8 do
			local hit = workspace:Spherecast(pivot, PROBE_RADIUS, reach, probeParams)
			if not hit then
				break
			end
			local part = hit.Instance
			-- Invisible fence walls keep players in, not the camera; a post or rail is seen
			-- through (Occlusion fades it) instead of pulling the lens in.
			if part:IsA("BasePart") and (part.Transparency >= 0.9 or isThin(part)) then
				probeParams:AddToFilter(part)
			else
				allowed = math.max(hit.Distance - 0.1, 1.5)
				break
			end
		end
	end
	local length = armLength
	if not length or allowed < length then
		length = allowed
	else
		length += (allowed - length) * (1 - math.exp(-dt * ARM_OUT_RATE))
	end
	armLength = length
	if reach.Magnitude > 0.5 and length < reach.Magnitude - 0.01 then
		-- Pulled in by a wall or rock: crane up over your head rather than into it.
		current = crane(pivot, reach.Unit, reach.Magnitude, length, head)
	end
	-- The lagged lens trails a moving arm: keep it inside the ring and off your head too.
	if arena then
		current = fitArena(arena, pivot, current, head)
	end
	if (current - head).Magnitude < MIN_HEAD and (current - pivot).Magnitude > 0.5 then
		local arm = current - pivot
		current = crane(pivot, arm.Unit, arm.Magnitude, arm.Magnitude, head)
	end
	-- A shortened arm looks a little down toward you, so you stay in the shot.
	local shown = Vector2.new(current.X - pivot.X, current.Z - pivot.Z).Magnitude
	local short = math.clamp(1 - shown / math.max(fullArm, 1e-3), 0, 1)
	if short > 0 then
		focus = focus:Lerp(head, FOCUS_SELF * short)
	end
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

-- The free follow camera keeps its world angle through a teleport or a respawn, so a royale could
-- start with you facing sideways and no one in view, and a body respawned at the boss shrine
-- (BossService's BossReturn) started with the camera still at the lock-on angle from the side.
-- When your character spawns, and when it is put in a match, the camera swings behind it
-- (keeping its pitch; Roblox's camera keeps its own zoom) as soon as the body has arrived.
local function snapBehind(root: BasePart)
	local camera = workspace.CurrentCamera
	if target or not camera or camera.CameraType ~= Enum.CameraType.Custom then
		return
	end
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		return
	end
	flat = flat.Unit
	local offset = camera.CFrame.Position - camera.Focus.Position
	local distance = math.clamp(offset.Magnitude, 8, 24)
	local pitch = if offset.Magnitude > 1e-3
		then math.clamp(math.asin(math.clamp(offset.Unit.Y, -1, 1)), math.rad(8), math.rad(35))
		else math.rad(18)
	local focus = root.Position + Vector3.new(0, 1.5, 0)
	local at = focus - flat * distance * math.cos(pitch) + Vector3.yAxis * distance * math.sin(pitch)
	camera.CFrame = CFrame.lookAt(at, focus)
end

-- Snaps behind `character` once it has arrived: when its root jumps more than 6 studs from
-- `from` (a teleport replicating), or at `deadline` (it was already there).
local function snapWhenArrived(character: Model, from: Vector3?, timeout: number)
	local deadline = os.clock() + timeout
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		local root = rootOf(character)
		local now = root and root.Position
		if root and now and (not from or (now - from).Magnitude > 6 or os.clock() > deadline) then
			connection:Disconnect()
			snapBehind(root)
		elseif not character.Parent then
			connection:Disconnect()
		end
	end)
end

local function watchCharacter(character: Model, spawned: boolean)
	local before: Vector3? = nil
	local seen = RunService.Heartbeat:Connect(function()
		local root = rootOf(character)
		before = root and root.Position
	end)
	if spawned then
		-- (A frame on, after Roblox's camera has taken the new body as its subject.)
		task.defer(snapWhenArrived, character, nil, 0)
	end
	character:GetAttributeChangedSignal("InMatch"):Connect(function()
		if character:GetAttribute("InMatch") == true then
			snapWhenArrived(character, before, 0.6)
		end
	end)
	character.AncestryChanged:Connect(function()
		if not character.Parent then
			seen:Disconnect()
		end
	end)
	character.Destroying:Once(function()
		seen:Disconnect()
	end)
end

function LockOn.start()
	RunService:BindToRenderStep("SekiroLockOn", Enum.RenderPriority.Camera.Value + 1, updateCamera)
	player.CharacterAdded:Connect(function(character)
		LockOn.set(nil)
		watchCharacter(character, true)
	end)
	if player.Character then
		watchCharacter(player.Character, false)
	end
end

return LockOn
