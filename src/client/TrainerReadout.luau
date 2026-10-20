--!strict
-- Timing feedback for the lobby's Deflect Trainer: after each of its swings at you, a
-- line under the crosshair says how early your block press was and what it earned
-- ("PERFECT  ·  42 ms before impact"). Teaches the deflect window, and doubles as a
-- netcode check: the numbers are on the shared server clock the server judges with.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local LocalCombat = require(script.Parent.LocalCombat)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer

local TrainerReadout = {}

local label: TextLabel
local pendingHitAt: { [Model]: number } = {}

local function show(text: string, color: Color3)
	label.Text = text
	label.TextColor3 = color
	label.TextTransparency = 0
	label.TextStrokeTransparency = 0.4
	TweenService:Create(label, TweenInfo.new(1.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}):Play()
end

local function early(hitAt: number): number
	return math.floor((hitAt - LocalCombat.deflectStamp) * 1000 + 0.5)
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
	local window = math.floor(Config.Deflect.Window * 1000)
	if kind == "Deflect" then
		if data.perfect then
			show(`PERFECT  ·  {ms} ms before impact`, UI.Gold)
		else
			show(
				`DEFLECT  ·  {ms} ms before impact  (perfect is under {math.floor(Config.Deflect.PerfectWindow * 1000)})`,
				UI.Parchment
			)
		end
	elseif kind == "Guard" then
		local grey = Color3.fromRGB(170, 175, 185)
		if ms > 600 then
			show(`GUARDED  ·  tap block within {window} ms of impact to deflect`, grey)
		else
			show(`GUARDED  ·  {ms} ms early  (deflect window is {window} ms)`, grey)
		end
	elseif kind == "Hit" then
		if ms < 0 and ms > -400 then
			show(`TOO LATE  ·  {-ms} ms after impact`, UI.Crimson)
		elseif ms >= 0 and ms < 1500 then
			show(`TOO EARLY  ·  {ms} ms  (and guard wasn't held)`, UI.Crimson)
		else
			show("HIT  ·  press block just before the blade lands", UI.Crimson)
		end
	end
end

function TrainerReadout.start()
	local screen = UI.new("ScreenGui", { Name = "TrainerReadout", ResetOnSpawn = false, DisplayOrder = 4 })
	label = UI.text({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.62),
		Size = UDim2.fromOffset(700, 30),
		Font = UI.Bold,
		TextSize = 24,
		TextTransparency = 1,
		TextStrokeTransparency = 1,
		Text = "",
	}, screen)
	screen.Parent = player:WaitForChild("PlayerGui")

	local combatEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CombatEvent") :: RemoteEvent
	combatEvent.OnClientEvent:Connect(function(kind: string, data: { [string]: any })
		if kind == "Windup" then
			local attacker: Model? = data.attacker
			if attacker and attacker:GetAttribute("Trainer") then
				pendingHitAt[attacker] = data.hitAt
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
