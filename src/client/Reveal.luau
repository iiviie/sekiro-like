--!strict
-- The Shrine reveal (UI style guide 11.1): the omikuji box drops in and shakes, a fortune
-- stick slides out with its tip already painted the true best rarity of the result, then
-- the paper slip unrolls with the item (one draw) or a grid of cards flips over, lowest
-- rarity first and the best last (several draws). A tap after 0.4 s skips to the end;
-- reduced motion jumps straight there. The colour never lies: the stick's tip is the best
-- result, there are no near-misses.
--
-- Reveal.play(results, opts) with ShopService outcomes ({ kind, id, amount, rarity, dup,
-- shards, pity }); opts = { title?, again = { label, variant?, run }?, onDone? }.
--
-- A purchase uses the same stage without the box (`gift = true`): nothing random happened,
-- so there's no stick and no flip, just the title ("Thank you"), what you got popping in
-- (a slip for one thing, cards for several), a `note` line and an optional `primary` action
-- ("Equip it", "Open the Pass") beside Done.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(ReplicatedStorage.Shared.Assets)
local Catalog = require(ReplicatedStorage.Shared.Catalog)
local Text = require(ReplicatedStorage.Shared.Text)
local StoreUI = require(script.Parent.StoreUI)
local UI = require(script.Parent.UI)

local T = UI.Theme
local ICONS = Assets.Icons :: any
local player = Players.LocalPlayer

local Reveal = {}

export type Outcome = { [string]: any }
export type Options = {
	title: string?,
	again: { label: string, variant: string?, run: () -> () }?,
	onDone: (() -> ())?,
	gift: boolean?, -- a purchase: no box, no stick, no card backs
	note: string?, -- a line under the result
	primary: { label: string, variant: string?, run: () -> () }?, -- beside Done (gift)
}

local RANK = { common = 1, uncommon = 2, rare = 3, epic = 4, legendary = 5, mythic = 6 }

local CURRENCY_ICON: { [string]: string } = {
	Coins = ICONS.Coin,
	Gems = ICONS.Gem,
	Whetstones = ICONS.Whetstone or ICONS.Skin,
	Shards = ICONS.Shard or ICONS.Gem,
}

local function rankOf(outcome: Outcome): number
	return RANK[outcome.rarity or "common"] or 1
end

local function nameOf(outcome: Outcome): string
	if outcome.kind == "item" then
		local item = Catalog.get(outcome.id)
		return if item then item.name else tostring(outcome.id)
	end
	local amount = outcome.amount or 0
	return Text.currency(amount, tostring(outcome.kind))
end

-- The art of one outcome inside `holder`.
local function art(holder: Frame, outcome: Outcome)
	local item = outcome.kind == "item" and Catalog.get(outcome.id) or nil
	if item then
		StoreUI.thumb(holder, item)
	else
		UI.new("ImageLabel", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.86, 0.86),
			BackgroundTransparency = 1,
			Image = CURRENCY_ICON[outcome.kind] or ICONS.Rewards,
			ScaleType = Enum.ScaleType.Fit,
		}, holder)
	end
end

local function stinger(rank: number)
	if rank >= 5 then
		UI.sound("RevealLegendary")
	elseif rank >= 3 then
		UI.sound("RevealRare")
	else
		UI.sound("RevealCommon")
	end
end

