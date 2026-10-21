--!strict
-- A Kannagi Usagi boss brain: replays the boss's decoded AI (Shared/KannagiMoves deck data)
-- step by step. Faithful to EnemyBase's framework (research_notes/Kannagi Usagi RE/
-- boss_movesets.md):
--
--   Main      a shuffle-bag deck of patterns (no immediate repeat, special openers 100/101
--             inserted at the front); each pattern is a step script: timed waits, strafes,
--             approaches to a range, moves (one animation, any number of scheduled hits),
--             attack-sign watches, phase / range / cooldown branches, random and MultiGate
--             choices. While idle or moving (not in an action) the boss raises a plain guard
--             the instant it sees your swing (ReceiveAttackSign).
--   Reactions the boss's flinch, guard success (-> the guard deck's counters), parry (-> the
--             parry deck's counters), recoil when you deflect a recoil hit, Mikiri, stomp,
--             break, deathblow (-> phase 2), death, and circling a downed player.
--   Flags     Kannagi's Guard / Hajiki / HajikiDisable / SuperArmor, reset by every move and
--             set by the deck data and the move's notifies; CombatService reads them as they
--             stood at each blow's impact (bossGuard).
--   Cooldowns SkillGroupCoolCount: groups counted in moves, decremented by the moves marked
--             `dec`, reset to the CDO child value by `set`.
--
-- Movement: locomotion through the Humanoid (Move + WalkSpeed), turning through a capped
-- AlignOrientation (the op's turn rate, or the move's lookAtPlayer windows during an
-- action), and authored root motion through a LinearVelocity, stopped short of the target.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Bosses = require(ReplicatedStorage.Shared.Bosses)
local Config = require(ReplicatedStorage.Shared.Config)
local KannagiMoves = require(ReplicatedStorage.Shared.KannagiMoves)
local Spacing = require(ReplicatedStorage.Shared.Spacing)
local CombatService = require(script.Parent.CombatService)

type Combatant = CombatService.Combatant
type Move = KannagiMoves.Move
type Step = { [string]: any }

type Deck = {
	role: string,
	queue: { number },
	last: number?,
	started: boolean,
}

type Action = {
	key: string,
	move: Move,
	startedAt: number,
	endsAt: number,
	events: { { at: number, flag: string, value: any } },
	armorUntil: number, -- BP-set super armour ends here (SuperArmorFlagSet_AN)
	armorLevel: number,
	windows: { { from: number, to: number, level: number } },
	token: number,
}

type FlagSample = { t: number, guard: boolean, hajiki: boolean, hajikiDisable: boolean }

type Loco = { fwd: number, right: number, speed: number, turnRate: number, dot: number }

export type Brain = {
	id: string,
	data: KannagiMoves.Boss,
	c: Combatant,
	target: Combatant?,
	zp: number,
	phase: number,
	decks: { [string]: Deck },
	cool: { number },
	gates: { [any]: { used: { [number]: boolean }, flip: number, started: boolean } },
	flags: { guard: boolean, hajiki: boolean, hajikiDisable: boolean, superArmor: number },
	flagLog: { FlagSample },
	action: Action?,
	actionSeq: number,
	thread: thread?,
	mode: string, -- "main" | a reaction name
	reactionStart: number,
	pending: { name: string, priority: number, arg: any }?,
	hajikiReaction: number, -- the player's latest swing side as the boss sees it: 0 right, 2 left
	signFrom: number,
	signUntil: number,
	signBy: Combatant?,
	loco: Loco?,
	turnRate: number?, -- an op's turn toward the target (no walking)
	align: AlignOrientation,
	push: LinearVelocity,
	stopped: boolean,
	defeated: boolean,
	openerUsed: boolean,
	log: { string }, -- recent moves and reactions, for tests
	breakHandled: boolean,
	lastDeflectedAt: number,
	reflex: boolean,
	allSuperArmor: boolean,
	connection: RBXScriptConnection?,
	-- Callbacks for BossService.
	onPhase: ((brain: Brain) -> ())?,
	onStage: ((brain: Brain, lesson: string?) -> ())?,
	onDefeated: ((brain: Brain) -> ())?,
}

local BossAI = {}

local combatEvent: RemoteEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CombatEvent") :: RemoteEvent

local CM_PER_STUD = 28
local FLAG_HISTORY = 2 -- seconds of flag samples kept for impact-time reads
local PRIORITY: { [string]: number } = {
	die = 100,
	ninsatsu = 100,
	["break"] = 90,
	breakReHajiki = 90,
	reMikiri = 60,
	reFumitsuke = 60,
	reHajiki = 50,
	damage = 40,
	hajiki = 30,
	guardSuccess = 30,
	revival = 20,
	playerDie = 20,
	guardKamae01 = 10,
}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function broadcast(kind: string, data: { [string]: any })
	combatEvent:FireAllClients(kind, data)
end

---------------------------------------------------------------------------------------
-- Decks (AIA_ArrFormat / AIA_ArrReset / AIA_ArrNext)

local function deckDefs(brain: Brain): { [string]: any }
	return brain.data.deck.decks
end

-- The id -> pattern table a role reads now: the tutorial stage's, phase 2's, or the base.
local function tableFor(brain: Brain, role: string): { [string]: any }?
	local decks = deckDefs(brain)
	local stages = brain.data.deck.stages
	if stages and stages.list then
		local stage = stages.list[tostring(brain.zp)]
		local names = stage and stage.decks
		if names and names[role] then
			return decks[names[role]]
		end
	end
	if brain.phase >= 2 then
		local p2 = decks[role .. "Phase2"]
		if p2 then
			return p2
		end
	end
	return decks[role]
end

local function shuffled(size: number, avoidFirst: number?): { number }
	local ids = {}
	for i = 0, size - 1 do
		table.insert(ids, i)
	end
	for i = #ids, 2, -1 do
		local j = math.random(1, i)
		ids[i], ids[j] = ids[j], ids[i]
	end
	if avoidFirst ~= nil and #ids > 1 and ids[1] == avoidFirst then
		local j = math.random(2, #ids)
		ids[1], ids[j] = ids[j], ids[1]
	end
	return ids
end

local function deckOf(brain: Brain, role: string): Deck
	local deck = brain.decks[role]
	if not deck then
		deck = { role = role, queue = {}, last = nil, started = false }
		brain.decks[role] = deck
	end
	return deck
end

local function refill(brain: Brain, deck: Deck, first: boolean)
	local def = tableFor(brain, deck.role)
	local size = if def then def.size else 1
	local queue = shuffled(size, if first then nil else deck.last)
	if first and def and def.forceFirst ~= nil then
		local index = table.find(queue, def.forceFirst)
		if index then
			queue[1], queue[index] = queue[index], queue[1]
		end
	end
	for _, id in queue do
		table.insert(deck.queue, id)
	end
end

local function start(brain: Brain, deck: Deck)
	deck.started = true
	table.clear(deck.queue)
	refill(brain, deck, true)
	if deck.role == "main" and not brain.openerUsed and brain.data.deck.special["100"] then
		table.insert(deck.queue, 1, 100)
	end
	if deck.role == "main" then
		brain.openerUsed = true
	end
end

local function current(brain: Brain, deck: Deck): number
	if not deck.started then
		start(brain, deck)
	end
	if #deck.queue == 0 then
		refill(brain, deck, false)
	end
	return deck.queue[1]
end

local function advance(brain: Brain, deck: Deck)
	if not deck.started then
		start(brain, deck)
		return
	end
	local popped = table.remove(deck.queue, 1)
	if popped and popped < 100 then
		deck.last = popped
	end
end

local function patternFor(brain: Brain, role: string, id: number): (string?, { [string]: any }?)
	local key: string?
	if id >= 100 then
		key = brain.data.deck.special[tostring(id)]
	else
		local def = tableFor(brain, role)
		key = def and def.ids[tostring(id)]
	end
	local pattern = key and brain.data.deck.patterns[key]
	return key, pattern
end

---------------------------------------------------------------------------------------
-- Cooldowns (SkillGroupCoolCount)

local function cooldownReady(brain: Brain, group: number): boolean
	return (brain.cool[group + 1] or 0) <= 0
end

local function applyCooldown(brain: Brain, cooldown: { [string]: any }?)
	if not cooldown then
		return
	end
	if cooldown.dec then
		for i, value in brain.cool do
			if value > 0 then
				brain.cool[i] = value - 1
			end
		end
	end
	local group = cooldown.set
	if typeof(group) == "number" then
		local child = brain.data.stats.cooldownChild
		brain.cool[group + 1] = if child then child[group + 1] or 0 else 0
	end
end

local function runnable(brain: Brain, pattern: { [string]: any }): boolean
	local phase = pattern.phase
	if phase == "1" and brain.phase ~= 1 then
		return false
	elseif phase == "2" and brain.phase ~= 2 then
		return false
	end
	local group = pattern.cooldownGroup
	if typeof(group) == "number" and pattern.skipIfNotReady ~= false and not cooldownReady(brain, group) then
		return false
	end
	return true
end

---------------------------------------------------------------------------------------
-- Flags and the action (IsActionAnim)

local function logFlags(brain: Brain)
	local t = now()
	local f = brain.flags
	local log = brain.flagLog
	local last = log[#log]
	if last and last.guard == f.guard and last.hajiki == f.hajiki and last.hajikiDisable == f.hajikiDisable then
		return
	end
	table.insert(log, { t = t, guard = f.guard, hajiki = f.hajiki, hajikiDisable = f.hajikiDisable })
	while #log > 2 and log[2].t < t - FLAG_HISTORY do
		table.remove(log, 1)
	end
end

local function flagsAt(brain: Brain, t: number): (boolean, boolean, boolean)
	local log = brain.flagLog
	for i = #log, 1, -1 do
		local sample = log[i]
		if sample.t <= t then
			return sample.guard, sample.hajiki, sample.hajikiDisable
		end
	end
	local f = brain.flags
	return f.guard, f.hajiki, f.hajikiDisable
end

local function setFlag(brain: Brain, flag: string, value: any)
	local f = brain.flags :: any
	if flag == "superArmor" then
		f.superArmor = if typeof(value) == "number" then value elseif value then 1 else 0
	elseif flag == "weaponOff" then
		-- The interrupted swing's collider is already cancelled by the new move.
		return
	elseif f[flag] ~= nil then
		f[flag] = value == true
	end
	logFlags(brain)
end

local function inAction(brain: Brain): boolean
	local action = brain.action
	return action ~= nil and now() < action.endsAt
end

local function clearFlags(brain: Brain)
	local f = brain.flags
	f.guard, f.hajiki, f.hajikiDisable = false, false, false
	f.superArmor = if brain.allSuperArmor then 1 else 0
	logFlags(brain)
end

local function distance(brain: Brain): number
	local target = brain.target
	if not target then
		return math.huge
	end
	return flat(target.root.Position - brain.c.root.Position).Magnitude
end

-- The flat distance at which the boss's body meets its target's (plus the stop margin).
local function contactStop(brain: Brain): number
	local target = brain.target
	return if target
		then Spacing.contact(brain.c.model, target.model) + Config.Spacing.StopMargin
		else Config.Spacing.Radius * 2
end

-- Kannagi's ReceiveAttackSign: the target's swing sphere overlaps the boss right now.
local function attackSign(brain: Brain): boolean
	local t = now()
	return t >= brain.signFrom and t <= brain.signUntil and distance(brain) <= Config.Bosses.SignRadius
end

-- The perilous tell (危) for the move's next Tsuki or Gedan hit.
local function kiken(brain: Brain, action: Action)
	local t = now()
	local until_ = t + 0.9
	for _, hit in action.move.hits do
		local at = action.startedAt + hit.at
		if (hit.type == "Tsuki" or hit.type == "Gedan") and at > t then
			until_ = at
			break
		end
	end
	broadcast("Kiken", { model = brain.c.model, duration = math.max(until_ - t, 0.35) })
end

-- PlayActionAnimation: starts a move, resetting the flags first (every action does), then
-- applies the step's `set`, the move's own flag notifies, its cooldown and its tell.
local function playMove(brain: Brain, key: string, step: Step?): Action?
	local move = brain.data.moves[key]
	if not move then
		warn(`[BossAI] {brain.id}: unknown move {key}`)
		return nil
	end
	local t = now()
	brain.actionSeq += 1
	local action: Action = {
		key = key,
		move = move,
		startedAt = t,
		endsAt = t + move.duration,
		events = {},
		armorUntil = math.huge,
		armorLevel = 0,
		windows = {},
		token = brain.actionSeq,
	}
	brain.action = action
	table.insert(brain.log, key)
	if #brain.log > 400 then
		table.remove(brain.log, 1)
	end
	brain.loco = nil
	brain.turnRate = nil
	clearFlags(brain)

	local flags = move.flags :: { [string]: any }
	if flags.guardFromStart then
		setFlag(brain, "guard", true)
	end
	if flags.parryFromStart then
		setFlag(brain, "hajiki", true)
	end
	local armor = flags.superArmor
	if typeof(armor) == "table" and typeof(armor.to) == "number" then
		action.armorUntil = t + armor.to
		-- The level comes from the BP's own set (below); the notify only marks where it ends.
	end
	for _, window in flags.superArmorWindows or {} do
		table.insert(action.windows, { from = t + window.from, to = t + window.to, level = window.level or 1 })
	end
	for _, event in flags.flagEvents or {} do
		table.insert(action.events, { at = t + event.at, flag = event.flag, value = event.value })
	end
	local set = step and step.set
	if set then
		for flag, value in set do
			setFlag(brain, flag, value)
		end
		if typeof(set.superArmor) == "number" then
			action.armorLevel = set.superArmor
		end
	end
	if step then
		applyCooldown(brain, step.cooldown)
	end

	-- Hits through CombatService, each on its own server time.
	local hits = {}
	for i, hit in move.hits do
		table.insert(hits, { kind = Bosses.kind(brain.id, key, i), at = t + hit.at })
	end
	if #hits > 0 then
		CombatService.scriptedAttack(brain.c, hits, action.endsAt)
	else
		CombatService.cancel(brain.c)
	end
	local relative = {}
	for _, hit in move.hits do
		table.insert(relative, hit.at)
	end
	broadcast("BossMove", {
		model = brain.c.model,
		boss = brain.id,
		anim = move.anim,
		key = key,
		at = t,
		duration = move.duration,
		hits = relative,
		types = (function()
			local types = {}
			for _, hit in move.hits do
				table.insert(types, hit.type)
			end
			return types
		end)(),
	})

	local tell = if step and step.kiken ~= nil then step.kiken else flags.kiken
	if typeof(tell) == "number" then
		local token = action.token
		task.delay(tell, function()
			if brain.action and brain.action.token == token and not brain.stopped then
				kiken(brain, action)
			end
		end)
	end
	return action
end

---------------------------------------------------------------------------------------
-- Step interpreter (runs inside the brain's thread; waits yield a frame at a time)

local function frame()
	RunService.Heartbeat:Wait()
end

local function waitUntil(predicate: () -> boolean)
	while not predicate() do
		frame()
	end
end

local function cond(brain: Brain, text: string): boolean
	if text == "phase1" then
		return brain.phase == 1
	elseif text == "phase2" then
		return brain.phase == 2
	elseif text == "attackSign" then
		return attackSign(brain)
	elseif text == "hajikiReaction==0" then
		return brain.hajikiReaction == 0
	elseif text == "hajikiReaction==2" then
		return brain.hajikiReaction == 2
	elseif text == "hajikiReaction==0 || hajikiReaction==2" then
		return brain.hajikiReaction == 0 or brain.hajikiReaction == 2
	end
	local zp = string.match(text, "^zp==(%d+)$")
	if zp then
		return brain.zp == tonumber(zp)
	end
	local within = string.match(text, "^dist<=([%d%.]+)$")
	if within then
		return distance(brain) <= (tonumber(within) :: number)
	end
	local beyond = string.match(text, "^dist>([%d%.]+)$")
	if beyond then
		return distance(brain) > (tonumber(beyond) :: number)
	end
	local group = string.match(text, "^cooldownReady:(%d+)$")
	if group then
		return cooldownReady(brain, tonumber(group) :: number)
	end
	local flag = string.match(text, "^!(%a+)$")
	if flag then
		return not (brain.flags :: any)[flag]
	end
	warn(`[BossAI] {brain.id}: unknown condition {text}`)
	return false
end

local function pick(brain: Brain, step: Step): { Step }?
	local options = step.options :: { { w: number?, steps: { Step } } }
	if #options == 0 then
		return nil
	end
	local mode = step.mode
	if mode == "multigate" or mode == "flipflop" then
		local key = step.id or step
		local gate = brain.gates[key]
		if not gate then
			gate = { used = {}, flip = (step.startIndex or 0) - 1, started = false }
			brain.gates[key] = gate
		end
		local index: number
		if mode == "flipflop" then
			gate.flip = (gate.flip + 1) % #options
			index = gate.flip + 1
		else
			local free = {}
			for i = 1, #options do
				if not gate.used[i] then
					table.insert(free, i)
				end
			end
			if #free == 0 then
				table.clear(gate.used)
				for i = 1, #options do
					table.insert(free, i)
				end
			end
			local first = step.startIndex
			if next(gate.used) == nil and typeof(first) == "number" and not gate.started then
				index = first + 1
				gate.started = true
			else
				index = free[math.random(1, #free)]
			end
			gate.used[index] = true
		end
		return options[index].steps
	end
	local total = 0
	for _, option in options do
		total += option.w or 1
	end
	local roll = math.random() * total
	for _, option in options do
		roll -= option.w or 1
		if roll <= 0 then
			return option.steps
		end
	end
	return options[#options].steps
end

local INSTANT: { [string]: boolean } =
	{ insert = true, note = true, cooldown = true, setFlag = true, ["if"] = true, next = true }

local runSteps: (brain: Brain, steps: { Step }, ended: boolean?) -> boolean

-- Movement intents: an approach, strafe or plain locomotion, held while `keep` is true.
local function locomote(brain: Brain, step: Step, keep: () -> boolean)
	if step.waitNotInAction then
		waitUntil(function()
			return not inAction(brain)
		end)
	end
	local fwd, right = step.fwd or 0, step.right or 0
	if step.op == "strafe" then
		local dir = step.dir
		right = if dir == "right" then 1 elseif dir == "left" then -1 else 0
		fwd = if dir == "back" then -1 elseif dir == "none" then 0 else step.fwd or 0
	elseif step.op == "approach" then
		fwd, right = 1, 0
	end
	local speed = step.speed or 0
	if step.speedCm == nil and speed > 30 then
		speed /= CM_PER_STUD -- a few reaction steps carry raw cm/s
	end
	brain.loco = { fwd = fwd, right = right, speed = speed, turnRate = step.turnRate or 500, dot = step.dot or 0.5 }
	while keep() do
		frame()
	end
	brain.loco = nil
end

local function waitStep(brain: Brain, step: Step, since: number): string?
	local t = step.t or 0
	local from = if step.from == "reactionStart" then brain.reactionStart else since
	local abort = step.abortIfFartherThan
	while now() < from + t do
		if typeof(abort) == "number" and distance(brain) > abort then
			return "abort"
		end
		frame()
	end
	return nil
end

-- The end of a pattern cut short (Kannagi's SubIndex 99): wait for the action, then the
-- pattern's closing next / insert steps.
local function abortPattern(brain: Brain, top: { Step }): boolean
	waitUntil(function()
		return not inAction(brain)
	end)
	local tail = {}
	for i = #top, 1, -1 do
		local op = top[i].op
		if op == "next" or op == "insert" then
			table.insert(tail, 1, top[i])
		else
			break
		end
	end
	if #tail == 0 then
		advance(brain, deckOf(brain, "main"))
		return true
	end
	return runSteps(brain, tail, false)
end

local currentTop: { [Brain]: { Step } } = {}

function runSteps(brain: Brain, steps: { Step }, ended: boolean?): boolean
	local done = ended == true
	local since = now()
	for _, step in steps do
		local op = step.op
		if done and not INSTANT[op] then
			continue
		end
		if op == "move" then
			playMove(brain, step.move, step)
		elseif op == "wait" then
			if waitStep(brain, step, since) == "abort" then
				return abortPattern(brain, currentTop[brain] or steps)
			end
		elseif op == "waitEnd" then
			waitUntil(function()
				return not inAction(brain)
			end)
		elseif op == "approach" then
			local until_ = step["until"] or 0
			-- Never closer than the two bodies can stand (Shared/Spacing), or it would walk on forever.
			local floor = contactStop(brain) + 0.1
			locomote(brain, step, function()
				return distance(brain) > math.max(until_, floor)
			end)
		elseif op == "strafe" or op == "locomote" then
			local endsAt = if typeof(step.dur) == "number" then now() + step.dur else math.huge
			local until_ = step["until"]
			locomote(brain, step, function()
				return now() < endsAt and not (typeof(until_) == "number" and distance(brain) <= until_)
			end)
		elseif op == "turn" then
			local endsAt = now() + (step.dur or 0.5)
			brain.turnRate = step.turnRate or 500
			waitUntil(function()
				return now() >= endsAt
			end)
			brain.turnRate = nil
		elseif op == "choose" then
			local chosen = pick(brain, step)
			if chosen and runSteps(brain, chosen, done) then
				done = true
			end
		elseif op == "if" then
			local branch = if cond(brain, step.cond) then step["then"] else step["else"]
			if branch and runSteps(brain, branch, done) then
				done = true
			end
		elseif op == "watch" then
			local endsAt = if step.untilEnd then nil else now() + (step.dur or 0)
			local fired = false
			while true do
				if endsAt then
					if now() >= endsAt then
						break
					end
				elseif not inAction(brain) then
					break
				end
				local blocked = step.unless and (brain.flags :: any)[step.unless] == true
				if not blocked and cond(brain, step.cond) then
					fired = true
					break
				end
				frame()
			end
			if fired and step["then"] and runSteps(brain, step["then"], false) then
				done = true
			end
		elseif op == "setFlag" then
			setFlag(brain, step.flag, step.value)
		elseif op == "kiken" then
			local action = brain.action
			if action then
				local token = action.token
				task.delay(step.delay or 0, function()
					if brain.action and brain.action.token == token and not brain.stopped then
						kiken(brain, action)
					end
				end)
			end
		elseif op == "cooldown" then
			applyCooldown(brain, step)
		elseif op == "insert" then
			local deck = deckOf(brain, step.deck or "main")
			if not deck.started then
				start(brain, deck)
			end
			table.insert(deck.queue, 1, step.id)
		elseif op == "next" then
			advance(brain, deckOf(brain, step.deck or "main"))
			done = true
		elseif op == "goto" then
			local pattern = brain.data.deck.patterns[step.pattern]
			if pattern then
				return runSteps(brain, pattern.steps, false)
			end
		end
		-- "note": nothing to do
		since = now()
	end
	return done
end

---------------------------------------------------------------------------------------
-- Threads: the main loop and reactions

local mainLoop: (brain: Brain) -> ()

local function replace(brain: Brain, fn: () -> ())
	local old = brain.thread
	brain.loco = nil
	brain.turnRate = nil
	brain.thread = task.spawn(fn)
	if old and old ~= coroutine.running() and coroutine.status(old) ~= "dead" then
		task.cancel(old)
	end
end

-- Dispatches a reactive deck (guard / hajiki): ArrNext before every dispatch (the first
-- time it formats the deck), then the first runnable slot, trying the next slot each tick.
local function runReactiveDeck(brain: Brain, role: string)
	local deck = deckOf(brain, role)
	if deck.started then
		advance(brain, deck)
	else
		start(brain, deck)
	end
	for _ = 1, 32 do
		local id = current(brain, deck)
		local key, pattern = patternFor(brain, role, id)
		if pattern and runnable(brain, pattern) then
			currentTop[brain] = pattern.steps
			if not runSteps(brain, pattern.steps, false) then
				advance(brain, deckOf(brain, "main"))
			end
			return
		end
		if not key then
			warn(`[BossAI] {brain.id}: {role} deck has no pattern for {id}`)
		end
		advance(brain, deck)
		frame()
	end
	advance(brain, deckOf(brain, "main"))
end

local function reactionMove(brain: Brain, reaction: { [string]: any }, arg: any): boolean
	local entry = reaction
	if reaction.right or reaction.left then
		local right = if typeof(arg) == "boolean" then arg else brain.hajikiReaction == 0
		entry = if right then reaction.right else reaction.left
	elseif reaction.type1 then
		entry = if arg then reaction.type2 else reaction.type1
	end
	local key = entry and entry.move
	if not key then
		return false
	end
	local merged: Step = { set = reaction.set or entry.set }
	playMove(brain, key, merged)
	return true
end

local function phaseSetup(brain: Brain)
	if brain.onPhase then
		brain.onPhase(brain)
	end
end

local function react(brain: Brain, name: string, arg: any)
	local reactions = brain.data.deck.reactions :: { [string]: any }
	local reaction = reactions[name]
	brain.mode = name
	brain.reactionStart = now()
	table.insert(brain.log, "R:" .. name)
	replace(brain, function()
		if name == "playerDie" then
			local step = if typeof(reaction) == "table" then reaction else { op = "locomote", right = 1, speed = 50 }
			local endsAt = math.huge
			locomote(brain, step, function()
				return now() < endsAt
			end)
			return
		end
		if typeof(reaction) ~= "table" then
			return -- no anim for this one (e.g. superArmorHit): keep acting next tick
		end
		if not reactionMove(brain, reaction, arg) then
			if name == "reHajiki" then
				return
			end
		end
		if name == "guardSuccess" then
			runReactiveDeck(brain, "guard")
		elseif name == "hajiki" then
			runReactiveDeck(brain, "hajiki")
		else
			if name == "ninsatsu" then
				waitUntil(function()
					return not inAction(brain)
				end)
				phaseSetup(brain)
			end
			local after = reaction.after
			if after then
				currentTop[brain] = after
				local ended = runSteps(brain, after, false)
				if not ended and name ~= "die" then
					advance(brain, deckOf(brain, "main"))
				end
			end
			if name == "die" then
				waitUntil(function()
					return not inAction(brain)
				end)
				return
			end
		end
	end)
end

function mainLoop(brain: Brain)
	brain.mode = "main"
	replace(brain, function()
		while not brain.stopped do
			local deck = deckOf(brain, "main")
			local id = current(brain, deck)
			local key, pattern = patternFor(brain, "main", id)
			if pattern and runnable(brain, pattern) then
				currentTop[brain] = pattern.steps
				if not runSteps(brain, pattern.steps, false) then
					advance(brain, deck)
				end
			else
				if not key then
					warn(`[BossAI] {brain.id}: main deck has no pattern for {id}`)
				end
				advance(brain, deck)
			end
			frame()
		end
	end)
end

-- Asks for a reaction; the highest priority request of a frame wins and starts on the next
-- Heartbeat (after this frame's combat events have gone out, so its clip plays last).
local function request(brain: Brain, name: string, arg: any)
	if brain.stopped then
		return
	end
	local priority = PRIORITY[name] or 0
	local pending = brain.pending
	if not pending or priority >= pending.priority then
		brain.pending = { name = name, priority = priority, arg = arg }
	end
end

---------------------------------------------------------------------------------------
-- Per-frame body: flags, facing, root motion, locomotion, reflex guard, breaks

local function rootVector(move: Move, t: number): Vector3
	local root = move.root
	if not root or #root.curve == 0 then
		return Vector3.zero
	end
	local curve = root.curve
	if t <= curve[1][1] then
		return Vector3.new(curve[1][3] or 0, 0, -(curve[1][2] or 0))
	end
	for i = 2, #curve do
		local b = curve[i]
		if t <= b[1] then
			local a = curve[i - 1]
			local span = b[1] - a[1]
			local u = if span > 1e-6 then (t - a[1]) / span else 1
			local fwd = a[2] + (b[2] - a[2]) * u
			local right = (a[3] or 0) + ((b[3] or 0) - (a[3] or 0)) * u
			return Vector3.new(right, 0, -fwd)
		end
	end
	local last = curve[#curve]
	return Vector3.new(last[3] or 0, 0, -(last[2] or 0))
end

local function update(brain: Brain, dt: number)
	local c = brain.c
	if brain.stopped or CombatService.get(c.model) ~= c then
		return
	end
	local t = now()
	local action = brain.action

	-- Timed flag notifies and super armour.
	if action then
		local events = action.events
		while #events > 0 and events[1].at <= t do
			local event = table.remove(events, 1) :: any
			setFlag(brain, event.flag, event.value)
		end
		if t >= action.endsAt then
			-- IdleReset / IdleReset2: the action is over and its flags with it.
			brain.action = nil
			clearFlags(brain)
		else
			local level = if t < action.armorUntil then action.armorLevel else 0
			for _, window in action.windows do
				if t >= window.from and t <= window.to then
					level = math.max(level, window.level)
				end
			end
			if brain.allSuperArmor then
				level = math.max(level, 1)
			end
			brain.flags.superArmor = math.max(if level > 0 then level else 0, if brain.allSuperArmor then 1 else 0)
		end
	end
	c.superArmor = brain.flags.superArmor
	logFlags(brain)

	-- Facing: the move's lookAtPlayer windows during an action, else the op's turn rate.
	local target = brain.target
	local rate = 0
	action = brain.action
	if action then
		local elapsed = t - action.startedAt
		for _, track in action.move.track do
			if elapsed >= track.from and elapsed <= track.to then
				rate = math.max(rate, track.turnSpeed)
			end
		end
	elseif brain.loco then
		rate = (brain.loco :: Loco).turnRate
	elseif brain.turnRate then
		rate = brain.turnRate :: number
	end
	if c.state == "Broken" or c.state == "Downed" then
		rate = 0
	end
	local toTarget = if target then flat(target.root.Position - c.root.Position) else Vector3.zero
	if rate > 0 and toTarget.Magnitude > 0.1 then
		brain.align.CFrame = CFrame.lookAt(Vector3.zero, toTarget.Unit)
		brain.align.MaxAngularVelocity = math.rad(rate)
		brain.align.Enabled = true
	else
		brain.align.Enabled = false
	end

	-- Root motion: the move's authored travel, in the body's current frame.
	local humanoid = c.humanoid
	local pushing = false
	if action and action.move.root then
		local elapsed = t - action.startedAt
		local a = rootVector(action.move, elapsed)
		local b = rootVector(action.move, elapsed + dt)
		local delta = (b - a) / math.max(dt, 1e-3)
		if delta.Magnitude > 0.05 then
			local world = c.root.CFrame:VectorToWorldSpace(delta)
			world = flat(world)
			-- Kannagi's capsules stop the boss's travel at contact (AirBlockCapsule): slide
			-- around anyone it already touches, and shorten a step that would reach them.
			world = Spacing.limit(c.model, c.root.Position, world, dt)
			local combatPush = c.root:FindFirstChild("CombatPush") :: LinearVelocity?
			if not (combatPush and combatPush.Enabled) then
				brain.push.PlaneVelocity = Vector2.new(world.X, world.Z)
				brain.push.Enabled = true
				pushing = true
			end
		end
	end
	if not pushing then
		brain.push.Enabled = false
	end

	-- Locomotion (AI_RotationAndMoveForwardRight): walk only while roughly facing the target.
	local loco = brain.loco
	if loco and not inAction(brain) and c.state ~= "Broken" and target then
		local look = flat(c.root.CFrame.LookVector)
		local facing = if toTarget.Magnitude > 0.1 and look.Magnitude > 0.01 then look.Unit:Dot(toTarget.Unit) else 1
		local dir = c.root.CFrame:VectorToWorldSpace(Vector3.new(loco.right, 0, -loco.fwd))
		dir = flat(dir)
		if dir.Magnitude > 0.01 then
			-- Approach and strafe steps stop at contact instead of walking into you.
			dir = Spacing.clip(c.model, c.root.Position, dir.Unit)
		end
		if facing >= loco.dot and dir.Magnitude > 0.05 and loco.speed > 0 then
			humanoid.WalkSpeed = loco.speed * dir.Magnitude
			humanoid:Move(dir.Unit, false)
		else
			humanoid:Move(Vector3.zero, false)
		end
	else
		humanoid:Move(Vector3.zero, false)
	end

	-- Posture break (TPBreak / HPBreak): the break anim, then back to the deck.
	if c.state == "Broken" then
		if not brain.breakHandled then
			brain.breakHandled = true
			local fromDeflect = t - brain.lastDeflectedAt < 0.25
			request(brain, if fromDeflect then "breakReHajiki" else "break", nil)
		end
	else
		brain.breakHandled = false
	end

	-- Reflex guard: idle or moving, and your swing is coming.
	if brain.reflex and brain.mode == "main" and not brain.pending and not inAction(brain) and attackSign(brain) then
		request(brain, "guardKamae01", nil)
	end

	local pending = brain.pending
	if pending then
		brain.pending = nil
		if pending.name == "main" then
			mainLoop(brain)
		else
			react(brain, pending.name, pending.arg)
		end
	elseif not brain.thread or coroutine.status(brain.thread :: thread) == "dead" then
		if brain.defeated then
			return
		end
		mainLoop(brain)
	end
end

---------------------------------------------------------------------------------------
-- Construction and the outside world

function BossAI.new(id: string, c: Combatant): Brain
	local data = Bosses.data(id) :: KannagiMoves.Boss
	local attachment = c.root:FindFirstChild("RootAttachment") :: Attachment?
	if not attachment then
		local created = Instance.new("Attachment")
		created.Name = "RootAttachment"
		created.Parent = c.root
		attachment = created
	end
	local align = Instance.new("AlignOrientation")
	align.Name = "BossFacing"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.Responsiveness = 60
	align.MaxTorque = math.huge
	align.Enabled = false
	align.Parent = c.root
	local push = Instance.new("LinearVelocity")
	push.Name = "BossRootMotion"
	push.Attachment0 = attachment
	push.RelativeTo = Enum.ActuatorRelativeTo.World
	push.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	push.PrimaryTangentAxis = Vector3.xAxis
	push.SecondaryTangentAxis = Vector3.zAxis
	push.MaxForce = 6e4
	push.Enabled = false
	push.Parent = c.root

	local stats = data.stats
	local cool = table.clone(stats.cooldownStart or stats.cooldownChild or {})
	local brain: Brain = {
		id = id,
		data = data,
		c = c,
		target = nil,
		zp = stats.zp or 2,
		phase = 1,
		decks = {},
		cool = cool,
		gates = {},
		flags = { guard = false, hajiki = false, hajikiDisable = false, superArmor = 0 },
		flagLog = {},
		action = nil,
		actionSeq = 0,
		thread = nil,
		mode = "idle",
		reactionStart = 0,
		pending = nil,
		hajikiReaction = 0,
		signFrom = -math.huge,
		signUntil = -math.huge,
		signBy = nil,
		loco = nil,
		turnRate = nil,
		align = align,
		push = push,
		stopped = true,
		defeated = false,
		openerUsed = false,
		log = {},
		breakHandled = false,
		lastDeflectedAt = -math.huge,
		reflex = data.deck.reactions.guardKamae01 ~= nil,
		allSuperArmor = stats.allSuperArmor == true or (stats.superArmorEveryTick or 0) > 0,
		connection = nil,
		onPhase = nil,
		onStage = nil,
		onDefeated = nil,
	}
	clearFlags(brain)
	c.bossGuard = function(t: number): (boolean, boolean, boolean)
		return flagsAt(brain, t)
	end
	return brain
end

function BossAI.start(brain: Brain)
	if not brain.stopped then
		return
	end
	brain.stopped = false
	brain.connection = RunService.Heartbeat:Connect(function(dt)
		update(brain, dt)
	end)
end

function BossAI.stop(brain: Brain)
	brain.stopped = true
	brain.pending = nil
	local connection = brain.connection
	if connection then
		connection:Disconnect()
		brain.connection = nil
	end
	local thread = brain.thread
	if thread and thread ~= coroutine.running() and coroutine.status(thread) ~= "dead" then
		task.cancel(thread)
	end
	brain.thread = nil
	currentTop[brain] = nil
	brain.loco = nil
	if brain.align.Parent then
		brain.align.Enabled = false
	end
	if brain.push.Parent then
		brain.push.Enabled = false
	end
	if brain.c.humanoid.Parent then
		brain.c.humanoid:Move(Vector3.zero, false)
	end
end

-- Kannagi's ReceiveAttackSign from one of the boss's foes: their swing lands at `hitAt`.
-- `side` is the swing's deflect side as the boss sees it (0 right, 2 left).
function BossAI.sign(brain: Brain, attacker: Combatant, hitAt: number, side: number)
	local rules = Config.Bosses
	brain.signFrom = hitAt - rules.SignLead
	brain.signUntil = hitAt + rules.SignTail
	brain.signBy = attacker
	brain.hajikiReaction = side
end

-- What happened to a blow involving the boss (CombatService.onOutcome).
function BossAI.outcome(brain: Brain, outcome: string, attacker: Combatant, target: Combatant?, kind: string)
	if brain.stopped or brain.defeated then
		return
	end
	local c = brain.c
	local mode = brain.mode
	local locked = mode == "ninsatsu" or mode == "die"
	if target == c then
		if attacker.player then
			brain.target = attacker
		end
		if locked or c.state == "Broken" then
			return
		end
		if outcome == "Hit" then
			if brain.flags.superArmor <= 0 then
				request(brain, "damage", nil)
			end
		elseif outcome == "Guarded" then
			request(brain, "guardSuccess", nil)
		elseif outcome == "Deflect" or outcome == "PerfectDeflect" then
			request(brain, "hajiki", nil) -- the boss parried
		end
	elseif attacker == c then
		if outcome == "Deflect" or outcome == "PerfectDeflect" then
			brain.lastDeflectedAt = now()
			-- Kannagi's ReHajiki: only hits authored with a recoil knock the boss back, to the
			-- side the hit says (ReactionType 1 right, 2 left).
			local _, _, index = Bosses.parse(kind)
			local move = Bosses.move(kind)
			local hit = move and index and move.hits[index]
			if hit and hit.recoil ~= "None" and not locked then
				request(brain, "reHajiki", string.find(hit.recoil, "Right", 1, true) ~= nil)
			end
		elseif outcome == "Mikiri" then
			brain.lastDeflectedAt = now()
			local type2 = false
			local action = brain.action
			local windows = action and (action.move.flags :: any).reMikiriType2
			if action and windows then
				local elapsed = now() - action.startedAt
				for _, window in windows do
					if elapsed >= window.from and elapsed <= window.to then
						type2 = true
					end
				end
			end
			request(brain, "reMikiri", type2)
		elseif outcome == "Stomped" then
			request(brain, "reFumitsuke", nil)
		end
	end
end

-- The target was cut down (will rise) / rose again.
function BossAI.targetDown(brain: Brain)
	request(brain, "playerDie", nil)
end

function BossAI.targetRose(brain: Brain)
	request(brain, "revival", nil)
end

-- A deathblow landed: one life gone. Returns whether it was the last. The reaction runs
-- next frame (phase 2 is set up when the deathblow anim ends; see BossService.onPhase).
function BossAI.deathblow(brain: Brain): boolean
	local stages = brain.data.deck.stages
	local order = stages and stages.order :: { string }?
	local nextZp = brain.zp - 1
	if order then
		local index = table.find(order, tostring(brain.zp))
		local following = index and order[index + 1]
		nextZp = if following then tonumber(following) :: number else 0
	end
	if nextZp == 94 then
		-- The tutorial's bridge stage lasts one tick: straight on to the real fight (ZP 2),
		-- with a fresh two-slot main deck and two cooldown decs.
		nextZp = 2
		table.clear(brain.decks)
		applyCooldown(brain, { dec = true })
		applyCooldown(brain, { dec = true })
	elseif order then
		table.clear(brain.decks) -- each tutorial stage has its own decks
	end
	brain.zp = nextZp
	if nextZp <= 0 then
		brain.defeated = true
		request(brain, "die", nil)
		return true
	end
	if nextZp == 1 then
		brain.phase = 2
	end
	request(brain, "ninsatsu", nil)
	return false
end

function BossAI.flagsAt(brain: Brain, t: number): (boolean, boolean, boolean)
	return flagsAt(brain, t)
end

-- Starts a move by key right now (testing).
function BossAI.play(brain: Brain, key: string)
	playMove(brain, key, nil)
end

return BossAI
