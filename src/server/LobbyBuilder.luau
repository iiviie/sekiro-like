--!strict
-- Builds the free-roam lobby: a floating shrine island high above the castle, looking down
-- on the courtyard where the royale is fought. A flagstone plaza on a rough rock underside,
-- a mossy lip, a torii and stone lanterns (cloned from Workspace.Props), the glowing Royale
-- queue pad, a sand circle for the deflect trainer, leaderboard boards and the spawn.
--
-- Performance: about 150 anchored parts; decorative pieces don't collide, query or touch.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Palette = require(ReplicatedStorage.Shared.Palette)

local LOBBY = Config.Lobby
local ORIGIN = LOBBY.Origin

local LobbyBuilder = {}

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

local function disc(radius: number, height: number, center: Vector3, props: { [string]: any }, parent: Instance)
	props.Shape = Enum.PartType.Cylinder
	props.Size = Vector3.new(height, radius * 2, radius * 2)
	props.CFrame = CFrame.new(center) * CFrame.Angles(0, 0, math.rad(90))
	return part(props, parent)
end

local function decor(props: { [string]: any }): { [string]: any }
	props.CanCollide = false
	props.CanQuery = false
	props.CastShadow = props.CastShadow or false
	return props
end

-- The island: plaza on top, a mossy lip, and a rough tapering rock underside.
local function island(parent: Instance)
	local r = LOBBY.Radius
	disc(r, 4, ORIGIN - Vector3.new(0, 2, 0), {
		Name = "Plaza",
		Material = Enum.Material.Slate,
		Color = Palette.Flagstone,
	}, parent)
	disc(
		r + 0.8,
		1.2,
		ORIGIN - Vector3.new(0, 0.75, 0),
		decor({
			Name = "MossLip",
			Material = Enum.Material.Grass,
			Color = Palette.Moss,
		}),
		parent
	)
	-- Inlaid ring patterns on the plaza, like the reference's carved floor.
	for _, ring in { { 30, 0.8 }, { 15, 0.6 } } do
		disc(
			ring[1],
			0.06,
			ORIGIN + Vector3.new(0, 0.02, 0),
			decor({
				Name = "Inlay",
				Material = Enum.Material.Slate,
				Color = Palette.Stone,
			}),
			parent
		)
		disc(
			ring[1] - ring[2],
			0.08,
			ORIGIN + Vector3.new(0, 0.03, 0),
			decor({
				Name = "InlayFill",
				Material = Enum.Material.Slate,
				Color = Palette.Flagstone,
			}),
			parent
		)
	end
	local random = Random.new(11)
	local depth = 4
	for i, radius in { r - 2, r * 0.78, r * 0.55, r * 0.34, r * 0.16 } do
		local height = 6 + i * 2
		depth += height * 0.8
		disc(
			radius,
			height,
			ORIGIN - Vector3.new(random:NextNumber(-2, 2), depth, random:NextNumber(-2, 2)),
			decor({
				Name = "Underside",
				Material = Enum.Material.Rock,
				Color = Color3.fromRGB(96, 90, 86):Lerp(Color3.fromRGB(70, 66, 64), i / 5),
				CastShadow = true,
			}),
			parent
		)
	end
	-- Boulders breaking the silhouette of the edge.
	for i = 1, 14 do
		local angle = (i / 14) * math.pi * 2 + random:NextNumber(-0.15, 0.15)
		local radius = r + random:NextNumber(-1, 1.5)
		local size = random:NextNumber(4, 8)
		part(
			decor({
				Name = "Boulder",
				Shape = Enum.PartType.Ball,
				Size = Vector3.one * size,
				CFrame = CFrame.new(
					ORIGIN + Vector3.new(math.cos(angle) * radius, -size * 0.55, math.sin(angle) * radius)
				),
				Material = Enum.Material.Rock,
				Color = Color3.fromRGB(104, 98, 92),
			}),
			parent
		)
	end
	-- Low stone posts around the rim so the edge reads; the gaps are walkable on purpose.
	for i = 1, 36 do
		local angle = (i / 36) * math.pi * 2
		if i % 9 ~= 0 then
			local position = ORIGIN + Vector3.new(math.cos(angle) * (r - 1.2), 1.1, math.sin(angle) * (r - 1.2))
			part({
				Name = "RimPost",
				Size = Vector3.new(1, 2.2, 1),
				CFrame = CFrame.lookAt(position, ORIGIN + Vector3.new(0, 1.1, 0)),
				Material = Enum.Material.Slate,
				Color = Palette.Stone,
				CastShadow = false,
			}, parent)
		end
	end
