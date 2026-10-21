--!strict
-- Builds the free-roam lobby: a sculpted floating island high above the castle, laid out
-- in tiers so it reads with depth from the moment you spawn.
--
--   Spawn plaza (lower tier)  ->  grand stair  ->  Torii terrace (upper tier, overlooking
--   the castle): the glowing Royale pad, a great torii and two towering stone lanterns.
--   Left wing: the dojo, with the deflect trainer under a pavilion.
--   Right wing: the hall of champions, with the leaderboards and a pedestal showing the
--   season's capstone blade (earned at the last tier of the pass, never sold).
--   Spawn plaza: the Store and Season boards (painted, Assets.Boards); walking up shows a
--   prompt and a click opens the panel (client/LobbyHUD reads their OpensPanel attribute).
--   Duel grounds: two pairs of gold duel pads on the lower tier, each sending its pair to a
--   fenced terrace floating just off the rim (east and west).
--   Two ponds spill off the rim as waterfalls; rope bridges lead to two small islets; more
--   islets drift at a distance over a sea of cloud.
--
-- The island is smooth terrain (organic cliffs for little memory); plazas and paths are
-- painted onto it. Architecture is parts, and props are cloned from Workspace.Props. The
-- layout's key points (spawn, pad, trainer) are published as attributes on Workspace.Lobby
-- for LobbyService.
--
-- Terrain note: a fill whose top is at height Y gives a walkable surface at Y + 2, and a
-- thin fill can't repaint existing voxels, so materials are painted with ReplaceMaterial.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(ReplicatedStorage.Shared.Assets)
local Catalog = require(ReplicatedStorage.Shared.Catalog)
local Config = require(ReplicatedStorage.Shared.Config)
local SwordRig = require(script.Parent.SwordRig)
local EnvironmentProfile = require(script.Parent.EnvironmentProfile)
local Palette = require(ReplicatedStorage.Shared.Palette)
local Torii = require(script.Parent.Torii)

local LOBBY = Config.Lobby
local O = LOBBY.Origin -- fill top of the lower tier
local MAIN_RADIUS = LOBBY.Radius
local LOWER = O.Y + 2 -- walk heights of the three tiers
local WING = O.Y + 6
local UPPER = O.Y + 10

-- Terrain materials for the walkable floors. The fighting floors (duel and boss terraces,
-- the plazas where lobby PvP happens) are fine raked sand in a quiet mid value so the
-- fighters separate from the ground (colours in EnvironmentProfile); busier cobble is kept
-- for the side paths between them. (Smooth stone floors pick up a strong sky sheen at midday
-- and read pale lilac, whatever their colour.)
local FLOOR = Enum.Material.Sand
local PATH = Enum.Material.Cobblestone

local LobbyBuilder = {}

local terrain = workspace.Terrain

---------------------------------------------------------------------------------------
-- Helpers

local function flatUnit(v: Vector3): Vector3
	local flat = Vector3.new(v.X, 0, v.Z)
	return if flat.Magnitude > 1e-3 then flat.Unit else Vector3.zAxis
end

local function at(x: number, y: number, z: number): Vector3
	return Vector3.new(O.X + x, y, O.Z + z)
end

local function part(props: { [string]: any }, parent: Instance): BasePart
	local className = props.ClassName or "Part"
	props.ClassName = nil
	local p = Instance.new(className) :: BasePart
	p.Anchored = true
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		(p :: any)[k] = v
	end
	p.Parent = parent
	return p
end

local function decor(props: { [string]: any }): { [string]: any }
	props.CanCollide = false
	props.CanQuery = false
	if props.CastShadow == nil then
		props.CastShadow = false
	end
	return props
end

-- Decorative parts the cameras look through (EnvironmentProfile.CAMERA_IGNORE): `instance`
-- itself if it's a part, and every part inside it.
local function ignoreCamera(instance: Instance?)
	if not instance then
		return
	end
	if instance:IsA("BasePart") then
		CollectionService:AddTag(instance, EnvironmentProfile.CAMERA_IGNORE)
	end
	for _, d in instance:GetDescendants() do
		if d:IsA("BasePart") then
			CollectionService:AddTag(d, EnvironmentProfile.CAMERA_IGNORE)
		end
	end
end

local function disc(
	radius: number,
	height: number,
	center: Vector3,
	props: { [string]: any },
	parent: Instance
): BasePart
	props.Shape = Enum.PartType.Cylinder
	props.Size = Vector3.new(height, radius * 2, radius * 2)
	props.CFrame = CFrame.new(center) * CFrame.Angles(0, 0, math.rad(90))
	return part(props, parent)
end

-- A flat-topped landmass: a grass cap over rock, top at `top` (walkable at top + 2).
local function plateau(center: Vector3, radius: number, top: number, depth: number)
	terrain:FillCylinder(CFrame.new(center.X, top - depth / 2, center.Z), depth, radius, Enum.Material.Rock)
	terrain:FillCylinder(CFrame.new(center.X, top - 3, center.Z), 6, radius, Enum.Material.Grass)
end

-- Repaint the top voxel layers inside a circle, row by row on the 4-stud voxel grid.
local function paint(center: Vector3, radius: number, top: number, material: Enum.Material, layers: number?)
	local bottom = top - 4 * (layers or 1)
	for z = -radius, radius, 4 do
		local half = math.sqrt(math.max(radius * radius - z * z, 0))
		if half >= 2 then
			local from = Vector3.new(center.X - half, bottom, center.Z + z - 2)
			local to = Vector3.new(center.X + half, top, center.Z + z + 2)
			local region = Region3.new(from, to):ExpandToGrid(4)
			for _, source in { Enum.Material.Grass, Enum.Material.Rock, Enum.Material.LeafyGrass, Enum.Material.Ground } do
				if source ~= material then
					terrain:ReplaceMaterial(region, 4, source, material)
				end
			end
		end
	end
end

-- A straight painted path between two points on one tier.
local function path(from: Vector3, to: Vector3, width: number, top: number, material: Enum.Material)
	local steps = math.ceil((to - from).Magnitude / 3)
	for i = 0, steps do
		paint(from:Lerp(to, i / steps), width / 2, top, material)
	end
end

-- Flatten a rectangular landing so a stair or bridge meets flush ground at walk height
-- `walk`: clear everything above it and fill solid ground below, topped with `material`.
-- Smooth terrain rounds a plateau's rim down and rim boulders spill over it, so without
-- this a stair can end in a rock and a bridge in a dip. `frame` is a yaw-only CFrame;
-- `size` is its width (local X) by length (local Z).
local function landing(frame: CFrame, size: Vector2, walk: number, material: Enum.Material)
	local flat = CFrame.new(frame.Position.X, walk - 2, frame.Position.Z) * frame.Rotation
	terrain:FillBlock(flat * CFrame.new(0, 12, 0), Vector3.new(size.X, 24, size.Y), Enum.Material.Air)
	terrain:FillBlock(flat * CFrame.new(0, -5, 0), Vector3.new(size.X, 10, size.Y), Enum.Material.Rock)
	terrain:FillBlock(flat * CFrame.new(0, -2, 0), Vector3.new(size.X, 4, size.Y), material)
end

-- Ground height under (x, z): the first collidable surface (terrain or part) a ray finds
-- going down from `from`, ignoring `ignore`, or nil over a void.
local groundParams = RaycastParams.new()
groundParams.RespectCanCollide = true
groundParams.FilterType = Enum.RaycastFilterType.Exclude
local function groundAt(x: number, z: number, from: number, ignore: Instance): number?
	groundParams.FilterDescendantsInstances = { ignore }
	local hit = workspace:Raycast(Vector3.new(x, from, z), Vector3.new(0, -30, 0), groundParams)
	return if hit then hit.Position.Y else nil
end

-- Terrain filled this frame isn't hit by raycasts until the next one, so props are placed
-- at their nominal height first and seated on the ground once the build has yielded a
-- frame (see LobbyBuilder.build).
local pendingSeats: { () -> () } = {}

-- A lumpy rock rim, open at each gap: a direction (radians) and the half-width in studs
-- that must stay clear there (a path, stair or bridge landing). A boulder is skipped when
-- any part of it would reach into that clearance, not just when its centre is in the gap.
type Gap = { angle: number, clear: number }
-- A stretch of rim kept low (a row of knee-high stones rather than boulders): any boulder whose
-- centre falls within `reach` studs of `at` (horizontally). The duel pads stand near the rim,
-- and a full-size boulder there overlapped a pad and filled the camera behind it.
type Low = { at: Vector3, reach: number }
local LOW_ROCK = 5 -- radius of a low rim stone; it sits 3 below the rim's top (its top ~2 above)

