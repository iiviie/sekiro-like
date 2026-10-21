--!strict
-- Teaches the fight inside the fight. For a player's first matches (and at the lobby's
-- Deflect Trainer), every swing coming at you flashes a small "[F] DEFLECT" prompt in time
-- with the glint, low on the screen just over the posture bar (never over the fighters); a
-- deflect is followed by
-- "CLICK  RIPOSTE" when it recoiled the attacker; a broken opponent by "CLICK  DEATHBLOW"; perilous attacks name their
-- answer. Nobody reads a rules screen before their first fight, so the rules come to them,
-- at the moment they matter. It retires itself once the player has the hang of it; the
-- perilous prompts stay (through the newcomer matches) until each kind has been seen once.
-- A new PC player's first royale exchange is followed by a one-time "R · LOCK ON". Key
-- names follow the player's controls (InputNames).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Bosses = require(ReplicatedStorage.Shared.Bosses)
local Config = require(ReplicatedStorage.Shared.Config)
local CombatHUD = require(script.Parent.CombatHUD)
local InputNames = require(script.Parent.InputNames)
local LockOn = require(script.Parent.LockOn)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer

local MATCHES = 3 -- coach for this many matches...
local DEFLECTS = 12 -- ...or until this many lifetime deflects, whichever comes first
local GLINT_LEAD = 0.3 -- matches CombatVisuals' glint
local RANGE = 12 -- studs: swings from further away aren't aimed at you (a thrust reaches ~11)
local TIP_TIME = 6 -- seconds a death tip stays up
local PROMPT_BOTTOM = CombatHUD.PostureTop + 4 -- just over the posture bar
local TIP_BOTTOM = 100 -- over the spectate bar; in the lobby, low in the middle

-- What beat you, and the answer to it: shown when you're cut down or killed, for everyone.
-- Losing is only useful if you learn something from it.
-- {block} and {dodge} become the player's own input names.
local DEATH_TIPS: { [string]: string } = {
	Light1 = "Slashes come in strings of three. Tap {block} as each blade glints.",
	Light2 = "Slashes come in strings of three. Tap {block} as each blade glints.",
	Light3 = "The third slash is fast. Keep tapping {block} on the glints, don't swing back early.",
	Overhead = "That was a delayed overhead. Don't press early: wait for the glint.",
	Riposte = "Your string's last hit was deflected, then countered. Strings end on the third hit: guard after it.",
	Riposte2 = "That was a counter-string. After a riposte lands, hold {block}: the second cut follows fast.",
	DodgeSlash = "They dodged and cut straight back. Don't swing into a dodge: guard instead.",
	MikiriSlash = "Your thrust was Mikiri-countered. Thrusts are a read: use them when they're not dashing in.",
	Perilous = "Red perilous thrust: deflect it on the glint, or dash INTO it with {dodge} for a Mikiri Counter.",
	Sweep = "Red perilous sweep: only a jump avoids it (dodging doesn't). Press jump again over them to stomp.",
	Deathblow = "Your posture broke. When the middle bar fills up, back off and let it drain.",
	Mist = "The red mist hurts. Stay inside the ring.",
}

local Coach = {}

local tipLabel: TextLabel
local tipGroup: CanvasGroup
local lastHitKind: string? = nil
local lastHitAt = 0

local screen: ScreenGui
local prompt: Frame
local promptScale: UIScale
local keyLabel: TextLabel
local wordLabel: TextLabel
local token = 0
local seenPerilous: { [string]: boolean } = {} -- perilous kinds already prompted (Perilous, Sweep)
local lockTaught = false
local lockPending = false

-- In a fight, or in the lobby for the Deflect Trainer's swings only (`attacker`).
local function coachable(attacker: Model?): boolean
	local character = player.Character
	if not character then
		return false
	end
	local fighting = character:GetAttribute("InMatch") == true or character:GetAttribute("InDuel") == true
	local training = attacker ~= nil and attacker:GetAttribute("Trainer") ~= nil
	return fighting or training
end

-- Coaching is on in a fight, or in the lobby for the Deflect Trainer's swings only; never
-- for anything else in the lobby.
local function active(attacker: Model?): boolean
	return coachable(attacker)
		and (player:GetAttribute("Played") or 0) < MATCHES
		and (player:GetAttribute("Deflects") or 0) < DEFLECTS
end

-- Perilous prompts outlast the rest: rare and punishing, they stay through the newcomer
-- matches until each kind has been prompted once.
local function perilousActive(attacker: Model?, kind: string): boolean
	return active(attacker)
		or (
			coachable(attacker)
			and not seenPerilous[kind]
			and (player:GetAttribute("Played") or 0) < Config.NewcomerAssist.Matches
		)
end

-- The key cap for an input on the player's controls: "F", "L1", "DEFLECT"...
local function key(input: string): string
	return string.upper((InputNames.get() :: any)[input])
end

local function now(): number
	return workspace:GetServerTimeNow()
