--!strict
-- Title card shown on join: the camera drifts around the courtyard behind the game's
-- name until the player clicks or presses a key. Cheap: one ScreenGui and a camera
-- orbit that stops the moment you enter.

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)

local player = Players.LocalPlayer

local FONT = Enum.Font.Garamond
local PARCHMENT = Color3.fromRGB(232, 222, 200)
local BRONZE = Color3.fromRGB(150, 122, 82)
local CRIMSON = Color3.fromRGB(190, 34, 30)

local ORBIT_CENTER = Vector3.new(0, 6, 0)
local ORBIT_RADIUS = 95
local ORBIT_HEIGHT = 34
local ORBIT_SPEED = 0.05 -- radians per second

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
	group.BackgroundColor3 = Color3.new(0, 0, 0)
	group.BackgroundTransparency = 0.45
	group.Parent = screen

	-- Darker at the edges, so the title sits in a pool of light.
	local vignette = Instance.new("UIGradient")
	vignette.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.3, 0.55),
		NumberSequenceKeypoint.new(0.7, 0.55),
		NumberSequenceKeypoint.new(1, 0),
	})
	vignette.Parent = group

	text(group, Config.Title.Kanji, 46, CRIMSON, -118)
	text(group, Config.Title.Name, 88, PARCHMENT, -46)
	for _, side in { -1, 1 } do
		local rule = Instance.new("Frame")
		rule.AnchorPoint = Vector2.new(0.5, 0.5)
		rule.Position = UDim2.new(0.5, side * 210, 0.5, 18)
		rule.Size = UDim2.fromOffset(240, 1)
		rule.BackgroundColor3 = BRONZE
		rule.BorderSizePixel = 0
		rule.Parent = group
	end
	local tagline = text(group, Config.Title.Tagline, 22, PARCHMENT, 46)
	tagline.TextTransparency = 0.2
	local prompt = text(group, "Click or press any key to enter", 20, PARCHMENT, 170)
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
	local angle = math.pi * 0.5
	RunService:BindToRenderStep("TitleOrbit", Enum.RenderPriority.Camera.Value + 2, function(dt)
		angle += ORBIT_SPEED * dt
		local eye = ORBIT_CENTER
			+ Vector3.new(math.cos(angle) * ORBIT_RADIUS, ORBIT_HEIGHT, math.sin(angle) * ORBIT_RADIUS)
		camera.CFrame = CFrame.lookAt(eye, ORBIT_CENTER)
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
