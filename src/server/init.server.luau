--!strict
local BotService = require(script.BotService)
local CombatService = require(script.CombatService)
local MapBuilder = require(script.MapBuilder)

MapBuilder.build()
CombatService.start()
BotService.start()
