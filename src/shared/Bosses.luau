--!strict
-- Kannagi Usagi's nine bosses as LAST BLADE fights: presentation (names, weapons, looks,
-- difficulty order) plus the bridge from the decoded move data (Shared/KannagiMoves,
-- generated) to our AttackSpec, so CombatService, the boss AI and every client read a boss
-- hit the same way.
--
-- A boss hit is an attack "kind" string `<boss>|<move key>|<hit index>` (e.g.
-- "Enemy01|Attack09|2"); Bosses.spec(kind) resolves it. Damage, posture, reaction sizes,
-- recoil on deflect, knockback and stomp windows come straight from the hit's DamageStatus
-- and notifies; the hit area is the weapon's reach plus the root motion that carries the
-- swing while its collider is on.
--
-- Scaling keeps Kannagi's ratios: a boss's vitality, posture and posture recovery are
-- multiplied by (our player's Light1/Light2 damage and posture) / (Kannagi's player hit,
-- 10 / 10), so it takes the same number of our cuts to break or kill as Kannagi's; boss
-- hits deal Kannagi's numbers (x Config.Bosses.DamageScale) against our 100 vitality.

local Config = require(script.Parent.Config)
local KannagiMoves = require(script.Parent.KannagiMoves)
local Weapons = require(script.Parent.Weapons)

type AttackSpec = Config.AttackSpec

export type Look = {
	skin: Color3,
	gi: Color3,
	hakama: Color3,
	sash: Color3,
	headwear: "Kasa" | "Ears" | "Horns" | "Mask" | "None",
	ears: string?, -- "Rabbit" | "Cat" | "Fox"
	earColor: Color3?,
	mask: Color3?,
	height: number, -- HumanoidDescription height scale; also the body's BodyScale (capsule, pose offsets).
	-- Kannagi's bosses stand ~1.35x its player: these are the earlier 1.08-1.18 looks x 1.2.
}

export type BossDef = {
	id: string, -- "Enemy01"
	num: string, -- "01", BakedBoss bundle id
	name: string,
	nameJP: string,
	stars: number,
	weapon: "Katana" | "Naginata" | "Odachi" | "Dual",
	weaponLook: string, -- the Weapons id whose mesh the boss holds
	tutorial: boolean?,
	look: Look,
	blurb: string,
}

local Bosses = {}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local SKIN = rgb(226, 190, 160)
local PALE = rgb(236, 228, 222)

