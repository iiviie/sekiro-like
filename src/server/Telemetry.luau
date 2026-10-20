--!strict
-- Balance telemetry. Counts, across every match this server has run, how often each move is started, how each resolved
-- (hit, guarded, deflected, perfect, Mikiri, jumped, dodged, whiffed, deathblow), which
-- move landed the killing blow and how many attackers a fighter had when they fell. After
-- each match it prints the running totals and raises alarms once the sample is big enough,
-- and sends a few numbers to Roblox's custom analytics (published games only).
--
-- Alarm thresholds (inferred starting points from reports/Sword combat design and lobby.md):
--   * perilous above 20% of attack inputs
--   * perilous countered (deflected, Mikiri'd, jumped, dodged) under 40% of the time
--   * any one move landing over 35% of the killing blows
-- Bots are counted separately from humans: they play by fixed odds.

local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Round = require(ReplicatedStorage.Shared.Round)
local CombatService = require(script.Parent.CombatService)

type Combatant = CombatService.Combatant
type Tally = { [string]: { [string]: number } }

local PERILOUS = { Perilous = true, Sweep = true }
local COUNTERS = { Deflect = true, PerfectDeflect = true, Mikiri = true, Jumped = true, Dodged = true }

local Telemetry = {}

local tallies: { human: Tally, bot: Tally } = { human = {}, bot = {} }
local kills: { [string]: number } = {}
local outnumberedDeaths = 0
local deaths = 0
local deathblowKills = 0
local matches = 0
local lastBlow: { [Combatant]: string } = {}

local function bucket(c: Combatant): Tally
	return if c.player then tallies.human else tallies.bot
end

local function bump(tally: Tally, kind: string, field: string)
	local row = tally[kind]
	if not row then
		row = {}
		tally[kind] = row
	end
	row[field] = (row[field] or 0) + 1
end

local function summarize(): { string }
	local lines = {}
	local alarms = {}
	for _, side in { "human", "bot" } do
		local tally = (tallies :: any)[side] :: Tally
		local starts, perilousStarts, perilousResolved, perilousCountered = 0, 0, 0, 0
		for kind, row in tally do
			starts += row.Started or 0
			local parts = {}
			for field, count in row do
				table.insert(parts, `{field} {count}`)
			end
			table.sort(parts)
			table.insert(lines, `  [{side}] {kind}: {table.concat(parts, ", ")}`)
			if PERILOUS[kind] then
				perilousStarts += row.Started or 0
				for field, count in row do
					if field ~= "Started" then
						perilousResolved += count
						if COUNTERS[field] then
							perilousCountered += count
						end
					end
				end
			end
		end
		if side == "human" and starts >= 50 then
			local share = perilousStarts / starts
			if share > 0.2 then
				table.insert(alarms, string.format("perilous is %.0f%% of human attacks (> 20%%)", share * 100))
			end
		end
		if perilousResolved >= 20 then
			local counterRate = perilousCountered / perilousResolved
			if counterRate < 0.4 then
				table.insert(
					alarms,
					string.format("[%s] perilous countered only %.0f%% of the time (< 40%%)", side, counterRate * 100)
				)
			end
		end
	end
	local totalKills = 0
	for _, count in kills do
		totalKills += count
	end
	if totalKills >= 30 then
		for kind, count in kills do
			if kind ~= "Mist" and count / totalKills > 0.35 then
				table.insert(
					alarms,
					string.format("%s landed %.0f%% of killing blows (> 35%%)", kind, count / totalKills * 100)
				)
			end
		end
	end
	local killParts = {}
	for kind, count in kills do
		table.insert(killParts, `{kind} {count}`)
	end
	table.insert(lines, `  killing blows: {table.concat(killParts, ", ")}`)
	table.insert(
		lines,
		`  deaths by deathblow: {deathblowKills}/{deaths}   while outnumbered: {outnumberedDeaths}/{deaths}`
	)
	for _, alarm in alarms do
		table.insert(lines, `  ALARM: {alarm}`)
	end
	return lines
end

local function flush()
	local lines = summarize()
	matches += 1
	print(`[Telemetry] totals after {matches} match(es) on this server\n{table.concat(lines, "\n")}`)
	-- Roblox custom analytics: one event per human per match (the dashboard groups them).
	for _, player in Players:GetPlayers() do
		pcall(function()
			AnalyticsService:LogCustomEvent(player, "MatchPlayed", 1)
		end)
	end
end

function Telemetry.start()
	CombatService.onWindup(function(attacker: Combatant, kind: string)
		if Round.phase() == "Match" then
			bump(bucket(attacker), kind, "Started")
		end
	end)
	CombatService.onOutcome(function(kind: string, outcome: string, attacker: Combatant, target: Combatant?)
		if Round.phase() ~= "Match" then
			return
		end
		bump(bucket(attacker), kind, outcome)
		-- Credit kills to the move that struck, deathblow or not: a deathblow is the
		-- intended way to win, so it's reported as a share, not alarmed on.
		if target and (outcome == "Hit" or outcome == "Deathblow") then
			lastBlow[target] = kind -- CombatService marks deathblows via victim.executed
		end
	end)
	CombatService.onDied(function(victim: Combatant)
		if Round.phase() ~= "Match" then
			return
		end
		deaths += 1
		local strikers = 0
		for _ in victim.recentAttackers do
			strikers += 1
		end
		if strikers >= 2 then
			outnumberedDeaths += 1
		end
		if victim.executed then
			deathblowKills += 1
		end
		local blow = lastBlow[victim] or "Mist"
		kills[blow] = (kills[blow] or 0) + 1
		lastBlow[victim] = nil
	end)
	Round.state():GetAttributeChangedSignal("Phase"):Connect(function()
		if Round.phase() == "Results" then
			flush()
		end
	end)
end

return Telemetry
