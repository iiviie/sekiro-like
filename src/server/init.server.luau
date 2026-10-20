--!strict
local BotService = require(script.BotService)
local CombatService = require(script.CombatService)
local DevHooks = require(script.DevHooks)
local MapBuilder = require(script.MapBuilder)
local RoundService = require(script.RoundService)
local StatsService = require(script.StatsService)

MapBuilder.build()
CombatService.start()
BotService.start()
StatsService.start()
RoundService.start()
DevHooks.start()
