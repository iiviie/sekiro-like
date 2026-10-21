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
	Dim = Color3.fromRGB(140, 130, 120), -- disabled / not-yet text
	Selected = Color3.fromRGB(64, 46, 36), -- a picked card
	Muted = Color3.fromRGB(28, 24, 27), -- a card for something not owned
	Danger = Color3.fromRGB(240, 150, 120), -- warnings (save failed)
	Touch = 60, -- touch target height at scale 1 (large panels scale to >= 0.8 on a phone)
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
	-- The resting colour lives in an attribute, so a button recoloured later (PLAY turning
	-- QUEUED) keeps its new colour when the mouse leaves; see UI.setButtonColor.
	button:SetAttribute("RestColor", button.BackgroundColor3)
	local function rest(): Color3
		local color = button:GetAttribute("RestColor")
		return if typeof(color) == "Color3" then color else button.BackgroundColor3
	end
	button.MouseEnter:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.12), { BackgroundColor3 = rest():Lerp(Color3.new(1, 1, 1), 0.12) })
			:Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.12), { BackgroundColor3 = rest() }):Play()
	end)
	return button
end

-- Recolour a button and remember the new colour as its resting state for hover.
function UI.setButtonColor(button: TextButton, color: Color3)
	button:SetAttribute("RestColor", color)
	button.BackgroundColor3 = color
end

function UI.tween(instance: Instance, time: number, goal: { [string]: any })
	TweenService:Create(instance, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal):Play()
end

-- The lobby HUD's own scale on a screen this size (LobbyHUD's "Fit" UIScale).
function UI.lobbyScale(viewport: Vector2): number
	return math.clamp(viewport.X / 1100, 0.6, 1)
end

-- Keeps a lobby window (`height` px tall at scale 1) above the PLAY button and nav bar on
-- any screen: its bottom sits just over them and it shrinks to the height that's left.
function UI.fitAboveNav(window: GuiObject, height: number)
	local scale = UI.new("UIScale", { Name = "FitAboveNav" }, window)
	local camera = workspace.CurrentCamera
	local function refit()
		local size = camera.ViewportSize
		local reserve = math.floor(200 * UI.lobbyScale(size))
		window.AnchorPoint = Vector2.new(0.5, 1)
		window.Position = UDim2.new(0.5, 0, 1, -reserve)
		scale.Scale = math.clamp((size.Y - reserve - 44) / height, 0.45, 1)
	end
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(refit)
	refit()
end

-- 1,234,567
function UI.number(n: number): string
	local s = tostring(math.floor(n))
	local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (formatted:gsub("^,", ""))
end

---------------------------------------------------------------------------------------
-- Shared widgets for the large panels (Store, Locker): action buttons, notes and headings
-- for scrolling lists, balance pills, tab rows, dots, and modal sheets.

-- A button styled by whether it can be pressed now (crimson when live, quiet when not).
function UI.actionButton(parent: Instance, props: { [string]: any }, live: boolean): TextButton
	props.BackgroundColor3 = props.BackgroundColor3 or (if live then UI.Crimson else UI.Panel)
	props.TextColor3 = props.TextColor3 or (if live then UI.Parchment else UI.Dim)
	props.TextSize = props.TextSize or 18
	local button = UI.button(props, parent)
	if not live then
		UI.stroke(button, UI.Bronze, 1, 0.5)
	end
	return button
end

-- A quiet wrapped line in a list layout.
function UI.note(parent: Instance, text: string, order: number, height: number?): TextLabel
	return UI.text({
		Name = "Note",
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, height or 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		TextSize = 15,
		TextTransparency = 0.25,
		Text = text,
	}, parent)
end

-- A gold section heading in a list layout.
function UI.heading(parent: Instance, text: string, order: number): TextLabel
	return UI.text({
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 28),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = UI.Display,
		TextSize = 24,
		TextColor3 = UI.Gold,
		Text = text,
	}, parent)
end

-- A small crimson "something new" dot in a corner of `parent`.
function UI.dot(parent: Instance, size: number?, color: Color3?): Frame
	local s = size or 14
	local dot = UI.new("Frame", {
		Name = "Dot",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -s / 2 - 1, 0, s / 2 + 1),
		Size = UDim2.fromOffset(s, s),
		BackgroundColor3 = color or UI.Crimson,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, parent)
	UI.corner(dot, UDim.new(1, 0))
	UI.stroke(dot, UI.Parchment, 1.5, 0)
	return dot
end

---------------------------------------------------------------------------------------
-- A modal sheet over a panel window (parented to the window, so a panel redraw that clears
-- its body leaves it alone): title, close button, content; UI.confirm builds on it.

local openSheet: Frame? = nil

function UI.closeSheet()
	if openSheet then
		openSheet:Destroy()
		openSheet = nil
	end
end