local function rimRocks(
	center: Vector3,
	radius: number,
	top: number,
	count: number,
	gaps: { Gap },
	seed: number,
	low: { Low }?
)
	local random = Random.new(seed)
	for i = 1, count do
		local angle = (i / count) * math.pi * 2 + random:NextNumber(-0.08, 0.08)
		local open = false
		for _, gap in gaps do
			local diff = math.abs((angle - gap.angle + math.pi) % (math.pi * 2) - math.pi)
			if diff < 0.28 then
				open = true
			end
		end
		if not open then
			local r = radius - random:NextNumber(1, 4)
			local size = random:NextNumber(5, 9)
			local y = top - random:NextNumber(1, 4)
			-- (The draws above are made either way, so the rest of the rim keeps its layout.)
			for _, zone in low or {} do
				local spot = Vector3.new(center.X + math.cos(angle) * r, zone.at.Y, center.Z + math.sin(angle) * r)
				if (spot - zone.at).Magnitude < zone.reach then
					r = radius - 1
					size = math.min(size, LOW_ROCK)
					y = top - 3
				end
			end
			for _, gap in gaps do
				local diff = math.abs((angle - gap.angle + math.pi) % (math.pi * 2) - math.pi)
				-- Distance from the boulder's centre to the line the gap's path runs in on.
				if math.sin(math.min(diff, math.pi / 2)) * r - size < gap.clear then
					open = true
				end
			end
			if not open then
				terrain:FillBall(
					Vector3.new(center.X + math.cos(angle) * r, y, center.Z + math.sin(angle) * r),
					size,
					Enum.Material.Rock
				)
			end
		end
	end
end

-- An invisible wall along a stretch of rim (angles `from` to `to`, radians, at `radius` from
-- `center`), standing from `bottom` to `top`: like the duel terraces' FenceWall, it keeps
-- players on the island (a lock-on backpedal walked off the dojo wing) and never the camera
-- (no queries). Left open across `gaps` (a bridge).
local function rimWall(
	parent: Instance,
	center: Vector3,
	radius: number,
	from: number,
	to: number,
	bottom: number,
	top: number,
	gaps: { Gap }
)
	local segments = math.max(1, math.ceil((to - from) * radius / 4))
	local step = (to - from) / segments
	for i = 0, segments - 1 do
		local a0, a1 = from + step * i, from + step * (i + 1)
		local mid = (a0 + a1) / 2
		local open = false
		for _, gap in gaps do
			local diff = math.abs((mid - gap.angle + math.pi) % (math.pi * 2) - math.pi)
			if math.sin(math.min(diff, math.pi / 2)) * radius < gap.clear + 3 then
				open = true
			end
		end
		if not open then
			local p0 =
				Vector3.new(center.X + math.cos(a0) * radius, (bottom + top) / 2, center.Z + math.sin(a0) * radius)
			local p1 =
				Vector3.new(center.X + math.cos(a1) * radius, (bottom + top) / 2, center.Z + math.sin(a1) * radius)
			part({
				Name = "RimWall",
				Size = Vector3.new(0.5, top - bottom, (p1 - p0).Magnitude + 0.5),
				CFrame = CFrame.lookAt((p0 + p1) / 2, p1),
				Transparency = 1,
				CanQuery = false,
				CastShadow = false,
			}, parent)
		end
	end
end

