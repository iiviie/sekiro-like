--!strict
-- Title card shown on join, and the game's loading gate.
--
-- It opens on ink with the LAST BLADE logo and a calm progress line while client/WorldGate
-- waits for the server to finish building the island and preloads what the player sees
-- first. When the world is here the ink lifts on a slow dolly across the lobby island's
-- torii terrace (petals drifting past the lens, a soft vignette), and only once the assets
-- are loaded and the character has spawned does "press any key" / "tap to begin" appear. A
-- press then dips to ink for a moment and comes up on the player in the lobby, so nobody
-- ever sees the world half built.

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")

local Assets = require(ReplicatedStorage.Shared.Assets)
local Config = require(ReplicatedStorage.Shared.Config)
local UI = require(script.Parent.UI)
local WorldGate = require(script.Parent.WorldGate)

local player = Players.LocalPlayer
local T = UI.Theme

-- The shot, relative to the lobby's origin (Config.Lobby.Origin, the lower tier's fill top):
-- the floating island from off its north rim, low over the cloud sea, with the great torii
-- on the terrace's edge, the waterfalls and the duel terraces either side, and open sky
-- above for the logo. A slow lateral drift gives the islets parallax; one full sway takes
-- DOLLY_PERIOD seconds, eased at both ends.
local SHOT = {
	from = Vector3.new(-88, 26, -232),
	to = Vector3.new(-46, 31, -242),
	lookFrom = Vector3.new(-4, 47, -32),
	lookTo = Vector3.new(10, 49, -34),
	fov = 42,
}
local DOLLY_PERIOD = 46

local LOGO_ASPECT = 1526 / 958 -- art/logo/png/lb_inkgold_seal.png
local FADE_IN = TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local LOGO_IN = TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local DIP = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local LIFT = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local TitleScreen = {}

local function label(parent: Instance, props: { [string]: any }): TextLabel
	local l = UI.new("TextLabel", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		TextColor3 = T.Bone,
		TextStrokeColor3 = T.Ink,
		TextStrokeTransparency = 0.55,
	}, parent)
	for k, v in props do
		(l :: any)[k] = v
	end
	return l
end

