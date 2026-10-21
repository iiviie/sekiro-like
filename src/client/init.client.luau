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

-- Owner-only profile fields (server/StatsService.setPrivate) become local attributes on the
-- LocalPlayer, so the panels read them like the replicated ones.
local localPlayer = game:GetService("Players").LocalPlayer
local remotes = game:GetService("ReplicatedStorage"):WaitForChild("Remotes")
local profilePrivate = remotes:WaitForChild("ProfilePrivate") :: RemoteEvent
profilePrivate.OnClientEvent:Connect(function(name: unknown, value: unknown)
	if typeof(name) == "string" then
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