local current: ScreenGui? = nil
-- The lobby window behind a reveal steps out of the way while it plays (guide 11.1, "Panels
-- fade back"), so its rows and buttons don't read through the result; Done brings it back.
local hiddenPanels: ScreenGui? = nil

local function hidePanels()
	local gui = player:FindFirstChild("PlayerGui")
	local panels = gui and gui:FindFirstChild("LobbyPanels")
	if panels and panels:IsA("ScreenGui") and panels.Enabled then
		panels.Enabled = false
		hiddenPanels = panels
	end
end

local function restorePanels()
	local panels = hiddenPanels
	hiddenPanels = nil
	if panels then
		panels.Enabled = true
	end
end

-- Whether a reveal is on screen (the Store holds its balance pills until it closes, so the
-- coin count doesn't spoil the slip).
function Reveal.isOpen(): boolean
	return current ~= nil and (current :: ScreenGui).Parent ~= nil
end

-- Reveals asked for while one is on screen wait their turn (a Premium unlock's "Thank you"
-- and a refund reveal can land in the same second); each plays when the one before closes.
local waiting: { { results: { Outcome }, opts: Options? } } = {}

local function teardown()
	if current then
		current:Destroy()
		current = nil
	end
	restorePanels()
end

function Reveal.close()
	teardown()
	if #waiting > 0 then
		-- Deferred, so whatever the closing button runs next (Done's onDone, "Open the Pass")
		-- happens first and the next reveal plays over it.
		task.defer(function()
			if not Reveal.isOpen() and #waiting > 0 then
				local nextUp = table.remove(waiting, 1) :: { results: { Outcome }, opts: Options? }
				Reveal.play(nextUp.results, nextUp.opts)
			end
		end)
	end
end

function Reveal.play(results: { Outcome }, opts: Options?)
	if #results == 0 then
		return
	end
	if Reveal.isOpen() then
		table.insert(waiting, { results = results, opts = opts })
		return
	end
	teardown()
	local o: Options = opts or {}
	-- Draws sort lowest rarity first (the best flips last); a purchase keeps the order it was
	-- given in (the thing bought first).
	local sorted = table.clone(results)
	if not o.gift then
		table.sort(sorted, function(a, b)
			return rankOf(a) < rankOf(b)
		end)
	end
	local best = sorted[#sorted]
	local bestStyle = UI.rarity(best.rarity)
	local single = #results == 1
	local gift = o.gift == true
	-- The right-hand button: draw again, or (a purchase) the one thing worth doing next.
	local second = o.again or o.primary

	local screen = UI.new("ScreenGui", {
		Name = "Reveal",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 9,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	current = screen
	hidePanels()
	local scrim = UI.scrim(screen, 0.25, 1)
	scrim.Name = "Backdrop"
	local stage = UI.new("Frame", {
		Name = "Stage",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(820, 520),
		BackgroundTransparency = 1,
		ZIndex = 2,
	}, screen)
	local fit = UI.new("UIScale", { Name = "Fit" }, stage)
	local camera = workspace.CurrentCamera
	local function refit()
		local v = camera.ViewportSize
		fit.Scale = math.clamp(math.min((v.X - 24) / 820, (v.Y - 24) / 520), 0.4, 1)
	end
	refit()
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(refit)
	screen.Parent = player:WaitForChild("PlayerGui")

	-- Final states, applied at once when the player skips.
	local finals: { { any } } = {}
	local function final(instance: Instance, props: { [string]: any })
		table.insert(finals, { instance, props })
	end
	local skipped = UI.reducedMotion()
	local done = false
	local function wait(t: number)
		local t0 = os.clock()
		while not skipped and os.clock() - t0 < t do
			task.wait()
		end
	end
	local function tween(instance: Instance, info: TweenInfo, props: { [string]: any })
		final(instance, props)
		if not skipped then
			UI.play(instance, info, props)
		end
	end

	-- The omikuji box and its stick.
	local box = UI.new("ImageLabel", {
		Name = "Box",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0, -40),
		Size = UDim2.fromOffset(200, 200),
		BackgroundTransparency = 1,
		ScaleType = Enum.ScaleType.Fit,
		ZIndex = 4,
	}, stage)
	if not UI.art(box, "RevealBox") then
		box.Image = ICONS.Rewards
	end
	box.Visible = not gift
	local stick = UI.new("ImageLabel", {
		Name = "Stick",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 6, 1, -150),
		Size = UDim2.fromOffset(40, 160),
		BackgroundTransparency = 1,
		ZIndex = 3,
	}, box)
	local hasStick = UI.art(stick, "RevealStick")
	if not hasStick then
		stick.BackgroundTransparency = 0
		stick.BackgroundColor3 = Color3.fromRGB(214, 180, 120)
		UI.new("UICorner", { CornerRadius = UDim.new(0.4, 0) }, stick)
	end
	local tip = UI.new("ImageLabel", {
		Name = "Tip",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ImageColor3 = bestStyle.light,
		ZIndex = 3,
	}, stick)
	if not UI.art(tip, "RevealTip") then
		tip.Size = UDim2.fromScale(1, 0.3)
		tip.BackgroundTransparency = 0
		tip.BackgroundColor3 = bestStyle.light
		UI.new("UICorner", { CornerRadius = UDim.new(0.4, 0) }, tip)
	end
	stick.Visible = false

	if o.title then
		UI.text({
			Name = "Title",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromOffset(410, 0),
			Size = UDim2.new(1, -40, 0, 44),
			FontFace = UI.Fonts.Display,
			TextSize = 34,
			TextColor3 = T.GoldHi,
			Text = o.title,
			ZIndex = 9,
		}, stage)
	end
	if o.note then
		UI.text({
			Name = "Note",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -UI.Touch - 14),
			Size = UDim2.new(1, -60, 0, 44),
			TextWrapped = true,
			TextSize = 18,
			TextColor3 = T.Bone,
			Text = o.note,
			ZIndex = 9,
		}, stage)
	end

	local skipHint = UI.label("caption", {
		Name = "SkipHint",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.fromOffset(300, 20),
		TextColor3 = T.Dim,
		Text = if UI.touchSized() then "Tap to skip" else "Click to skip",
		ZIndex = 9,
	}, stage)

	local slip: Frame? = nil
	local grid: Frame? = nil
	local buttons: Frame

	local function showButtons()
		if done then
			return
		end
		done = true
		skipHint.Visible = false
		buttons.Visible = true
		UI.openMotion(buttons)
	end

	-- Skip: everything jumps to where it was going.
	scrim.Activated:Connect(function()
		if done or skipped then
			return
		end
		skipped = true
	end)

	buttons = UI.new("Frame", {
		Name = "Buttons",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -6),
		Size = UDim2.fromOffset(480, UI.Touch),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 9,
	}, stage)
	local doneButton = UI.button({
		Name = "Done",
		variant = "secondary",
		AnchorPoint = Vector2.new(if second then 0 else 0.5, 0),
		Position = UDim2.fromScale(if second then 0 else 0.5, 0),
		Size = UDim2.new(if second then 0.5 else 0.6, -8, 1, 0),
		Text = "Done",
		sound = "Cancel",
		ZIndex = 9,
	}, buttons)
	doneButton.Activated:Connect(function()
		Reveal.close()
		if o.onDone then
			o.onDone()
		end
	end)
	if second then
		local again = second
		local againButton = UI.button({
			Name = if o.again then "Again" else "Primary",
			variant = again.variant or "primary",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.new(0.5, -8, 1, 0),
			Text = again.label,
			FontFace = UI.Fonts.Number,
			ZIndex = 9,
		}, buttons)
		againButton.Activated:Connect(function()
			Reveal.close()
			again.run()
		end)
	end

	-- The single result on its washi slip.
	local function buildSlip()
		local outcome = best
		local style = UI.rarity(outcome.rarity)
		local s = UI.new("ImageLabel", {
			Name = "Slip",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, if gift then 0 else 20),
			Size = UDim2.fromOffset(0, 300),
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			ZIndex = 5,
		}, stage)
		if UI.art(s, "RevealSlip") then
			s.ScaleType = Enum.ScaleType.Slice
			s.SliceCenter = Rect.new(48, 40, 464, 120)
		else
			UI.paint(s, "washi")
		end
		s:SetAttribute("Washi", true)
		local inner = UI.new("Frame", {
			Name = "Inner",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(560, 300),
			BackgroundTransparency = 1,
			ZIndex = 5,
		}, s)
		-- The big brush kanji of the rarity, stamped faintly behind the art.
		local kanji = UI.new("ImageLabel", {
			Name = "Kanji",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0, 104),
			Size = UDim2.fromOffset(190, 180),
			BackgroundTransparency = 1,
			ImageColor3 = style.dark,
			ImageTransparency = 0.8,
			ScaleType = Enum.ScaleType.Fit,
			ZIndex = 5,
		}, inner)
		if not UI.art(kanji, style.kanji) then
			kanji.Visible = false
		end
		local holder = UI.new("Frame", {
			Name = "Art",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0, 104),
			Size = UDim2.fromOffset(150, 150),
			BackgroundColor3 = T.Lacquer,
			BorderSizePixel = 0,
			ZIndex = 6,
		}, inner)
		UI.rarityGlow(holder, outcome.rarity, 6)
		local artInner = UI.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.8, 0.8),
			BackgroundTransparency = 1,
			ZIndex = 7,
		}, holder)
		art(artInner, outcome)
		for _, d in artInner:GetDescendants() do
			if d:IsA("GuiObject") then
				d.ZIndex = 7
			end
		end
		local frame = UI.rarityFrame(holder, outcome.rarity, 8, 0.16)
		UI.text({
			Name = "ItemName",
			Position = UDim2.fromOffset(0, 186),
			Size = UDim2.new(1, 0, 0, 36),
			FontFace = UI.Fonts.Display,
			TextSize = 28,
			TextColor3 = T.Ink,
			Text = nameOf(outcome),
			ZIndex = 6,
		}, inner)
		UI.text({
			Name = "Rarity",
			Position = UDim2.fromOffset(0, 222),
			Size = UDim2.new(1, 0, 0, 20),
			FontFace = UI.Fonts.Number,
			TextSize = 16,
			TextColor3 = style.dark,
			Text = outcome.caption
				or (string.upper(outcome.rarity or "common") .. (if outcome.pity then "  ·  PITY" else "")),
			ZIndex = 6,
		}, inner)
		if outcome.dup then
			local line = UI.text({
				Name = "Dup",
				Position = UDim2.fromOffset(0, 246),
				Size = UDim2.new(1, 0, 0, 22),
				FontFace = UI.Fonts.Label,
				TextSize = 17,
				TextColor3 = T.JadeDeep,
				Text = "",
				ZIndex = 6,
			}, inner)
			UI.countUp(line, 0, outcome.shards or 0, function(n: number): string
				return `Already yours  →  +{Text.currency(n, "Shards")}`
			end, 0.6)
		end
		-- Unroll, pop the art, stamp the frame.
		tween(s, UI.Motion.Reveal, { Size = UDim2.fromOffset(600, 300) })
		local pop = UI.new("UIScale", { Scale = if skipped then 1 else 0.6 }, holder)
		tween(pop, UI.Motion.Pop, { Scale = 1 })
		if frame then
			UI.stamp(frame :: any)
		end
		slip = s
	end

	-- Several results: a grid of card backs that flip, lowest rarity first.
	local function buildGrid()
		local n = #sorted
		local columns = if n > 5 then 5 else n
		local cellW, cellH, gap = 142, 188, 12
		local rows = math.ceil(n / columns)
		local g = UI.new("Frame", {
			Name = "Grid",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, -16),
			Size = UDim2.fromOffset(columns * (cellW + gap) - gap, rows * (cellH + gap) - gap),
			BackgroundTransparency = 1,
			ZIndex = 5,
		}, stage)
		grid = g
		for i, outcome in sorted do
			local col = (i - 1) % columns
			local row = (i - 1) // columns
			local cell = UI.new("Frame", {
				Name = `Cell{i}`,
				Position = UDim2.fromOffset(col * (cellW + gap), row * (cellH + gap)),
				Size = UDim2.fromOffset(cellW, cellH),
				BackgroundTransparency = 1,
				ZIndex = 5,
			}, g)
			local item = outcome.kind == "item" and Catalog.get(outcome.id) or nil
			local face = UI.card({
				Name = "Face",
				name = nameOf(outcome),
				rarity = outcome.rarity,
				art = function(holder: Frame)
					art(holder, outcome)
				end,
				status = if outcome.dup
					then `+{Text.currency(outcome.shards or 0, "Shards")}`
					elseif outcome.pity then "Pity"
					elseif outcome.status then outcome.status
					elseif item then "New"
					else nil,
				statusColor = if outcome.dup then T.JadeText else T.GoldHi,
				isNew = item ~= nil and not outcome.dup,
				Size = UDim2.fromScale(1, 1),
			}, cell)
			face.AnchorPoint = Vector2.new(0.5, 0.5)
			face.Position = UDim2.fromScale(0.5, 0.5)
			local back = UI.new("ImageLabel", {
				Name = "Back",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				ZIndex = 9,
			}, cell)
			if not UI.art(back, "CardBack") then
				UI.paint(back, "lacquer")
			end
			face.Visible = skipped or gift
			back.Visible = not skipped and not gift
			final(face, { Visible = true, Size = UDim2.fromScale(1, 1) })
			final(back, { Visible = false })
		end
		if gift then
			-- A purchase: the cards pop in one after another, no flipping.
			for i = 1, n do
				local cell = g:FindFirstChild(`Cell{i}`) :: Frame
				local pop = UI.new("UIScale", { Scale = if skipped then 1 else 0.6 }, cell)
				if not skipped then
					task.delay(0.07 * (i - 1), function()
						UI.play(pop, UI.Motion.Pop, { Scale = 1 })
					end)
				end
				final(pop, { Scale = 1 })
			end
			if not skipped then
				stinger(rankOf(sorted[n]))
			end
			return
		end
		-- Flip each (lowest first, the best last), 0.08 s apart.
		task.spawn(function()
			for i = 1, n do
				if skipped then
					break
				end
				local cell = g:FindFirstChild(`Cell{i}`) :: Frame
				local face = cell:FindFirstChild("Face") :: TextButton
				local back = cell:FindFirstChild("Back") :: ImageLabel
				local half = TweenInfo.new(0.09, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
				UI.play(back, half, { Size = UDim2.fromScale(0, 1) })
				task.delay(0.09, function()
					back.Visible = false
					face.Size = UDim2.fromScale(0, 1)
					face.Visible = true
					UI.play(face, TweenInfo.new(0.09, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
						Size = UDim2.fromScale(1, 1),
					})
				end)
				if i == n then
					stinger(rankOf(sorted[i]))
				else
					UI.sound("Press", 1.1 + i * 0.05)
				end
				wait(0.08)
			end
		end)
	end

	-- The sequence.
	task.spawn(function()
		if gift then
			-- A purchase: straight to what you got.
			UI.sound("Purchase")
			if single then
				buildSlip()
				if not skipped then
					stinger(rankOf(best))
				end
			else
				buildGrid()
			end
			wait(if single then 0.5 else 0.08 * #sorted + 0.3)
			for _, entry in finals do
				for k, v in entry[2] do
					(entry[1] :: any)[k] = v
				end
			end
			showButtons()
			return
		end
		local hum = if skipped then nil else UI.sound("Hum")
		-- Box drops in and shakes.
		tween(box, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Position = UDim2.new(0.5, 0, 0.5, 70),
		})
		wait(0.4)
		for i = 1, 3 do
			if skipped then
				break
			end
			UI.sound("Knock", 1.5 + i * 0.1)
			box.Rotation = if i % 2 == 1 then 6 else -6
			wait(0.08)
			box.Rotation = 0
			wait(0.06)
		end
		final(box, { Rotation = 0 })
		-- The stick slides out, its tip the best result's colour.
		stick.Visible = true
		final(stick, { Visible = true, Position = UDim2.new(0.5, 6, 1, -230) })
		if not skipped then
			UI.play(stick, TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
				Position = UDim2.new(0.5, 6, 1, -230),
			})
			if hum then
				UI.play(hum, TweenInfo.new(0.5), { PlaybackSpeed = 1.1 })
			end
			if rankOf(best) >= 5 then
				local ring = UI.new("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.new(0.5, 6, 0.5, -70),
					Size = UDim2.fromOffset(40, 40),
					BackgroundTransparency = 1,
					ZIndex = 3,
				}, stage)
				UI.new("UICorner", { CornerRadius = UDim.new(1, 0) }, ring)
				local edge = UI.new("UIStroke", { Color = bestStyle.light, Thickness = 6 }, ring)
				UI.play(ring, UI.Motion.Reveal, { Size = UDim2.fromOffset(420, 420) })
				UI.play(edge, UI.Motion.Reveal, { Transparency = 1 })
			end
		end
		wait(0.45)
		-- The box steps back and the result shows.
		tween(box, UI.Motion.Slide, {
			Position = UDim2.new(0.5, 0, 0, if single then 150 else 120),
			Size = UDim2.fromOffset(if single then 120 else 0, if single then 120 else 0),
			ImageTransparency = if single then 0.2 else 1,
		})
		if single then
			buildSlip()
			if not skipped then
				stinger(rankOf(best))
			end
		else
			buildGrid()
		end
		wait(if single then 0.6 else 0.12 * #sorted + 0.3)
		for _, entry in finals do
			for k, v in entry[2] do
				(entry[1] :: any)[k] = v
			end
		end
		if hum then
			hum:Stop()
		end
		if skipped and single then
			stinger(rankOf(best))
		end
		local _ = slip
		local _ = grid
		showButtons()
	end)
end

return Reveal