-- Petals drifting across the lens: one emitter on an invisible part that rides just ahead
-- of the camera (local to this client, gone when the card closes).
local function petals(camera: Camera, few: boolean): (BasePart, () -> ())
	local part = Instance.new("Part")
	part.Name = "TitlePetals"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(44, 1, 26)
	part.Parent = camera
	local e = Instance.new("ParticleEmitter")
	e.Texture = (Assets.Cosmetics :: any).Petal
	e.Rate = if few then 2.5 else 6
	e.Lifetime = NumberRange.new(7, 10)
	e.Speed = NumberRange.new(0.5, 1.5)
	e.EmissionDirection = Enum.NormalId.Bottom
	e.Acceleration = Vector3.new(1.4, -0.9, 0.3)
	e.Drag = 0.2
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-60, 60)
	e.SpreadAngle = Vector2.new(25, 25)
	e.Size = NumberSequence.new(0.16, 0.24)
	e.Color = ColorSequence.new(Color3.fromRGB(255, 206, 220), Color3.fromRGB(240, 170, 192))
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.12, 0.1),
		NumberSequenceKeypoint.new(0.85, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.LightInfluence = 0.6
	e.Parent = part
	local function follow()
		local cf = camera.CFrame
		-- Above and ahead, so petals fall through the frame at 6-26 studs from the lens.
		part.CFrame = cf * CFrame.new(-6, 9, -16)
	end
	follow()
	e:Emit(if few then 6 else 14) -- a few already in the air when the ink lifts
	return part, follow
end

-- Shows the title card and yields until the player enters.
function TitleScreen.show()
	local playerGui = player:WaitForChild("PlayerGui")
	local touch = UI.isTouch() or workspace:GetAttribute("ForceTouchHUD") == true -- (the Studio phone aid)
	local reduced = UI.reducedMotion()
	local camera = workspace.CurrentCamera

	local screen = UI.new("ScreenGui", {
		Name = "TitleScreen",
		IgnoreGuiInset = true,
		DisplayOrder = 100,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})

	-- Soft vignette and a darker floor under the prompt (no letterbox bars).
	local vignette = UI.new("ImageLabel", {
		Name = "Vignette",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Image = Assets.UI.Vignette,
		ImageColor3 = T.Ink,
		ImageTransparency = 0.3,
		ZIndex = 1,
	}, screen)
	local floor = UI.new("Frame", {
		Name = "Floor",
		BackgroundColor3 = T.Ink,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0.38),
		ZIndex = 1,
	}, screen)
	UI.new("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(1, 0.35),
		}),
	}, floor)
	-- A lighter scrim behind the logo, so the ink letters hold on bright sky.
	local halo = UI.new("ImageLabel", {
		Name = "Halo",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Image = Assets.UI.Glow,
		ImageColor3 = T.Bone,
		ImageTransparency = 0.72,
		ZIndex = 2,
	}, screen)

	-- The loading cover: solid ink until the world is here, then it lifts.
	local cover = UI.new("Frame", {
		Name = "Cover",
		BackgroundColor3 = Color3.fromRGB(14, 12, 13),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 3,
	}, screen)

	local logo = UI.new("ImageLabel", {
		Name = "Logo",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		ScaleType = Enum.ScaleType.Fit,
		ZIndex = 5,
	}, screen)
	if not UI.art(logo, "Logo") then
		-- No art uploaded: the name in heavy display type.
		label(logo, {
			Size = UDim2.fromScale(1, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			FontFace = UI.Fonts.DisplayHeavy,
			TextScaled = true,
			Text = "LAST BLADE",
			TextStrokeTransparency = 0.2,
		})
	end
	local logoScale = UI.new("UIScale", { Scale = 1 }, logo)

	-- A soft ink smudge behind the tagline (the radial glow stretched wide, feathered all
	-- round), so it reads over pale cloud.
	local taglineInk = UI.new("ImageLabel", {
		Name = "TaglineInk",
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Image = Assets.UI.Glow,
		ImageColor3 = T.Ink,
		ImageTransparency = 1,
		ZIndex = 4,
	}, screen)
	local tagline = label(screen, {
		Name = "Tagline",
		FontFace = UI.Fonts.Body,
		Text = Config.Title.Tagline,
		TextTransparency = 0.12,
		TextStrokeTransparency = 0.3,
		ZIndex = 5,
	})

	-- Bottom: the progress line while loading, then the prompt.
	local status = UI.new("Frame", {
		Name = "Status",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(240, 34),
		ZIndex = 5,
	}, screen)
	local track = UI.new("Frame", {
		BackgroundColor3 = T.Bone,
		BackgroundTransparency = 0.82,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.new(1, 0, 0, 2),
		ZIndex = 5,
	}, status)
	local bar = UI.new("Frame", {
		BackgroundColor3 = T.Gold,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
		ZIndex = 6,
	}, track)
	local statusText = label(status, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.new(1, 0, 0, 18),
		FontFace = UI.Fonts.Label,
		TextSize = 13,
		Text = "PREPARING",
		TextTransparency = 0.3,
		ZIndex = 5,
	})

	local prompt = UI.new("Frame", {
		Name = "Prompt",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(420, 30),
		Visible = false,
		ZIndex = 5,
	}, screen)
	local promptText = label(prompt, {
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromScale(0.5, 0.5),
		FontFace = UI.Fonts.Label,
		TextSize = 17,
		Text = string.upper(if touch then "Tap to begin" else "Press any key"),
		TextStrokeTransparency = 0.4,
		TextTransparency = 1,
		ZIndex = 5,
	})
	local rules: { Frame } = {}
	for _, side in { -1, 1 } do
		local rule = UI.new("Frame", {
			BackgroundColor3 = T.Gold,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, side * 128, 0.5, 0),
			Size = UDim2.fromOffset(56, 1),
			ZIndex = 5,
		}, prompt)
		table.insert(rules, rule)
	end

	-- Layout from the viewport: the logo as large as reads well (smaller share on wide
	-- desktops, larger on phones), the tagline under it, the status/prompt near the bottom.
	local function layout()
		local vp = camera.ViewportSize
		local w = math.min(vp.X * 0.4, vp.Y * 0.5 * LOGO_ASPECT, 820)
		local h = w / LOGO_ASPECT
		-- In the sky above the torii, clear of Roblox's top-left buttons.
		local cy = math.max(vp.Y * 0.3, h / 2 + vp.Y * 0.05)
		logo.Size = UDim2.fromOffset(w, h)
		logo.Position = UDim2.fromOffset(vp.X / 2, cy)
		halo.Size = UDim2.fromOffset(w * 1.5, h * 1.35)
		halo.Position = logo.Position
		local small = vp.Y < 500
		tagline.TextSize = if small then 14 else 17
		tagline.Size = UDim2.fromOffset(math.min(vp.X - 32, 900), tagline.TextSize + 8)
		tagline.Position = UDim2.fromOffset(vp.X / 2, cy + h / 2 + (if small then 10 else 18))
		taglineInk.Size = UDim2.fromOffset(math.min(vp.X, tagline.TextSize * 44), tagline.TextSize * 4.4)
		taglineInk.Position = tagline.Position
		local bottom = vp.Y - (if small then 34 else 64)
		status.Position = UDim2.fromOffset(vp.X / 2, bottom)
		prompt.Position = UDim2.fromOffset(vp.X / 2, bottom)
		promptText.TextSize = if small then 15 else 17
	end
	layout()
	local resized = camera:GetPropertyChangedSignal("ViewportSize"):Connect(layout)

	screen.Parent = playerGui

	-- The logo fades in once its image has loaded (never a blank box or a pop).
	logo.ImageTransparency = 1
	tagline.TextTransparency = 1
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync({ logo })
		end)
		TweenService:Create(logo, LOGO_IN, { ImageTransparency = 0 }):Play()
		TweenService:Create(tagline, LOGO_IN, { TextTransparency = 0.12 }):Play()
		TweenService:Create(taglineInk, LOGO_IN, { ImageTransparency = 0 }):Play()
	end)

	-- Hide the game HUD and chat until the player enters.
	local hidden: { ScreenGui } = {}
	for _, gui in playerGui:GetChildren() do
		if
			gui:IsA("ScreenGui")
			and gui ~= screen
			and gui.Enabled
			and (gui.Name == "CombatHUD" or gui.Name == "RoundHUD")
		then
			gui.Enabled = false
			table.insert(hidden, gui)
		end
	end
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, false)
	end)

	-- The shot. The camera is placed at once (under the cover) so the renderer starts on
	-- the terrace's textures while the gate preloads the rest.
	local origin: Vector3 = Config.Lobby.Origin
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = SHOT.fov
	local startedAt = os.clock()
	local function shot(): CFrame
		local t = 0.5
		if not reduced then
			local phase = (os.clock() - startedAt) / DOLLY_PERIOD * math.pi * 2
			t = (1 - math.cos(phase)) / 2 -- eased ping-pong between the two ends
		end
		local eye = origin + SHOT.from:Lerp(SHOT.to, t)
		local target = origin + SHOT.lookFrom:Lerp(SHOT.lookTo, t)
		return CFrame.lookAt(eye, target)
	end
	camera.CFrame = shot()
	local petalPart, followPetals = petals(camera, touch or reduced)
	local depth: DepthOfFieldEffect? = nil
	if not touch then
		-- A touch of depth: the petals nearest the lens go soft. Desktop only.
		local d = Instance.new("DepthOfFieldEffect")
		d.Name = "TitleDepth"
		d.FocusDistance = 60
		d.InFocusRadius = 50
		d.NearIntensity = 0.45
		d.FarIntensity = 0.05
		d.Parent = Lighting
		depth = d
	end
	RunService:BindToRenderStep("TitleOrbit", Enum.RenderPriority.Camera.Value + 2, function()
		camera.CFrame = shot()
		followPetals()
	end)

	-- The gate. Progress eases toward its target so the line glides rather than jumps.
	local target, shown = 0, 0
	local worldHere = false
	local progressConn = RunService.Heartbeat:Connect(function(dt)
		shown += (target - shown) * math.min(1, dt * 6)
		bar.Size = UDim2.fromScale(shown, 1)
	end)
	local function liftCover()
		if worldHere then
			return
		end
		worldHere = true
		TweenService:Create(cover, FADE_IN, { BackgroundTransparency = 1 }):Play()
	end
	local gateDone = false
	task.spawn(function()
		-- Protected: whatever goes wrong in the gate, the player still gets in.
		local ok, result = pcall(WorldGate.run, function(p: number, line: string)
			target = math.max(target, p)
			statusText.Text = string.upper(line)
			if line ~= "Raising the island" then
				liftCover() -- the world is here: show it while the assets finish
			end
		end)
		if not ok then
			warn("[TitleScreen] loading gate failed:", result)
		end
		liftCover()
		-- The character too, so entering lands on the player, not on an empty spawn.
		local waited = os.clock()
		while not (player.Character and player.Character:FindFirstChild("HumanoidRootPart")) do
			if os.clock() - waited > 10 then
				break
			end
			task.wait(0.1)
		end
		WorldGate.stats.result = if ok then result else "error"
		WorldGate.stats.readyAt = os.clock() - startedAt
		-- For playtests (local only): how long the gate took and what it loaded.
		local st = WorldGate.stats
		player:SetAttribute(
			"TitleGate",
			string.format(
				"%s ready=%.1fs assets=%s/%s preload=%.1fs",
				tostring(st.result),
				st.readyAt,
				tostring(st.loaded),
				tostring(st.assets),
				tonumber(st.preloadSeconds) or -1
			)
		)
		gateDone = true
	end)

	-- Input: a press before the gate opens is remembered, so an impatient click enters as
	-- soon as the world is ready instead of being ignored.
	local pressed = false
	local connection = UserInputService.InputBegan:Connect(function(input)
		local kind = input.UserInputType
		if
			kind == Enum.UserInputType.Keyboard
			or kind == Enum.UserInputType.MouseButton1
			or kind == Enum.UserInputType.Touch
			or kind == Enum.UserInputType.Gamepad1
		then
			pressed = true
		end
	end)

	while not gateDone and os.clock() - startedAt < 45 do -- a hard cap, whatever happens
		task.wait()
	end
	liftCover()
	-- Ready: the status line gives way to the prompt.
	TweenService:Create(statusText, UI.Motion.Reveal, { TextTransparency = 1 }):Play()
	TweenService:Create(track, UI.Motion.Reveal, { BackgroundTransparency = 1 }):Play()
	TweenService:Create(bar, UI.Motion.Reveal, { BackgroundTransparency = 1 }):Play()
	prompt.Visible = true
	TweenService:Create(promptText, UI.Motion.Reveal, { TextTransparency = 0 }):Play()
	for _, rule in rules do
		TweenService:Create(rule, UI.Motion.Reveal, { BackgroundTransparency = 0.35 }):Play()
	end
	if not reduced then
		task.delay(0.5, function()
			if promptText.Parent then
				TweenService:Create(
					promptText,
					TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
					{ TextTransparency = 0.55 }
				):Play()
			end
		end)
	end
	-- A press during loading still lets the logo breathe a moment before entering.
	if pressed then
		task.wait(if worldHere then 0.6 else 0)
	end
	while not pressed do
		task.wait()
	end
	connection:Disconnect()

	-- Enter: the logo settles back, the screen dips to ink, and comes up on the player.
	TweenService:Create(logoScale, DIP, { Scale = 0.96 }):Play()
	TweenService:Create(cover, DIP, { BackgroundTransparency = 0 }):Play()
	task.wait(DIP.Time)
	RunService:UnbindFromRenderStep("TitleOrbit")
	progressConn:Disconnect()
	resized:Disconnect()
	petalPart:Destroy()
	if depth then
		depth:Destroy()
	end
	camera.FieldOfView = 70
	camera.CameraType = Enum.CameraType.Custom
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		camera.CameraSubject = humanoid
	end
	-- Start the follow camera behind the player, looking the way they face (up the stair),
	-- not wherever the title shot was pointing.
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		local back = -root.CFrame.LookVector
		camera.CFrame =
			CFrame.lookAt(root.Position + back * 12 + Vector3.new(0, 4, 0), root.Position + Vector3.new(0, 1.5, 0))
	end
	for _, child in screen:GetChildren() do
		if child ~= cover and child:IsA("GuiObject") then
			child.Visible = false
		end
	end
	vignette:Destroy()
	for _, gui in hidden do
		gui.Enabled = true
	end
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, true)
	end)
	task.wait() -- one frame for the follow camera to settle behind the character
	TweenService:Create(cover, LIFT, { BackgroundTransparency = 1 }):Play()
	task.delay(LIFT.Time, function()
		screen:Destroy()
	end)
end

return TitleScreen