Bosses.Defs = {
	Enemy01 = {
		id = "Enemy01",
		num = "01",
		name = "Nameless Warrior",
		nameJP = "追憶の名も無き武人",
		stars = 1,
		weapon = "Katana",
		weaponLook = "Katana",
		blurb = "A remembered swordsman. Guards your first cut, deflects the second, then counters.",
		look = {
			skin = SKIN,
			gi = rgb(58, 64, 88),
			hakama = rgb(34, 34, 42),
			sash = rgb(214, 206, 190),
			headwear = "Kasa",
			height = 1.34,
		},
	},
	Enemy02 = {
		id = "Enemy02",
		num = "02",
		name = "Puppet Maiden",
		nameJP = "傀儡巫女",
		stars = 3,
		weapon = "Naginata",
		weaponLook = "Katana",
		blurb = "A shrine maiden on strings. Never flinches; long naginata strings. Her mask falls in phase 2.",
		look = {
			skin = PALE,
			gi = rgb(236, 232, 226),
			hakama = rgb(170, 30, 34),
			sash = rgb(170, 30, 34),
			headwear = "Mask",
			mask = rgb(246, 240, 232),
			height = 1.34,
		},
	},
	Enemy03 = {
		id = "Enemy03",
		num = "03",
		name = "Shikigami of Rabbit",
		nameJP = "大兎の式神",
		stars = 0,
		weapon = "Katana",
		weaponLook = "Katana",
		tutorial = true,
		blurb = "The paper trainer. Teaches attack, deflect, double deflect, jump and Mikiri, then fights for real.",
		look = {
			skin = rgb(244, 240, 230),
			gi = rgb(244, 240, 230),
			hakama = rgb(206, 196, 180),
			sash = rgb(190, 40, 36),
			headwear = "Ears",
			ears = "Rabbit",
			earColor = rgb(244, 240, 230),
			height = 1.32,
		},
	},
	Enemy04 = {
		id = "Enemy04",
		num = "04",
		name = "Little Demon",
		nameJP = "荒くれの小鬼",
		stars = 2,
		weapon = "Odachi",
		weaponLook = "Odachi",
		blurb = "An oni with an odachi. Long chains; a perilous ender closes each one.",
		look = {
			skin = rgb(176, 62, 48),
			gi = rgb(92, 46, 34),
			hakama = rgb(196, 156, 64),
			sash = rgb(30, 26, 26),
			headwear = "Horns",
			height = 1.3,
		},
	},
	Enemy05 = {
		id = "Enemy05",
		num = "05",
		name = "Guard of Mist",
		nameJP = "狭霧の護り人",
		stars = 2,
		weapon = "Katana",
		weaponLook = "Katana",
		blurb = "Steps away into the mist and comes back with a delayed cut.",
		look = {
			skin = SKIN,
			gi = rgb(150, 162, 172),
			hakama = rgb(84, 94, 108),
			sash = rgb(226, 230, 236),
			headwear = "Kasa",
			height = 1.34,
		},
	},
	Enemy06 = {
		id = "Enemy06",
		num = "06",
		name = "Night Fox",
		nameJP = "夜狐",
		stars = 3,
		weapon = "Katana",
		weaponLook = "Katana",
		blurb = "Holds her windups frozen, sometimes for over a second. Don't press early.",
		look = {
			skin = PALE,
			gi = rgb(40, 30, 52),
			hakama = rgb(22, 18, 30),
			sash = rgb(210, 160, 70),
			headwear = "Ears",
			ears = "Fox",
			earColor = rgb(232, 170, 90),
			height = 1.42,
		},
	},
	Enemy07 = {
		id = "Enemy07",
		num = "07",
		name = "Cat General",
		nameJP = "ねこ大将",
		stars = 1,
		weapon = "Katana",
		weaponLook = "Katana",
		blurb = "Counters to whichever side you cut from.",
		look = {
			skin = rgb(236, 196, 140),
			gi = rgb(150, 82, 40),
			hakama = rgb(70, 48, 36),
			sash = rgb(214, 170, 60),
			headwear = "Ears",
			ears = "Cat",
			earColor = rgb(214, 140, 70),
			height = 1.32,
		},
	},
	Enemy08 = {
		id = "Enemy08",
		num = "08",
		name = "Crimson Shadow",
		nameJP = "残映の影",
		stars = 3,
		weapon = "Katana",
		weaponLook = "Katana",
		blurb = "Closes distance fast. Phase 2 switches to longer, meaner variants.",
		look = {
			skin = rgb(60, 52, 56),
			gi = rgb(26, 20, 24),
			hakama = rgb(16, 12, 16),
			sash = rgb(186, 24, 30),
			headwear = "None",
			height = 1.37,
		},
	},
	Enemy09 = {
		id = "Enemy09",
		num = "09",
		name = "Niten Usagi",
		nameJP = "二天兎",
		stars = 3,
		weapon = "Dual",
		weaponLook = "Katana",
		blurb = "Two swords. Double cuts land inside one deflect window; deflect in rhythm.",
		look = {
			skin = rgb(240, 236, 232),
			gi = rgb(232, 232, 240),
			hakama = rgb(52, 66, 110),
			sash = rgb(52, 66, 110),
			headwear = "Ears",
			ears = "Rabbit",
			earColor = rgb(240, 236, 232),
			height = 1.34,
		},
	},
} :: { [string]: BossDef }

-- The tutorial trainer first, then the bosses by difficulty (Kannagi's star ratings; ties by
-- how much vitality and posture they bring and how fast they press).
Bosses.Tutorial = "Enemy03"
Bosses.Order = { "Enemy01", "Enemy07", "Enemy05", "Enemy04", "Enemy06", "Enemy08", "Enemy02", "Enemy09" }
Bosses.List = { "Enemy03", "Enemy01", "Enemy07", "Enemy05", "Enemy04", "Enemy06", "Enemy08", "Enemy02", "Enemy09" }

function Bosses.def(id: string): BossDef?
	return Bosses.Defs[id]
end

-- The decoded Kannagi data for a boss (stats, phase2, moves, deck), loaded on first use.
function Bosses.data(id: string): KannagiMoves.Boss?
	return KannagiMoves.Bosses[id]
