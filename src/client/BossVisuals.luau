--!strict
-- Boss animation and tells. The boss AI broadcasts every move it starts ("BossMove": the
-- Kannagi animation asset, its start, its hit times); this plays the animation worker's
-- retargeted clip for that asset (Shared/BakedBoss, loaded on demand), stretched so its first
-- strike lands on the first hit. A clip that isn't baked yet falls back to our closest one
-- (Light1/Light2/Light3 for slashes, Perilous for a thrust, Sweep for a sweep), one per hit
-- with each windup stretched to that hit's real time, so every boss works now and upgrades
-- by itself when its clips arrive. "Kiken" shows the 危 perilous tell. Hits themselves come
-- through CombatVisuals' Windup handler like any swing (glints, predicted deflects).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Animator = require(script.Parent.Animator)
local CombatVisuals = require(script.Parent.CombatVisuals)
local BossLeads = require(ReplicatedStorage.Shared.BossLeads)
local Bosses = require(ReplicatedStorage.Shared.Bosses)

local combatEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CombatEvent") :: RemoteEvent

local BossVisuals = {}

local bySource: { [string]: string } = {} -- Kannagi asset name -> baked clip name
local registered: { [string]: boolean } = {}
local loading: { [string]: boolean } = {}
local playToken: { [Model]: number } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

-- Loads one BakedBoss bundle once its modules have arrived (the server keeps them in
-- ServerStorage until a fight needs them).
local function load(num: string)
	if registered[num] or loading[num] then
		return
	end
	loading[num] = true
	task.spawn(function()
		local ok, err = pcall(function()
			local shared = ReplicatedStorage:WaitForChild("Shared")
			local BakedBoss = require(shared:WaitForChild("BakedBoss")) :: any
			local parts = BakedBoss.Bosses[num]
			if not parts then
				return
			end
			local baked = shared:WaitForChild("Baked")
			for _, part in parts do
				if not baked:WaitForChild(part, 20) then
					error(`boss clip module {part} never arrived`)
				end
			end
			local Clips = require(shared:WaitForChild("Clips")) :: any
			for _, name in BakedBoss.register(num) do
				local clip = Clips.Clips[name]
				if clip and clip.impactLead == nil then
					clip.impactLead = BossLeads[name] -- so the blade reaches you on the hit (Shared/BossLeads)
				end
				local source = clip and clip.source
				if typeof(source) == "string" and not bySource[source] then
					bySource[source] = name
				end
			end
			registered[num] = true
		end)
		loading[num] = false
		if not ok then
			warn(`[BossVisuals] boss clips {num}: {err}`)
		end
	end)
end

-- Starts loading every bundle a boss uses (its own clips and any it borrows).
function BossVisuals.prepare(id: string)
	for _, num in Bosses.bundles(id) do
		load(num)
	end
end

-- Our closest stand-in for a move with no baked clip yet.
local function fallbackFor(anim: string): string?
	if string.find(anim, "BackStep") or string.find(anim, "Dodge") then
		return "DodgeBack"
	elseif string.find(anim, "ReHajikiLeft") then
		return "RecoilLeft"
	elseif string.find(anim, "ReHajiki") then
		return "Recoil"
	elseif string.find(anim, "HajikiLeft") then
		return "DeflectLeft"
	elseif string.find(anim, "Hajiki") then
		return "DeflectRight"
	elseif string.find(anim, "GuardSuccess") then
		return "GuardSmall"
	elseif string.find(anim, "Break") then
		return "GuardBreak"
	elseif string.find(anim, "Ninsatsu") or string.find(anim, "ReMikiri") then
		return "HitLarge"
	elseif string.find(anim, "Damage") then
		return "HitMiddle"
	elseif string.find(anim, "Die") then
		return "Executed"
	end
	return nil -- stances (GuardKamae, Kamae): the base stance covers them
end

local function slashFallback(types: { string }, index: number): string
	local kind = types[index]
	if kind == "Tsuki" then
		return "Perilous"
	elseif kind == "Gedan" then
		return "Sweep"
	elseif index == #types and #types >= 3 then
		return "Light3"
	end
	return if index % 2 == 1 then "Light1" else "Light2"
end

local function onMove(data: { [string]: any })
	local model = data.model :: Model?
	local anim = data.anim
	if not model or not model.Parent or typeof(anim) ~= "string" then
		return
	end
	BossVisuals.prepare(data.boss)
	local hits = (data.hits or {}) :: { number }
	local elapsed = math.max(now() - (data.at or now()), 0)
	local token = (playToken[model] or 0) + 1
	playToken[model] = token

	local clip = bySource[anim]
	if clip then
		local windup = if #hits > 0 then math.max(hits[1] - elapsed, 0.05) else nil
		-- Kannagi's PauseBlendIn: the move sits on its first frame for `hold` seconds (what's
		-- left of it if this event arrived late), then plays at its own pace into the hit.
		local bossData = typeof(data.boss) == "string" and Bosses.data(data.boss) or nil
		local move = bossData and typeof(data.key) == "string" and bossData.moves[data.key] or nil
		local hold = if move and move.hold then math.max(move.hold - elapsed, 0) else 0
		Animator.play(model, clip, windup, hold)
		if string.find(anim, "Die", 1, true) then
			Animator.holdLast(model, 30) -- stays down; the body is removed with the arena
		end
		return
	end
	if #hits == 0 then
		local stand = fallbackFor(anim)
		if stand then
			Animator.play(model, stand)
		end
		return
	end
	-- One stand-in swing per hit, each landing on that hit's time.
	local types = (data.types or {}) :: { string }
	local previous = 0
	for i, at in hits do
		local startRel = math.max(previous, elapsed)
		local windup = at - startRel
		previous = at
		if windup > 0.02 then
			task.delay(startRel - elapsed, function()
				if playToken[model] == token and model.Parent then
					Animator.play(model, slashFallback(types, i), math.max(windup, 0.12))
				end
			end)
		end
	end
end

function BossVisuals.start()
	combatEvent.OnClientEvent:Connect(function(kind: string, data: { [string]: any })
		if kind == "BossMove" then
			onMove(data)
		elseif kind == "Kiken" then
			local model = data.model :: Model?
			if model and model.Parent then
				CombatVisuals.telegraphPerilous(model, data.duration or 0.9)
			end
		end
	end)
end

return BossVisuals
