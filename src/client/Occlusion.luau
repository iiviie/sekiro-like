--!strict
-- Fighters pass through each other, so an opponent often ends up between the camera and
-- your own character and blots out the screen. Anyone standing in that line, or right on
-- top of the camera, fades out on your screen only (LocalTransparencyModifier) until they
-- step clear. Their blade stays visible enough to read a swing.
-- Locked on at contact range the camera swings round the pair (LockOn) so your own body rarely
-- hides the target; as a last resort, when it hides both their head and their chest, your body
-- (not your blade) fades to SELF_FADE until one of them is in clear view. And when a wall or rock
-- pulls the locked-on camera in close behind you, your body fades out as the lens nears your
-- head (as Roblox's own camera does), so the screen never fills with your hair.
-- Set dressing the camera can't collide with (tree canopies and trunks, ropes and streamers) or
-- looks through on purpose (posts, rails, CameraIgnore props) fades on your screen while the lens
-- is inside or right beside it, or while it stands between the lens and you or your lock-on
-- target. That covers both cameras: Roblox's follow camera only pulls in for solid parts, and the
-- lock-on probe passes through these.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Tagged = require(ReplicatedStorage.Shared.Tagged)
local Types = require(ReplicatedStorage.Shared.Types)
local LockOn = require(script.Parent.LockOn)

local player = Players.LocalPlayer

local FADE = 0.72 -- how see-through an occluding fighter becomes
local NEAR_FADE_FIGHTER = 0.85 -- ...and one right on the lens (a kasa filling the frame)
local NEAR_CAMERA = 6 -- studs: anyone whose body or head is this close to the lens fades
local LINE_RADIUS = 2.4 -- studs from the camera-to-you line that counts as "in the way"
local RATE = 14 -- fade speed
local SELF_FADE = 0.55 -- how see-through your own body gets while it hides your lock-on target
-- Locked on, your body fades from NEAR_FAR studs between the lens and your head to NEAR_FADE at
-- NEAR_CLOSE (at once: the camera is pulled in at once too).
local NEAR_FAR = 3.2
local NEAR_CLOSE = 1.6
local NEAR_FADE = 0.92

-- Props (see the header): where to find them, how near the lens they're checked, how far
-- around one the lens counts as inside it, and how see-through they get.
local PROP_ROOTS = { "Lobby", "Props", "Castle" }
local PROP_RESCAN = 0.25 -- seconds between refreshes of the props near the lens
local PROP_NEAR = 40 -- studs from the lens (to the prop's bounding sphere)
local PROP_MARGIN = 1.2 -- studs: the lens this close to a prop is in it (the near plane clips it)
local THIN_MARGIN = 4 -- ...and this close to a post, rope or cap (it fills the foreground)
local PROP_IN = 0.9 -- the lens is in it (a canopy filling the frame)
local PROP_LINE = 0.7 -- it stands between the lens and a fighter you're watching
local PROP_RATE = 12
-- A bulky prop (a canopy) is tested as the ellipsoid inside its box, its core (PROP_CORE of it)
-- for the line of sight, so a camera passing beside a tree's box doesn't fade the tree.
local PROP_CORE = 0.8

local Occlusion = {}

local faded: { [Model]: number } = {}
local parts: { [Model]: { BasePart | Decal } } = {}
local bodies: { [Model]: { Instance } } = {} -- partsOf minus the blade (hidesTarget's filter)

local function partsOf(model: Model): { BasePart | Decal }
	local list = parts[model]
	if list then
		return list
	end
	local found: { BasePart | Decal } = {}
	for _, d in model:GetDescendants() do
		if (d:IsA("BasePart") and d.Name ~= "HumanoidRootPart") or d:IsA("Decal") then
			table.insert(found, d :: any)
		end
	end
	parts[model] = found
	-- Only a new part or decal invalidates the list (not every hit sound or kanji billboard).
	local connection: RBXScriptConnection
	connection = model.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") or d:IsA("Decal") then
			parts[model] = nil
			bodies[model] = nil
			connection:Disconnect()
		end
	end)
	return found
end

local function apply(model: Model, amount: number)
	for _, part in partsOf(model) do
		if part.Parent then
			(part :: any).LocalTransparencyModifier = amount
		end
	end
end

-- How much `model` should fade: on the lens, in the line from the lens to you, or not at all.
local function blocking(model: Model, from: Vector3, to: Vector3): number
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return 0
	end
	local p = root.Position
	local head = model:FindFirstChild("Head")
	local top = if head and head:IsA("BasePart") then head.Position else p + Vector3.yAxis * 1.5
	if (p - from).Magnitude < NEAR_CAMERA or (top - from).Magnitude < NEAR_CAMERA then
		return NEAR_FADE_FIGHTER
	end
	local line = to - from
	local length = line.Magnitude
	if length < 0.1 then
		return 0
	end
	local along = (p - from):Dot(line.Unit)
	if along <= 0 or along >= length - 1.5 then
		return 0 -- behind the camera, or level with / past you
	end
	local closest = from + line.Unit * along
	return if (p - closest).Magnitude < LINE_RADIUS then FADE else 0
end

local selfFade = 0

-- The sword and everything welded to it (tsuba, pommel, edge line) stay solid.
local function isBlade(part: Instance): boolean
	return part.Name == "Sword"
		or part.Name == "Sword2"
		or part:FindFirstAncestor("Sword") ~= nil
		or part:FindFirstAncestor("Sword2") ~= nil
end
local selfParams = RaycastParams.new()
selfParams.FilterType = Enum.RaycastFilterType.Include
local selfBody: { Instance }? = nil -- the list selfParams filters on

-- Whether our own body stands between the camera and both the target's head and chest.
local function hidesTarget(character: Model, target: Model, from: Vector3): boolean
	local list = partsOf(character)
	local body = bodies[character]
	if not body then
		local built: { Instance } = {}
		for _, part in list do
			if part:IsA("BasePart") and not isBlade(part) then
				table.insert(built, part)
			end
		end
		bodies[character] = built
		body = built
	end
	if body ~= selfBody then
		selfParams.FilterDescendantsInstances = body :: { Instance }
		selfBody = body
	end
	local hidden = 0
	for _, name in { "UpperTorso", "Head" } do
		local part = target:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			if not workspace:Raycast(from, part.Position - from, selfParams) then
				return false
			end
			hidden += 1
		end
	end
	return hidden > 0
end

local function fadeSelf(character: Model, from: Vector3, head: Vector3, dt: number)
	local target = LockOn.target()
	local locked = target ~= nil and target.Parent ~= nil
	local goal = if locked and hidesTarget(character, target :: Model, from) then SELF_FADE else 0
	local near = 0
	if locked then
		near = math.clamp((NEAR_FAR - (from - head).Magnitude) / (NEAR_FAR - NEAR_CLOSE), 0, 1) * NEAR_FADE
		goal = math.max(goal, near)
	end
	if goal == 0 and selfFade == 0 then
		return -- nothing to undo: leave the parts to Roblox's own camera
	end
	if near > selfFade then
		selfFade = near -- the lens is in your hair now: fade now
	end
	selfFade += (goal - selfFade) * math.min(1, dt * RATE)
	if math.abs(selfFade - goal) < 0.02 then
		selfFade = goal
	end
	for _, part in partsOf(character) do
		if part.Parent and not isBlade(part) then
			(part :: any).LocalTransparencyModifier = selfFade
		end
	end
end

-- Props ------------------------------------------------------------------------------------

type Prop = { part: BasePart, round: boolean, margin: number, reach: number }
local props: { [BasePart]: Prop } = {}
local nearby: { Prop } = {}
local propFade: { [BasePart]: number } = {}
local scannedAt = -math.huge

-- Whether `part` is set dressing the lens may end up in or look through, and how to test it.
local function asProp(part: BasePart): Prop?
	if part:IsA("Terrain") or part.Transparency >= 0.9 then
		return nil
	end
	local model = part:FindFirstAncestorWhichIsA("Model")
	if model and model:FindFirstChildOfClass("Humanoid") then
		return nil -- fighters and dummies fade by the rules above
	end
	local size = part.Size
	-- Posts, rails and ropes, and small trim on them (a post's cap).
	local thin = LockOn.isThin(part) or math.max(size.X, size.Y, size.Z) < 2
	if part.CanCollide and not thin then
		return nil -- solid: the cameras pull in front of it instead
	end
	if math.max(size.X, size.Y, size.Z) > 120 then
		return nil
	end
	-- Flat ground dressing (pad rims, painted marks, petal piles) lies under the shot.
	local cf = part.CFrame
	local up = math.abs(cf.RightVector.Y) * size.X
		+ math.abs(cf.UpVector.Y) * size.Y
		+ math.abs(cf.LookVector.Y) * size.Z
	local middle = size.X + size.Y + size.Z - math.max(size.X, size.Y, size.Z) - math.min(size.X, size.Y, size.Z)
	if up < 0.6 and middle > 2 then -- (a rope lies level too, but it's thin both ways)
		return nil
	end
	local margin = if thin then THIN_MARGIN else PROP_MARGIN
	return {
		part = part,
		round = not thin and math.min(size.X, size.Y, size.Z) > 4,
		margin = margin,
		reach = size.Magnitude / 2 + margin,
	}
end

local function addProp(d: Instance)
	if d:IsA("BasePart") and not props[d] then
		local prop = asProp(d)
		if prop then
			props[d] = prop
		end
	end
end

local function watchRoot(root: Instance)
	for _, d in root:GetDescendants() do
		addProp(d)
	end
	root.DescendantAdded:Connect(addProp)
	root.DescendantRemoving:Connect(function(d)
		if d:IsA("BasePart") then
			props[d] = nil
		end
	end)
end

-- Whether the segment from `a` along `d` (0..1) crosses the box of half-size `half` centred at
-- the origin (both in the box's space).
local function segmentHitsBox(a: Vector3, d: Vector3, half: Vector3): boolean
	local t0, t1 = 0, 1
	for _, axis in { "X", "Y", "Z" } do
		local origin, delta, extent = (a :: any)[axis], (d :: any)[axis], (half :: any)[axis]
		if math.abs(delta) < 1e-6 then
			if math.abs(origin) > extent then
				return false
			end
		else
			local near, far = (-extent - origin) / delta, (extent - origin) / delta
			if near > far then
				near, far = far, near
			end
			t0, t1 = math.max(t0, near), math.min(t1, far)
			if t0 > t1 then
				return false
			end
		end
	end
	return true
end

-- Whether the segment from `a` along `d` (0..1) crosses the unit sphere at the origin.
local function segmentHitsSphere(a: Vector3, d: Vector3): boolean
	local dd = d:Dot(d)
	if dd < 1e-9 then
		return a.Magnitude < 1
	end
	local t = math.clamp(-a:Dot(d) / dd, 0, 1)
	return (a + d * t).Magnitude < 1
end

-- Distance from `p` to the segment `a`-`b`.
local function toSegment(p: Vector3, a: Vector3, b: Vector3): number
	local d = b - a
	local dd = d:Dot(d)
	local t = if dd > 1e-9 then math.clamp((p - a):Dot(d) / dd, 0, 1) else 0
	return (a + d * t - p).Magnitude
end

-- How much `prop` should fade with the lens at `lens` watching the points in `sights`.
local function propGoal(prop: Prop, lens: Vector3, sights: { Vector3 }): number
	local part = prop.part
	local centre = part.Position
	local cf = part.CFrame
	local half = part.Size * 0.5
	local l = cf:PointToObjectSpace(lens)
	if (centre - lens).Magnitude < prop.reach then
		local e = half + Vector3.one * prop.margin
		local inside = if prop.round
			then (l / e).Magnitude < 1
			else math.abs(l.X) < e.X and math.abs(l.Y) < e.Y and math.abs(l.Z) < e.Z
		if inside then
			return PROP_IN
		end
	end
	for _, sight in sights do
		if toSegment(centre, lens, sight) < prop.reach then
			local s = cf:PointToObjectSpace(sight)
			local hit = if prop.round
				then segmentHitsSphere(l / (half * PROP_CORE), (s - l) / (half * PROP_CORE))
				else segmentHitsBox(l, s - l, half + Vector3.one * 0.15)
			if hit then
				return PROP_LINE
			end
		end
	end
	return 0
end

local sights: { Vector3 } = {}
local goals: { [BasePart]: number } = {}
local function fadeProps(lens: Vector3, head: Vector3, dt: number)
	local now = os.clock()
	if now - scannedAt > PROP_RESCAN then
		scannedAt = now
		table.clear(nearby)
		for part, prop in props do
			if (part.Position - lens).Magnitude - prop.reach < PROP_NEAR then
				table.insert(nearby, prop)
			end
		end
	end
	table.clear(sights)
	table.insert(sights, head)
	local root = head - Vector3.yAxis * 1.5 -- (your chest, roughly)
	table.insert(sights, root)
	local target = LockOn.target()
	if target and target.Parent then
		for _, name in { "Head", "UpperTorso" } do
			local part = target:FindFirstChild(name)
			if part and part:IsA("BasePart") then
				table.insert(sights, part.Position)
			end
		end
	end
	table.clear(goals)
	for _, prop in nearby do
		local goal = propGoal(prop, lens, sights)
		if goal > 0 then
			goals[prop.part] = goal
			if not propFade[prop.part] then
				propFade[prop.part] = 0
			end
		end
	end
	local alpha = math.min(1, dt * PROP_RATE)
	for part, amount in propFade do
		local goal = goals[part] or 0
		if goal >= PROP_IN and amount < goal then
			amount = goal -- the lens is in it: it would fill this very frame, so at once
		else
			amount += (goal - amount) * alpha
		end
		if not part.Parent or (goal == 0 and amount < 0.02) then
			part.LocalTransparencyModifier = 0
			propFade[part] = nil
		else
			part.LocalTransparencyModifier = amount
			propFade[part] = amount
		end
	end
end

function Occlusion.start()
	-- (After the lock-on camera has moved this frame, so the fade matches the frame drawn.)
	RunService:BindToRenderStep("Occlusion", Enum.RenderPriority.Camera.Value + 2, function(dt)
		local camera = workspace.CurrentCamera
		local character = player.Character
		local head = character and character:FindFirstChild("Head")
		if not camera or not head or not head:IsA("BasePart") then
			return
		end
		local from, to = camera.CFrame.Position, head.Position
		fadeSelf(character :: Model, from, to, dt)
		fadeProps(from, to, dt)
		local alpha = math.min(1, dt * RATE)
		for _, instance in Tagged.list(Types.Tag) do
			if instance:IsA("Model") and instance ~= character then
				local goal = blocking(instance, from, to)
				local current = faded[instance] or 0
				if current ~= goal then
					local nextValue = current + (goal - current) * alpha
					if math.abs(nextValue - goal) < 0.02 then
						nextValue = goal
					end
					faded[instance] = nextValue
					apply(instance, nextValue)
				end
			end
		end
	end)
	-- The lobby and map are built on the server after the client starts: watch each as it arrives.
	for _, name in PROP_ROOTS do
		local root = workspace:FindFirstChild(name)
		if root then
			watchRoot(root)
		end
	end
	workspace.ChildAdded:Connect(function(child)
		if table.find(PROP_ROOTS, child.Name) then
			watchRoot(child)
		end
	end)
	CollectionService:GetInstanceRemovedSignal(Types.Tag):Connect(function(instance)
		if instance:IsA("Model") then
			faded[instance] = nil
			parts[instance] = nil
			bodies[instance] = nil
		end
	end)
end

return Occlusion
