--!strict
-- Studio-only test hooks: a BindableFunction in ServerStorage that lets automated tests
-- (and the command bar) drive the combat system directly. Never created in a live game.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local CombatService = require(script.Parent.CombatService)

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
	-- clear(): removes every dummy.
	hook.OnInvoke = function(command: string, ...: any): any
		local args = { ... }
		if command == "spawn" then
			local name, position, facing = args[1] :: string, args[2] :: Vector3, args[3] :: Vector3
			local model = Players:CreateHumanoidModelFromDescription(
				Instance.new("HumanoidDescription"),
				Enum.HumanoidRigType.R15
			)
			model.Name = name
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
			local model = dummies[args[1] :: string]
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
			}
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