end

---------------------------------------------------------------------------------------
-- Scale: Kannagi's player hit (10 vitality, 10 posture at scale 1) against ours.

type Scale = { health: number, posture: number, playerPosture: number }
local scale: Scale? = nil

function Bosses.scale(): Scale
	if scale then
		return scale
	end
	local light1, light2 = Weapons.spec("Katana", "Light1"), Weapons.spec("Katana", "Light2")
	local ourDamage = (light1.damage + light2.damage) / 2
	local ourPosture = (light1.postureDamage + light2.postureDamage) / 2
	local stats = KannagiMoves.PlayerStats
	local first = KannagiMoves.Player.Ichijiku_Attack01_LA
	local hit = first and first.hits[1]
	local theirDamage = stats.attackBaseDamage * (if hit then hit.damageScale else 1)
	local theirPosture = stats.attackBaseTDamage * (if hit then hit.postureScale else 1)
	local built = {
		health = ourDamage / theirDamage,
		posture = ourPosture / theirPosture,
		playerPosture = ourPosture, -- Kannagi's player.AttackBaseTDamage, in our units
	}
	scale = built
	return built
end

-- A boss's vitality, posture and recovery at our scale. `phase2` applies Kannagi's
-- DamageNinsatsu setup (absolute HP, or a multiplier; posture x postureMul).
function Bosses.stats(
	id: string,
	phase: number,
	previousPostureMax: number?
): { hp: number, posture: number, regen: number }
	local data = Bosses.data(id) :: KannagiMoves.Boss
	local s = Bosses.scale()
	local stats = data.stats
	local hp = stats.hp
	local posture = stats.posture * s.posture
	if phase >= 2 and data.phase2 then
		local p2 = data.phase2 :: { [string]: any }
		if typeof(p2.hp) == "number" then
			hp = p2.hp
		elseif typeof(p2.hpMul) == "number" then
			hp = stats.hp * p2.hpMul
		end
		if typeof(p2.posture) == "number" then
			posture = p2.posture * s.posture
		elseif typeof(p2.postureMul) == "number" then
			posture = (previousPostureMax or posture) * p2.postureMul
		end
	end
	return {
		hp = math.floor(hp * s.health + 0.5),
		posture = math.floor(posture + 0.5),
		regen = (stats.postureRegen or 8.2) * s.posture,
	}
end

---------------------------------------------------------------------------------------
-- Hit kinds and specs

local SEPARATOR = "|"

function Bosses.kind(id: string, moveKey: string, hitIndex: number): string
	return `{id}{SEPARATOR}{moveKey}{SEPARATOR}{hitIndex}`
end

function Bosses.isKind(kind: any): boolean
	return typeof(kind) == "string" and string.find(kind, SEPARATOR, 1, true) ~= nil
end

function Bosses.parse(kind: string): (string?, string?, number?)
	local id, moveKey, index = string.match(kind, "^([^|]+)|(.+)|(%d+)$")
	return id, moveKey, tonumber(index)
end

