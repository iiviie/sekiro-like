--!strict
local CombatHUD = require(script.CombatHUD)
local CombatInput = require(script.CombatInput)
local CombatVisuals = require(script.CombatVisuals)
local RoundHUD = require(script.RoundHUD)
local TitleScreen = require(script.TitleScreen)

CombatVisuals.start()
CombatHUD.start()
RoundHUD.start()
TitleScreen.show() -- yields until the player enters, so the click doesn't swing a sword
CombatHUD.showControls()
CombatInput.start()
