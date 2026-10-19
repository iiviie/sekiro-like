--!strict
local ArenaBuilder = require(script.ArenaBuilder)
local BotService = require(script.BotService)
local CombatService = require(script.CombatService)

ArenaBuilder.build()
CombatService.start()
BotService.start()