end

-- Clone a prop from Workspace.Props (the hand-placed, script-free Creator Store models).
local function prop(name: string, cframe: CFrame, parent: Instance)
	local props = workspace:FindFirstChild("Props")
	local source = props and props:FindFirstChild(name, true)
	if not source or not source:IsA("Model") then
		return
	end
	local copy = source:Clone()
	local _, size = copy:GetBoundingBox()
	copy:PivotTo(cframe * CFrame.new(0, size.Y / 2, 0))
	-- Rest it on the plaza: shift so the bounding box bottom sits at the target height.
	local boxCFrame, boxSize = copy:GetBoundingBox()
	local bottom = boxCFrame.Position.Y - boxSize.Y / 2
	copy:PivotTo(copy:GetPivot() + Vector3.new(0, cframe.Position.Y - bottom, 0))
	for _, d in copy:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanTouch = false
		end
	end
	copy.Parent = parent
end

local function billboard(adornee: BasePart, title: string, height: number): TextLabel
	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Size = UDim2.fromOffset(260, 70)
	gui.StudsOffsetWorldSpace = Vector3.new(0, height, 0)
	gui.MaxDistance = 90
	gui.LightInfluence = 0
	gui.Parent = adornee
	local heading = Instance.new("TextLabel")
	heading.BackgroundTransparency = 1
	heading.Size = UDim2.fromScale(1, 0.55)
	heading.Font = Enum.Font.Garamond
	heading.TextScaled = true
	heading.TextColor3 = Palette.Parchment
	heading.TextStrokeTransparency = 0.5
	heading.Text = title
	heading.Parent = gui
	local sub = heading:Clone()
	sub.Name = "Sub"
	sub.Position = UDim2.fromScale(0, 0.55)
	sub.Size = UDim2.fromScale(1, 0.4)
	sub.TextColor3 = Palette.Bronze
	sub.Text = ""
	sub.Parent = gui
	return sub
end

-- The glowing Royale pad: step on it (or press PLAY) to queue.
local function queuePad(parent: Instance): BasePart
	local center = ORIGIN + LOBBY.QueuePad
	local radius = LOBBY.QueuePadRadius
	local pad = disc(radius + 0.6, 0.5, center + Vector3.new(0, 0.2, 0), {
		Name = "QueuePad",
		Material = Enum.Material.Slate,
		Color = Palette.Ink,
		CanCollide = true,
	}, parent)
	disc(
		radius,
		0.12,
		center + Vector3.new(0, 0.48, 0),
		decor({
			Name = "PadGlow",
			Material = Enum.Material.Neon,
			Color = Palette.Crimson,
		}),
		parent
	)
	disc(
		radius - 0.7,
		0.14,
		center + Vector3.new(0, 0.5, 0),
		decor({
			Name = "PadInner",
			Material = Enum.Material.Sand,
			Color = Color3.fromRGB(186, 170, 144),
		}),
		parent
	)
	-- A soft column of crimson light rising from the pad.
	local beamRoot = part(
		decor({
			Name = "PadBeam",
			Size = Vector3.one,
			Transparency = 1,
			CFrame = CFrame.new(center),
		}),
		parent
	)
	for i = 1, 24 do
		local angle = (i / 24) * math.pi * 2
		local base = Vector3.new(math.cos(angle) * radius, 0.5, math.sin(angle) * radius)
		local a0 = Instance.new("Attachment")
		a0.Position = base
		a0.Parent = beamRoot
		local a1 = Instance.new("Attachment")
		a1.Position = base + Vector3.new(0, 7, 0)
		a1.Parent = beamRoot
		local beam = Instance.new("Beam")
		beam.Attachment0 = a0
		beam.Attachment1 = a1
		beam.FaceCamera = true
		beam.Width0 = 2 * math.pi * radius / 24 + 0.3
		beam.Width1 = beam.Width0
		beam.Color = ColorSequence.new(Palette.Crimson)
		beam.Transparency = NumberSequence.new(0.55, 1)
		beam.LightEmission = 0.6
		beam.Segments = 1
		beam.Parent = beamRoot
	end
	local light = Instance.new("PointLight")
	light.Color = Palette.Crimson
	light.Range = 16
	light.Brightness = 1.4
	light.Parent = beamRoot
	billboard(pad, "ROYALE", 9)
	return pad
