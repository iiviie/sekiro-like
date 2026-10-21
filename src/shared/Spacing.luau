--!strict
-- Body spacing (Kannagi's capsules). Fighters don't collide physically, so a dodge passes
-- through and a push can never fling anyone; instead every fighter keeps a capsule of
-- Config.Spacing.Radius (x its BodyScale attribute), and two solid fighters of the same arena
-- are kept at least their two radii apart:
--   * server/CombatService pushes bots and bosses out of anyone they overlap (half each
--     between two of them, all of it against a player, whose body the server doesn't own);
--   * client/Movement pushes your own character out of anyone you overlap (all of it
--     against a bot or boss, half against another player, who resolves the other half);
--   * lunges, boss root motion and approach steps ask `room` how far they may go and stop
--     StopMargin outside contact instead of passing through.
-- Dodging, downed and dead bodies don't push (you can dash past or through someone), and
-- neither do bodies far apart vertically (a jump over a sweep, a stomp).

local Config = require(script.Parent.Config)
local Tagged = require(script.Parent.Tagged)
local Types = require(script.Parent.Types)

local RULES = Config.Spacing

local Spacing = {}

local PASS_THROUGH: { [string]: boolean } = { Dodging = true, Downed = true, Dead = true }

local function rootOf(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- This body's capsule radius in studs.
function Spacing.radius(model: Model): number
	local scale = model:GetAttribute("BodyScale")
	return RULES.Radius * (if typeof(scale) == "number" and scale > 0 then scale else 1)
end

-- How close two bodies' roots may come (flat distance).
function Spacing.contact(a: Model, b: Model): number
	return Spacing.radius(a) + Spacing.radius(b)
end

-- Whether a body takes up room right now: alive, in an arena, not dodging, down or dead.
function Spacing.solid(model: Model): boolean
	local state = model:GetAttribute("CombatState")
	if typeof(state) == "string" and PASS_THROUGH[state] then
		return false
	end
	if model:GetAttribute("Arena") == nil then
		return false
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

-- Whether two bodies share a fight (the lobby has no spacing).
function Spacing.together(a: Model, b: Model): boolean
	local arena = a:GetAttribute("Arena")
	return arena ~= nil and arena == b:GetAttribute("Arena")
end

-- The solid bodies `model` keeps its distance from, with their roots. In the lobby nobody
-- pushes anybody (crowds on the pads), but `lobby` still lists other lobby fighters, so a
-- lunge at the trainer or a sparring partner stops short of them.
local function neighbours(model: Model, lobby: boolean?): { { model: Model, root: BasePart } }
	local out = {}
	local arena = model:GetAttribute("Arena")
	if arena == nil and not lobby then
		return out
	end
	for _, instance in Tagged.list(Types.Tag) do
		if instance ~= model and instance:IsA("Model") and instance:GetAttribute("Arena") == arena then
			local root = rootOf(instance)
			local humanoid = instance:FindFirstChildOfClass("Humanoid")
			local solid = if arena == nil
				then humanoid ~= nil
					and humanoid.Health > 0
					and not PASS_THROUGH[instance:GetAttribute("CombatState") :: any]
				else Spacing.solid(instance)
			if root and solid then
				table.insert(out, { model = instance, root = root })
			end
		end
	end
	return out
end

-- How far `model` may travel from `origin` along the flat unit `direction`, up to
-- `distance`, before it would come within StopMargin of touching another body. 0 when
-- someone is already that close in front.
function Spacing.room(model: Model, origin: Vector3, direction: Vector3, distance: number): number
	local room = distance
	for _, other in neighbours(model, true) do
		local offset = other.root.Position - origin
		if math.abs(offset.Y) <= RULES.Height then
			local flat = Vector3.new(offset.X, 0, offset.Z)
			local along = flat:Dot(direction)
			if along > 0 then
				local stop = Spacing.contact(model, other.model) + RULES.StopMargin
				local lateral2 = math.max(flat:Dot(flat) - along * along, 0)
				if lateral2 < stop * stop then
					local free = along - math.sqrt(stop * stop - lateral2)
					if other.model:GetAttribute("CombatState") == "Windup" then
						free *= 0.5 -- they may lunge too: each takes half the gap, so the two meet at contact
					end
					room = math.min(room, math.max(free, 0))
				end
			end
		end
	end
	return room
end

-- Removes the part of a flat velocity or step `vector` that would carry `model` (at
-- `origin`) further into anyone within StopMargin of contact: it can still slide around them
-- or back away.
function Spacing.clip(model: Model, origin: Vector3, vector: Vector3): Vector3
	for _, other in neighbours(model) do
		local offset = other.root.Position - origin
		if math.abs(offset.Y) <= RULES.Height then
			local flat = Vector3.new(offset.X, 0, offset.Z)
			local gap = flat.Magnitude
			if gap > 1e-3 and gap < Spacing.contact(model, other.model) + RULES.StopMargin then
				local toward = flat / gap
				local into = vector:Dot(toward)
				if into > 0 then
					vector -= toward * into
				end
			end
		end
	end
	return vector
end

-- A flat velocity for the next `dt` seconds that neither presses into a body already at
-- contact (`clip`) nor travels past where the next one starts (`room`).
function Spacing.limit(model: Model, origin: Vector3, velocity: Vector3, dt: number): Vector3
	velocity = Spacing.clip(model, origin, velocity)
	local speed = velocity.Magnitude
	if speed < 1e-3 or dt <= 0 then
		return velocity
	end
	local step = speed * dt
	return velocity * (Spacing.room(model, origin, velocity / speed, step) / step)
end

-- The flat offset that takes `model` (its root at `origin`) out of every body it overlaps.
-- `share(other)` is how much of each overlap this body resolves itself (1 = all of it).
function Spacing.separation(model: Model, origin: Vector3, share: (other: Model) -> number): Vector3
	local total = Vector3.zero
	for _, other in neighbours(model) do
		local offset = origin - other.root.Position
		if math.abs(offset.Y) <= RULES.Height then
			local flat = Vector3.new(offset.X, 0, offset.Z)
			local gap = flat.Magnitude
			local contact = Spacing.contact(model, other.model)
			if gap < contact then
				local away: Vector3
				if gap > 1e-3 then
					away = flat / gap
				else
					-- Exactly on top of each other: step back out of the way we face.
					local root = rootOf(model)
					local look = if root then root.CFrame.LookVector else Vector3.zAxis
					local back = -Vector3.new(look.X, 0, look.Z)
					away = if back.Magnitude > 1e-3 then back.Unit else Vector3.xAxis
				end
				total += away * (contact - gap) * share(other.model)
			end
		end
	end
	return total
end

return Spacing
