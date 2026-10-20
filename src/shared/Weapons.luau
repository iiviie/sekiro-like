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
	GuardZ: number, -- tsuba; the swing trail starts here
	TipZ: number,
}

export type WeaponDef = {
	id: string,
	name: string,
	description: string,
	archetype: string,
	price: number, -- coins; 0 = owned from the start. Weapons are never sold for Robux.
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

local defs: { [string]: WeaponDef } = {
	-- The baseline everything is measured against: no strengths, no weaknesses.
	Katana = {
		id = "Katana",
		name = "Katana",
		description = "Balanced. Fast enough to pressure, safe enough to deflect with.",
		archetype = "All-rounder",
		price = 0,
		look = {
			MeshId = KATANA_MESH,
			TextureId = KATANA_TEXTURE,
			Scale = Vector3.new(0.6 * 1.35, 0.6 * 2.6, 0.6 * 1.13),
			Size = Vector3.new(0.39, 0.99, 4.4),
			GripZ = -1.7,
			GuardZ = -1.07,
			TipZ = 2.15,
		},
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
		price = 600,
		look = {
			MeshId = KATANA_MESH,
			TextureId = KATANA_TEXTURE,
			Scale = Vector3.new(0.6 * 1.6, 0.6 * 3.2, 0.6 * 1.5),
			Size = Vector3.new(0.46, 1.22, 5.85),
			GripZ = -2.15,
			GuardZ = -1.35,
			TipZ = 2.85,
		},
		windup = 1.4,
		recovery = 1.3,
		damage = 1.3,
		postureDamage = 1.5,
		reach = 1.25,
		stamina = 1.35,
		moves = {
			-- Strings don't speed up as much: an odachi string is two swings, not a flurry.
			Light2 = { chainWindup = 0.54 },
			Light3 = { chainWindup = 0.56 },
			-- Its overhead has late-windup armour: trade into it and lose.
			Overhead = { armorFrom = 0.25 },
			-- The riposte is the one fast move it gets, so the parry still pays.
			Riposte = { windup = 0.2, recovery = 0.4 },
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
for _, field in
	{ "armorFrom", "chainWindup", "cooldownGroup", "riposte", "ender", "perilous", "noGuard", "thrust", "low" }
do
	KNOWN_SPEC_FIELDS[field] = true
end

-- Load-time validation: bad content fails in Studio, not mid-match.
for id, def in defs do
	assert(def.id == id, `[Weapons] {id}: id mismatch`)
	for _, field in REQUIRED_NUMBERS do
		local value = (def :: any)[field]
		assert(typeof(value) == "number" and value > 0, `[Weapons] {id}: {field} must be a positive number`)
	end
	assert(typeof(def.price) == "number" and def.price >= 0, `[Weapons] {id}: price must be >= 0`)
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
	local spec = table.clone(base) :: any
	spec.windup = base.windup * def.windup
	if base.chainWindup then
		spec.chainWindup = base.chainWindup * def.windup
	end
	spec.recovery = base.recovery * def.recovery
	spec.damage = base.damage * def.damage
	spec.postureDamage = base.postureDamage * def.postureDamage
	spec.range = base.range * def.reach
	spec.lunge = base.lunge * def.reach
	-- Perilous timing and armour are universal: the red warning means the same thing on
	-- every weapon, so defenders learn one rhythm.
	if base.perilous then
		spec.windup = base.windup
		spec.armorFrom = base.armorFrom
	end
	for field, value in (def.moves and def.moves[kind]) or {} do
		spec[field] = value
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

function Weapons.staminaCost(id: string?, action: string): number?
	local base = Config.Stamina.Costs[action]
	if not base then
		return nil
	end
	-- Dodges are a universal defensive verb; only attacks scale with the weapon.
	return if action == "Dodge" then base else base * Weapons.get(id).stamina
end

return Weapons