end

local function show(cap: string, word: string, color: Color3, hold: number)
	token += 1
	local mine = token
	keyLabel.Text = cap
	wordLabel.Text = word
	wordLabel.TextColor3 = color
	prompt.Visible = true
	promptScale.Scale = 1.2
	UI.tween(promptScale, 0.12, { Scale = 1 })
	task.delay(hold, function()
		if token == mine then
			prompt.Visible = false
		end
	end)
end

local function rootOf(model: Model?): BasePart?
	local root = model and model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- Is this swing aimed at me: close, and the attacker roughly facing me?
local function aimedAtMe(attacker: Model): boolean
	local mine, theirs = rootOf(player.Character), rootOf(attacker)
	if not mine or not theirs or attacker == player.Character then
		return false
	end
	local offset = mine.Position - theirs.Position
	if offset.Magnitude > RANGE then
		return false
	end
	local flat = Vector3.new(offset.X, 0, offset.Z)
	return flat.Magnitude < 0.5 or theirs.CFrame.LookVector:Dot(flat.Unit) > 0.4
end

-- The death tip: up for TIP_TIME, then faded and hidden for real. (A CanvasGroup that ran
-- out of texture budget draws plainly and ignores GroupTransparency, so the fade alone left
-- the tip on screen for good, over the lobby's panels.)
local tipToken = 0
local function hideTip()
	tipToken += 1
	tipGroup.Visible = false
	tipGroup.GroupTransparency = 1
end

local function showTip()
	local kind = if os.clock() - lastHitAt < 4 then lastHitKind else "Mist"
	local tip = kind and DEATH_TIPS[kind]
	if not tip then
		return
	end
	local names = InputNames.get()
	tip = string.gsub(tip, "{block}", names.block)
	tip = string.gsub(tip, "{dodge}", names.dodge)
	tipToken += 1
	local mine = tipToken
	tipLabel.Text = tip
	-- Over the spectate bar while the match goes on; at the very bottom once you're back in
	-- the lobby (nothing else lives in its bottom-centre).
	local character = player.Character
	local inFight = character ~= nil
		and (character:GetAttribute("InMatch") == true or character:GetAttribute("InDuel") == true)
	tipGroup.Position = UDim2.new(0.5, 0, 1, -(if inFight then TIP_BOTTOM else 20))
	tipGroup.Visible = true
	tipGroup.GroupTransparency = 1
	UI.tween(tipGroup, 0.4, { GroupTransparency = 0 })
	task.delay(TIP_TIME, function()
		if tipToken ~= mine then
			return
		end
		UI.tween(tipGroup, 0.5, { GroupTransparency = 1 })
		task.wait(0.55)
		if tipToken == mine then
			hideTip()
		end
	end)
end

local handlers: { [string]: (data: { [string]: any }) -> () } = {
	Hit = function(data)
		if data.defender == player.Character then
			lastHitKind, lastHitAt = data.kind, os.clock()
		end
	end,
	Deathblow = function(data)
		if data.defender == player.Character then
			lastHitKind, lastHitAt = "Deathblow", os.clock()
		end
	end,
	CutDown = function(data)
		if data.model == player.Character then
			task.delay(1.8, showTip)
		end
	end,
	Died = function(data)
		if data.model == player.Character then
			task.delay(2.6, showTip)
		end
	end,
	Windup = function(data)
		local attacker: Model? = data.attacker
		if not attacker or not aimedAtMe(attacker) then
			return
		end
		local kind = data.kind
		if data.boss then
			-- A boss hit: prompt by what it is, not by its name.
			local spec = Bosses.spec(kind)
			kind = if spec and spec.low then "Sweep" elseif spec and spec.thrust then "Perilous" else "Light1"
		end
		-- A new PC (or gamepad) player's first royale exchange, fought on the free camera:
		-- once it has passed, name the lock-on key. Touch locks on by itself.
		local character = player.Character
		if
			not lockTaught
			and not lockPending
			and not data.boss
			and character
			and character:GetAttribute("InMatch") == true
			and InputNames.scheme() ~= "Touch"
			and LockOn.target() == nil
			and (player:GetAttribute("Played") or 0) < Config.NewcomerAssist.Matches
		then
			lockPending = true
			task.delay(math.max(data.hitAt + 0.45 - now(), 0), function()
				lockPending = false
				-- Not over another prompt: the next exchange tries again.
				if LockOn.target() == nil and character:GetAttribute("InMatch") == true and not prompt.Visible then
					lockTaught = true
					show(key("lock"), "LOCK ON", UI.Gold, 1.6)
				end
			end)
		end
		task.delay(math.max(data.hitAt - GLINT_LEAD - now(), 0), function()
			if attacker:GetAttribute("CombatState") ~= "Windup" then
				return
			end
			local block = key("block")
			if kind == "Sweep" or kind == "Perilous" then
				if not perilousActive(attacker, kind) then
					return
				end
				seenPerilous[kind] = true
			elseif not active(attacker) then
				return
			end
			if kind == "Sweep" then
				show(key("jump"), "JUMP IT", UI.Theme.CrimsonText, 0.5)
				-- Then a second press over their head stomps them.
				task.delay(0.42, function()
					if coachable(attacker) then
						show(key("jump"), "STOMP", UI.Gold, 0.4)
					end
				end)
			elseif kind == "Perilous" then
				-- On touch the cap already reads DEFLECT (the button's own name).
				show(
					block,
					if block == "DEFLECT" then "THE THRUST" else "DEFLECT THE THRUST",
					UI.Theme.CrimsonText,
					0.5
				)
			else
				show(block, if block == "DEFLECT" then "NOW" else "DEFLECT", UI.Parchment, 0.4)
			end
		end)
	end,
	Deflect = function(data)
		if data.defender == player.Character and active(data.attacker) then
			-- Only a recoiled (or broken) attacker can be riposted; an opener's string goes on,
			-- and the next glint prompts the next deflect.
			if data.recoil or data.broke then
				show(key("attack"), "RIPOSTE", UI.Gold, 0.5)
			end
		end
	end,
	Mikiri = function(data)
		if data.defender == player.Character and active(data.attacker) then
			show(key("attack"), "CUT", UI.Gold, 0.5)
		end
	end,
	PostureBroken = function(data)
		local model: Model? = data.model
		if model and model ~= player.Character and active() then
			local mine, theirs = rootOf(player.Character), rootOf(model)
			if mine and theirs and (mine.Position - theirs.Position).Magnitude < 14 then
				show(key("attack"), "DEATHBLOW", UI.Theme.CrimsonText, 0.9)
			end
		end
		-- No prompt for your own break: a Broken fighter can't dodge or act until it ends.
	end,
}

function Coach.start()
	screen = UI.new("ScreenGui", {
		Name = "Coach",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		-- Under the lobby HUD (5) and its panels (6): a tip never covers a window.
		DisplayOrder = 4,
	}, player:WaitForChild("PlayerGui"))
	local fit = UI.new("UIScale", { Name = "Fit" }, screen)
	local function refit()
		fit.Scale = UI.hudScale()
	end
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(refit)
	player:GetAttributeChangedSignal("UIViewport"):Connect(refit)
	refit()
	-- A small key cap and the word beside it, low in the middle: just over your posture bar,
	-- under the fighters' feet, so the exchange itself stays in view.
	prompt = UI.new("Frame", {
		Name = "Prompt",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -PROMPT_BOTTOM),
		Size = UDim2.fromOffset(0, 32),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		Visible = false,
	}, screen)
	promptScale = UI.new("UIScale", {}, prompt)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, prompt)
	local cap = UI.new("Frame", {
		Name = "Key",
		LayoutOrder = 1,
		Size = UDim2.fromOffset(0, 28),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = UI.Ink,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
	}, prompt)
	UI.corner(cap, UDim.new(0, 7))
	UI.stroke(cap, UI.Parchment, 2, 0)
	UI.new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, cap)
	keyLabel = UI.text({
		Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = UI.Number,
		TextSize = 18,
		Text = "F",
	}, cap)
	wordLabel = UI.text({
		Name = "Word",
		LayoutOrder = 2,
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = UI.Display,
		TextSize = 24,
		TextStrokeColor3 = UI.Theme.Ink,
		TextStrokeTransparency = 0.2,
		Text = "DEFLECT",
	}, prompt)

	-- The death tip: a small lacquer plate low in the middle (over the spectate bar), clear of
	-- the screen's centre, so it reads over any ground.
	tipGroup = UI.new("CanvasGroup", {
		Name = "Tip",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -TIP_BOTTOM),
		Size = UDim2.fromOffset(540, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Visible = false,
	}, screen)
	local plate = UI.panel({
		Name = "Plate",
		material = "plain",
		sliceScale = 0.4,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, tipGroup)
	UI.new("UIPadding", {
		PaddingLeft = UDim.new(0, 16),
		PaddingRight = UDim.new(0, 16),
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 10),
	}, plate)
	tipLabel = UI.text({
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		Font = UI.Display,
		TextSize = 17,
		TextColor3 = UI.Gold,
		Text = "",
	}, plate)

	-- A new fight (or a new life) starts clean.
	player.CharacterAdded:Connect(function(character)
		character:GetAttributeChangedSignal("InMatch"):Connect(function()
			if character:GetAttribute("InMatch") == true then
				hideTip()
			end
		end)
		character:GetAttributeChangedSignal("InDuel"):Connect(function()
			if character:GetAttribute("InDuel") == true then
				hideTip()
			end
		end)
	end)

	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CombatEvent") :: RemoteEvent
	remote.OnClientEvent:Connect(function(kind: string, data: { [string]: any })
		local handler = handlers[kind]
		if handler then
			handler(data)
		end
	end)
end

return Coach
