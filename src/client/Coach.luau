--!strict
-- Teaches the fight inside the fight. For a player's first matches, every swing coming at
-- you flashes a small "[F] DEFLECT" prompt in time with the glint, in the lower third above
-- the bars (never over the fighters); a deflect is followed by
-- "CLICK  RIPOSTE" when it recoiled the attacker; a broken opponent by "CLICK  DEATHBLOW"; perilous attacks name their
-- answer. Nobody reads a rules screen before their first fight, so the rules come to them,
-- at the moment they matter. It retires itself once the player has the hang of it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Bosses = require(ReplicatedStorage.Shared.Bosses)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer

local MATCHES = 3 -- coach for this many matches...
local DEFLECTS = 12 -- ...or until this many lifetime deflects, whichever comes first
local GLINT_LEAD = 0.3 -- matches CombatVisuals' glint
local RANGE = 12 -- studs: swings from further away aren't aimed at you (a thrust reaches ~11)

-- What beat you, and the answer to it: shown when you're cut down or killed, for everyone.
-- Losing is only useful if you learn something from it.
local DEATH_TIPS: { [string]: string } = {
	Light1 = "Slashes come in strings of three. Tap F as each blade glints.",
	Light2 = "Slashes come in strings of three. Tap F as each blade glints.",
	Light3 = "The third slash is fast. Keep tapping F on the glints, don't swing back early.",
	Overhead = "That was a delayed overhead. Don't press early: wait for the glint.",
	Riposte = "Your string's last hit was deflected, then countered. Strings end on the third hit: guard after it.",
	Riposte2 = "That was a counter-string. After a riposte lands, hold F: the second cut follows fast.",
	DodgeSlash = "They dodged and cut straight back. Don't swing into a dodge: guard instead.",
	MikiriSlash = "Your thrust was Mikiri-countered. Thrusts are a read: use them when they're not dashing in.",
	Perilous = "Red 危 thrust: deflect it on the glint, or dash INTO it with Q for a Mikiri Counter.",
	Sweep = "Red 危 sweep: only a jump avoids it (dodging doesn't). Press jump again over them to stomp.",
	Deathblow = "Your posture broke. When the middle bar fills up, back off and let it drain.",
	Mist = "The red mist hurts. Stay inside the ring.",
}

local Coach = {}

local tipLabel: TextLabel
local lastHitKind: string? = nil
local lastHitAt = 0

local screen: ScreenGui
local prompt: Frame
local promptScale: UIScale
local keyLabel: TextLabel
local wordLabel: TextLabel
local token = 0

local function active(): boolean
	local character = player.Character
	if not character or (character:GetAttribute("InMatch") ~= true and character:GetAttribute("InDuel") ~= true) then
		return false
	end
	return (player:GetAttribute("Played") or 0) < MATCHES and (player:GetAttribute("Deflects") or 0) < DEFLECTS
end

