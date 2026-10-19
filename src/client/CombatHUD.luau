--!strict
-- Posture and health bars: a Sekiro-style posture bar for you at the bottom of the
-- screen, and small overhead bars for everyone else. Reads replicated attributes only.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Types = require(ReplicatedStorage.Shared.Types)

local player = Players.LocalPlayer

local POSTURE_LOW = Color3.fromRGB(255, 200, 80)
local POSTURE_HIGH = Color3.fromRGB(255, 70, 30)
local POSTURE_BROKEN = Color3.fromRGB(255, 245, 200)
local HEALTH = Color3.fromRGB(200, 40, 40)
local TRACK = Color3.fromRGB(20, 18, 16)

local CONTROLS =
	"LMB / R1  slash      F / L1  deflect (tap) · guard (hold)      E / Y  perilous thrust      Q / B  dodge"

type Bars = { posture: Frame, health: Frame }

local CombatHUD = {}

local overheads: { [Model]: { gui: BillboardGui, bars: Bars } } = {}

local function bar(parent: Instance, size: UDim2, position: UDim2, color: Color3, centered: boolean): Frame
	local track = Instance.new("Frame")
	track.BackgroundColor3 = TRACK
	track.BackgroundTransparency = 0.25
	track.BorderSizePixel = 0
	track.Size = size
	track.Position = position
	track.AnchorPoint = Vector2.new(0.5, 0)
	track.Parent = parent

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	-- Posture grows outward from the centre, like Sekiro; health drains from the right.
	fill.AnchorPoint = if centered then Vector2.new(0.5, 0.5) else Vector2.new(0, 0.5)
	fill.Position = if centered then UDim2.fromScale(0.5, 0.5) else UDim2.fromScale(0, 0.5)
	fill.Size = UDim2.fromScale(if centered then 0 else 1, 1)
	fill.Parent = track
	return fill
end

local function update(model: Model, bars: Bars)
	local max = model:GetAttribute("PostureMax")
	local posture = model:GetAttribute("Posture")
	if typeof(max) == "number" and typeof(posture) == "number" and max > 0 then
		local ratio = math.clamp(posture / max, 0, 1)
		bars.posture.Size = UDim2.fromScale(ratio, 1)
		bars.posture.BackgroundColor3 = if model:GetAttribute("CombatState") == "Broken"
			then POSTURE_BROKEN
			else POSTURE_LOW:Lerp(POSTURE_HIGH, ratio)
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.MaxHealth > 0 then
		bars.health.Size = UDim2.fromScale(math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1), 1)
	end
end

local function buildScreen(): Bars
	local screen = Instance.new("ScreenGui")
	screen.Name = "CombatHUD"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true

	local posture = bar(screen, UDim2.fromOffset(380, 10), UDim2.new(0.5, 0, 1, -70), POSTURE_LOW, true)
	local health = bar(screen, UDim2.fromOffset(260, 8), UDim2.new(0.5, 0, 1, -50), HEALTH, false)

	local controls = Instance.new("TextLabel")
	controls.BackgroundTransparency = 1
	controls.AnchorPoint = Vector2.new(0.5, 1)
	controls.Position = UDim2.new(0.5, 0, 1, -16)
	controls.Size = UDim2.fromOffset(760, 20)
	controls.Font = Enum.Font.GothamMedium
	controls.Text = CONTROLS
	controls.TextColor3 = Color3.fromRGB(235, 225, 210)
	controls.TextSize = 13
	controls.TextStrokeTransparency = 0.6
	controls.Parent = screen

	screen.Parent = player:WaitForChild("PlayerGui")
	return { posture = posture, health = health }
end

local function addOverhead(instance: Instance)
	if not instance:IsA("Model") or instance == player.Character or overheads[instance] then
		return
	end
	local model = instance
	local head = model:FindFirstChild("Head") or model:WaitForChild("Head", 5)
	if not head or not head:IsA("BasePart") or not model.Parent then
		return
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "CombatOverhead"
	gui.Adornee = head
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(120, 16)
	gui.StudsOffset = Vector3.new(0, 2.4, 0)
	gui.MaxDistance = 80

	local posture = bar(gui, UDim2.new(1, 0, 0, 6), UDim2.fromScale(0.5, 0), POSTURE_LOW, true)
	local health = bar(gui, UDim2.new(0.8, 0, 0, 4), UDim2.new(0.5, 0, 0, 9), HEALTH, false)
	gui.Parent = player:WaitForChild("PlayerGui")

	overheads[model] = { gui = gui, bars = { posture = posture, health = health } }
end

local function removeOverhead(instance: Instance)
	local entry = overheads[instance :: Model]
	if entry then
		entry.gui:Destroy()
		overheads[instance :: Model] = nil
	end
end

function CombatHUD.start()
	local own = buildScreen()

	CollectionService:GetInstanceAddedSignal(Types.Tag):Connect(addOverhead)
	CollectionService:GetInstanceRemovedSignal(Types.Tag):Connect(removeOverhead)
	for _, instance in CollectionService:GetTagged(Types.Tag) do
		task.spawn(addOverhead, instance)
	end

	RunService.RenderStepped:Connect(function()
		local character = player.Character
		if character then
			update(character, own)
		end
		for model, entry in overheads do
			if not model.Parent or model:GetAttribute("CombatState") == "Dead" then
				removeOverhead(model)
			else
				update(model, entry.bars)
			end
		end
	end)
end

return CombatHUD
