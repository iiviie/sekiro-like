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
-- Bots are counted separately from humans: they play by fixed odds. Moves are keyed
-- "kind@weapon" (Light1@Odachi), so each weapon's numbers read on their own.
--
-- RoundService reports each royale's end (Telemetry.royaleEnded): every human who fought
-- gets a MatchPlayed and a RoyaleResult event (value: place; fields: bot tier, weapon, win or
-- loss) and a RoyaleSeconds event (the match's length), and the printout keeps human results
-- by bot tier and by weapon, and the average match length. Lobby idlers aren't counted.

local AnalyticsService = game:GetService("AnalyticsService")
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
local matchSeconds = 0
local lastBlow: { [Combatant]: string } = {}
type Record = { played: number, wins: number, places: number }
local byTier: { [string]: Record } = {} -- humans' royale results by the match's bot tier
local byWeapon: { [string]: Record } = {} -- ...and by the weapon they fought with

-- Only the royale's blows count: duels and boss trials (Bosses' scripted hits, and your
-- swings against a boss) can run during a match and would skew its balance.
local function inRoyale(c: Combatant?): boolean
	return c ~= nil and Round.phase() == "Match" and c.model:GetAttribute("Arena") == "Royale"
end

local function bucket(c: Combatant): Tally
	return if c.player then tallies.human else tallies.bot
end

local function moveKey(c: Combatant, kind: string): string
	return `{kind}@{c.weapon}`
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
			if PERILOUS[string.split(kind, "@")[1]] then
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
	for label, records in { ["by bot tier"] = byTier, ["by weapon"] = byWeapon } do
		local parts = {}
		for key, r in records do
			table.insert(
				parts,
				string.format("%s %d/%d won, avg place %.1f", key, r.wins, r.played, r.places / r.played)
			)
		end
		table.sort(parts)
		table.insert(lines, `  human results {label}: {table.concat(parts, "; ")}`)
	end
	if matches > 0 then
		table.insert(lines, string.format("  average match length: %.0f s", matchSeconds / matches))
	end
	for _, alarm in alarms do
		table.insert(lines, `  ALARM: {alarm}`)
	end
	return lines
end

local function record(records: { [string]: Record }, key: string, place: number)
	local r = records[key]
	if not r then
		r = { played = 0, wins = 0, places = 0 }
		records[key] = r
	end
	r.played += 1
	r.places += place
	if place == 1 then
		r.wins += 1
	end
end

-- A royale has ended: `places` holds each human's finishing place, `weapons` the weapon
-- every human who fought started it with, `tier` the bots' tier, `seconds` its length.
function Telemetry.royaleEnded(
	places: { [Player]: number },
	weapons: { [Player]: string },
	tier: string,
	seconds: number
)
	matches += 1
	matchSeconds += seconds
	for player, weapon in weapons do
		local place = places[player]
		if place then
			record(byTier, tier, place)
			record(byWeapon, weapon, place)
		end
		-- Roblox custom analytics, for the humans who fought (published games only).
		if player.Parent then
			pcall(function()
				AnalyticsService:LogCustomEvent(player, "MatchPlayed", 1)
				AnalyticsService:LogCustomEvent(player, "RoyaleResult", place or 0, {
					[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = tier,
					[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = weapon,
					[Enum.AnalyticsCustomFieldKeys.CustomField03.Name] = if place == 1 then "win" else "loss",
				})
				AnalyticsService:LogCustomEvent(player, "RoyaleSeconds", math.round(seconds))
			end)
		end
	end
	local lines = summarize()
	print(
		`[Telemetry] royale {matches} ended after {math.round(seconds)} s (bots: {tier}); totals on this server\n{table.concat(
			lines,
			"\n"
		)}`
	)
end

function Telemetry.start()
	CombatService.onWindup(function(attacker: Combatant, kind: string)
		if inRoyale(attacker) then
			bump(bucket(attacker), moveKey(attacker, kind), "Started")
		end
	end)
	CombatService.onOutcome(function(kind: string, outcome: string, attacker: Combatant, target: Combatant?)
		if not inRoyale(attacker) or (target and not inRoyale(target)) then
			return
		end
		bump(bucket(attacker), moveKey(attacker, kind), outcome)
		-- Credit kills to the move that struck, deathblow or not: a deathblow is the
		-- intended way to win, so it's reported as a share, not alarmed on.
		if target and (outcome == "Hit" or outcome == "Deathblow") then
			lastBlow[target] = kind -- CombatService marks deathblows via victim.executed
		end
	end)
	CombatService.onDied(function(victim: Combatant)
		if not inRoyale(victim) then
			lastBlow[victim] = nil
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
end

return Telemetry
