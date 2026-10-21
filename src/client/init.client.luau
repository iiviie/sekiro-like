--!strict
local Audio = require(script.Audio)
local BladeOutlines = require(script.BladeOutlines)
local BossHUD = require(script.BossHUD)
local ChatTags = require(script.ChatTags)
local Coach = require(script.Coach)
local CombatHUD = require(script.CombatHUD)
local CombatInput = require(script.CombatInput)
local CombatVisuals = require(script.CombatVisuals)
local DuelHUD = require(script.DuelHUD)
local LobbyHUD = require(script.LobbyHUD)
local Motion = require(script.Motion)
local Movement = require(script.Movement)
local Occlusion = require(script.Occlusion)
local Podium = require(script.Podium)
local RoundHUD = require(script.RoundHUD)
local TitleScreen = require(script.TitleScreen)
local Toasts = require(script.Toasts)
local TrainerReadout = require(script.TrainerReadout)

local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local localPlayer = game:GetService("Players").LocalPlayer
local remotes = game:GetService("ReplicatedStorage"):WaitForChild("Remotes")

-- Low-end phones start on Fewer particles (fewer effects, 4 blade outlines instead of 12):
-- a touch-only screen whose Roblox graphics quality is Automatic or 4 and below. A choice
-- saved in the profile replaces it when the profile arrives; the default itself isn't saved
-- (client/Panels saves only what the player picks).
local function lowEndTouch(): boolean
	local touch = (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled)
		or workspace:GetAttribute("ForceTouchHUD") == true
	if not touch then
		return false
	end
	local ok, level = pcall(function()
		return UserSettings():GetService("UserGameSettings").SavedQualityLevel.Value
	end)
	return ok and typeof(level) == "number" and level <= 4
end
if localPlayer:GetAttribute("SettingReducedEffects") == nil and lowEndTouch() then
	localPlayer:SetAttribute("SettingReducedEffects", true)
end

-- Owner-only profile fields (server/StatsService.setPrivate) become local attributes on the
-- LocalPlayer, so the panels read them like the replicated ones. "Settings" is the saved
-- settings (sent when the profile loads; the server doesn't echo the player's own picks).
local profilePrivate = remotes:WaitForChild("ProfilePrivate") :: RemoteEvent
profilePrivate.OnClientEvent:Connect(function(name: unknown, value: unknown)
	if name == "Settings" then
		if typeof(value) ~= "string" then
			return
		end
		local ok, saved = pcall(HttpService.JSONDecode, HttpService, value)
		if ok and typeof(saved) == "table" then
			for key, setting in saved do
				if typeof(key) == "string" and string.sub(key, 1, 7) == "Setting" then
					localPlayer:SetAttribute(key, setting)
				end
			end
		end
	elseif typeof(name) == "string" then
		localPlayer:SetAttribute(name, value)
	end
end)

Audio.start()
BladeOutlines.start()
Motion.start()
Movement.start()
Occlusion.start()
CombatVisuals.start()
CombatHUD.start()
RoundHUD.start()
Podium.start()
DuelHUD.start()
BossHUD.start()
LobbyHUD.start()
Toasts.start()
ChatTags.start()
Coach.start()
TrainerReadout.start()
TitleScreen.show() -- yields until the player enters, so the click doesn't swing a sword
LobbyHUD.setEntered()
Audio.setEntered()
CombatHUD.showControls()
CombatInput.start()
