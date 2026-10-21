--!strict
-- Weapons as data. A weapon is the base moveset in Config.Attacks bent by a few multipliers
-- (its "stat budget") plus per-move overrides, and a look. Adding a weapon means adding an
-- entry here: combat, bots and the client all read moves through Weapons.spec.
--
-- Balance rules (reports/Sword combat design and lobby.md):
--   * Every weapon spends the same budget: a weapon better than the katana at one thing must
--     be worse at another. Sidegrades, never upgrades.
--   * Defensive verbs (deflect, guard, dodge, jump, Mikiri) are universal and not tuned per
--     weapon, so no matchup is a hard lock and the netcode tolerance isn't swamped.
--   * Reach follows the blade: a longer visual blade gets a longer hit range, so a swing
--     never visibly passes through someone without hitting.

local Config = require(script.Parent.Config)

type AttackKind = Config.AttackKind
type AttackSpec = Config.AttackSpec

export type WeaponLook = {
	MeshId: string,
	TextureId: string,
	Scale: Vector3, -- SpecialMesh scale
	Size: Vector3, -- the part's size at that scale; blade along +Z, edge toward -Y
	GripZ: number, -- handle centre, where the fist closes
	GuardZ: number, -- where the edge starts (the habaki); the swing trail starts here
	TipZ: number,
	-- Fittings built from parts by server/SwordRig over the mesh, so the sword reads at
	-- camera distance: a bold tsuba, a pommel cap and a bright line along the cutting edge.
	TsubaZ: number, -- the tsuba's centre
	Tsuba: Vector3, -- its thickness, width and height
	PommelZ: number,
	Edge: { Vector3 }, -- the cutting edge in part space, habaki to tip
}

export type WeaponDef = {
	id: string,
	name: string,
	description: string,
	archetype: string,
	-- Price and unlock rule: Shared/Catalog (`weapon.<id>`), coins only. Never sold for Robux.
	look: WeaponLook,
	-- Multipliers on every move unless a move overrides the field.
	windup: number,
	recovery: number,
	damage: number,
	postureDamage: number,
	reach: number, -- range and lunge
	stamina: number,
	-- Field-by-field overrides for single moves, applied after the multipliers.
	moves: { [string]: { [string]: any } }?,
}

local KATANA_MESH = "rbxassetid://114165484128397"
local KATANA_TEXTURE = "rbxassetid://85720589438351"
local KATANA_NATIVE = Vector3.new(0.4782, 0.6382, 6.4796) -- the mesh's own size (SpecialMesh scale 1)

-- Where the katana mesh's own parts sit, as fractions of the part's size (measured in Studio
-- from a side-on capture): the habaki, the tip, the tsuba's centre, and the cutting edge from
-- the habaki to the tip, set a hair inside the silhouette.
local KATANA_GUARD = -0.2436
local KATANA_TIP = 0.489
local KATANA_TSUBA = -0.2818
local KATANA_EDGE = {
	Vector2.new(-0.2432, -0.148),
	Vector2.new(-0.1023, -0.153),
	Vector2.new(-0.0091, -0.133),
	Vector2.new(0.0864, -0.085),
	Vector2.new(0.1795, -0.023),
	Vector2.new(0.275, 0.056),
	Vector2.new(0.3682, 0.150),
	Vector2.new(0.4636, 0.292),
	Vector2.new(0.4885, 0.43),
}

-- A look on the katana mesh at SpecialMesh `scale`. The fist (a 1-stud-deep R15 hand) closes
-- right behind the tsuba, so the blade's whole length shows and the pommel peeks out behind.
local function katanaLook(scale: Vector3, tsubaThickness: number): WeaponLook
	local size = KATANA_NATIVE * scale
	local tsubaZ = KATANA_TSUBA * size.Z
	local edge = {}
	for i, point in KATANA_EDGE do
		edge[i] = Vector3.new(0, point.Y * size.Y, point.X * size.Z)
	end
	return {
		MeshId = KATANA_MESH,
		TextureId = KATANA_TEXTURE,
		Scale = scale,
		Size = size,
		GripZ = tsubaZ - tsubaThickness / 2 - 0.5,
		GuardZ = KATANA_GUARD * size.Z,
		TipZ = KATANA_TIP * size.Z,
		TsubaZ = tsubaZ,
		-- An oval disc a little larger than the mesh's own (thin, pointed) tsuba, which it hides.
		Tsuba = Vector3.new(tsubaThickness, 0.78 * size.Y, 1.1 * size.Y),
		PommelZ = -size.Z / 2,
		Edge = edge,
	}
