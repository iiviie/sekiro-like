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

local player = Players.LocalPlayer

local FONT = Enum.Font.Garamond
local PARCHMENT = Palette.Parchment
local BRONZE = Palette.Bronze
local CRIMSON = Palette.Crimson

-- The camera sways slowly side to side at about head height in front of the duelling
-- circle, always framing the shrine hall with the pagoda rising behind it.
local DOLLY_FROM = Vector3.new(-22, 6.5, 40)
local DOLLY_TO = Vector3.new(22, 9, 26)
local DOLLY_PERIOD = 40 -- seconds for one full sway
local LOOK_AT = Vector3.new(0, 11, -60)
local LETTERBOX = 0.1 -- each bar's share of the screen height

local TitleScreen = {}

local function text(parent: Instance, value: string, size: number, color: Color3, y: number): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.new(0.5, 0, 0.5, y)
	label.Size = UDim2.fromOffset(900, size + 12)
	label.Font = FONT
	label.TextSize = size
	label.TextColor3 = color
	label.Text = value
	label.TextStrokeTransparency = 0.7
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

	-- The text sits in the sky, above the shrine roof.
	local TOP = -130
	text(group, Config.Title.Kanji, 46, CRIMSON, TOP - 118)
	text(group, Config.Title.Name, 88, PARCHMENT, TOP - 46)
	for _, side in { -1, 1 } do
		local rule = Instance.new("Frame")
		rule.AnchorPoint = Vector2.new(0.5, 0.5)
		rule.Position = UDim2.new(0.5, side * 210, 0.5, TOP + 18)
		rule.Size = UDim2.fromOffset(240, 1)
		rule.BackgroundColor3 = BRONZE
		rule.BorderSizePixel = 0
		rule.Parent = group
	end
	local tagline = text(group, Config.Title.Tagline, 22, PARCHMENT, TOP + 46)
	tagline.TextTransparency = 0.2
	local prompt = text(group, "Click or press any key to enter", 20, PARCHMENT, 300)
	TweenService:Create(
		prompt,
		TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ TextTransparency = 0.75 }
	):Play()

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