-- The rough, tapering rock underside of an island: rings of boulders that shrink toward a
-- point `depth` studs below the island's `bottom`, like an inverted cone. Every boulder
-- stays inside or below the island's rock, never poking up through its walkable top.
local function underside(center: Vector3, radius: number, bottom: number, depth: number, seed: number)
	local random = Random.new(seed)
	-- No boulder may rise more than 4 studs into the island's rock, whatever its size.
	local cap = bottom + 4
	local function ball(position: Vector3, size: number, material: Enum.Material)
		local r = math.min(size, cap - position.Y)
		if r >= 2 then
			terrain:FillBall(position, r, material)
		end
	end
	local layers = math.clamp(math.floor(depth / 9), 2, 5)
	local step = depth / layers
	for k = 0, layers - 1 do
		local frac = k / layers
		local ring = radius * 0.85 * (1 - frac)
		local size = math.max(radius * 0.24 * (1 - frac * 0.55), 4)
		local y = bottom - step * (k + 0.5)
		-- A flat core disc per layer (discs, unlike balls, can't bulge up through the top).
		if ring > 3 then
			terrain:FillCylinder(CFrame.new(center.X, y, center.Z), step + 2, ring * 0.92, Enum.Material.Rock)
		end
		-- Boulders around its edge make the silhouette rough.
		local count = if ring < size then 1 else math.max(3, math.floor(2 * math.pi * ring / (size * 1.3)))
		for i = 1, count do
			local angle = (i / count) * math.pi * 2 + random:NextNumber(-0.25, 0.25)
			local r = if count == 1 then 0 else ring * random:NextNumber(0.85, 1.05)
			ball(
				Vector3.new(
					center.X + math.cos(angle) * r,
					y + random:NextNumber(-2, 2),
					center.Z + math.sin(angle) * r
				),
				size * random:NextNumber(0.85, 1.15),
				if k == layers - 1 and i % 2 == 0 then Enum.Material.Slate else Enum.Material.Rock
			)
		end
	end
	-- The tip.
	ball(Vector3.new(center.X, bottom - depth, center.Z), math.max(radius * 0.1, 3), Enum.Material.Slate)
end

-- Where a footprint should stand: the lowest ground under its centre and corners (so no
-- corner hangs far over a slope or a rounded rim), but never more than 0.75 stud below
-- the ground at its centre, nor more than a stud above the height asked for (a prop at the
-- foot of a rim boulder stays at its foot rather than climbing on top). Falls back to `y`
-- where there is no ground.
local function seat(boxCFrame: CFrame, boxSize: Vector3, y: number, ignore: Instance): number
	local from = y + 6
	local centre = groundAt(boxCFrame.Position.X, boxCFrame.Position.Z, from, ignore)
	if not centre then
		return y
	end
	local lowest = centre
	for _, sx in { -0.4, 0.4 } do
		for _, sz in { -0.4, 0.4 } do
			local corner = boxCFrame * Vector3.new(sx * boxSize.X, 0, sz * boxSize.Z)
			local g = groundAt(corner.X, corner.Z, from, ignore)
			if g then
				lowest = math.min(lowest, g)
			end
		end
	end
	return math.min(math.max(lowest, centre - 0.75), y + 1)
end

-- Clone a prop from Workspace.Props, standing on the ground found under `cframe` (a ray
-- at build time, so it stays seated whatever the terrain does there; see pendingSeats).
local function prop(name: string, cframe: CFrame, parent: Instance, scale: number?): Model?
	local props = workspace:FindFirstChild("Props")
	local source = props and props:FindFirstChild(name, true)
	if not source or not source:IsA("Model") then
		return nil
	end
	local copy = source:Clone()
	if scale then
		copy:ScaleTo(copy:GetScale() * scale)
	end
	copy:PivotTo(cframe)
	local boxCFrame, boxSize = copy:GetBoundingBox()
	local bottom = boxCFrame.Position.Y - boxSize.Y / 2
	copy:PivotTo(copy:GetPivot() + Vector3.new(0, cframe.Position.Y - bottom, 0))
	table.insert(pendingSeats, function()
		local ground = seat(boxCFrame, boxSize, cframe.Position.Y, copy)
		copy:PivotTo(copy:GetPivot() + Vector3.new(0, ground - cframe.Position.Y, 0))
	end)
	for _, d in copy:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanTouch = false
		end
	end
	copy.Parent = parent
	return copy
end

local treeIndex = 0
local function tree(position: Vector3, parent: Instance, scale: number?)
	local trees = workspace:FindFirstChild("Props") and workspace.Props:FindFirstChild("Trees")
	if not trees then
		return
	end
	local list = trees:GetChildren()
	treeIndex = treeIndex % #list + 1
	local source = list[treeIndex]
	if not source:IsA("Model") then
		return
	end
	local copy = source:Clone()
	if scale then
		copy:ScaleTo(copy:GetScale() * scale)
	end
	local boxCFrame, boxSize = copy:GetBoundingBox()
	local pivotToBottom = copy:GetPivot().Position.Y - (boxCFrame.Position.Y - boxSize.Y / 2)
	copy:PivotTo(
		CFrame.new(position + Vector3.new(0, pivotToBottom - 0.5, 0)) * CFrame.Angles(0, math.rad(treeIndex * 47), 0)
	)
	copy.Parent = parent
	-- The trunk stands on the ground under it (sunk half a stud so its foot never shows a gap).
	table.insert(pendingSeats, function()
		local ground = groundAt(position.X, position.Z, position.Y + 6, copy)
		if ground then
			copy:PivotTo(copy:GetPivot() + Vector3.new(0, ground - position.Y, 0))
		end
	end)
end

local function lantern(position: Vector3, parent: Instance): Model?
	local model = prop("Lantern", CFrame.new(position), parent)
	if model then
		local light = Instance.new("PointLight")
		light.Color = Palette.Ember
		light.Range = 14
		light.Brightness = 0.9
		light.Shadows = false
		local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
		if primary then
			light.Parent = primary
		end
	end
	return model
end

local function billboard(adornee: BasePart, title: string, height: number)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Size = UDim2.fromOffset(280, 70)
	gui.StudsOffsetWorldSpace = Vector3.new(0, height, 0)
	gui.MaxDistance = 120
	gui.LightInfluence = 0
	gui.Parent = adornee
	local heading = Instance.new("TextLabel")
	heading.BackgroundTransparency = 1
	heading.Size = UDim2.fromScale(1, 0.6)
	heading.Font = Enum.Font.Garamond
	heading.TextScaled = true
	heading.TextColor3 = Palette.Parchment
	heading.TextStrokeTransparency = 0.5
	heading.Text = title
	heading.Parent = gui
end

---------------------------------------------------------------------------------------
-- Landforms

local BRIDGE_LEFT =
	{ from = Vector2.new(-62, 31), to = Vector2.new(-86, 40), islet = Vector2.new(-102, 46), radius = 18 }
local BRIDGE_BACK = { from = Vector2.new(16, 66), to = Vector2.new(23, 93), islet = Vector2.new(27, 109), radius = 17 }

local DUEL = Config.Duel
local DUEL_GROUNDS = {
	-- Pad pair centre (lower tier) and terrace centre, as offsets from the lobby origin.
	-- The terraces sit in gaps between the far islets (see farIslets' seed).
	{ pads = Vector2.new(44, 28), arena = Vector2.new(106, -14) },
	{ pads = Vector2.new(-38, 24), arena = Vector2.new(-108, -16) },
}
local BOSS = Config.Bosses
local BOSS_ARENA = Vector2.new(-60, 135) -- offset from the lobby origin; far islets keep clear (reservedZones)
local BOSS_PAD = Vector2.new(-6, 3) -- offset from the back islet's centre
-- The boss shrine's torii stands this far behind its pad, on the side away from the arena.
local BOSS_TORII_BACK = 5
-- Where a finished trial puts you back (BossReturn): this far from the pad's centre toward the
-- arena, just past the torii, facing the pad. Behind you is the open drop toward the arena, so
-- the camera has nothing to look through; the islet's lanterns, maple and rim rocks are ahead.
local BOSS_RETURN_OUT = 8

local function bossToriiSpot(): Vector2
	local pad = BRIDGE_BACK.islet + BOSS_PAD
	local away = (pad - BOSS_ARENA).Unit
	return pad - away * BOSS_TORII_BACK
end

-- Where the main island's rim stays open: the bridges and the waterfalls.
local MAIN_GAPS: { Gap } = {
	{ angle = math.atan2(BRIDGE_LEFT.from.Y, BRIDGE_LEFT.from.X), clear = 5 },
	{ angle = math.atan2(BRIDGE_BACK.from.Y, BRIDGE_BACK.from.X), clear = 5 },
	{ angle = math.atan2(-36, 60), clear = 4 }, -- right waterfall
	{ angle = math.atan2(-42, -56), clear = 4 }, -- left waterfall
}
-- The rim stays low around each pair of duel pads (see Low).
local DUEL_RIM_REACH = 24

local function landforms()
	-- Main island (lower tier) with a lumpy rock rim, open where bridges and falls leave.
	plateau(at(0, 0, 0), MAIN_RADIUS, O.Y, 26)
	local low: { Low } = {}
	for _, ground in DUEL_GROUNDS do
		table.insert(low, { at = at(ground.pads.X, LOWER, ground.pads.Y), reach = DUEL_RIM_REACH })
	end
	rimRocks(at(0, 0, 0), MAIN_RADIUS, O.Y + 2, 44, MAIN_GAPS, 3, low)
	underside(at(0, 0, 0), MAIN_RADIUS, O.Y - 26, 44, 5)

	-- Upper tier: the torii terrace, and two wings.
	plateau(at(0, 0, -40), 34, O.Y + 8, 14)
	rimRocks(at(0, 0, -40), 34, O.Y + 10, 26, {
		{ angle = math.rad(90), clear = 11 }, -- the grand stair (18 wide, posts outside)
		{ angle = math.rad(-90), clear = 7 }, -- the path through the great torii
		{ angle = math.rad(-60), clear = 4 }, -- the towering stone lanterns
		{ angle = math.rad(-120), clear = 4 },
	}, 7)
	plateau(at(-48, 0, -2), 20, O.Y + 4, 10)
	plateau(at(48, 0, -2), 20, O.Y + 4, 10)

	-- Plazas and paths.
	paint(at(0, 0, 24), 24, O.Y, FLOOR)
	path(at(0, 0, 14), at(0, 0, 4), 12, O.Y, FLOOR)
	path(at(-16, 0, 16), at(-30, 0, 2), 6, O.Y, PATH)
	path(at(16, 0, 16), at(30, 0, 2), 6, O.Y, PATH)
	path(
		at(-14, 0, 32),
		Vector3.new(O.X + BRIDGE_LEFT.from.X, 0, O.Z + BRIDGE_LEFT.from.Y),
		5,
		O.Y,
		Enum.Material.Ground
	)
	path(at(6, 0, 44), Vector3.new(O.X + BRIDGE_BACK.from.X, 0, O.Z + BRIDGE_BACK.from.Y), 5, O.Y, Enum.Material.Ground)
	paint(at(0, 0, -44), 18, O.Y + 8, FLOOR)
	path(at(0, 0, -10), at(0, 0, -28), 10, O.Y + 8, FLOOR)
	path(at(0, 0, -58), at(0, 0, -70), 10, O.Y + 8, FLOOR)
	paint(at(-48, 0, -2), 12, O.Y + 4, Enum.Material.Sand)
	paint(at(48, 0, -2), 14, O.Y + 4, FLOOR)

	-- Ponds whose streams run to the rim, where the waterfalls take over. Water only
	-- replaces the top voxel layer and stops short of the cliff, so the rock face stays solid.
	for _, pond in { { at(44, 0, -36), Vector2.new(1, 0) }, { at(-44, 0, -42), Vector2.new(-1, 0) } } do
		local center = pond[1] :: Vector3
		paint(center, 7, O.Y, Enum.Material.Water)
		local dir = pond[2] :: Vector2
		path(center, center + Vector3.new(dir.X * 12, 0, dir.Y * 12), 4, O.Y, Enum.Material.Water)
	end

	-- The two islets the bridges reach.
	for i, bridge in { BRIDGE_LEFT, BRIDGE_BACK } do
		local center = Vector3.new(O.X + bridge.islet.X, 0, O.Z + bridge.islet.Y)
		plateau(center, bridge.radius, O.Y, 12)
		underside(center, bridge.radius, O.Y - 12, bridge.radius * 1.5, 20 + i)
		local landingGaps =
			{ { angle = math.atan2(bridge.to.Y - bridge.islet.Y, bridge.to.X - bridge.islet.X), clear = 5 } }
		if bridge == BRIDGE_BACK then
			-- Keep the boss shrine's torii and its view of the arena clear of boulders.
			local torii = bossToriiSpot() - bridge.islet
			table.insert(landingGaps, { angle = math.atan2(torii.Y, torii.X), clear = 8 })
		end
		rimRocks(center, bridge.radius, O.Y + 2, 12, landingGaps, 30 + i)
	end

	-- Flush landings where stairs and bridges meet the ground, so no rim boulder or rounded
	-- plateau edge stands in the way (see landing()).
	landing(CFrame.new(at(0, 0, -13.5)), Vector2.new(22, 13), UPPER, FLOOR)
	for _, side in { -1, 1 } do
		landing(CFrame.new(at(side * 33.5, 0, -2)), Vector2.new(10, 12), WING, Enum.Material.Grass)
	end
	for _, bridge in { BRIDGE_LEFT, BRIDGE_BACK } do
		local from = Vector3.new(O.X + bridge.from.X, 0, O.Z + bridge.from.Y)
		local to = Vector3.new(O.X + bridge.to.X, 0, O.Z + bridge.to.Y)
		local dir = flatUnit(to - from)
		landing(CFrame.lookAt(from - dir * 3.5, from), Vector2.new(8, 9), LOWER, Enum.Material.Ground)
		landing(CFrame.lookAt(to + dir * 3.5, to + dir * 5), Vector2.new(8, 9), LOWER, Enum.Material.Grass)
	end
end

-- Footprints (offset from the lobby origin, radius) the far islets must keep clear of: the
-- island, its bridged islets and the duel and boss terraces.
local function reservedZones(): { { at: Vector2, radius: number } }
	local zones = {
		{ at = Vector2.zero, radius = MAIN_RADIUS },
		{ at = BRIDGE_LEFT.islet, radius = BRIDGE_LEFT.radius },
		{ at = BRIDGE_BACK.islet, radius = BRIDGE_BACK.radius },
		{ at = BOSS_ARENA, radius = BOSS.ArenaRadius + 4 },
	}
	for _, ground in DUEL_GROUNDS do
		table.insert(zones, { at = ground.arena, radius = DUEL.ArenaRadius + 4 })
	end
	return zones
end

-- Far islets drifting around the island: depth and scale without anything to load.
local function farIslets(parent: Instance)
	local random = Random.new(41)
	local zones = reservedZones()
	local placed = 0
	local candidates = 0
	local attempts = 0
	while placed < 9 and attempts < 60 do
		attempts += 1
		local angle = random:NextNumber(0, math.pi * 2)
		-- Keep the view toward the castle (-Z from the island) clear.
		local towardCastle = math.abs((angle - math.rad(-90) + math.pi) % (math.pi * 2) - math.pi)
		if towardCastle > math.rad(40) then
			-- Every candidate draws the same numbers whether or not it's kept, so dropping
			-- one never reshuffles the others.
			candidates += 1
			local distance = random:NextNumber(130, 250)
			local radius = random:NextNumber(10, 26)
			local top = O.Y + random:NextNumber(-24, 46)
			local treeScale = if radius > 15 then random:NextNumber(0.9, 1.3) else nil
			local offset = Vector2.new(math.cos(angle), math.sin(angle)) * distance
			-- An islet over a terrace would hang its rocky underside into the fight.
			local clear = true
			for _, zone in zones do
				if (offset - zone.at).Magnitude < radius + zone.radius + 6 then
					clear = false
				end
			end
			if clear then
				placed += 1
				local center = Vector3.new(O.X + offset.X, 0, O.Z + offset.Y)
				local thickness = math.max(radius * 0.4, 8)
				plateau(center, radius, top, thickness)
				underside(center, radius, top - thickness, radius * 1.4, 100 + candidates)
				if treeScale then
					tree(Vector3.new(center.X, top + 2, center.Z), parent, treeScale)
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------
-- Architecture

local function stairs(parent: Instance, from: Vector3, to: Vector3, width: number, steps: number)
	-- `from` is the foot (lower walk height), `to` the head; steps rise evenly.
	local run = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	local stepRun = run.Magnitude / steps
	local rise = (to.Y - from.Y) / steps
	local forward = run.Unit
	local look = CFrame.lookAt(Vector3.zero, forward)
	for i = 1, steps do
		local top = from.Y + rise * i
		local height = top - (from.Y - 3)
		local center = Vector3.new(from.X, 0, from.Z) + forward * (stepRun * (i - 0.5))
		part({
			Name = "Step",
			Size = Vector3.new(width, height, stepRun + 0.05),
			CFrame = CFrame.new(center.X, top - height / 2, center.Z) * look.Rotation,
			Material = Enum.Material.Slate,
			Color = Palette.Flagstone:Lerp(Palette.Stone, (i % 3) / 6),
			CastShadow = false,
		}, parent)
	end
	-- Low stone posts down both edges, every other step. They stand just outside the steps,
	-- so each runs down to the steps' footing rather than hanging over the ground beside.
	for i = 1, steps, 2 do
		local top = from.Y + rise * i
		local height = top + 2.4 - (from.Y - 3)
		for _, side in { -1, 1 } do
			local position = Vector3.new(from.X, 0, from.Z)
				+ forward * (stepRun * (i - 0.5))
				+ look.RightVector * side * (width / 2 + 0.5)
			part({
				Name = "StairPost",
				Size = Vector3.new(1, height, 1),
				CFrame = CFrame.new(position.X, top + 2.4 - height / 2, position.Z) * look.Rotation,
				Material = Enum.Material.Slate,
				Color = Palette.Stone,
				CastShadow = false,
			}, parent)
		end
	end
end

-- Plank width: the rope rails sit just outside it, so this is the walkable width.
local BRIDGE_WIDTH = 6

local function bridge(parent: Instance, data)
	local a = Vector3.new(O.X + data.from.X, LOWER, O.Z + data.from.Y)
	local b = Vector3.new(O.X + data.to.X, LOWER, O.Z + data.to.Y)
	local length = (b - a).Magnitude
	local look = CFrame.lookAt(a, b)
	local planks = math.floor(length / 1.2)
	for i = 0, planks do
		local t = i / planks
		local sag = math.sin(t * math.pi) * 1.2
		part({
			Name = "Plank",
			Size = Vector3.new(BRIDGE_WIDTH, 0.3, 1),
			CFrame = look * CFrame.new(0, -0.15 - sag, -length * t),
			Material = Enum.Material.WoodPlanks,
			Color = Palette.Deck:Lerp(Palette.Timber, (i % 4) / 6),
		}, parent)
	end
	-- A stone footing under each end, flush with the planks: smooth terrain rounds down
	-- toward the cliff edge, so without it the bridge starts with a step up out of a dip.
	for _, span in { { -4.5, 0.5 }, { length - 0.5, length + 4.5 } } do
		local mid, run = (span[1] + span[2]) / 2, span[2] - span[1]
		part({
			Name = "BridgeFoot",
			Size = Vector3.new(BRIDGE_WIDTH + 0.8, 4, run),
			CFrame = look * CFrame.new(0, -2, -mid),
			Material = Enum.Material.Slate,
			Color = Palette.Stone,
		}, parent)
	end
	for _, side in { -1, 1 } do
		for i = 0, 4 do
			local t = i / 4
			local sag = math.sin(t * math.pi) * 1.2
			part(
				decor({
					Name = "RopePost",
					Size = Vector3.new(0.35, 3.2, 0.35),
					CFrame = look * CFrame.new(side * (BRIDGE_WIDTH / 2 + 0.1), 1.4 - sag, -length * t),
					Material = Enum.Material.Wood,
					Color = Palette.Timber,
				}),
				parent
			)
		end
		-- Rope rails: two attachments per side joined by a sagging beam.
		local holder =
			part(decor({ Name = "RopeHolder", Size = Vector3.one * 0.2, Transparency = 1, CFrame = look }), parent)
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(side * (BRIDGE_WIDTH / 2 + 0.1), 2.8, 0)
		a0.Parent = holder
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(side * (BRIDGE_WIDTH / 2 + 0.1), 2.8, -length)
		a1.Parent = holder
		local rope = Instance.new("Beam")
		rope.Attachment0 = a0
		rope.Attachment1 = a1
		rope.Width0 = 0.18
		rope.Width1 = 0.18
		rope.Color = ColorSequence.new(Color3.fromRGB(150, 122, 82))
		rope.CurveSize0 = -length * 0.25
		rope.CurveSize1 = length * 0.25
		rope.FaceCamera = true
		rope.Segments = 12
		rope.LightInfluence = 1
		rope.Parent = holder
	end
end

local function waterfall(parent: Instance, top: Vector3, outward: Vector3)
	local holder =
		part(decor({ Name = "Waterfall", Size = Vector3.one, Transparency = 1, CFrame = CFrame.new(top) }), parent)
	local a0 = Instance.new("Attachment")
	a0.Parent = holder
	local a1 = Instance.new("Attachment")
	a1.Position = outward * 6 + Vector3.new(0, -70, 0)
	a1.Parent = holder
	for i, width in { 7, 4.5 } do
		local fall = Instance.new("Beam")
		fall.Attachment0 = a0
		fall.Attachment1 = a1
		fall.Width0 = width
		fall.Width1 = width * 1.8
		fall.CurveSize0 = 8
		fall.FaceCamera = true
		fall.Segments = 16
		fall.Texture = "rbxasset://textures/particles/smoke_main.dds"
		fall.TextureMode = Enum.TextureMode.Wrap
		fall.TextureLength = 10
		fall.TextureSpeed = if i == 1 then -1.6 else -2.4
		fall.Color = ColorSequence.new(Color3.fromRGB(214, 232, 240), Color3.fromRGB(180, 200, 210))
		fall.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.25),
			NumberSequenceKeypoint.new(0.7, 0.45),
			NumberSequenceKeypoint.new(1, 1),
		})
		fall.LightEmission = 0.25
		fall.LightInfluence = 0.8
		fall.Parent = holder
	end
	-- Spray where the water leaves the rim.
	local spray = Instance.new("ParticleEmitter")
	spray.Texture = "rbxasset://textures/particles/smoke_main.dds"
	spray.Color = ColorSequence.new(Color3.fromRGB(235, 242, 246))
	spray.Size = NumberSequence.new(3, 9)
	spray.Transparency = NumberSequence.new(0.55, 1)
	spray.Lifetime = NumberRange.new(2, 3)
	spray.Rate = 6
	spray.Speed = NumberRange.new(6, 12)
	spray.EmissionDirection = Enum.NormalId.Bottom
	spray.SpreadAngle = Vector2.new(15, 15)
	spray.Acceleration = Vector3.new(0, -12, 0)
	spray.LightInfluence = 1
	spray.Parent = holder
	local sound = Instance.new("Sound")
	sound.Name = "Rush"
	sound.SoundId = "rbxassetid://9112854440"
	sound.Looped = true
	sound.Volume = 0.25
	sound.RollOffMinDistance = 10
	sound.RollOffMaxDistance = 70
	sound.Parent = holder
	sound:Play()
