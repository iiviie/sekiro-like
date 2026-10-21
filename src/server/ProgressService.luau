--!strict
-- Rewards for good play, as they happen. Every deflect, kill and win pays XP (and some
-- coins) the moment it lands, with a toast on the player's screen; XP fills Mastery levels
-- that pay coins; daily Trials track events and pay out when complete; and each match ends
-- with a report card of what you did. Numbers live in Shared/Progression.
--
-- Remotes (server -> one client), on ReplicatedStorage.Remotes.Progress:
--   "Reward"  { xp, coins, reason }         a toast
--   "LevelUp" { level, coins }
--   "Trial"   { id, text, coins, xp }       a trial completed
--   "Report"  { placement, fighters, kills, deathblows, deflects, perfects, xp, coins, won,
--               duel? { score, opponent, rating? } }   (duel: "3 - 1", their name, rating change)
-- Skin requests arrive on LobbyAction ("BuySkin" / "EquipSkin", handled in LobbyService).

local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Progression = require(ReplicatedStorage.Shared.Progression)
local Round = require(ReplicatedStorage.Shared.Round)
local CombatService = require(script.Parent.CombatService)
local StatsService = require(script.Parent.StatsService)

type Combatant = CombatService.Combatant

local SECONDS_PER_DAY = 86400

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

local function today(): number
	return math.floor(os.time() / SECONDS_PER_DAY)
end

local function reportOf(player: Player): Report?
	return reports[player]
end

-- Pays XP and coins, levels up as often as the XP allows, and shows a toast.
local function grant(player: Player, xp: number, coins: number, reason: string?)
	local d = StatsService.get(player)
	if not d or (xp <= 0 and coins <= 0) then
		return
	end
	d.Coins += coins
	d.XP += xp
	local report = reportOf(player)
	if report then
		report.xp += xp
		report.coins += coins
	end
	while d.XP >= Progression.xpToNext(d.Level) do
		d.XP -= Progression.xpToNext(d.Level)
		d.Level += 1
		local bonus = Progression.levelReward(d.Level)
		d.Coins += bonus
		if report then
			report.coins += bonus
		end
		remote:FireClient(player, "LevelUp", { level = d.Level, coins = bonus })
	end
	StatsService.commit(player)
	if reason then
		remote:FireClient(player, "Reward", { xp = xp, coins = coins, reason = reason })
	end
end

local function reward(player: Player, event: string, reason: string?)
	local r = Progression.Rewards[event]
	if r then
		grant(player, r.XP or 0, r.Coins or 0, reason)
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
-- "fight" trial but not the royale-only ones (top 3, win a royale).
function ProgressService.duelEnded(results: { [Player]: DuelResult })
	for player, result in results do
		if player.Parent then
			funnel(player, 5)
			reward(player, "Played", "Duel fought")
			trialEvent(player, "Played")
			local perRound = Progression.Rewards.DuelRound.XP or 0
			if result.rounds > 0 then
				grant(
					player,
					perRound * result.rounds,
					0,
					if result.rounds == 1 then "Round taken" else `{result.rounds} rounds taken`
				)
			end
			if result.won then
				reward(player, "DuelWin", "Duel won")
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
	local rewards = Config.Bosses.Rewards
	local function pay(r: { XP: number?, Coins: number? }, times: number, reason: string)
		grant(player, math.floor((r.XP or 0) * times), math.floor((r.Coins or 0) * times), reason)
	end
	funnel(player, 5)
	pay(rewards.Fought, 1, "Boss fought")
	trialEvent(player, "Played")
	if result.lives > 0 then
		pay(rewards.Phase, result.lives, if result.lives == 1 then "Life taken" else `{result.lives} lives taken`)
	end
	local first = false
	if result.won then
		pay(rewards.Clear, math.max(result.stars, 1), `{result.name} defeated`)
		local d = StatsService.get(player)
		if d then
			first = (d.BossClears[result.boss] or 0) == 0
			d.BossClears[result.boss] = (d.BossClears[result.boss] or 0) + 1
			StatsService.commit(player)
		end
		if first then
			pay(rewards.FirstClear, 1, "First clear")
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

local function onKill(_victim: Combatant, killer: Combatant?, deathblow: boolean)
	local player = killer and killer.player
	if not player or not scoring(killer) then
		return
	end
	local report = reports[player]
	if report then
		report.kills += 1
		if deathblow then
			report.deathblows += 1
		end
	end
	reward(player, "Kill", "Cut down")
	funnel(player, 4)
	trialEvent(player, "Kill")
	if deathblow then
		reward(player, "Deathblow", "Deathblow")
		trialEvent(player, "Deathblow")
	end
end

-- Skins: buy once the unlock condition is met, then equip.
function ProgressService.skinUnlocked(player: Player, id: string): boolean
	local skin = Progression.skin(id)
	local d = StatsService.get(player)
	if not d or skin.id ~= id then
		return false
	end
	local rule = skin.unlock
	return rule == nil or ((d :: any)[rule.stat] or 0) >= rule.amount
end

function ProgressService.buySkin(player: Player, id: string): boolean
	local skin = Progression.skin(id)
	local d = StatsService.get(player)
	if not d or skin.id ~= id or d.OwnedSkins[id] or not ProgressService.skinUnlocked(player, id) then
		return false
	end
	if not StatsService.spend(player, "Coins", skin.price) then
		return false
	end
	d.OwnedSkins[id] = true
	d.Skin = id
	StatsService.commit(player)
	return true
end

function ProgressService.equipSkin(player: Player, id: string): boolean
	local d = StatsService.get(player)
	if not d or not d.OwnedSkins[id] then
		return false
	end
	d.Skin = id
	StatsService.commit(player)
	return true
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