-- Forward root motion (studs) a move covers between two of its times.
local function rootAt(move: KannagiMoves.Move, t: number): number
	local root = move.root
	if not root then
		return 0
	end
	local curve = root.curve
	if #curve == 0 then
		return 0
	end
	if t <= curve[1][1] then
		return curve[1][2]
	end
	for i = 2, #curve do
		local b = curve[i]
		if t <= b[1] then
			local a = curve[i - 1]
			local span = b[1] - a[1]
			local u = if span > 1e-6 then (t - a[1]) / span else 1
			return a[2] + (b[2] - a[2]) * u
		end
	end
	return curve[#curve][2]
end
Bosses.rootAt = rootAt

local REACTIONS: { [string]: Config.Reaction } =
	{ Small = "Small", Middle = "Middle", Large = "Large", Gedan = "Gedan" }
local GUARDS: { [string]: Config.GuardReaction } = { BackSmall = "Small", BackMiddle = "Middle", BackLarge = "Large" }

local function deflectSide(reaction: string): Config.DeflectSide
	if string.find(reaction, "Right", 1, true) then
		return "Right"
	elseif string.find(reaction, "Left", 1, true) then
		return "Left"
	end
	return "Back"
end

local cache: { [string]: AttackSpec | false } = {}

local function build(kind: string): AttackSpec?
	local id, moveKey, index = Bosses.parse(kind)
	if not id or not moveKey or not index then
		return nil
	end
	local data = Bosses.data(id)
	local def = Bosses.Defs[id]
	local move = data and data.moves[moveKey]
	local hit = move and move.hits[index]
	if not data or not def or not move or not hit then
		return nil
	end
	local rules = Config.Bosses
	local stats = data.stats
	local s = Bosses.scale()
	local damage = (hit.damage or hit.damageScale * stats.attackBaseDamage) * rules.DamageScale
	local posture = math.max(hit.postureDamage or hit.postureScale * stats.attackBaseTDamage, 0.01)
	-- Posture the boss takes when this hit is deflected: Kannagi's reTScale x the defender's
	-- AttackBaseTDamage, in our units. Our deflect computes postureDamage x deflectPosture.
	local toBoss = hit.reTScale * s.playerPosture
	local lunge = math.max(rootAt(move, hit.at + hit.dur) - rootAt(move, hit.at), 0)
	local stomp = move.flags.stompable :: { { from: number, to: number } }?
	local stompFrom, stompUntil = 0, 0
	if stomp and stomp[1] then
		stompFrom, stompUntil = stomp[1].from - hit.at, stomp[1].to - hit.at
	end
	local thrust = hit.type == "Tsuki"
	local low = hit.type == "Gedan"
	local spec = {
		windup = hit.at,
		recovery = math.max((move.duration or hit.at) - hit.at - hit.dur, 0),
		cooldown = 0,
		damage = damage,
		postureDamage = posture,
		range = (rules.Reach[def.weapon] or 7) + lunge,
		width = rules.Width,
		lunge = 0,
		unblockable = low, -- only a jump answers a sweep
		perilous = thrust or low,
		noGuard = thrust,
		thrust = thrust,
		low = low,
		armorFrom = nil,
		cooldownGroup = nil,
		riposte = nil,
		chainWindup = nil,
		ender = nil,
		follow = nil,
		startTurn = 0,
		startTurnRate = 0,
		trackRate = 0,
		trackFrom = 0,
		trackUntil = 0,
		recoilOnDeflect = hit.recoil ~= "None",
		deflectPosture = toBoss / posture,
		cancel = {},
		lungeAt = -0.05,
		lungeTime = 0.16,
		reaction = REACTIONS[hit.reaction] or "Small",
		guardReaction = GUARDS[hit.guardReaction] or "Small",
		deflectSide = deflectSide(hit.deflectReaction),
		knockback = hit.knockback,
		stompFrom = stompFrom,
		stompUntil = stompUntil,
		kind = kind :: any,
		weapon = def.weaponLook,
	}
	return spec :: AttackSpec
end

-- The AttackSpec of one boss hit, or nil if `kind` isn't a boss hit.
function Bosses.spec(kind: string): AttackSpec?
	local cached = cache[kind]
	if cached == nil then
		cached = build(kind) or false
		cache[kind] = cached
	end
	return if cached then cached else nil
end

-- The move a boss kind belongs to.
function Bosses.move(kind: string): KannagiMoves.Move?
	local id, moveKey = Bosses.parse(kind)
	local data = id and Bosses.data(id)
	return if data and moveKey then data.moves[moveKey] else nil
end

-- Our spec for any attack kind a model performs: a boss hit, or the weapon's move.
function Bosses.specFor(weapon: string?, kind: any): AttackSpec?
	if Bosses.isKind(kind) then
		return Bosses.spec(kind)
	end
	if typeof(kind) == "string" and Config.Attacks[kind :: Config.AttackKind] then
		return Weapons.spec(weapon, kind :: Config.AttackKind)
	end
	return nil
end

-- Which BakedBoss bundles a boss's moves use ("01" for its own clips, plus any boss whose
-- animations it borrows, e.g. Enemy05 reuses Enemy01's).
function Bosses.bundles(id: string): { string }
	local data = Bosses.data(id)
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	if not data then
		return out
	end
	for _, move in data.moves do
		local num = string.match(move.anim, "^Enemy(%d%d)_")
		if num and not seen[num] then
			seen[num] = true
			table.insert(out, num)
		end
	end
	table.sort(out)
	return out
end

return Bosses
