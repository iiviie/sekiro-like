--!strict
-- One small style kit for every menu, so the lobby UI speaks the same visual language as
-- the world: ink panels, parchment text, bronze rules, crimson for action. Garamond for
-- display text, Source Sans for body and numbers; one corner radius and stroke weight.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Palette = require(ReplicatedStorage.Shared.Palette)

local UI = {
	Display = Enum.Font.Garamond,
	Body = Enum.Font.SourceSansSemibold,
	Bold = Enum.Font.SourceSansBold,
	Ink = Palette.Ink,
	Panel = Color3.fromRGB(22, 19, 22),
	PanelLight = Color3.fromRGB(38, 33, 36),
	Parchment = Palette.Parchment,
	Bronze = Palette.Bronze,
	Crimson = Palette.Crimson,
	Gold = Color3.fromRGB(232, 190, 92),
	Jade = Color3.fromRGB(96, 176, 132),
	Corner = UDim.new(0, 6),
}

function UI.new(className: string, props: { [string]: any }, parent: Instance?): any
	local instance = Instance.new(className)
	for key, value in props do
		(instance :: any)[key] = value
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

function UI.corner(parent: Instance, radius: UDim?)
	UI.new("UICorner", { CornerRadius = radius or UI.Corner }, parent)
end

function UI.stroke(parent: Instance, color: Color3?, thickness: number?, transparency: number?)
	UI.new("UIStroke", {
		Color = color or UI.Bronze,
		Thickness = thickness or 1.5,
		Transparency = transparency or 0.2,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

function UI.panel(props: { [string]: any }, parent: Instance?): Frame
	props.BackgroundColor3 = props.BackgroundColor3 or UI.Panel
	props.BackgroundTransparency = props.BackgroundTransparency or 0.08
	props.BorderSizePixel = 0
	local frame = UI.new("Frame", props, parent)
	UI.corner(frame)
	UI.stroke(frame)
	return frame
end

function UI.text(props: { [string]: any }, parent: Instance?): TextLabel
	props.BackgroundTransparency = 1
	props.Font = props.Font or UI.Body
	props.TextColor3 = props.TextColor3 or UI.Parchment
	props.TextSize = props.TextSize or 18
	return UI.new("TextLabel", props, parent)
end

function UI.button(props: { [string]: any }, parent: Instance?): TextButton
	props.BackgroundColor3 = props.BackgroundColor3 or UI.PanelLight
	props.BorderSizePixel = 0
	props.AutoButtonColor = false
	props.Font = props.Font or UI.Bold
	props.TextColor3 = props.TextColor3 or UI.Parchment
	props.TextSize = props.TextSize or 18
	local button = UI.new("TextButton", props, parent)
	UI.corner(button)
	local base = button.BackgroundColor3
	button.MouseEnter:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.12), { BackgroundColor3 = base:Lerp(Color3.new(1, 1, 1), 0.12) })
			:Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.12), { BackgroundColor3 = base }):Play()
	end)
	return button
end

-- Recolour a button and remember the new colour as its resting state for hover.
function UI.setButtonColor(button: TextButton, color: Color3)
	button.BackgroundColor3 = color
end

function UI.tween(instance: Instance, time: number, goal: { [string]: any })
	TweenService:Create(instance, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal):Play()
end

-- 1,234,567
function UI.number(n: number): string
	local s = tostring(math.floor(n))
	local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (formatted:gsub("^,", ""))
end

return UI