end

-- A sand circle for the deflect trainer, with a signpost.
local function trainerRing(parent: Instance)
	local center = ORIGIN + LOBBY.Trainer
	disc(
		8,
		0.12,
		center + Vector3.new(0, 0.06, 0),
		decor({
			Name = "TrainerSand",
			Material = Enum.Material.Sand,
			Color = Color3.fromRGB(186, 170, 144),
		}),
		parent
	)
	disc(
		8.6,
		0.1,
		center + Vector3.new(0, 0.04, 0),
		decor({
			Name = "TrainerKerb",
			Material = Enum.Material.Slate,
			Color = Palette.Stone,
		}),
		parent
	)
end

-- Upright boards for the leaderboards; LeaderboardService fills their SurfaceGuis.
local function boards(parent: Instance)
	local titles = { "TOTAL WINS", "RANKED RATING" }
	for i, offset in LOBBY.Leaderboards do
		local base = ORIGIN + offset
		local look = CFrame.lookAt(base, Vector3.new(ORIGIN.X, base.Y, ORIGIN.Z + LOBBY.Spawn.Z * 0.4))
		for _, side in { -1, 1 } do
			part({
				Name = "BoardPost",
				Size = Vector3.new(0.6, 12, 0.6),
				CFrame = look * CFrame.new(side * 4.3, 6, 0),
				Material = Enum.Material.Wood,
				Color = Palette.Timber,
				CastShadow = false,
			}, parent)
		end
		local board = part({
			Name = "Leaderboard",
			Size = Vector3.new(8, 9, 0.4),
			CFrame = look * CFrame.new(0, 6.5, 0),
			Material = Enum.Material.SmoothPlastic,
			Color = Palette.Ink,
			CastShadow = false,
		}, parent)
		board:SetAttribute("Board", titles[i])
		part({
			Name = "BoardCap",
			Size = Vector3.new(9.6, 0.6, 1.2),
			CFrame = look * CFrame.new(0, 11.3, 0),
			Material = Enum.Material.ClayRoofTiles,
			Color = Palette.Roof,
			CastShadow = false,
		}, parent)
	end
end

function LobbyBuilder.build(): Folder
	local previous = workspace:FindFirstChild("Lobby")
	if previous then
		previous:Destroy()
	end
	local lobby = Instance.new("Folder")
	lobby.Name = "Lobby"

	island(lobby)
	queuePad(lobby)
	trainerRing(lobby)
	boards(lobby)

	-- Props: a torii framing the view down to the castle, lanterns and two trees.
	local toCastle = CFrame.lookAt(ORIGIN, Vector3.new(0, ORIGIN.Y, 0))
	prop("Torii", toCastle * CFrame.new(0, 0, -(LOBBY.Radius - 8)), lobby)
	for _, x in { -9, 9 } do
		prop("Lantern", toCastle * CFrame.new(x, 0, -(LOBBY.Radius - 16)), lobby)
		prop("Lantern", toCastle * CFrame.new(x * 1.6, 0, LOBBY.Spawn.Z - 30), lobby)
	end
	local trees = workspace:FindFirstChild("Props") and workspace.Props:FindFirstChild("Trees")
	if trees then
		local list = trees:GetChildren()
		for i, spot in { Vector3.new(-30, 0, 22), Vector3.new(32, 0, 20) } do
			local source = list[i * 3]
			if source and source:IsA("Model") then
				local copy = source:Clone()
				local boxCFrame, boxSize = copy:GetBoundingBox()
				local pivotToBottom = copy:GetPivot().Position.Y - (boxCFrame.Position.Y - boxSize.Y / 2)
				copy:PivotTo(CFrame.new(ORIGIN + spot + Vector3.new(0, pivotToBottom, 0)))
				copy.Parent = lobby
			end
		end
	end

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "LobbySpawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Size = Vector3.new(10, 0.2, 10)
	spawn.CFrame = CFrame.lookAt(ORIGIN + LOBBY.Spawn + Vector3.new(0, 0.1, 0), ORIGIN + LOBBY.QueuePad)
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.CanQuery = false
	spawn.Parent = lobby

	lobby.Parent = workspace
	return lobby
end

return LobbyBuilder
