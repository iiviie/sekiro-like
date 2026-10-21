--!strict
-- Rewards for good play, as they happen. Every deflect, kill and win pays XP (and some
-- coins) the moment it lands, with a toast on the player's screen; XP fills Mastery levels
-- that pay coins (and every 5th, gems and Whetstones); daily Trials track events and pay out
-- when complete; and each match ends with a report card of what you did. Numbers live in
-- Shared/EconomyConfig; currencies move through server/Economy (logged, checked).
--
-- Anti-farm: a fighter's kill coins pay once per match (finishing someone who rose from a
-- cut-down pays XP only); duels against the same human pay less after the second that day
-- (EconomyConfig.AntiFarm); Whetstones and Shrine Draws from wins are capped per day.
--
-- Remotes (server -> one client), on ReplicatedStorage.Remotes.Progress:
--   "Reward"  { xp, coins, reason }         a toast
--   "LevelUp" { level, coins }
--   "Trial"   { id, text, coins, xp }       a trial completed
--   "Unlock"  { id, name, category }         an item granted by a rule (server/Economy)
--   "Notice"  { text }                        a line of feedback (server/Monetization)
--   "Report"  { placement, fighters, kills, deathblows, deflects, perfects, xp, coins, won,
--               duel? { score, opponent, rating? } }   (duel: "3 - 1", their name, rating change)

local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local Progression = require(ReplicatedStorage.Shared.Progression)
local Round = require(ReplicatedStorage.Shared.Round)
local CombatService = require(script.Parent.CombatService)
local Economy = require(script.Parent.Economy)
local StatsService = require(script.Parent.StatsService)

type Combatant = CombatService.Combatant

local ProgressService = {}

local remote: RemoteEvent

type Report = {
	kills: number,
	deathblows: number,
	deflects: number,
	perfects: number,
	xp: number,
	coins: number,
}
local reports: { [Player]: Report } = {}

-- Onboarding funnel (Creator Dashboard > Analytics > Funnels): where first-time players
-- drop off. Logged once per step, only for players on their very first visit.
local FUNNEL = { "Entered", "First match", "First deflect", "First cut down", "Match finished", "Second match" }
local funnelReached: { [Player]: number } = {}

local function funnel(player: Player, step: number)
	local reached = funnelReached[player]
	if not reached or step <= reached then
		return -- not a first-time player, or already logged
	end
	funnelReached[player] = step
	pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, step, FUNNEL[step])
	end)
end

local today = EconomyConfig.day

