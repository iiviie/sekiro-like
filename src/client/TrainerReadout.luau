--!strict
-- Timing feedback for the lobby's Deflect Trainer: after each of its swings at you, a
-- small line low on the screen (over the Coach's prompt and the posture bar, under the
-- fighters' feet) says how early your block press was and what it earned
-- ("PERFECT  ·  42 ms before impact"). Teaches the deflect window, and doubles as a
-- netcode check: the numbers are on the shared server clock the server judges with.
-- The windows quoted are your own (a newcomer's are wider), from the DeflectWindow and
-- PerfectWindow attributes the server publishes on your character.
--
-- When the trainer first swings at you with no lock-on, the camera locks on to it (pair
-- framing, your own body faded) so you can watch the blade and the glint; it lets go once
-- you walk away, and stays off if you release it yourself while you train.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local CombatHUD = require(script.Parent.CombatHUD)
local Config = require(ReplicatedStorage.Shared.Config)
local LocalCombat = require(script.Parent.LocalCombat)
local LockOn = require(script.Parent.LockOn)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer

local TrainerReadout = {}

local label: TextLabel
local group: CanvasGroup
local pendingHitAt: { [Model]: number } = {}
local showToken = 0

-- Shown, then faded and hidden for real (a CanvasGroup out of texture budget ignores its
-- GroupTransparency).
local function show(text: string, color: Color3)
	showToken += 1
	local mine = showToken
	label.Text = text
	label.TextColor3 = color
	group.Visible = true
	group.GroupTransparency = 0
	local fade = TweenService:Create(group, TweenInfo.new(1.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		GroupTransparency = 1,
	})
	fade.Completed:Once(function(state)
		if state == Enum.PlaybackState.Completed and showToken == mine then
			group.Visible = false
		end
	end)
	fade:Play()
end

-- How early the press was, from the press itself (not from a window a re-press opened late).
local function early(hitAt: number): number
	return math.floor((hitAt - LocalCombat.pressStamp) * 1000 + 0.5)
end

-- "42 ms before impact" or, for a press after it (still inside the late tolerance), "11 ms late".
local function timing(ms: number): string
	return if ms < 0 then `{-ms} ms late` else `{ms} ms before impact`
end

-- Your windows in ms (the server publishes them on your character as you press).
local function windows(): (number, number)
	local character = player.Character
	local deflect = character and character:GetAttribute("DeflectWindow")
	local perfect = character and character:GetAttribute("PerfectWindow")
	deflect = if typeof(deflect) == "number" then deflect else Config.Deflect.Window
	perfect = if typeof(perfect) == "number" then perfect else Config.Deflect.PerfectWindow
	return math.floor(deflect * 1000 + 0.5), math.floor(perfect * 1000 + 0.5)
end

local function outcome(kind: string, data: { [string]: any })
	local attacker: Model? = data.attacker
	if not attacker or not attacker:GetAttribute("Trainer") or data.defender ~= player.Character then
		return
	end
	local hitAt = pendingHitAt[attacker]
	pendingHitAt[attacker] = nil
	if not hitAt then
		return
	end
	local ms = early(hitAt)
	local window, perfect = windows()
	if kind == "Deflect" then
		if data.perfect then
			show(`PERFECT  ·  {timing(ms)}`, UI.Gold)
		else
			show(`DEFLECT  ·  {timing(ms)}  (perfect is under {perfect})`, UI.Parchment)
		end
	elseif kind == "Guard" then
		local grey = UI.Theme.Steel
		if LocalCombat.pressDelayed and ms <= window + 200 then
			show(`GUARDED  ·  pressed again too soon: the window opened late`, grey)
		elseif ms > 600 then
			show(`GUARDED  ·  tap block within {window} ms of impact to deflect`, grey)
		elseif ms < 0 then
			show(`GUARDED  ·  {-ms} ms late  (deflect window is {window} ms)`, grey)
		else
			show(`GUARDED  ·  {ms} ms early  (deflect window is {window} ms)`, grey)
		end
	elseif kind == "Hit" then
		if ms < 0 and ms > -400 then
			show(`TOO LATE  ·  {-ms} ms after impact`, UI.Theme.CrimsonText)
		elseif LocalCombat.pressDelayed and ms >= 0 and ms <= window + 200 then
			show(`HIT  ·  pressed again too soon: the window opened late`, UI.Theme.CrimsonText)
		elseif ms >= 0 and ms < 1500 then
			show(`TOO EARLY  ·  {ms} ms  (and guard wasn't held)`, UI.Theme.CrimsonText)
		else
			show("HIT  ·  press block just before the blade lands", UI.Theme.CrimsonText)
		end
	end
end

-- Frames the trainer when it swings at you (CB-04): the follow camera otherwise sits behind
-- it or puts it behind you, faded, right where you're meant to watch the glint.
local TRAINER_RING = 10 -- it swings at the nearest player within 9 studs (LobbyService)
local TRAINER_LET_GO = 16 -- an automatic lock lets go once you're this far away
local SESSION_GAP = 6 -- seconds without a swing at you: you left, so the next visit locks again
local declined = false
local lastSwingAt = -math.huge

local function frameTrainer(trainer: Model)
	local clock = os.clock()
	if clock - lastSwingAt > SESSION_GAP then
		declined = false
	end
	lastSwingAt = clock
	if declined or LockOn.target() ~= nil or LockOn.distanceTo(trainer) > TRAINER_RING then
		return
	end
	-- Aimed at you, not at someone else standing closer: the trainer turns to its target
	-- before it swings.
	local character = player.Character
	local mine = character and character:FindFirstChild("HumanoidRootPart")
	local theirs = trainer:FindFirstChild("HumanoidRootPart")
	if not mine or not theirs or not mine:IsA("BasePart") or not theirs:IsA("BasePart") then
		return
	end
	local toMe = mine.Position - theirs.Position
	toMe = Vector3.new(toMe.X, 0, toMe.Z)
	if toMe.Magnitude > 0.1 and theirs.CFrame.LookVector:Dot(toMe.Unit) < 0.7 then
		return
	end
	LockOn.engage(trainer, 1)
	task.spawn(function()
		local deadline = os.clock() + 1.2
		while LockOn.target() ~= trainer and os.clock() < deadline do
			task.wait(0.1)
		end
		if LockOn.target() ~= trainer then
			return
		end
		while LockOn.target() == trainer do
			if LockOn.distanceTo(trainer) > TRAINER_LET_GO then
				LockOn.set(nil)
				return
			end
			task.wait(0.25)
		end
		-- Let go by hand while still training: leave the camera alone until they walk off.
		if LockOn.distanceTo(trainer) <= TRAINER_LET_GO then
			declined = true
		end
	end)
end

function TrainerReadout.start()
	local screen = UI.new("ScreenGui", {
		Name = "TrainerReadout",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 4,
	})
	local fit = UI.new("UIScale", { Name = "Fit" }, screen)
	local function refit()
		fit.Scale = UI.hudScale()
	end
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(refit)
	player:GetAttributeChangedSignal("UIViewport"):Connect(refit)
	refit()
	-- The line sits on a lacquer plate (it's over the world), fading as one: low in the
	-- middle, over the Coach's prompt, which sits on the posture bar.
	group = UI.new("CanvasGroup", {
		Name = "Readout",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -(CombatHUD.PostureTop + 40)),
		Size = UDim2.fromOffset(0, 36),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		Visible = false,
	}, screen)
	local plate = UI.panel({
		Name = "Plate",
		material = "plain",
		sliceScale = 0.4,
		Size = UDim2.fromOffset(0, 36),
		AutomaticSize = Enum.AutomaticSize.X,
	}, group)
	UI.new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }, plate)
	label = UI.label("label", {
		Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		TextSize = 17,
		Text = "",
	}, plate)
	screen.Parent = player:WaitForChild("PlayerGui")

	local combatEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CombatEvent") :: RemoteEvent
	combatEvent.OnClientEvent:Connect(function(kind: string, data: { [string]: any })
		if kind == "Windup" then
			local attacker: Model? = data.attacker
			if attacker and attacker:GetAttribute("Trainer") then
				pendingHitAt[attacker] = data.hitAt
				frameTrainer(attacker)
			end
		elseif kind == "Deflect" or kind == "Guard" or kind == "Hit" then
			outcome(kind, data)
		elseif kind == "Mikiri" and data.attacker and data.attacker:GetAttribute("Trainer") then
			if data.defender == player.Character then
				show("MIKIRI COUNTER", UI.Gold)
			end
		end
	end)
end

return TrainerReadout