end

-- The glowing Royale pad: step on it (or press PLAY) to queue.
local function queuePad(parent: Instance, center: Vector3)
	local radius = LOBBY.QueuePadRadius
	disc(radius + 0.8, 0.6, center + Vector3.new(0, 0.2, 0), {
		Name = "QueuePad",
		Material = Enum.Material.Slate,
		Color = Palette.Ink,
	}, parent)
	disc(
		radius,
		0.14,
		center + Vector3.new(0, 0.52, 0),
		decor({
			Name = "PadGlow",
			Material = Enum.Material.Neon,
			Color = Palette.Crimson,
		}),
		parent
	)
	disc(
		radius - 0.8,
		0.16,
		center + Vector3.new(0, 0.54, 0),
		decor({
			Name = "PadInner",
			Material = Enum.Material.Sand,
			Color = Palette.Sand,
		}),
		parent
	)
	local beamRoot =
		part(decor({ Name = "PadBeam", Size = Vector3.one, Transparency = 1, CFrame = CFrame.new(center) }), parent)
	for i = 1, 28 do
		local angle = (i / 28) * math.pi * 2
		local base = Vector3.new(math.cos(angle) * radius, 0.6, math.sin(angle) * radius)
		local a0 = Instance.new("Attachment")
		a0.Position = base
		a0.Parent = beamRoot
		local a1 = Instance.new("Attachment")
		a1.Position = base + Vector3.new(0, 9, 0)
		a1.Parent = beamRoot
		local beam = Instance.new("Beam")
		beam.Attachment0 = a0
		beam.Attachment1 = a1
		beam.FaceCamera = true
		beam.Width0 = 2 * math.pi * radius / 28 + 0.3
		beam.Width1 = beam.Width0
		beam.Color = ColorSequence.new(Palette.Crimson)
		-- Faint enough that standing queued inside the ring doesn't flood the screen pink.
		beam.Transparency = NumberSequence.new(0.75, 1)
		beam.LightEmission = 0.3
		beam.Segments = 1
		beam.Parent = beamRoot
	end
	local light = Instance.new("PointLight")
	light.Color = Palette.Crimson
	light.Range = 20
	light.Brightness = 1.6
	light.Parent = beamRoot
	-- On the upright beam root, not the pad: the pad is a cylinder turned on its side, and a
	-- billboard's StudsOffsetWorldSpace on it came out sideways (the sign stood at floor level,
	-- 11 studs to the left, behind the stair-top lantern: "R..YALE").
	billboard(beamRoot, "ROYALE", 11)