-- Victims whose kill reward was already paid this life cycle (a cut-down, then the death).
local paidVictims: { [Combatant]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function reportOf(player: Player): Report?
	return reports[player]
end

-- Pays XP and coins, levels up as often as the XP allows, and shows a toast. XP also counts
-- toward the weapon in hand's Mastery. Milestone levels pay gems and Whetstones on top.
local function grant(player: Player, xp: number, coins: number, reason: string?)
	local d = StatsService.get(player)
	xp, coins = math.floor(xp), math.floor(coins)
	if not d or (xp <= 0 and coins <= 0) then
		return
	end
	if coins > 0 then
		Economy.grant(player, "Coins", coins, reason or "Reward", "Gameplay", true)
	end
	d.XP += xp
	if xp > 0 then
		-- The blade in hand (equipping mid-match only changes the saved choice).
		local character = player.Character
		local weapon = (character and character:GetAttribute("Weapon")) or player:GetAttribute("Weapon")
		if typeof(weapon) == "string" and weapon ~= "" then
			d.WeaponXP[weapon] = (d.WeaponXP[weapon] or 0) + xp
		end
	end
	local report = reportOf(player)
	if report then
		report.xp += xp
		report.coins += coins
	end
	while d.XP >= Progression.xpToNext(d.Level) do
		d.XP -= Progression.xpToNext(d.Level)
		d.Level += 1
		local bonus = Progression.levelReward(d.Level)
		local milestone = EconomyConfig.isMilestone(d.Level)
		local gems, stones = 0, 0
		if milestone then
			local m = EconomyConfig.Milestone
			bonus += m.Coins
			gems, stones = m.Gems, m.Whetstones
			Economy.grant(player, "Gems", gems, `Mastery {d.Level}`, "Gameplay", true)
			Economy.grant(player, "Whetstones", stones, `Mastery {d.Level}`, "Gameplay", true)
		end
		Economy.grant(player, "Coins", bonus, `Mastery {d.Level}`, "Gameplay", true)
		if report then
			report.coins += bonus
		end
		remote:FireClient(player, "LevelUp", {
			level = d.Level,
			coins = bonus,
			gems = if gems > 0 then gems else nil,
			whetstones = if stones > 0 then stones else nil,
		})
	end
	StatsService.commit(player)
	if reason then
		remote:FireClient(player, "Reward", { xp = xp, coins = coins, reason = reason })
	end
end

-- Earn-only extras (Whetstones, Shrine Draws, Pass XP): no toast of their own.
local function extra(player: Player, currency: Economy.Currency, amount: number, reason: string)
	if amount > 0 then
		Economy.grant(player, currency, amount, reason, "Gameplay")
	end
end

-- A win's Whetstones and (royale) Shrine Draw, under the daily caps.
local function winExtras(player: Player, royale: boolean)
	local stones = EconomyConfig.Whetstones
	if Economy.dayCount(player, "winStones", 1) < stones.WinCapPerDay then
		extra(player, "Whetstones", if royale then stones.RoyaleWin else stones.DuelWin, "Win")
	end
	local draws = EconomyConfig.Draws
	if royale then
		if Economy.dayCount(player, "royaleDraws", 1) < draws.RoyaleWinCapPerDay then
			extra(player, "Draws", draws.RoyaleWin, "Royale win")
		end
	elseif Economy.dayCount(player, "duelDraws", 1) < draws.DuelWinPerDay then
		extra(player, "Draws", 1, "Duel win")
	end
end

local function passXP(player: Player, amount: number, reason: string)
	extra(player, "PassXP", amount, reason)
end

local function reward(player: Player, event: string, reason: string?, factor: number?)
	local r = Progression.Rewards[event]
	local f = factor or 1
	if r and f > 0 then
		grant(player, (r.XP or 0) * f, (r.Coins or 0) * f, reason)
	end
end

-- Advances any of today's trials listening for `event`; completed ones pay at once.
local function trialEvent(player: Player, event: string, amount: number?)
	local d = StatsService.get(player)
	if not d then
		return
	end
	local day = today()
	if d.TrialDay ~= day then
		d.TrialDay = day
		table.clear(d.TrialProgress)
	end
	local changed = false
	for _, id in Progression.dailyTrials(player.UserId, day) do
		local trial = Progression.trial(id)
		if trial and trial.event == event then
			local before = d.TrialProgress[id] or 0
			if before < trial.goal then
				local after = math.min(trial.goal, before + (amount or 1))
				d.TrialProgress[id] = after
				changed = true
				if after >= trial.goal then
					remote:FireClient(
						player,
						"Trial",
						{ id = id, text = trial.text, coins = trial.coins, xp = trial.xp }
					)
					grant(player, trial.xp, trial.coins, nil)
					extra(player, "Whetstones", EconomyConfig.Whetstones.Trial, "Trial")
				end
			end
		end
	end
	if changed then
		StatsService.commit(player)
	end
end

-- Rewards count only in a fight that matters: the royale while it runs, or a duel. Lobby
-- sparring never pays, so it can't be farmed.
local function scoring(c: Combatant?): boolean
	if not c then
		return false
	end
	if c.model:GetAttribute("InDuel") == true then
		return true
	end
	return Round.phase() == "Match" and c.model:GetAttribute("InMatch") == true
end

-- Called by RoundService when a match starts (and DuelService when a duel does), with the
-- humans fighting in it. A royale and duels can run at once, so reports are per player.
function ProgressService.matchStarted(players: { Player })
	for _, player in players do
		funnel(player, if (funnelReached[player] or 0) >= 5 then 6 else 2)
		reports[player] = { kills = 0, deathblows = 0, deflects = 0, perfects = 0, xp = 0, coins = 0 }
	end
end

-- Called by RoundService with every human participant's place (1 = winner) among all
-- `fighters`, bots included.
function ProgressService.matchEnded(places: { [Player]: number }, fighters: number, winner: Player?)
	for player, place in places do
		if player.Parent then
			funnel(player, 5)
			reward(player, "Played", "Match fought")
			passXP(player, EconomyConfig.Pass.Played, "Match fought")
			trialEvent(player, "Played")
			-- Placement among every fighter (bots count): outlasting them is worth something.
			local report = reports[player]
			local outlasted = math.max(0, fighters - place)
			if outlasted > 0 then
				local per = Progression.Rewards.Outlasted.XP or 0
				grant(player, per * outlasted, 0, `Outlasted {outlasted}`)
			end
			if place <= 3 then
				trialEvent(player, "Top3")
			end
			if player == winner then
				reward(player, "Win", "Victory")
				passXP(player, EconomyConfig.Pass.Win, "Victory")
				winExtras(player, true)
				trialEvent(player, "Win")
			end
			if report then
				remote:FireClient(player, "Report", {
					placement = place,
					fighters = fighters,
					kills = report.kills,
					deathblows = report.deathblows,
					deflects = report.deflects,
					perfects = report.perfects,
					xp = report.xp,
					coins = report.coins,
					won = player == winner,
				})
			end
		end
		reports[player] = nil
	end
end

export type DuelResult = { won: boolean, rounds: number, score: string, opponent: string, rating: number? }

-- Called by DuelService with each human duellist's result. A duel pays for the fight and
-- for every round taken, and a win pays about half a royale win; it counts toward the
-- "fight" trial but not the royale-only ones (top 3, win a royale). The third and later duel
-- against the same human in a day pays less (StatsService.recordDuel counts them).
function ProgressService.duelEnded(results: { [Player]: DuelResult })
	for player, result in results do
		if player.Parent then
			local factor = StatsService.lastDuelFactor(player)
			funnel(player, 5)
			reward(player, "Played", "Duel fought", factor)
			trialEvent(player, "Played")
			if factor > 0 then
				passXP(player, EconomyConfig.Pass.Played * factor, "Duel fought")
			end
			local perRound = Progression.Rewards.DuelRound.XP or 0
			if result.rounds > 0 and factor > 0 then
				grant(
					player,
					perRound * result.rounds * factor,
					0,
					if result.rounds == 1 then "Round taken" else `{result.rounds} rounds taken`
				)
			end
			if result.won and factor > 0 then
				reward(player, "DuelWin", "Duel won", factor)
				passXP(player, EconomyConfig.Pass.Win * factor, "Duel won")
				if factor >= 1 then
					winExtras(player, false)
				end
			end
			local report = reports[player]
			if report then
				remote:FireClient(player, "Report", {
					placement = if result.won then 1 else 2,
					fighters = 2,
					kills = report.kills,
					deathblows = report.deathblows,
					deflects = report.deflects,
					perfects = report.perfects,
					xp = report.xp,
					coins = report.coins,
					won = result.won,
					duel = { score = result.score, opponent = result.opponent, rating = result.rating },
				})
			end
		end
		reports[player] = nil
	end
end

-- A boss duel's result (BossService): "Boss fought", XP per life taken, a clear scaled by the
-- boss's stars, and a one-time first-clear bonus; then the report card.
export type BossResult = {
	boss: string, -- Shared/Bosses id
	name: string,
	stars: number,
	won: boolean,
	lives: number, -- lives (deathblows) taken from the boss
	time: number, -- seconds
}
function ProgressService.bossEnded(player: Player, result: BossResult): boolean
	if not player.Parent then
		reports[player] = nil
		return false
	end
	local rewards = EconomyConfig.Boss
	local function pay(r: any, times: number, reason: string)
		grant(player, math.floor((r.XP or 0) * times), math.floor((r.Coins or 0) * times), reason)
	end
	funnel(player, 5)
	pay(rewards.Fought, 1, "Boss fought")
	passXP(player, EconomyConfig.Pass.Played, "Boss fought")
	trialEvent(player, "Played")
	if result.lives > 0 then
		pay(rewards.Phase, result.lives, if result.lives == 1 then "Life taken" else `{result.lives} lives taken`)
	end
	local first = false
	if result.won then
		local stars = math.max(result.stars, 1)
		pay(rewards.Clear, stars, `{result.name} defeated`)
		extra(player, "Whetstones", rewards.Clear.Whetstones * stars, "Boss clear")
		local d = StatsService.get(player)
		if d then
			first = (d.BossClears[result.boss] or 0) == 0
			d.BossClears[result.boss] = (d.BossClears[result.boss] or 0) + 1
			StatsService.commit(player)
		end
		if first then
			local firstClear = rewards.FirstClear
			pay(firstClear, 1, "First clear")
			extra(player, "Whetstones", firstClear.Whetstones, "First clear")
			local gems = firstClear.Gems + firstClear.GemsPerStar * result.stars
			Economy.grant(player, "Gems", gems, `First clear {result.boss}`, "Gameplay")
			remote:FireClient(
				player,
				"Reward",
				{ xp = 0, coins = 0, gems = gems, reason = `First clear  ·  +{gems} gems` }
			)
		end
	end
	local report = reports[player]
	if report then
		local minutes = math.floor(result.time / 60)
		local seconds = math.floor(result.time % 60)
		remote:FireClient(player, "Report", {
			placement = if result.won then 1 else 2,
			fighters = 2,
			-- A boss's lives are taken by deathblows its AI absorbs (no Died event to count).
			kills = math.max(report.kills, if result.won then 1 else 0),
			deathblows = math.max(report.deathblows, result.lives),
			boss = true,
			deflects = report.deflects,
			perfects = report.perfects,
			xp = report.xp,
			coins = report.coins,
			won = result.won,
			duel = {
				score = if result.won then string.format("Cleared  %d:%02d", minutes, seconds) else "Fallen",
				opponent = result.name,
			},
		})
	end
	reports[player] = nil
	return first
end

local function onOutcome(kind: string, outcome: string, attacker: Combatant, target: Combatant?)
	local defender = target and target.player
	if defender and scoring(target) then
		local d = StatsService.get(defender)
		local report = reports[defender]
		if outcome == "Deflect" or outcome == "PerfectDeflect" then
			if d then
				d.Deflects += 1
				if outcome == "PerfectDeflect" then
					d.Perfects += 1
				end
			end
			if report then
				report.deflects += 1
				if outcome == "PerfectDeflect" then
					report.perfects += 1
				end
			end
			reward(defender, outcome, nil)
			funnel(defender, 3)
			trialEvent(defender, "Deflect")
			if outcome == "PerfectDeflect" then
				trialEvent(defender, "PerfectDeflect")
			end
		elseif outcome == "Mikiri" or outcome == "Jumped" then
			if outcome == "Mikiri" then
				if d then
					d.Mikiris += 1
				end
				reward(defender, "Mikiri", "Mikiri Counter")
			end
			trialEvent(defender, outcome)
		end
	end
	local striker = attacker.player
	if striker and kind == "Riposte" and outcome == "Hit" and scoring(attacker) then
		trialEvent(striker, "Riposte")
	end
end

-- Kills and deathblows count in fights that matter only. A fighter pays out once per life
-- cycle: the cut-down pays, and finishing the same fighter after they rise pays XP only.
local function onKill(victim: Combatant, killer: Combatant?, deathblow: boolean)
	local player = killer and killer.player
	if not player or not scoring(killer) then
		return
	end
	local d = StatsService.get(player)
	if paidVictims[victim] then
		local xp = Progression.Rewards.Kill.XP or 0
		grant(player, xp, 0, "Finished")
		return
	end
	paidVictims[victim] = true
	-- A duel against a human you've fought often today pays less (anti-farm).
	local factor = 1
	local other = victim.player
	if other and (killer :: Combatant).model:GetAttribute("InDuel") == true then
		factor = EconomyConfig.repeatFactor(StatsService.duelsToday(player, other))
	end
	if d then
		d.Kills += 1
		if deathblow then
			d.Deathblows += 1
		end
	end
	local report = reports[player]
	if report then
		report.kills += 1
		if deathblow then
			report.deathblows += 1
		end
	end
	reward(player, "Kill", "Cut down", factor)
	funnel(player, 4)
	trialEvent(player, "Kill")
	if deathblow then
		reward(player, "Deathblow", "Deathblow", factor)
		trialEvent(player, "Deathblow")
	end
	StatsService.commit(player)
end

function ProgressService.start()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	remote = Instance.new("RemoteEvent")
	remote.Name = "Progress"
	remote.Parent = remotes

	Players.PlayerRemoving:Connect(function(player)
		funnelReached[player] = nil
		reports[player] = nil
	end)
	CombatService.onOutcome(onOutcome)
	CombatService.onDied(onKill)
	CombatService.onCutDown(onKill)

	-- Keep today's trial list fresh on join, and start the funnel for first-time players
	-- once their data has loaded (Played == 0) and they're past the title card.
	Players.PlayerAdded:Connect(function(player)
		player:GetAttributeChangedSignal("Entered"):Once(function()
			if player:GetAttribute("Played") == 0 then
				funnelReached[player] = 0
				funnel(player, 1)
			end
		end)
		task.delay(5, function()
			if player.Parent then
				trialEvent(player, "")
			end
		end)
	end)
end

return ProgressService
