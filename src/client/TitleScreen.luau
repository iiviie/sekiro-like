--!strict
-- Title card shown on join: a slow, low dolly across the courtyard toward the shrine and
-- pagoda against the sunset, letterboxed, behind the game's name, until the player clicks
-- or presses a key. Cheap: one ScreenGui and a camera path that stops the moment you enter.

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local Palette = require(ReplicatedStorage.Shared.Palette)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer

local PARCHMENT = UI.Theme.Bone
local GOLD = UI.Theme.Gold

-- The camera sways slowly side to side at about head height in front of the duelling
-- circle, always framing the shrine hall with the pagoda rising behind it.
local DOLLY_FROM = Vector3.new(-22, 6.5, 40)
local DOLLY_TO = Vector3.new(22, 9, 26)
local DOLLY_PERIOD = 40 -- seconds for one full sway
local LOOK_AT = Vector3.new(0, 11, -60)
local LETTERBOX = 0.1 -- each bar's share of the screen height

local TitleScreen = {}

local function text(parent: Instance, value: string, size: number, color: Color3, y: number, face: Font): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.new(0.5, 0, 0.5, y)
	label.Size = UDim2.fromOffset(1000, size + 16)
	label.FontFace = face
	label.TextSize = size
	label.TextColor3 = color
	label.Text = value
	label.TextStrokeColor3 = UI.Theme.Ink
	label.TextStrokeTransparency = 0.6
	label.Parent = parent
	return label
end

-- Shows the title card and yields until the player dismisses it.
function TitleScreen.show()
	local screen = Instance.new("ScreenGui")
	screen.Name = "TitleScreen"
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 100
	screen.ResetOnSpawn = false

	local group = Instance.new("CanvasGroup")
	group.Size = UDim2.fromScale(1, 1)
	group.BackgroundColor3 = Palette.Ink
	group.BackgroundTransparency = 0.6
	group.Parent = screen

	-- Darkest behind the text in the middle, fading out to the sides so the scene stays
	-- visible around the title.
	local vignette = Instance.new("UIGradient")
	vignette.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(0.35, 0.1),
		NumberSequenceKeypoint.new(0.65, 0.1),
		NumberSequenceKeypoint.new(1, 0.5),
	})
	vignette.Parent = group

	-- Cinema letterbox; inside the group so it fades out with the title.
	for _, top in { true, false } do
		local bar = Instance.new("Frame")
		bar.AnchorPoint = Vector2.new(0, if top then 0 else 1)
		bar.Position = UDim2.fromScale(0, if top then 0 else 1)
		bar.Size = UDim2.fromScale(1, LETTERBOX)
		bar.BackgroundColor3 = Color3.new(0, 0, 0)
		bar.BorderSizePixel = 0
		bar.Parent = group
	end

	-- The logo lockup sits in the sky, above the shrine roof: the wordmark in heavy
	-- Merriweather, tracked, over a crimson brush swipe, with the 最後の刃 seal (an image,
	-- when its art is uploaded) standing beside it.
	local TOP = -130
	local swipe = UI.brush(group, "swipe", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, TOP - 30),
		Size = UDim2.fromOffset(760, 130),
		color = UI.Theme.LacquerRed,
		ImageTransparency = 0.1,
	})
	swipe.ZIndex = 1
	local wordmark = text(group, UI.tracked(Config.Title.Name), 66, PARCHMENT, TOP - 40, UI.Fonts.DisplayHeavy)
	wordmark.ZIndex = 2
	wordmark.TextStrokeTransparency = 0.4
	local seal = Instance.new("ImageLabel")
	seal.Name = "Seal"
	seal.BackgroundTransparency = 1
	seal.AnchorPoint = Vector2.new(0, 0.5)
	seal.Position = UDim2.new(0.5, 400, 0.5, TOP - 10)
	seal.Size = UDim2.fromOffset(62, 182)
	seal.ScaleType = Enum.ScaleType.Fit
	seal.ImageColor3 = UI.Theme.Crimson
	seal.ZIndex = 2
	seal.Parent = group
	if not UI.art(seal, "KanjiTitle") then
		seal:Destroy()
	end
	for _, side in { -1, 1 } do
		local rule = Instance.new("Frame")
		rule.AnchorPoint = Vector2.new(0.5, 0.5)
		rule.Position = UDim2.new(0.5, side * 210, 0.5, TOP + 26)
		rule.Size = UDim2.fromOffset(240, 1)
		rule.BackgroundColor3 = GOLD
		rule.BackgroundTransparency = 0.3
		rule.BorderSizePixel = 0
		rule.Parent = group
	end
	local diamond = Instance.new("Frame")
	diamond.AnchorPoint = Vector2.new(0.5, 0.5)
	diamond.Position = UDim2.new(0.5, 0, 0.5, TOP + 26)
	diamond.Size = UDim2.fromOffset(9, 9)
	diamond.Rotation = 45
	diamond.BackgroundColor3 = UI.Theme.Ink
	diamond.BorderSizePixel = 0
	diamond.Parent = group
	UI.new("UIStroke", { Color = GOLD, Thickness = 1 }, diamond)
	local tagline = text(group, Config.Title.Tagline, 22, PARCHMENT, TOP + 58, UI.Fonts.Display)
	tagline.TextTransparency = 0.1
	local prompt = text(
		group,
		string.upper(if UI.isTouch() then "Tap to begin" else "Click or press any key"),
		18,
		PARCHMENT,
		300,
		UI.Fonts.Label
	)
	prompt.TextStrokeTransparency = 0.35
	if not UI.reducedMotion() then
		TweenService:Create(prompt, UI.Motion.Pulse, { TextTransparency = 0.7 }):Play()
	end

	screen.Parent = player:WaitForChild("PlayerGui")

	-- Hide the game HUD and chat until the player enters.
	local playerGui = player:WaitForChild("PlayerGui")
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

	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	local startedAt = os.clock()
	camera.FieldOfView = 50 -- a longer lens flattens the layers of wall, shrine and mountains
	RunService:BindToRenderStep("TitleOrbit", Enum.RenderPriority.Camera.Value + 2, function()
		local phase = (os.clock() - startedAt) / DOLLY_PERIOD * math.pi * 2
		local t = (1 - math.cos(phase)) / 2 -- eased ping-pong between the two ends
		camera.CFrame = CFrame.lookAt(DOLLY_FROM:Lerp(DOLLY_TO, t), LOOK_AT)
	end)

	local dismissed = Instance.new("BindableEvent")
	local connection = UserInputService.InputBegan:Connect(function(input)
		local kind = input.UserInputType
		if
			kind == Enum.UserInputType.Keyboard
			or kind == Enum.UserInputType.MouseButton1
			or kind == Enum.UserInputType.Touch
			or kind == Enum.UserInputType.Gamepad1
		then
			dismissed:Fire()
		end
	end)
	dismissed.Event:Wait()
	connection:Disconnect()
	dismissed:Destroy()

	TweenService:Create(group, TweenInfo.new(0.7), { GroupTransparency = 1 }):Play()
	task.wait(0.7)
	RunService:UnbindFromRenderStep("TitleOrbit")
	camera.FieldOfView = 70
	camera.CameraType = Enum.CameraType.Custom
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		camera.CameraSubject = humanoid
	end
	screen:Destroy()
	for _, gui in hidden do
		gui.Enabled = true
	end
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, true)
	end)
end

return TitleScreen