end

-- Duel grounds: a pair of gold pads facing each other on the lower tier, and the fenced
-- terrace it sends its duellists to, floating just off the rim so the lobby can watch from
-- the edge. Each ground is a folder under Workspace.Lobby.DuelGrounds with its key points
-- as attributes (PadA, PadB, Arena: walk-surface positions) and a Sign whose Status label
-- DuelService keeps up to date.
local DUEL_PAD_GAP = 12 -- studs between the two pads of a pair
-- Terraces sit a little below the rim, in full view of it. Their fill top (walk - 2) stays
-- on the 4-stud voxel grid, or the surface comes out higher than asked.
local DUEL_WALK = LOWER - 4

local function duelPad(parent: Instance, name: string, center: Vector3)
	local radius = DUEL.PadRadius
	disc(radius + 0.6, 0.6, center + Vector3.new(0, 0.2, 0), {
		Name = name,
		Material = Enum.Material.Slate,
		Color = Palette.Ink,
	}, parent)
	disc(
		radius,
		0.14,
		center + Vector3.new(0, 0.52, 0),
		-- Bronze, a step darker since Neon brightens it: a plain Bronze or Ember ring rendered as
		-- the lobby's one "gamey" saturated yellow.
		decor({ Name = name .. "Glow", Material = Enum.Material.Neon, Color = Palette.Bronze:Lerp(Color3.new(), 0.3) }),
		parent
	)
	disc(
		radius - 0.6,
		0.16,
		center + Vector3.new(0, 0.54, 0),
		decor({ Name = name .. "Inner", Material = Enum.Material.Sand, Color = Palette.Sand }),
		parent
	)
end

local function duelTerrace(parent: Instance, center: Vector3, seed: number, size: number?, marks: number?)
	local radius = size or DUEL.ArenaRadius
	local startDistance = marks or DUEL.StartDistance
	local top = center.Y - 2
	plateau(center, radius + 4, top, 10)
	underside(center, radius + 4, top - 10, 28, seed)
	paint(center, radius + 1, top, FLOOR)

	-- A sacred-rope fence: round lacquered posts with black caps, a straw rope between them
	-- hung with paper streamers, and an invisible wall so nobody is knocked off mid-duel.
	local posts = math.max(16, math.floor(radius * 0.95))
	for i = 1, posts do
		local a0 = (i / posts) * math.pi * 2
		local a1 = ((i + 1) / posts) * math.pi * 2
		local p0 = center + Vector3.new(math.cos(a0) * radius, 0, math.sin(a0) * radius)
		local p1 = center + Vector3.new(math.cos(a1) * radius, 0, math.sin(a1) * radius)
		-- Rooted 3 studs down: the terrace's rounded rim sags under the fence line.
		-- The fence is set dressing to the cameras: they look through posts, rope and paper.
		EnvironmentProfile.post(
			"FencePost",
			CFrame.new(p0 - Vector3.new(0, 3, 0)),
			7.4,
			0.8,
			parent,
			{ cameraIgnore = true }
		)
		local mid = (p0 + p1) / 2
		local length = (p1 - p0).Magnitude
		local rope = CFrame.lookAt(mid + Vector3.new(0, 3.6, 0), p1 + Vector3.new(0, 3.6, 0))
		ignoreCamera(part(
			decor({
				Name = "FenceRope",
				Shape = Enum.PartType.Cylinder, -- a cylinder's axis is its X: turn it along the rope
				Size = Vector3.new(length, 0.4, 0.4),
				CFrame = rope * CFrame.Angles(0, math.rad(90), 0),
				Material = Enum.Material.Fabric,
				Color = Palette.Straw,
			}),
			parent
		))
		-- A zigzag paper streamer (shide) hanging from the middle of each span.
		ignoreCamera(part(
			decor({
				Name = "FenceShide",
				Size = Vector3.new(0.05, 1.1, 0.4),
				CFrame = rope * CFrame.new(0, -0.75, 0) * CFrame.Angles(0, math.rad(90), 0),
				Material = Enum.Material.SmoothPlastic,
				Color = Color3.fromRGB(244, 240, 230),
			}),
			parent
		))
		part({
			Name = "FenceWall",
			Size = Vector3.new(0.5, 16, length + 0.5),
			CFrame = CFrame.lookAt(mid + Vector3.new(0, 8, 0), p1 + Vector3.new(0, 8, 0)),
			Transparency = 1,
			CanQuery = false,
			CastShadow = false,
		}, parent)
	end
	-- Starting marks, and a lantern at each corner outside the rope.
	for _, side in { -1, 1 } do
		disc(
			1.4,
			0.1,
			center + Vector3.new(side * startDistance / 2, 0.05, 0),
			decor({ Name = "Mark", Material = Enum.Material.Slate, Color = Palette.Crimson }),
			parent
		)
	end
	for i = 0, 3 do
		local angle = math.rad(45 + i * 90)
		ignoreCamera(
			lantern(center + Vector3.new(math.cos(angle) * (radius + 2), 0, math.sin(angle) * (radius + 2)), parent)
		)
	end
end