-- Opens a sheet over `window`; `build(content)` fills it. Returns the content frame.
function UI.sheet(window: GuiObject, title: string, build: (Frame) -> (), size: Vector2?): Frame
	UI.closeSheet()
	local dims = size or Vector2.new(560, 320)
	local shade = UI.new("TextButton", {
		Name = "Sheet",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.4,
		Text = "",
		AutoButtonColor = false,
		ZIndex = 20,
	}, window)
	UI.corner(shade)
	local card = UI.panel({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(dims.X, dims.Y),
		ZIndex = 21,
	}, shade)
	UI.text({
		Position = UDim2.fromOffset(20, 10),
		Size = UDim2.new(1, -90, 0, 34),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = UI.Display,
		TextSize = 28,
		Text = title,
		ZIndex = 22,
	}, card)
	local close = UI.button({
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 8),
		Size = UDim2.fromOffset(UI.Touch, 44),
		Text = "X",
		TextSize = 20,
		BackgroundColor3 = UI.PanelLight,
		ZIndex = 22,
	}, card)
	close.Activated:Connect(UI.closeSheet)
	local content = UI.new("Frame", {
		Name = "Content",
		Position = UDim2.fromOffset(20, 58),
		Size = UDim2.new(1, -40, 1, -70),
		BackgroundTransparency = 1,
		ZIndex = 22,
	}, card)
	openSheet = shade :: any
	build(content)
	-- Everything inside sits above the shade.
	for _, child in content:GetDescendants() do
		if child:IsA("GuiObject") then
			child.ZIndex = math.max(child.ZIndex, 22)
		end
	end
	return content
end

-- "Spend 400 gems on Ink Brush?" with a confirm and a cancel.
function UI.confirm(window: GuiObject, title: string, text: string, yes: string, onYes: () -> ())
	UI.sheet(window, title, function(content)
		UI.text({
			Size = UDim2.new(1, 0, 1, -UI.Touch - 12),
			TextWrapped = true,
			TextSize = 20,
			Text = text,
		}, content)
		local ok = UI.button({
			Name = "Confirm",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.fromScale(1, 1),
			Size = UDim2.new(0.5, -6, 0, UI.Touch),
			Text = yes,
			BackgroundColor3 = UI.Crimson,
		}, content)
		local cancel = UI.button({
			Name = "Cancel",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(0.5, -6, 0, UI.Touch),
			Text = "Not now",
		}, content)
		UI.stroke(cancel)
		ok.Activated:Connect(function()
			UI.closeSheet()
			onYes()
		end)
		cancel.Activated:Connect(UI.closeSheet)
	end, Vector2.new(480, 240))
end

-- A small balance chip ("[gem] 1,240") for a panel header.
function UI.pill(parent: Instance, image: string, value: number, color: Color3, order: number)
	local chip = UI.new("Frame", {
		Size = UDim2.fromOffset(0, 34),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = order,
		BackgroundColor3 = UI.Ink,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
	}, parent)
	UI.corner(chip, UDim.new(1, 0))
	UI.new("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 12) }, chip)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 4),
	}, chip)
	UI.new("ImageLabel", {
		Size = UDim2.fromOffset(32, 32),
		BackgroundTransparency = 1,
		Image = image,
	}, chip)
	UI.text({
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = UI.Bold,
		TextSize = 18,
		TextColor3 = color,
		Text = UI.number(value),
	}, chip)
end

-- A scrolling list filling `parent` (vertical list layout).
function UI.scroll(parent: Instance, padding: number?): ScrollingFrame
	local list = UI.new("ScrollingFrame", {
		Name = "List",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = UI.Bronze,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, parent)
	UI.new("UIListLayout", { Padding = UDim.new(0, padding or 10), SortOrder = Enum.SortOrder.LayoutOrder }, list)
	UI.new("UIPadding", { PaddingRight = UDim.new(0, 10), PaddingBottom = UDim.new(0, 8) }, list)
	return list
end

-- A row of tab buttons; `selected` is highlighted; `onPick(id)` on press. Each tab may
-- carry a dot (something new inside).
function UI.tabs(
	parent: Instance,
	tabs: { { id: string, label: string, dot: boolean? } },
	selected: string,
	onPick: (string) -> (),
	height: number?
): Frame
	local row = UI.new("Frame", {
		Name = "Tabs",
		Size = UDim2.new(1, 0, 0, height or 48),
		BackgroundTransparency = 1,
	}, parent)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, row)
	for i, tab in tabs do
		local on = tab.id == selected
		local button = UI.button({
			Name = tab.id,
			LayoutOrder = i,
			Size = UDim2.new(1 / #tabs, -8 * (#tabs - 1) / #tabs, 1, 0),
			Text = tab.label,
			TextSize = 18,
			Font = if on then UI.Bold else UI.Body,
			BackgroundColor3 = if on then UI.Crimson else UI.PanelLight,
			TextColor3 = if on then UI.Parchment else Color3.fromRGB(200, 190, 172),
		}, row)
		if not on then
			UI.stroke(button, UI.Bronze, 1, 0.5)
		end
		if tab.dot then
			UI.dot(button, nil, if on then UI.Gold else UI.Crimson)
		end
		button.Activated:Connect(function()
			onPick(tab.id)
		end)
	end
	return row
end

return UI
