--!strict
-- Studio-only test hooks: a BindableFunction in ServerStorage that lets automated tests
-- (and the command bar) drive the combat system directly. Never created in a live game.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local CombatService = require(script.Parent.CombatService)
local Economy = require(script.Parent.Economy)
local Monetization = require(script.Parent.Monetization)
local ProgressService = require(script.Parent.ProgressService)
local StatsService = require(script.Parent.StatsService)

local CURRENCIES = { Coins = true, Gems = true, Whetstones = true, Shards = true, PassXP = true, Draws = true }

local DevHooks = {}

function DevHooks.start()
	if not RunService:IsStudio() then
		return
	end
	local hook = Instance.new("BindableFunction")
	hook.Name = "CombatTest"
	local dummies: { [string]: Model } = {}

	-- spawn(name, position, facing): a plain R15 fighter with no brain.
	-- perform(name, action, stampOffset?, flag?): CombatService.perform at now + offset.
	-- get(name): a snapshot of that fighter's combat state.
	-- grant(field, amount): adds to the first player's data, e.g. grant("Coins", 500). Marks
	--   the session as a test session, so it never writes to a real DataStore.
	-- economy(op, ...): server/Economy on the first player: ("buy", id), ("equip", slot, id),
	--   ("own", id), ("spend", currency, n), ("upgrade", lineId, gemWhetstones), ("can").
	-- receipt(key, purchaseId?): a mock ProcessReceipt for a developer product.
	-- prompt(key): Monetization.prompt (mock path in Studio while ids are 0).
	-- pass(key): pretend the first player bought game pass `key`.
	-- reload(raw?): re-saves the first player's profile as `raw` (any version) in the Studio
	--   in-memory store and reloads it through the lock + migration path.
	-- raw(): the first player's saved payload in the in-memory store.
	-- writeRaw(raw): overwrites that payload without reloading; save(): StatsService.saveNow.
	-- progress(op, ...): ProgressService results for the first player, as if a fight ended:
	--   ("boss", bossId, name, stars, won, lives), ("royale", place, fighters, won),
	--   ("duel", won, rounds).
	-- posture(name, value): sets a dummy's posture.
	-- clear(): removes every dummy.
	-- damage(name, amount): hurts a dummy, or the first player's character when name is "player".
	-- resurrections(name, count): sets how many lethal blows a fighter will rise from.
	-- pivot(name, cframe): moves a dummy.
	hook.OnInvoke = function(command: string, ...: any): any
		local args = { ... }
		if command == "spawn" then
			local name, position, facing = args[1] :: string, args[2] :: Vector3, args[3] :: Vector3
			local weapon = args[4] :: string?
			local model = Players:CreateHumanoidModelFromDescription(
				Instance.new("HumanoidDescription"),
				Enum.HumanoidRigType.R15
			)
			model.Name = name
			model:SetAttribute("Weapon", weapon)
			model:PivotTo(CFrame.lookAt(position, facing))
			model.Parent = workspace
			local c = CombatService.register(model, nil)
			if c then
				c.protectedUntil = 0
			end
			dummies[name] = model
			return c ~= nil
		elseif command == "perform" then
			local model = dummies[args[1] :: string]
			local c = model and CombatService.get(model)
			if not c then
				return false
			end
			local offset = (args[3] :: number?) or 0
			return CombatService.perform(c, args[2], workspace:GetServerTimeNow() + offset, args[4])
		elseif command == "get" then
			local model = if args[1] == "player"
				then (Players:GetPlayers()[1] and Players:GetPlayers()[1].Character)
				else dummies[args[1] :: string]
			local c = model and CombatService.get(model)
			if not c then
				return nil
			end
			return {
				state = c.state,
				posture = c.posture,
				stamina = c.stamina,
				health = c.humanoid.Health,
				riposteUntil = c.riposteUntil - workspace:GetServerTimeNow(),
				perilousReadyIn = (c.groupReadyAt.Perilous or 0) - workspace:GetServerTimeNow(),
				windupKind = c.windupKind,
				windupIn = c.windupHitAt - workspace:GetServerTimeNow(),
				comboIndex = c.comboIndex,
				trickUsed = c.stringTrickUsed,
				resolve = c.resolve,
				brokenBy = c.brokenBy and c.brokenBy.model.Name,
				blocking = c.blocking,
				blockHeld = c.blockHeld,
				deflectIn = c.deflectStamp - workspace:GetServerTimeNow(), -- negative: opened that long ago
				buffered = c.buffered,
				attackKind = c.attackKind,
				postureRegenIn = math.max(c.postureRegenAt, c.postureFrozenUntil) - workspace:GetServerTimeNow(),
				jumpAgo = workspace:GetServerTimeNow() - c.jumpStamp,
				protectedIn = c.protectedUntil - workspace:GetServerTimeNow(),
			}
		elseif command == "grant" then
			-- grant(field, amount): adds to the first player's saved data (coins, gems...).
			local target = Players:GetPlayers()[1]
			if target then
				StatsService.markTest(target)
				local field, amount = args[1] :: string, args[2] :: number
				if CURRENCIES[field] and amount > 0 then
					Economy.grant(target, field :: any, amount, "DevHooks", "Gameplay")
				else
					StatsService.add(target, field, amount)
				end
			end
			return target and target:GetAttribute(args[1] :: string)
		elseif command == "economy" then
			local target = Players:GetPlayers()[1]
			if not target then
				return nil
			end
			StatsService.markTest(target)
			local op = args[1]
			if op == "buy" then
				local ok, why = Economy.buy(target, args[2], args[3])
				return { ok, why }
			elseif op == "equip" then
				return Economy.equip(target, args[2], args[3])
			elseif op == "own" then
				return Economy.own(target, args[2], "grant")
			elseif op == "spend" then
				return Economy.spend(target, args[2], args[3], "DevHooks")
			elseif op == "upgrade" then
				local ok, why = Economy.upgradeLine(target, args[2], args[3])
				return { ok, why }
			elseif op == "can" then
				return Economy.canTransact(target)
			end
			return nil
		elseif command == "receipt" then
			local target = Players:GetPlayers()[1]
			return target and Monetization.mockReceipt(target, args[1], args[2]).Name
		elseif command == "prompt" then
			local target = Players:GetPlayers()[1]
			if not target then
				return nil
			end
			local ok, why = Monetization.prompt(target, args[1])
			return { ok, why }
		elseif command == "pass" then
			local target = Players:GetPlayers()[1]
			return target and Monetization.mockPass(target, args[1])
		elseif command == "reload" then
			local target = Players:GetPlayers()[1]
			local d = target and StatsService.debugReload(target, args[1])
			return d and game:GetService("HttpService"):JSONEncode(d)
		elseif command == "progress" then
			local target = Players:GetPlayers()[1]
			if not target then
				return nil
			end
			StatsService.markTest(target)
			local op = args[1]
			ProgressService.matchStarted({ target })
			if op == "boss" then
				return ProgressService.bossEnded(
					target,
					{ boss = args[2], name = args[3], stars = args[4], won = args[5], lives = args[6], time = 60 }
				)
			elseif op == "royale" then
				ProgressService.matchEnded({ [target] = args[2] }, args[3], if args[4] then target else nil)
			elseif op == "duel" then
				ProgressService.duelEnded({
					[target] = { won = args[2], rounds = args[3], score = "3 - 1", opponent = "Test" },
				})
			end
			return true
		elseif command == "writeRaw" then
			local target = Players:GetPlayers()[1]
			return target ~= nil and StatsService.debugWriteRaw(target, args[1])
		elseif command == "save" then
			local target = Players:GetPlayers()[1]
			return target ~= nil and StatsService.saveNow(target)
		elseif command == "raw" then
			local target = Players:GetPlayers()[1]
			local raw = target and StatsService.debugRaw(target)
			return raw and game:GetService("HttpService"):JSONEncode(raw)
		elseif command == "posture" then
			-- posture(name, value): set a dummy's posture directly.
			local model = dummies[args[1] :: string]
			local c = model and CombatService.get(model)
			if c then
				c.posture = args[2] :: number
			end
			return c ~= nil
		elseif command == "damage" or command == "resurrections" then
			local model = if args[1] == "player"
				then (Players:GetPlayers()[1] and Players:GetPlayers()[1].Character)
				else dummies[args[1] :: string]
			local c = model and CombatService.get(model)
			if not c then
				return false
			end
			if command == "damage" then
				CombatService.damage(c, args[2] :: number)
			else
				CombatService.setResurrections(c, args[2] :: number)
			end
			return c.state
		elseif command == "pivot" then
			-- pivot(name, cframe): teleports a dummy (e.g. to step out of a swing mid-windup).
			local model = dummies[args[1] :: string]
			if model then
				model:PivotTo(args[2] :: CFrame)
			end
			return model ~= nil
		elseif command == "clear" then
			for _, model in dummies do
				model:Destroy()
			end
			table.clear(dummies)
			return true
		end
		return nil
	end
	hook.Parent = ServerStorage
end

return DevHooks
