--!strict
local BotService = require(script.BotService)
local CombatService = require(script.CombatService)
local MapBuilder = require(script.MapBuilder)
local RoundService = require(script.RoundService)

MapBuilder.build()
CombatService.start()
BotService.start()
RoundService.start()