local function duelGrounds(lobby: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "DuelGrounds"
	folder.Parent = lobby
	for i, ground in DUEL_GROUNDS do
		local holder = Instance.new("Folder")
		holder.Name = `Ground{i}`
		local mid = at(ground.pads.X, LOWER, ground.pads.Y)
		local padA = mid - Vector3.new(DUEL_PAD_GAP / 2, 0, 0)
		local padB = mid + Vector3.new(DUEL_PAD_GAP / 2, 0, 0)
		duelPad(holder, "PadA", padA)
		duelPad(holder, "PadB", padB)
		-- The sign between the pads: a title, and a status line DuelService rewrites.
		local sign =
			part(decor({ Name = "Sign", Size = Vector3.one, Transparency = 1, CFrame = CFrame.new(mid) }), holder)
		billboard(sign, "DUEL  ·  一騎討", 7)
		local gui = sign:FindFirstChild("Label") :: BillboardGui
		local status = Instance.new("TextLabel")
		status.Name = "Status"
		status.BackgroundTransparency = 1
		status.Position = UDim2.fromScale(0, 0.6)
		status.Size = UDim2.fromScale(1, 0.4)
		status.Font = Enum.Font.SourceSansSemibold
		status.TextScaled = true
		status.TextColor3 = Palette.Ember
		status.TextStrokeTransparency = 0.5
		status.Text = `Step on a pad  ·  first to {DUEL.FirstTo}`
		status.Parent = gui
		local arena = at(ground.arena.X, DUEL_WALK, ground.arena.Y)
		duelTerrace(holder, arena, 60 + i)
		holder:SetAttribute("PadA", padA)
		holder:SetAttribute("PadB", padB)
		holder:SetAttribute("Arena", arena)
		holder.Parent = folder
	end
end

-- Boss trials: a shrine pad on the back islet opens the boss picker (BossService / BossHUD),
-- and the fight is on a larger fenced terrace floating behind the island. Published on
-- Workspace.Lobby.BossShrine as attributes Pad and Arena (walk-surface positions).

local function bossGrounds(lobby: Instance, islet: Vector3)
	local holder = Instance.new("Folder")
	holder.Name = "BossShrine"
	local pad = islet + Vector3.new(BOSS_PAD.X, 0, BOSS_PAD.Y)
	local radius = DUEL.PadRadius + 0.6
	disc(radius + 0.6, 0.6, pad + Vector3.new(0, 0.2, 0), {
		Name = "Pad",
		Material = Enum.Material.Slate,
		Color = Palette.Ink,
	}, holder)
	disc(
		radius,
		0.14,
		pad + Vector3.new(0, 0.52, 0),
		decor({ Name = "PadGlow", Material = Enum.Material.Neon, Color = Color3.fromRGB(150, 90, 230) }),
		holder
	)
	disc(
		radius - 0.6,
		0.16,
		pad + Vector3.new(0, 0.54, 0),
		decor({ Name = "PadInner", Material = Enum.Material.Sand, Color = Palette.Sand }),
		holder
	)
	local arena = at(BOSS_ARENA.X, DUEL_WALK, BOSS_ARENA.Y)
	-- A torii behind the pad frames the arena terrace beyond it.
	local away = flatUnit(pad - arena)
	local torii =
		prop("Torii", CFrame.lookAt(pad - away * BOSS_TORII_BACK, pad - away * (BOSS_TORII_BACK + 1)), holder, 0.55)
	if torii then
		Torii.openGate(torii)
	end
	lantern(pad + Vector3.new(-away.Z, 0, away.X) * 6, holder)
	lantern(pad - Vector3.new(-away.Z, 0, away.X) * 6, holder)
	local sign = part(decor({ Name = "Sign", Size = Vector3.one, Transparency = 1, CFrame = CFrame.new(pad) }), holder)
	billboard(sign, "BOSS TRIALS  ·  試練", 8)
	local gui = sign:FindFirstChild("Label") :: BillboardGui
	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.BackgroundTransparency = 1
	status.Position = UDim2.fromScale(0, 0.6)
	status.Size = UDim2.fromScale(1, 0.4)
	status.Font = Enum.Font.SourceSansSemibold
	status.TextScaled = true
	status.TextColor3 = Color3.fromRGB(196, 160, 255)
	status.TextStrokeTransparency = 0.5
	status.Text = "Step on the shrine to choose a boss"
	status.Parent = gui
	duelTerrace(holder, arena, 77, BOSS.ArenaRadius, BOSS.StartDistance)
	holder:SetAttribute("Pad", pad)
	holder:SetAttribute("PadRadius", radius)
	holder:SetAttribute("Arena", arena)
	-- The return point (BossService respawns you here after every trial) and a disabled
	-- SpawnLocation on it: spawning a new body there, rather than moving it after it spawned on
	-- the plaza, sets the camera up behind you facing the pad.
	local back = pad - away * BOSS_RETURN_OUT
	local returnSpawn = Instance.new("SpawnLocation")
	returnSpawn.Name = "BossReturn"
	returnSpawn.Anchored = true
	returnSpawn.Enabled = false
	returnSpawn.Neutral = true
	returnSpawn.Duration = 0
	returnSpawn.Size = Vector3.new(4, 0.2, 4)
	returnSpawn.Transparency = 1
	returnSpawn.CanCollide = false
	returnSpawn.CanQuery = false
	returnSpawn.CanTouch = false
	returnSpawn.CFrame = CFrame.lookAt(back, Vector3.new(pad.X, back.Y, pad.Z))
	returnSpawn.Parent = holder
	holder:SetAttribute("BossReturn", back)
	table.insert(pendingSeats, function()
		-- The islet's edge slopes away there: stand it on the terrain actually under it.
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { workspace.Terrain }
		local hit = workspace:Raycast(back + Vector3.new(0, 8, 0), Vector3.new(0, -20, 0), params)
		if hit then
			local ground = Vector3.new(back.X, hit.Position.Y, back.Z)
			returnSpawn.CFrame = CFrame.lookAt(ground, Vector3.new(pad.X, ground.Y, pad.Z))
			holder:SetAttribute("BossReturn", ground)
		end
	end)
	holder.Parent = lobby
end

local function boards(parent: Instance, spots: { Vector3 }, faceToward: Vector3)
	local titles = { "TOTAL WINS", "RANKED RATING" }
	for i, base in spots do
		local look = CFrame.lookAt(base, Vector3.new(faceToward.X, base.Y, faceToward.Z))
		for _, side in { -1, 1 } do
			part({
				Name = "BoardPost",
				Size = Vector3.new(0.7, 13, 0.7),
				CFrame = look * CFrame.new(side * 4.6, 6.5, 0),
				Material = Enum.Material.Wood,
				Color = Palette.Timber,
				CastShadow = false,
			}, parent)
		end
		local board = part({
			Name = "Leaderboard",
			Size = Vector3.new(8.6, 9.5, 0.4),
			CFrame = look * CFrame.new(0, 7.2, 0),
			Material = Enum.Material.SmoothPlastic,
			Color = Palette.Ink,
			CastShadow = false,
		}, parent)
		board:SetAttribute("Board", titles[i])
		part({
			Name = "BoardCap",
			Size = Vector3.new(10.4, 0.7, 1.4),
			CFrame = look * CFrame.new(0, 12.3, 0),
			Material = Enum.Material.ClayRoofTiles,
			Color = Palette.Roof,
			CastShadow = false,
		}, parent)
	end
end

-- How a board or pedestal opens its panel: a prompt when you walk up, a click from afar.
-- The client (LobbyHUD) handles both through the OpensPanel attribute.
local function opens(target: BasePart, panel: string, action: string, objectText: string)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "OpenPanel"
	prompt.ActionText = action
	prompt.ObjectText = objectText
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt:SetAttribute("OpensPanel", panel)
	prompt.Parent = target
	local click = Instance.new("ClickDetector")
	click.MaxActivationDistance = 60
	click:SetAttribute("OpensPanel", panel)
	click.Parent = target
end

-- A painted board on two timber posts under a tiled cap, with a title strip over the art.
local function panelBoard(parent: Instance, base: Vector3, faceToward: Vector3, spec: { [string]: string })
	local look = CFrame.lookAt(base, Vector3.new(faceToward.X, base.Y, faceToward.Z))
	local holder = Instance.new("Model")
	holder.Name = spec.name
	for _, side in { -1, 1 } do
		part({
			Name = "BoardPost",
			Size = Vector3.new(0.7, 9.6, 0.7),
			CFrame = look * CFrame.new(side * 5.6, 4.8, 0.3),
			Material = Enum.Material.Wood,
			Color = Palette.Timber,
			CastShadow = false,
		}, holder)
	end
	local board = part({
		Name = "Board",
		Size = Vector3.new(10.4, 5.2, 0.35),
		CFrame = look * CFrame.new(0, 5.6, 0),
		Material = Enum.Material.SmoothPlastic,
		Color = Palette.Ink,
		CastShadow = false,
	}, holder)
	part({
		Name = "BoardCap",
		Size = Vector3.new(12.6, 0.6, 1.5),
		CFrame = look * CFrame.new(0, 8.6, 0.2),
		Material = Enum.Material.ClayRoofTiles,
		Color = Palette.Roof,
		CastShadow = false,
	}, holder)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Art"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(1024, 512)
	gui.LightInfluence = 0.25
	gui.Brightness = 1.2
	gui.MaxDistance = 220
	gui.Parent = board
	local art = Instance.new("ImageLabel")
	art.Size = UDim2.fromScale(1, 1)
	art.BackgroundTransparency = 1
	art.Image = spec.image
	art.Parent = gui
	local strip = Instance.new("Frame")
	strip.AnchorPoint = Vector2.new(0, 1)
	strip.Position = UDim2.fromScale(0, 1)
	strip.Size = UDim2.new(1, 0, 0, 132)
	strip.BackgroundColor3 = Palette.Ink
	strip.BackgroundTransparency = 0.25
	strip.BorderSizePixel = 0
	strip.Parent = art
	local heading = Instance.new("TextLabel")
	heading.BackgroundTransparency = 1
	heading.Position = UDim2.fromOffset(0, 6)
	heading.Size = UDim2.new(1, 0, 0, 78)
	heading.Font = Enum.Font.Garamond
	heading.TextSize = 72
	heading.TextColor3 = Palette.Parchment
	heading.Text = spec.title
	heading.Parent = strip
	local sub = heading:Clone()
	sub.Position = UDim2.fromOffset(0, 84)
	sub.Size = UDim2.new(1, 0, 0, 40)
	sub.Font = Enum.Font.SourceSansSemibold
	sub.TextSize = 32
	sub.TextColor3 = Color3.fromRGB(232, 190, 92)
	sub.Text = spec.subtitle
	sub.Parent = strip
	opens(board, spec.panel, spec.action, spec.title)
	holder.Parent = parent
	return holder
end

-- The season capstone (the last tier's premium blade), from Shared/Season when it exists.
local function capstone(): (string?, string?)
	local module = ReplicatedStorage.Shared:FindFirstChild("Season")
	if not module or not module:IsA("ModuleScript") then
		return nil, nil
	end
	local ok, Season = pcall(require, module)
	if not ok or typeof(Season) ~= "table" or typeof(Season.at) ~= "function" then
		return nil, nil
	end
	local def = Season.at() or Season.List[1]
	local last = def and def.tiers and def.tiers[#def.tiers]
	for _, reward in (last and last.premium) or {} do
		local item = reward.kind == "item" and Catalog.get(reward.id)
		if item and item.category == "bladeSkin" then
			return item.ref, `{item.name}  ·  {def.name or "Season"}`
		end
	end
	return nil, nil
end

-- The Hall of Champions pedestal: a stone plinth holding the season's capstone blade point
-- up, lit, with a plaque. Pressing it opens the pass (the blade is its last tier).
local function pedestal(parent: Instance, base: Vector3, faceToward: Vector3)
	local look = CFrame.lookAt(base, Vector3.new(faceToward.X, base.Y, faceToward.Z))
	local holder = Instance.new("Model")
	holder.Name = "ChampionPedestal"
	disc(3.2, 0.8, base + Vector3.new(0, 0.4, 0), {
		Name = "PlinthBase",
		Material = Enum.Material.Slate,
		Color = Palette.Stone,
	}, holder)
	part({
		Name = "Plinth",
		Size = Vector3.new(2.6, 3.4, 2.6),
		CFrame = look * CFrame.new(0, 2.5, 0),
		Material = Enum.Material.Limestone,
		Color = Palette.LanternStone,
	}, holder)
	local top = part({
		Name = "PlinthTop",
		Size = Vector3.new(3.4, 0.5, 3.4),
		CFrame = look * CFrame.new(0, 4.45, 0),
		Material = Enum.Material.Slate,
		Color = Palette.Lacquer,
	}, holder)
	-- The blade: a stand-in "hand" holds it like a fighter would, turned point up.
	local ref, label = capstone()
	local stand = Instance.new("Model")
	stand.Name = "Blade"
	local hand = part({
		Name = "RightHand",
		Size = Vector3.new(0.6, 0.6, 0.6),
		CFrame = look * CFrame.new(0, 5.6, 0) * CFrame.Angles(math.rad(90), 0, 0),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
	}, stand)
	hand.Anchored = true
	stand.Parent = holder
	local sword = SwordRig.attach(stand, "Katana")
	if sword then
		SwordRig.applySkin(stand, ref)
		local glow = Instance.new("PointLight")
		glow.Name = "Showcase"
		glow.Color = Color3.fromRGB(255, 214, 170)
		glow.Range = 10
		glow.Brightness = 1.4
		glow.Shadows = false
		glow.Parent = top
	end
	local plaque = Instance.new("BillboardGui")
	plaque.Name = "Plaque"
	plaque.Size = UDim2.fromScale(9, 2.2) -- in studs: it shrinks with distance like the board
	plaque.StudsOffsetWorldSpace = Vector3.new(0, 6.5, 0)
	plaque.MaxDistance = 28 -- close up only: from the plaza its micro-text read as a broken HUD line
	plaque.LightInfluence = 0
	plaque.Parent = top
	local heading = Instance.new("TextLabel")
	heading.BackgroundTransparency = 1
	heading.Size = UDim2.fromScale(1, 0.55)
	heading.Font = Enum.Font.Garamond
	heading.TextScaled = true
	heading.TextColor3 = Color3.fromRGB(232, 190, 92)
	heading.TextStrokeTransparency = 0.5
	heading.Text = label or "The season blade"
	heading.Parent = plaque
	local sub = heading:Clone()
	sub.Position = UDim2.fromScale(0, 0.58)
	sub.Size = UDim2.fromScale(1, 0.38)
	sub.Font = Enum.Font.SourceSansSemibold
	sub.TextColor3 = Palette.Parchment
	sub.Text = "Earned at the pass's last tier, never sold"
	sub.Parent = plaque
	opens(top, "Pass", "See the season", "Hall of Champions")
	holder.Parent = parent
end

-- An open dojo pavilion: four lacquered posts and a tiled roof over a wooden deck.
-- Edge stops on the main island's rim where you're likely to back off it without looking: the
-- two wings (a lock-on backpedal at the deflect trainer walked straight off the dojo wing) and
-- the low rim by the duel pads. Each stretch spans the wing or the pad pair and a margin.
local RIM_WALL_RADIUS = MAIN_RADIUS - 2
local RIM_WALL_SPAN = math.rad(22) -- either side of the wing's or the pad pair's bearing
local function rimWalls(parent: Instance)
	local bearings = {
		math.atan2(-2, -48), -- the dojo wing
		math.atan2(-2, 48), -- the hall of champions
	}
	for _, ground in DUEL_GROUNDS do
		table.insert(bearings, math.atan2(ground.pads.Y, ground.pads.X))
	end
	for _, bearing in bearings do
		rimWall(
			parent,
			at(0, 0, 0),
			RIM_WALL_RADIUS,
			bearing - RIM_WALL_SPAN,
			bearing + RIM_WALL_SPAN,
			O.Y - 6,
			WING + 10,
			MAIN_GAPS
		)
	end
end

local function pavilion(parent: Instance, center: Vector3, facing: Vector3)
	local look = CFrame.lookAt(center, center + facing)
	local w, d, h = 16, 10, 9
	part({
		Name = "DojoDeck",
		Size = Vector3.new(w, 0.6, d),
		CFrame = look * CFrame.new(0, 0.3, 0),
		Material = Enum.Material.WoodPlanks,
		Color = Palette.Deck,
	}, parent)
	for _, x in { -w / 2 + 0.6, w / 2 - 0.6 } do
		for _, z in { -d / 2 + 0.6, d / 2 - 0.6 } do
			-- The lock-on camera passes through the posts instead of pulling in on a strafe.
			EnvironmentProfile.post("DojoPost", look * CFrame.new(x, 0, z), h, 0.9, parent, {
				castShadow = false,
				band = 1,
				cameraIgnore = true,
			})
		end
	end
	for _, side in { -1, 1 } do
		part({
			Name = "DojoRoof",
			Size = Vector3.new(w + 4, 0.7, d / 2 + 2.6),
			CFrame = look * CFrame.new(0, h + 1.2, side * (d / 4 + 1)) * CFrame.Angles(math.rad(side * 24), 0, 0),
			Material = Enum.Material.ClayRoofTiles,
			Color = Palette.Roof,
		}, parent)
	end
	part({
		Name = "DojoRidge",
		Size = Vector3.new(w + 4, 0.8, 1),
		CFrame = look * CFrame.new(0, h + 2.2, 0),
		Material = Enum.Material.Slate,
		Color = Palette.Roof,
		CastShadow = false,
	}, parent)
	local sign = part({
		Name = "DojoSign",
		Size = Vector3.new(6, 1.6, 0.3),
		CFrame = look * CFrame.new(0, h - 0.4, -d / 2 - 0.1),
		Material = Enum.Material.Wood,
		Color = Palette.Timber,
		CastShadow = false,
	}, parent)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0.4
	gui.Parent = sign
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Size = UDim2.fromScale(1, 1)
	text.Font = Enum.Font.Garamond
	text.TextScaled = true
	text.TextColor3 = Palette.Parchment
	text.Text = "道場  ·  DEFLECT TRAINER"
	text.Parent = gui
end

-- The backdrop mountains (Workspace.Props.Mountains) were laid out around the castle before
-- the lobby floated above it, and one of them sliced through the back islet and the boss
-- shrine. Push any mountain whose footprint reaches the lobby further out along its
-- bearing from the castle: the castle keeps the same horizon, a little farther off.
local LOBBY_FOOTPRINT = { at = Vector2.new(-10, 40), radius = 150 } -- the island, islets and terraces
local function clearBackdrop()
	local props = workspace:FindFirstChild("Props")
	local mountains = props and props:FindFirstChild("Mountains")
	if not mountains then
		return
	end
	local centre = Vector2.new(O.X, O.Z) + LOBBY_FOOTPRINT.at
	for _, mountain in mountains:GetChildren() do
		if not mountain:IsA("BasePart") then
			continue
		end
		-- The cone is narrower than its box at the lobby's height.
		local reach = LOBBY_FOOTPRINT.radius + math.max(mountain.Size.X, mountain.Size.Z) / 2 * 0.8
		local flat = Vector2.new(mountain.Position.X, mountain.Position.Z)
		local bearing = if flat.Magnitude > 1 then flat.Unit else Vector2.new(0, 1)
		local pushed = 0
		while (flat + bearing * pushed - centre).Magnitude < reach and pushed < 600 do
			pushed += 10
		end
		if pushed > 0 then
			mountain.Position += Vector3.new(bearing.X, 0, bearing.Y) * pushed
		end
	end
end

-- A sea of cloud beneath the island, parting toward the castle valley.
local function cloudSea(parent: Instance)
	local layer = part(
		decor({
			Name = "CloudSea",
			Size = Vector3.new(620, 1, 400),
			CFrame = CFrame.new(O.X, O.Y - 60, O.Z + 90),
			Transparency = 1,
		}),
		parent
	)
	local clouds = Instance.new("ParticleEmitter")
	clouds.Texture = "rbxasset://textures/particles/smoke_main.dds"
	clouds.Color = ColorSequence.new(Color3.fromRGB(250, 238, 232), Color3.fromRGB(214, 196, 204))
	clouds.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 55),
		NumberSequenceKeypoint.new(1, 85),
	})
	clouds.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.25, 0.45),
		NumberSequenceKeypoint.new(0.75, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	clouds.Lifetime = NumberRange.new(40, 55)
	clouds.Rate = 9
	-- Puffs drift sideways and barely rise, so the sea stays below the island instead of
	-- climbing through the lobby as haze for the first minute of a server.
	clouds.Speed = NumberRange.new(0, 0.15)
	clouds.Acceleration = Vector3.new(0.12, 0, 0.05)
	clouds.SpreadAngle = Vector2.new(80, 80)
	clouds.Rotation = NumberRange.new(0, 360)
	clouds.RotSpeed = NumberRange.new(-2, 2)
	clouds.LightInfluence = 1
	clouds.Parent = layer
	-- Warm the sea up from the start instead of letting it fill in over a minute.
	clouds:Emit(300)
end

---------------------------------------------------------------------------------------

function LobbyBuilder.build(): Folder
	local previous = workspace:FindFirstChild("Lobby")
	if previous then
		previous:Destroy()
	end
	local lobby = Instance.new("Folder")
	lobby.Name = "Lobby"
	lobby.Parent = workspace

	landforms()
	rimWalls(lobby)

	-- Spawn plaza.
	local spawnPoint = at(0, LOWER, 30)
	local terraceCenter = at(0, UPPER, -44)
	for _, x in { -11, 11 } do
		lantern(at(x, LOWER, 12), lobby)
		lantern(at(x * 1.7, LOWER, 36), lobby)
	end
	-- The two maples stand back from the duel pads, out of the camera's arc on a pad.
	tree(at(-24, LOWER, 60), lobby, 1.2)
	tree(at(26, LOWER, 58), lobby, 1.1)
	-- The cherry and the maple off the wings stand behind them, over the ponds, 30 studs from the
	-- trainer: by the duel pads, (-58, 18) and (62, 16), their low canopies swallowed the camera
	-- at the pads and at the trainer.
	tree(at(-52, LOWER, -32), lobby)
	tree(at(54, LOWER, -30), lobby)
	tree(at(-8, LOWER, 60), lobby, 0.9)

	-- The grand stair up to the torii terrace, and the wing stairs.
	stairs(lobby, at(0, LOWER, 8), at(0, UPPER, -8), 18, 10)
	stairs(lobby, at(-20, LOWER, -2), at(-29, WING, -2), 10, 5)
	stairs(lobby, at(20, LOWER, -2), at(29, WING, -2), 10, 5)

	-- Torii terrace: the queue pad, a great torii framing the castle, two guardians.
	queuePad(lobby, terraceCenter)
	local torii = prop("Torii", CFrame.lookAt(at(0, UPPER, -68), at(0, UPPER, -200)), lobby, 1.55)
	if torii then
		Torii.openGate(torii) -- the path runs through it to the terrace's far edge
	end
	for _, side in { -1, 1 } do
		-- The stair-top pair stands clear of the stair's edges, off the camera's path up it.
		lantern(at(side * 12, UPPER, -12), lobby)
		lantern(at(side * 11.7, UPPER, -62), lobby)
	end
	-- Two towering stone lanterns flank the torii.
	for _, x in { -18, 18 } do
		prop("Lantern", CFrame.new(at(x, UPPER, -64)), lobby, 2.4)
	end
	tree(at(-24, UPPER, -30), lobby, 0.9)
	tree(at(26, UPPER, -28), lobby, 0.9)

	-- Left wing: the dojo.
	local trainerHome = at(-48, WING, -2)
	pavilion(lobby, at(-56, WING - 0.2, -2), Vector3.new(1, 0, 0))
	disc(
		9,
		0.1,
		trainerHome + Vector3.new(0, 0.05, 0),
		decor({
			Name = "TrainerKerb",
			Material = Enum.Material.Slate,
			Color = Palette.Stone,
		}),
		lobby
	)
	disc(
		8.4,
		0.12,
		trainerHome + Vector3.new(0, 0.07, 0),
		decor({
			Name = "TrainerSand",
			Material = Enum.Material.Sand,
			Color = Palette.Sand,
		}),
		lobby
	)

	-- Right wing: the hall of champions.
	boards(lobby, { at(42, WING, -16), at(56, WING, 4) }, at(30, WING, 10))
	for _, z in { -14, 10 } do
		lantern(at(34, WING, z), lobby)
	end
	pedestal(lobby, at(52, WING, -6), at(30, WING, -2))

	-- The Store and Season boards, either side of the spawn plaza, facing where you spawn.
	panelBoard(lobby, at(-24, LOWER, 26), at(0, LOWER, 34), {
		name = "SeasonBoard",
		image = Assets.Boards.Season,
		title = "PATH OF THE BLADE",
		subtitle = "Season rewards and missions",
		panel = "Pass",
		action = "See the season",
	})
	panelBoard(lobby, at(24, LOWER, 26), at(0, LOWER, 34), {
		name = "StoreBoard",
		image = Assets.Boards.Store,
		title = "STORE",
		subtitle = "Daily shop  ·  gems  ·  the shrine",
		panel = "Store",
		action = "Open the Store",
	})

	-- Bridges and their islets.
	bridge(lobby, BRIDGE_LEFT)
	bridge(lobby, BRIDGE_BACK)
	local leftIslet = Vector3.new(O.X + BRIDGE_LEFT.islet.X, LOWER, O.Z + BRIDGE_LEFT.islet.Y)
	tree(leftIslet + Vector3.new(-4, 0, 4), lobby, 1.2)
	lantern(leftIslet + Vector3.new(6, 0, -4), lobby)
	local backIslet = Vector3.new(O.X + BRIDGE_BACK.islet.X, LOWER, O.Z + BRIDGE_BACK.islet.Y)
	prop("CornerLantern", CFrame.new(backIslet + Vector3.new(7, 0, -6)), lobby, 1.3)
	tree(backIslet + Vector3.new(6, 0, 6), lobby)
	bossGrounds(lobby, backIslet)

	-- Waterfalls leave the rim where the streams end (the rim is at MAIN_RADIUS).
	waterfall(lobby, at(math.sqrt(MAIN_RADIUS ^ 2 - 36 ^ 2) - 1, LOWER - 1.5, -36), Vector3.new(1, 0, 0))
	waterfall(lobby, at(-math.sqrt(MAIN_RADIUS ^ 2 - 42 ^ 2) + 1, LOWER - 1.5, -42), Vector3.new(-1, 0, 0))
	farIslets(lobby)
	duelGrounds(lobby)
	cloudSea(lobby)
	clearBackdrop()

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "LobbySpawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Size = Vector3.new(10, 0.2, 10)
	spawn.CFrame = CFrame.lookAt(spawnPoint + Vector3.new(0, 0.1, 0), terraceCenter)
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.CanQuery = false
	spawn.Parent = lobby

	-- Key points for LobbyService.
	lobby:SetAttribute("SpawnPoint", spawnPoint)
	lobby:SetAttribute("QueuePad", terraceCenter)
	lobby:SetAttribute("TrainerHome", trainerHome)
	-- Seat every prop on the terrain now that it can be raycast (see pendingSeats).
	task.wait()
	for _, seatIt in pendingSeats do
		seatIt()
	end
	table.clear(pendingSeats)
	return lobby
end

return LobbyBuilder