end

-- Blades are stylised and oversized (Dueling Grounds' read at Roblox scale): every weapon is
-- 1.3x its old length and breadth and 1.5x as thick, so it reads at 30 studs.
local OVERSIZE = Vector3.new(1.5, 1.3, 1.3)

local defs: { [string]: WeaponDef } = {
	-- The baseline everything is measured against: no strengths, no weaknesses.
	Katana = {
		id = "Katana",
		name = "Katana",
		description = "Balanced. Fast enough to pressure, safe enough to deflect with.",
		archetype = "All-rounder",
		-- 5.7 studs, the tip 5 studs from the hand.
		look = katanaLook(Vector3.new(0.6 * 1.35, 0.6 * 2.6, 0.6 * 1.13) * OVERSIZE, 0.1),
		windup = 1,
		recovery = 1,
		damage = 1,
		postureDamage = 1,
		reach = 1,
		stamina = 1,
	},

	-- Slow, long and crushing on guard: it breaks posture, but every swing is a commitment.
	-- Counter: deflect it and punish the long recovery, or interrupt the early windup.
	Odachi = {
		id = "Odachi",
		name = "Odachi",
		description = "Heavy and long. Breaks guards and posture, but every swing is a commitment.",
		archetype = "Bruiser",
		-- 7.6 studs, the tip 6.4 studs from the hand.
		look = katanaLook(Vector3.new(0.6 * 1.6, 0.6 * 3.2, 0.6 * 1.5) * OVERSIZE, 0.12),
		windup = 1.4,
		recovery = 1.3,
		damage = 1.3,
		postureDamage = 1.5,
		reach = 1.25,
		stamina = 1.35,
		moves = {
			-- Strings scale with the 1.4x windup (Light2 0.64, chained 0.59: a smaller speed-up
			-- than the katana's, so an odachi string is two heavy swings, not a flurry).
			-- Its overhead has late-windup armour: trade into it and lose.
			-- Its own deflected swings cost it about 1.15x the katana's (not the full 1.5x
			-- posture multiplier): a fully deflected string (86 vs 77) no longer breaks it by
			-- itself; perfect deflects still do.
			Light1 = { deflectPosture = 0.75 },
			Light2 = { deflectPosture = 0.75 },
			Light3 = { deflectPosture = 0.9 },
			Overhead = { armorFrom = 0.25, deflectPosture = 1.15 },
			DodgeSlash = { deflectPosture = 0.75 },
			-- The riposte is the one fast move it gets (it must land inside the 0.5 s recoil), so
			-- the parry still pays. Its recovery still scales.
			Riposte = { windup = 0.2, deflectPosture = 0.75 },
			Riposte2 = { deflectPosture = 0.9 },
			-- Likewise the Mikiri follow-up, which must land inside the 0.9 s Mikiri stagger.
			MikiriSlash = { windup = 0.32, deflectPosture = 0.75 },
		},
	},
}

local Weapons = {
	Default = "Katana",
	Order = { "Katana", "Odachi" },
}

local REQUIRED_NUMBERS = { "windup", "recovery", "damage", "postureDamage", "reach", "stamina" }
local KNOWN_SPEC_FIELDS: { [string]: boolean } = {}
for _, spec in Config.Attacks do
	for field in spec do
		KNOWN_SPEC_FIELDS[field] = true
	end
end
for field in Config.MoveDefaults do
	KNOWN_SPEC_FIELDS[field] = true
end
for _, field in
	{
		"armorFrom",
		"chainWindup",
		"cooldownGroup",
		"riposte",
		"ender",
		"perilous",
		"noGuard",
		"thrust",
		"low",
		"follow",
	}
do
	KNOWN_SPEC_FIELDS[field] = true
end
local KNOWN_CANCELS = { Attack = true, Block = true, Dodge = true, Jump = true, Heal = true }
for kind, move in Config.Attacks do
	for input in move.cancel or {} do
		assert(KNOWN_CANCELS[input], `[Config] Attacks.{kind}.cancel: unknown input {input}`)
	end
	assert(move.follow == nil or Config.Attacks[move.follow], `[Config] Attacks.{kind}: unknown follow`)
end

-- Load-time validation: bad content fails in Studio, not mid-match.
for id, def in defs do
	assert(def.id == id, `[Weapons] {id}: id mismatch`)
	for _, field in REQUIRED_NUMBERS do
		local value = (def :: any)[field]
		assert(typeof(value) == "number" and value > 0, `[Weapons] {id}: {field} must be a positive number`)
	end
	for kind, overrides in def.moves or {} do
		assert(Config.Attacks[kind :: AttackKind], `[Weapons] {id}: unknown move {kind}`)
		for field in overrides do
			assert(KNOWN_SPEC_FIELDS[field], `[Weapons] {id}.{kind}: unknown field {field}`)
		end
	end
end

local cache: { [string]: { [string]: AttackSpec } } = {}

local function build(def: WeaponDef, kind: AttackKind): AttackSpec
	local base = Config.Attacks[kind]
	-- Per-move timing hooks fall back to Config.MoveDefaults; cancel points merge per input.
	local spec = table.clone(Config.MoveDefaults) :: any
	for field, value in base do
		spec[field] = value
	end
	local cancel = table.clone(Config.MoveDefaults.cancel)
	for input, at in base.cancel or {} do
		cancel[input] = at
	end
	spec.cancel = cancel
	spec.windup = base.windup * def.windup
	if base.chainWindup then
		spec.chainWindup = base.chainWindup * def.windup
	end
	spec.recovery = base.recovery * def.recovery
	-- Cancel points are part of recovery: a slower weapon's open later.
	for input, at in cancel do
		cancel[input] = at * def.recovery
	end
	spec.damage = base.damage * def.damage
	spec.postureDamage = base.postureDamage * def.postureDamage
	spec.range = base.range * def.reach
	spec.lunge = base.lunge * def.reach
	-- A slower blade also turns slower inside its swing (tracking scales with the windup ratio).
	spec.trackRate = spec.trackRate / def.windup
	spec.startTurnRate = spec.startTurnRate / def.windup
	-- Perilous timing and armour are universal: the red warning means the same thing on
	-- every weapon, so defenders learn one rhythm.
	if base.perilous then
		spec.windup = base.windup
		spec.armorFrom = base.armorFrom
		spec.trackRate = base.trackRate or Config.MoveDefaults.trackRate
		spec.startTurnRate = base.startTurnRate or Config.MoveDefaults.startTurnRate
	end
	for field, value in (def.moves and def.moves[kind]) or {} do
		if field == "cancel" then
			for input, at in value do
				cancel[input] = at
			end
		else
			spec[field] = value
		end
	end
	spec.kind = kind
	spec.weapon = def.id
	return spec
end

function Weapons.get(id: string?): WeaponDef
	return defs[id or ""] or defs[Weapons.Default]
end

-- The move `kind` as performed with weapon `id` (falls back to the default weapon).
function Weapons.spec(id: string?, kind: AttackKind): AttackSpec
	local def = Weapons.get(id)
	local moves = cache[def.id]
	if not moves then
		moves = {}
		cache[def.id] = moves
	end
	local spec = moves[kind]
	if not spec then
		spec = build(def, kind)
		moves[kind] = spec
	end
	return spec
end

-- The weapon a fighter is holding, from its replicated attribute.
function Weapons.of(model: Instance?): string
	local id = model and model:GetAttribute("Weapon")
	return if typeof(id) == "string" and defs[id] then id else Weapons.Default
end

-- How a fighter may turn during its own swing (Kannagi turns once into an attack, then only
-- inside authored tracking windows). `elapsed` is the time since the attack started and
-- `untilImpact` the time left until hitAt (negative in recovery). Returns the allowed turn
-- rate in degrees/s (always capped), and whether this is the attack's opening turn.
-- Recovery never turns.
function Weapons.turnRate(spec: AttackSpec, elapsed: number, untilImpact: number): (number, boolean)
	if untilImpact <= 0 then
		return 0, false
	end
	if elapsed < spec.startTurn then
		return math.max(spec.startTurnRate, spec.trackRate), true
	end
	if elapsed >= spec.trackFrom and untilImpact > spec.trackUntil then
		return spec.trackRate, false
	end
	return 0, false
end

function Weapons.staminaCost(id: string?, action: string): number?
	local base = if action == "Feint" then Config.Feint.StaminaCost else Config.Stamina.Costs[action]
	if not base then
		return nil
	end
	-- Dodges are a universal defensive verb; feints (and attacks, if any cost stamina) scale
	-- with the weapon: a heavy blade's cancelled windup costs more.
	return if action == "Dodge" then base else base * Weapons.get(id).stamina
end

return Weapons
