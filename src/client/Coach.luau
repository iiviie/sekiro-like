--!strict
-- Teaches the fight inside the fight. For a player's first matches, every swing coming at
-- you flashes a big "F  DEFLECT" prompt in time with the glint; a deflect is followed by
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
local RANGE = 11 -- studs: swings from further away aren't aimed at you

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
	prompt.Visible = true
	prompt.Size = UDim2.fromOffset(150, 150)
	UI.tween(prompt, 0.12, { Size = UDim2.fromOffset(190, 190) })
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
	prompt = UI.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.64),
		Size = UDim2.fromOffset(190, 190),
		BackgroundTransparency = 1,
		Visible = false,
	}, screen)
	local cap = UI.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromScale(0.62, 0.5),
		BackgroundColor3 = UI.Ink,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
	}, prompt)
	UI.corner(cap, UDim.new(0.18, 0))
	UI.stroke(cap, UI.Parchment, 3, 0)
	UI.new("UIAspectRatioConstraint", { AspectRatio = 1.25 }, cap)
	keyLabel = UI.text({
		Size = UDim2.fromScale(1, 1),
		Font = UI.Bold,
		TextScaled = true,
		Text = "F",
	}, cap)
	UI.new("UIPadding", {
		PaddingTop = UDim.new(0.12, 0),
		PaddingBottom = UDim.new(0.12, 0),
		PaddingLeft = UDim.new(0.1, 0),
		PaddingRight = UDim.new(0.1, 0),
	}, cap)
	wordLabel = UI.text({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.56),
		Size = UDim2.fromScale(2.4, 0.26),
		Font = UI.Display,
		TextScaled = true,
		TextStrokeTransparency = 0.2,
		Text = "DEFLECT",
	}, prompt)

	tipLabel = UI.text({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.7),
		Size = UDim2.fromOffset(900, 34),
		Font = UI.Display,
		TextSize = 28,
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