local function touch(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function now(): number
	return workspace:GetServerTimeNow()
end

local function show(key: string, word: string, color: Color3, hold: number)
	token += 1
	local mine = token
	keyLabel.Text = key
	wordLabel.Text = word
	wordLabel.TextColor3 = color
	-- Above the boss's bars in a boss fight, else just above your own posture bar.
	local gui = player:FindFirstChild("PlayerGui")
	local hud = gui and gui:FindFirstChild("BossHUD")
	local bossBar = hud and hud:FindFirstChild("BossBar")
	local overBoss = bossBar ~= nil and bossBar:IsA("GuiObject") and bossBar.Visible
	prompt.Position = UDim2.new(0.5, 0, 1, if overBoss then -264 else -192)
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

local function showTip()
	local kind = if os.clock() - lastHitAt < 4 then lastHitKind else "Mist"
	local tip = kind and DEATH_TIPS[kind]
	if not tip then
		return
	end
	tipLabel.Text = tip
	tipLabel.Visible = true
	tipLabel.TextTransparency = 1
	UI.tween(tipLabel, 0.4, { TextTransparency = 0 })
	task.delay(5, function()
		UI.tween(tipLabel, 0.6, { TextTransparency = 1 })
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
		task.delay(math.max(data.hitAt - GLINT_LEAD - now(), 0), function()
			if attacker:GetAttribute("CombatState") ~= "Windup" or not active() then
				return
			end
			if kind == "Sweep" then
				show(if touch() then "JUMP" else "SPACE", "JUMP IT", Color3.fromRGB(255, 90, 70), 0.5)
				-- Then a second press over their head stomps them.
				task.delay(0.42, function()
					if active() then
						show(if touch() then "JUMP" else "SPACE", "STOMP", UI.Gold, 0.4)
					end
				end)
			elseif kind == "Perilous" then
				show(if touch() then "BLOCK" else "F", "DEFLECT THE THRUST", Color3.fromRGB(255, 90, 70), 0.5)
			else
				show(if touch() then "BLOCK" else "F", "DEFLECT", UI.Parchment, 0.4)
			end
		end)
	end,
	Deflect = function(data)
		if data.defender == player.Character and active() then
			-- Only a recoiled (or broken) attacker can be riposted; an opener's string goes on,
			-- and the next glint prompts the next deflect.
			if data.recoil or data.broke then
				show(if touch() then "SLASH" else "CLICK", "RIPOSTE", UI.Gold, 0.5)
			end
		end
	end,
	Mikiri = function(data)
		if data.defender == player.Character and active() then
			show(if touch() then "SLASH" else "CLICK", "CUT", UI.Gold, 0.5)
		end
	end,
	PostureBroken = function(data)
		local model: Model? = data.model
		if model and model ~= player.Character and active() then
			local mine, theirs = rootOf(player.Character), rootOf(model)
			if mine and theirs and (mine.Position - theirs.Position).Magnitude < 14 then
				show(if touch() then "SLASH" else "CLICK", "DEATHBLOW", Color3.fromRGB(255, 70, 60), 0.9)
			end
		elseif model == player.Character and active() then
			show(if touch() then "DODGE" else "Q", "GET AWAY", Color3.fromRGB(255, 70, 60), 0.9)
		end
	end,
}

function Coach.start()
	screen = UI.new("ScreenGui", {
		Name = "Coach",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 8,
	}, player:WaitForChild("PlayerGui"))
	-- A key cap and the word beside it, centred in the lower third: above your posture bar
	-- and a boss's bars, below the fighters, so the exchange itself stays in view.
	prompt = UI.new("Frame", {
		Name = "Prompt",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -192),
		Size = UDim2.fromOffset(0, 40),
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
		Size = UDim2.fromOffset(0, 36),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = UI.Ink,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
	}, prompt)
	UI.corner(cap, UDim.new(0, 7))
	UI.stroke(cap, UI.Parchment, 2, 0)
	UI.new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, cap)
	keyLabel = UI.text({
		Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = UI.Bold,
		TextSize = 22,
		Text = "F",
	}, cap)
	wordLabel = UI.text({
		Name = "Word",
		LayoutOrder = 2,
		Size = UDim2.fromOffset(0, 36),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = UI.Display,
		TextSize = 30,
		TextStrokeTransparency = 0.2,
		Text = "DEFLECT",
	}, prompt)

	-- The death tip sits just above where the prompt flashes, clear of the screen's centre.
	tipLabel = UI.text({
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -312),
		Size = UDim2.fromOffset(760, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		Font = UI.Display,
		TextSize = 26,
		TextStrokeTransparency = 0.3,
		TextColor3 = UI.Gold,
		Visible = false,
		Text = "",
	}, screen)

	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CombatEvent") :: RemoteEvent
	remote.OnClientEvent:Connect(function(kind: string, data: { [string]: any })
		local handler = handlers[kind]
		if handler then
			handler(data)
		end
	end)
end

return Coach
