--!strict
-- Swordsman stance and footwork for every R15 fighter, procedural: client/Animator turns these
-- targets into joint Transforms with leg IK, under the stance poses and clips.
--
-- Kannagi Usagi's own locomotion doesn't fit (an upright idle with the sword hanging, Paragon
-- jogs with the blade trailing, and the jog folds the R15 block torso into a heap when
-- retargeted), so the stance and cycles are built here from how people walk and run:
--   standing  knees bent, feet wide, the right foot forward and the hips turned off the facing.
--             Feet hold their place in the world: when the body turns or drifts off them they
--             step back under it, one foot then the other (turning on the spot, settling after
--             a stop or a lunge).
--   moving    a cycle by ground speed: cadence rises gently with speed (about 2 steps a second
--             walking, 3 running) and the stride makes up the rest, so a run has a flight phase
--             instead of legs scurrying. A planted foot is locked to the ground where it landed
--             (no sliding, even with a jittery replicated velocity), lands on the heel walking
--             or flat running, rolls over onto the toes and pushes off from them; the swinging
--             foot kicks up behind, then reaches forward. The pelvis bobs (high mid-stance
--             walking, low mid-stance running), sways and turns with the legs, the chest
--             counter-turns, the arms swing against the legs, and the body leans into a run,
--             into acceleration and into turns.
-- Distances are for a 1x R15 body (leg 1.8 studs, hip to ankle); the Animator scales them by
-- the actual leg length, so bosses (BodyScale 1.3-1.4) step in proportion.
--
-- Gait.Mode picks who animates walking and running forward (review round 1 A/B):
--   "hybrid"      Roblox's default R15 walk and run (the Animate script's own clips, what most
--                 Roblox players know) on the legs and the free arm, with the sword arm and the
--                 stance layered on top; this cycle only takes slow steps (under ~4 studs/s, where
--                 its planted feet matter), lock-on strafes and backpedals, and standing.
--   "procedural"  this cycle for every speed and direction.
-- In Studio a workspace attribute GaitMode overrides it live (client/Animator).

local Gait = {
	Mode = "hybrid" :: "hybrid" | "procedural",
}

local rad = math.rad
local TAU = 2 * math.pi

-- A classic R15 foot (1x): the ankle pivot's height over the sole and its distance to toe and
-- heel. The Animator passes each rig's real foot (avatars' feet differ a lot) through Gait.setFoot.
export type FootShape = { ankleH: number, toe: number, heel: number }
local DEFAULT_FOOT: FootShape = { ankleH = 0.2, toe = 0.42, heel = 0.3 }
-- The swinging ankle never comes closer to the hip than this share of the leg (a knee folded
-- tighter than ~115 degrees flips the shin on a block rig).
local MIN_FOLD = 0.62
local LEG = 1.8 -- hip pivot to ankle pivot, standing straight
local REACH = 1.74 -- the longest hip-to-ankle distance asked of the IK (a planted leg keeps a little bend)
local GRAVITY = 196.2

-- Where the ankles stand at rest (root space: x right, z back), how low the hips sit and how far
-- they turn left of the facing (degrees), and which way each foot points (degrees left of facing).
type Shape = {
	drop: number,
	hipYaw: number,
	right: Vector3,
	left: Vector3,
	rightYaw: number,
	leftYaw: number,
}

-- In a fight: a low, wide stance, right foot leading, back foot turned out.
local IDLE_COMBAT: Shape = {
	drop = 0.52,
	hipYaw = 36,
	right = Vector3.new(0.48, 0, -0.9),
	left = Vector3.new(-0.7, 0, 0.6),
	rightYaw = 6,
	leftYaw = 56,
}
-- Out of a fight: the same stance, standing taller and narrower.
local IDLE_RELAXED: Shape = {
	drop = 0.12,
	hipYaw = 16,
	right = Vector3.new(0.48, 0, -0.26),
	left = Vector3.new(-0.52, 0, 0.22),
	rightYaw = 4,
	leftYaw = 26,
}

-- How the stance carries into a stride. drop/runDrop: hip drop walking / running; hipYaw: the
-- stance's turn kept on top of the turn toward travel; width: half the track; stagger: the right
-- foot's lead (walking); bob: hip bob scale; lean: forward lean running (degrees); swing: chest
-- counter-turn and arm swing scale.
local MOVE_COMBAT = {
	drop = 0.2, -- moving stands taller than the planted fight stance (a guarded side-step, not a crouch)
	runDrop = 0.14,
	hipYaw = 12,
	width = 0.46,
	stagger = 0.14,
	toeOut = 8,
	bob = 0.6,
	lean = 5,
	swing = 0.4,
}
local MOVE_RELAXED =
	{ drop = 0.16, runDrop = 0.13, hipYaw = 0, width = 0.42, stagger = 0, toeOut = 5, bob = 1, lean = 9, swing = 1 }

-- The cycle by ground speed (1x studs/s): FREQ = strides per second (two steps each), DUTY = the
-- share of a stride a foot would like to spend on the ground (a stride too long for the legs to
-- cover planted shortens it into a flight phase), LIFT = how high the swinging ankle rises.
local SPEEDS = { 0, 3, 6, 9, 13, 16, 22, 28 }
-- Roblox legs are short for the body (~35% of its height, ~50% on a person), so the cadence sits a
-- little above a real runner's at the same speed: ~3.5 steps a second at 16, never above 4.
local FREQ = { 1.0, 1.15, 1.3, 1.45, 1.65, 1.75, 1.88, 2.0 }
local DUTY = { 0.64, 0.62, 0.52, 0.38, 0.34, 0.33, 0.29, 0.26 }
local LIFT = { 0.08, 0.12, 0.26, 0.38, 0.46, 0.5, 0.56, 0.6 }

-- Degrees the hips turn toward the travel direction, so a lock-on strafe runs on legs pointing
-- (nearly) where they go instead of crossing over; the waist takes the twist back to the facing,
-- with CHEST_FOLLOW of it showing in the chest.
local TURN_LIMIT = 40
local CHEST_FOLLOW = 0.3
-- Standing: a foot further than STEP_DIST (studs) or STEP_YAW (degrees) off its place in the stance
-- steps back to it over STEP_TIME seconds; then the other foot follows if it is off at all.
local STEP_DIST = 0.32
local STEP_YAW = 24
local FOLLOW_DIST = 0.1
local FOLLOW_YAW = 8
local STEP_TIME = 0.17
local STEP_LIFT = 0.17
local HIP_TURN_RATE = 7
local MOVE_RATE = 9 -- moving weight in and out
local SPEED_RATE = 10 -- smoothing of the measured ground speed
local COMBAT_RATE = 4
-- Hybrid mode: the authored cycle takes forward travel above AUTHORED_ON studs/s within ~30
-- degrees of the facing (and lets go below AUTHORED_OFF or past ~55 degrees), blending at this rate.
local AUTHORED_ON = 5
local AUTHORED_OFF = 3.5
local AUTHORED_RATE = 10
-- A hard stop (from a run to nothing in a frame) shows BRAKE_TIME seconds of braking: hips sink
-- and the body rocks back over the planted feet before the stance settles.
local BRAKE_TIME = 0.24
local BRAKE_DROP = 0.1
local BRAKE_LEAN = 6 -- degrees back
-- The relaxed stance breathes (studs of hip rise, degrees of chest pitch) and shifts its weight
-- from foot to foot every IDLE_SHIFT seconds; the fight stance holds still.
local BREATH = 0.05
local BREATH_PITCH = 1.5
local IDLE_SWAY = 0.08
local IDLE_SHIFT = 4

type FootMem = {
	planted: boolean, -- on the ground in the cycle last frame
	lock: Vector3?, -- world point (1x) the planted foot landed on
	liftFrom: Vector3, -- root-space ankle where the last stance ended (the swing starts here)
	anchor: Vector3?, -- world point (1x) the standing foot stands on
	anchorYaw: number, -- world yaw (degrees) the standing foot points
	lastPos: Vector3, -- this frame's cycle ankle (root space), for the anchors
	lastYaw: number,
}

export type Memory = {
	phase: number, -- 0..1 along the stride; the right foot lands at 0, the left at 0.5
	speed: number, -- smoothed ground speed (1x studs/s)
	accel: number, -- smoothed forward acceleration (1x studs/s^2)
	dir: Vector3, -- smoothed travel direction (root space, unit, y = 0)
	moveW: number, -- 0 standing .. 1 moving
	combat: number, -- 0 relaxed .. 1 fight stance
	hipTurn: number, -- smoothed turn toward travel (degrees)
	backing: boolean, -- travelling backward: the hips turn away from the travel direction
	clock: number,
	facing: number?, -- last frame's facing (world yaw, degrees)
	yawRate: number, -- smoothed turn rate (degrees/s)
	authored: number, -- 0..1, how much the authored cycle takes (hybrid mode)
	authoredOn: boolean,
	brakeT: number, -- seconds since a hard stop began (BRAKE_TIME and over: none)
	brakeAmt: number,
	fastAt: number, -- clock when the body last ran faster than 13 studs/s
	feet: { [string]: FootMem },
	stepping: string?, -- the standing foot stepping back under the body ("Right" / "Left")
	stepFrom: Vector3,
	stepFromYaw: number,
	stepT: number,
	stepsLeft: number,
	stepLanded: string?, -- the standing step that finished this frame
	foot: FootShape,
}

-- `landed`: the foot touched down this frame (a stride's touchdown or a standing step's end).
export type Foot = { pos: Vector3, yaw: number, pitch: number, planted: number, landed: boolean }

export type Targets = {
	drop: number, -- studs the hips sit below standing (bob included)
	sway: number, -- studs the hips shift right
	hipYaw: number, -- radians, + = left (right hip forward)
	hipRoll: number, -- radians, + = right hip up (bank included)
	hipPitch: number, -- radians, - = pelvis tipped forward
	lean: number, -- radians of forward torso pitch over the hips (- = forward)
	bank: number, -- radians the whole body leans into a turn (+ = toward the left)
	chestYaw: number, -- radians the chest turns off the facing (counter to the hips)
	right: Foot,
	left: Foot,
	armSwing: number, -- radians, + = left arm forward
	armBend: number, -- radians of elbow bend (more running)
	moveW: number,
	run: number, -- 0 walking .. 1 running
	combat: number,
	authored: number, -- 0..1, how much of the moving body the authored cycle takes (hybrid mode)
}

local function footMem(): FootMem
	return {
		planted = false,
		lock = nil,
		liftFrom = Vector3.zero,
		anchor = nil,
		anchorYaw = 0,
		lastPos = Vector3.zero,
		lastYaw = 0,
	}
end

function Gait.new(): Memory
	return {
		phase = 0,
		speed = 0,
		accel = 0,
		dir = Vector3.new(0, 0, -1),
		moveW = 0,
		combat = 0,
		hipTurn = 0,
		backing = false,
		clock = 0,
		facing = nil,
		yawRate = 0,
		authored = 0,
		authoredOn = false,
		brakeT = math.huge,
		brakeAmt = 0,
		fastAt = -math.huge,
		feet = { Right = footMem(), Left = footMem() },
		stepping = nil,
		stepFrom = Vector3.zero,
		stepFromYaw = 0,
		stepT = 0,
		stepsLeft = 0,
		stepLanded = nil,
		foot = DEFAULT_FOOT,
	}
end

-- The rig's foot in 1x studs: ankle pivot height over the sole, and its distance to toe and heel.
function Gait.setFoot(m: Memory, ankleH: number, toe: number, heel: number)
	local f = m.foot
	if f == DEFAULT_FOOT or math.abs(f.ankleH - ankleH) + math.abs(f.toe - toe) + math.abs(f.heel - heel) > 1e-3 then
		m.foot = {
			ankleH = math.clamp(ankleH, 0.05, 0.8),
			toe = math.clamp(toe, 0.1, 1),
			heel = math.clamp(heel, 0.05, 0.8),
		}
	end
end

-- Hybrid mode: where a foot the authored cycle is showing stands right now (root space, 1x
-- studs; yaw in degrees left of the facing), so that when this cycle takes over again (a stop,
-- a slow step) the standing feet start from what was on screen.
function Gait.observeFoot(m: Memory, side: string, pos: Vector3, yaw: number)
	local f = m.feet[side]
	if f then
		f.lastPos = Vector3.new(pos.X, 0, pos.Z)
		f.lastYaw = yaw
	end
end

-- Piecewise-linear lookup in the speed table.
local function bySpeed(column: { number }, speed: number): number
	if speed <= SPEEDS[1] then
		return column[1]
	end
	for i = 2, #SPEEDS do
		if speed <= SPEEDS[i] then
			local a = (speed - SPEEDS[i - 1]) / (SPEEDS[i] - SPEEDS[i - 1])
			return column[i - 1] + (column[i] - column[i - 1]) * a
		end
	end
	return column[#column]
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function clamp01(x: number): number
	return math.clamp(x, 0, 1)
end

-- Rotates a root-space vector `degrees` to the left about the vertical.
local function turn(v: Vector3, degrees: number): Vector3
	local r = rad(degrees)
	local c, s = math.cos(r), math.sin(r)
	return Vector3.new(v.X * c + v.Z * s, v.Y, -v.X * s + v.Z * c)
end

local function smooth(u: number): number
	u = clamp01(u)
	return u * u * (3 - 2 * u)
end

local function smoother(u: number): number
	u = clamp01(u)
	return u * u * u * (u * (u * 6 - 15) + 10)
end

local function wrap(degrees: number): number
	return (degrees + 180) % 360 - 180
end

-- The ankle (root space, y over its standing height) of a foot whose sole would stand flat at
-- ground point `g`, pointing `yaw` degrees left, pitched `pitch` radians (+ = toes up, rocking
-- on the heel; - = heel up, rocking on the toes).
local function rolled(g: Vector3, yaw: number, pitch: number, foot: FootShape): Vector3
	if math.abs(pitch) < 1e-4 then
		return g
	end
	local pivot = if pitch < 0 then Vector3.new(0, -foot.ankleH, -foot.toe) else Vector3.new(0, -foot.ankleH, foot.heel)
	local local_ = pivot + CFrame.Angles(pitch, 0, 0) * -pivot
	return g + turn(local_, yaw)
end

-- Root-space <-> world (1x units, ground plane) for a body at `origin` facing `facing` degrees.
local function toRoot(p: Vector3, origin: Vector3, facing: number): Vector3
	local d = p - origin
	return turn(Vector3.new(d.X, 0, d.Z), -facing)
end

local function toWorld(p: Vector3, origin: Vector3, facing: number): Vector3
	local d = turn(Vector3.new(p.X, 0, p.Z), facing)
	return Vector3.new(origin.X + d.X, 0, origin.Z + d.Z)
end

-- Standing: each foot keeps its world place; a foot that the body has turned or drifted off
-- steps back to its place in the stance. Returns each foot's root-space ground point, yaw
-- (degrees left of facing) and lift. `owned`: a clip is posing the legs, so the places just
-- follow the stance.
local function standing(
	m: Memory,
	dt: number,
	origin: Vector3,
	facing: number,
	want: { [string]: Vector3 },
	wantYaw: { [string]: number },
	owned: boolean
): ({ [string]: Vector3 }, { [string]: number }, { [string]: number })
	local feet = m.feet
	local pos: { [string]: Vector3 } = {}
	local yaw: { [string]: number } = {}
	local lift: { [string]: number } = { Right = 0, Left = 0 }
	for side, f in feet do
		if m.moveW > 0.5 or owned or not f.anchor then
			-- Moving (or posed by a clip): the place follows where the foot is right now.
			local at = if m.moveW > 0.5 then f.lastPos else want[side]
			f.anchor = toWorld(at, origin, facing)
			f.anchorYaw = facing + (if m.moveW > 0.5 then f.lastYaw else wantYaw[side])
		end
	end
	if m.moveW > 0.5 or owned then
		m.stepping = nil
	end
	local function errorOf(side: string): (number, number)
		local f = feet[side]
		local at = toRoot(f.anchor :: Vector3, origin, facing)
		return (at - want[side]).Magnitude, math.abs(wrap(f.anchorYaw - facing - wantYaw[side]))
	end
	if not m.stepping and m.moveW <= 0.5 and not owned then
		local rd, ry = errorOf("Right")
		local ld, ly = errorOf("Left")
		local rScore, lScore = math.max(rd / STEP_DIST, ry / STEP_YAW), math.max(ld / STEP_DIST, ly / STEP_YAW)
		if math.max(rScore, lScore) > 1 then
			local side = if rScore >= lScore then "Right" else "Left"
			m.stepping = side
			m.stepFrom = feet[side].anchor :: Vector3
			m.stepFromYaw = feet[side].anchorYaw
			m.stepT = 0
			m.stepsLeft = 2
		end
	end
	local side = m.stepping
	if side then
		local f = feet[side]
		m.stepT = math.min(m.stepT + dt / STEP_TIME, 1)
		local goal = toWorld(want[side], origin, facing)
		local goalYaw = facing + wantYaw[side]
		local s = smooth(m.stepT)
		f.anchor = m.stepFrom:Lerp(goal, s)
		f.anchorYaw = m.stepFromYaw + wrap(goalYaw - m.stepFromYaw) * s
		lift[side] = STEP_LIFT * math.sin(math.pi * m.stepT)
		if m.stepT >= 1 then
			m.stepLanded = side
			m.stepsLeft -= 1
			local other = if side == "Right" then "Left" else "Right"
			local od, oy = errorOf(other)
			if m.stepsLeft > 0 and (od > FOLLOW_DIST or oy > FOLLOW_YAW) then
				m.stepping = other
				m.stepFrom = feet[other].anchor :: Vector3
				m.stepFromYaw = feet[other].anchorYaw
				m.stepT = 0
			else
				m.stepping = nil
			end
		end
	end
	for s, f in feet do
		pos[s] = toRoot(f.anchor :: Vector3, origin, facing)
		yaw[s] = wrap(f.anchorYaw - facing)
	end
	return pos, yaw, lift
end

-- Advances the memory by dt for a body moving at `velocity` (root space, 1x studs/s), facing
-- `facing` (world yaw, degrees) from `origin` (world position / leg scale), and returns this
-- frame's targets. `combat` is the stance wanted (1 = fight stance, 0 = relaxed); `owned` = a
-- clip is posing the legs right now (standing feet then follow the stance instead of stepping).
function Gait.step(
	m: Memory,
	dt: number,
	velocity: Vector3,
	combat: number,
	facing: number,
	origin: Vector3?,
	owned: boolean?
): Targets
	dt = math.clamp(dt, 0, 0.1)
	m.clock += dt
	local at = origin or Vector3.zero
	local flat = Vector3.new(velocity.X, 0, velocity.Z)
	local speed = flat.Magnitude
	local kSpeed = 1 - math.exp(-dt * SPEED_RATE)
	local before = m.speed
	m.speed += (speed - m.speed) * kSpeed
	if dt > 0 then
		m.accel += ((m.speed - before) / dt - m.accel) * (1 - math.exp(-dt * 6))
	end
	-- A hard stop: the (lightly smoothed) ground speed falls from a run to under half of it at once.
	if speed > 13 then
		m.fastAt = m.clock
	end
	if speed < 7 and m.clock - m.fastAt < 0.25 and m.brakeT >= BRAKE_TIME then
		m.brakeT = 0
		m.brakeAmt = clamp01((math.max(before, speed) - 4) / 10)
		m.fastAt = -math.huge
	elseif m.brakeT < BRAKE_TIME then
		m.brakeT += dt
		if speed > 4 and speed > before then
			m.brakeT = BRAKE_TIME -- speeding up again: no more braking
		end
	end
	local wasStill = m.moveW < 0.05
	m.moveW += (clamp01((speed - 0.6) / 2.4) - m.moveW) * (1 - math.exp(-dt * MOVE_RATE))
	m.combat += (combat - m.combat) * (1 - math.exp(-dt * COMBAT_RATE))
	if speed > 0.5 then
		local d = flat.Unit
		-- Turn the smoothed direction toward the new one (a reversal passes through the side).
		local blended = m.dir:Lerp(d, math.min(kSpeed * 1.5, 1))
		m.dir = if blended.Magnitude > 1e-3 then blended.Unit else d
	end
	if m.facing and dt > 0 then
		m.yawRate += (wrap(facing - m.facing) / dt - m.yawRate) * (1 - math.exp(-dt * 8))
	end
	m.facing = facing
	local c = m.combat
	local w = m.moveW
	local v = m.speed
	local run = clamp01((v - 4) / 4)
	local walk = 1 - run

	-- Hybrid: forward travel at a walk or faster goes to the authored cycle (with hysteresis, so a
	-- turn or a speed change near the limits doesn't flicker between the two).
	local forwardTravel = -m.dir.Z
	if Gait.Mode ~= "hybrid" then
		m.authoredOn = false
	elseif m.authoredOn then
		m.authoredOn = v > AUTHORED_OFF and forwardTravel > 0.57
	else
		m.authoredOn = v > AUTHORED_ON and forwardTravel > 0.87
	end
	m.authored += ((if m.authoredOn then 1 else 0) - m.authored) * (1 - math.exp(-dt * AUTHORED_RATE))

	-- Hips turn toward the direction of travel (degrees left of the facing), or away from it when
	-- backing off, with some hysteresis so a pure strafe doesn't flip between the two.
	local travelYaw = math.deg(math.atan2(-m.dir.X, -m.dir.Z))
	if m.backing then
		m.backing = math.abs(travelYaw) > 80
	else
		m.backing = math.abs(travelYaw) > 100
	end
	local toward = if m.backing then (travelYaw + (if travelYaw > 0 then -180 else 180)) else travelYaw
	toward = math.clamp(toward, -TURN_LIMIT, TURN_LIMIT) * w
	m.hipTurn += (toward - m.hipTurn) * (1 - math.exp(-dt * HIP_TURN_RATE))

	local idleHip = lerp(IDLE_RELAXED.hipYaw, IDLE_COMBAT.hipYaw, c)
	-- (The fight stance's own hip turn only shows while going forward or back.)
	local sidewaysTravel = math.abs(math.sin(rad(travelYaw)))
	local stanceHip = lerp(MOVE_RELAXED.hipYaw, MOVE_COMBAT.hipYaw, c) * (1 - sidewaysTravel)
	local moveHip = math.clamp(m.hipTurn + stanceHip, -75, 75)
	local hipYaw = lerp(idleHip, moveHip, w)

	-- The stride: cadence by speed, a stride long enough to cover the ground at that cadence, and
	-- the share of it a foot can stay planted given how far the legs reach from these hips.
	local moveDrop =
		lerp(lerp(MOVE_RELAXED.drop, MOVE_COMBAT.drop, c), lerp(MOVE_RELAXED.runDrop, MOVE_COMBAT.runDrop, c), run)
	local inHips = turn(m.dir, -hipYaw)
	local sideways = math.abs(inHips.X)
	local freq = bySpeed(FREQ, v) * (1 + 0.25 * sideways) -- side steps are shorter, quicker
	local stride = math.max(v / freq, 0.01)
	local high = LEG - moveDrop
	local front = math.sqrt(math.max(REACH * REACH - high * high, 0.04))
	local toePitch = rad(lerp(26, 40, run))
	local foot = m.foot
	local rise = foot.toe * math.sin(toePitch) * 0.9
	local back = math.sqrt(math.max(REACH * REACH - (high - rise) ^ 2, 0.04))
	local reachScale = 1 - 0.35 * sideways -- legs don't reach as far across the body
	front *= reachScale
	back *= reachScale
	-- Backing off, the push-off happens in front of the body: keep that reach short.
	local backward = clamp01(inHips.Z * 1.2)
	back = lerp(back, math.min(back, 0.55), backward)
	local duty = math.min(bySpeed(DUTY, v), (front + back) / stride)
	local span = duty * stride
	-- Running lands closer under the body and pushes off far behind.
	local frontShare = lerp(lerp(0.5, 0.36, run), 0.62, backward)
	local a = math.min(span * frontShare, front)
	local b = math.min(span - a, back)
	span = a + b
	duty = span / stride
	if v > 0.05 then
		m.phase = (m.phase + v * dt / stride) % 1
	end
	if wasStill and w >= 0.05 then
		-- Starting off: the foot further behind (along the travel) swings first.
		local rightAt, leftAt = m.feet.Right.anchor, m.feet.Left.anchor
		local r = if rightAt then toRoot(rightAt, at, facing):Dot(m.dir) else 0
		local l = if leftAt then toRoot(leftAt, at, facing):Dot(m.dir) else 0
		m.phase = if r <= l then duty else (duty + 0.5) % 1
		m.feet.Right.lock, m.feet.Left.lock = nil, nil
		m.feet.Right.planted, m.feet.Left.planted = false, false
	end
	-- Backing off, the legs reach back low and land on the toes: no heel kick or knee drive. In a
	-- fight the feet stay lower too, a guarded run rather than a sprint.
	local lift = bySpeed(LIFT, v) * (1 - 0.15 * sideways) * (1 - 0.45 * backward) * (1 - 0.2 * c)

	-- Where each foot tracks while moving: under the turned hips, the right foot a little ahead.
	local width = lerp(MOVE_RELAXED.width, MOVE_COMBAT.width, c) + 0.1 * sideways
	local stagger = lerp(MOVE_RELAXED.stagger, MOVE_COMBAT.stagger, c) * walk
	local toeOut = lerp(MOVE_RELAXED.toeOut, MOVE_COMBAT.toeOut, c)
	local track = {
		Right = turn(Vector3.new(width, 0, -stagger), hipYaw),
		Left = turn(Vector3.new(-width, 0, stagger), hipYaw),
	}
	local trackYaw = { Right = hipYaw - toeOut, Left = hipYaw + toeOut }

	-- Heel strike walking, flat running; heel rise late in the stance, toes pushing off.
	local strikePitch = rad(lerp(lerp(14, 3, run), -8, backward))
	local kick = lerp(0.05, 0.36, run) * (1 - backward) * (1 - 0.45 * c) -- how far the foot drifts on behind after toe-off
	local overreach = lerp(0.04, 0.16, run) * (1 - backward) -- and past its landing spot before pulling back
	local rollStart = lerp(0.55, 0.35, run)

	local cyc: { [string]: Foot } = {}
	for side, f in m.feet do
		local p = if side == "Right" then m.phase else (m.phase + 0.5) % 1
		local offset = track[side]
		local yaw = trackYaw[side]
		if p < duty then
			local u = p / duty
			local g = offset + m.dir * (a - span * u)
			local touchdown = not f.planted
			if touchdown or not f.lock then
				f.lock = toWorld(g, at, facing) -- touchdown: this spot holds until lift-off
			end
			f.planted = true
			local held = toRoot(f.lock :: Vector3, at, facing)
			local off = held - g
			if off.Magnitude > 0.6 then
				held = g + off.Unit * 0.6 -- (a teleport or a wild velocity: don't stretch the leg)
				f.lock = toWorld(held, at, facing)
			end
			local pitch = if u < 0.2
				then strikePitch * (1 - smooth(u / 0.2))
				else -toePitch * smooth((u - rollStart) / (1 - rollStart))
			local pos = rolled(held, yaw, pitch, foot)
			f.liftFrom = pos
			cyc[side] = { pos = pos, yaw = yaw, pitch = pitch, planted = 1, landed = touchdown }
		else
			if f.planted then
				f.planted = false
			end
			f.lock = nil
			local u = (p - duty) / (1 - duty)
			local from = if w > 0.5 then f.liftFrom else rolled(offset - m.dir * b, yaw, -toePitch, foot)
			local to = rolled(offset + m.dir * a, yaw, strikePitch, foot)
			local s = smoother((u - 0.06) / 0.94)
			-- Heel kicks up behind first (peak a little before mid-swing), then the knee drives
			-- the foot forward past where it will land and it pulls back down onto the spot.
			local height = lift * math.sin(math.pi * u ^ 0.78) ^ 1.3
			local drift = -kick * math.sin(math.pi * math.min(u / 0.45, 1))
				+ overreach * math.sin(math.pi * clamp01((u - 0.5) / 0.5))
			-- The toes point down after push-off and come up to land.
			local toesDown = -toePitch * 0.55
			local pitch = if u < 0.3
				then lerp(-toePitch, toesDown, smooth(u / 0.3))
				else lerp(toesDown, strikePitch, smooth((u - 0.3) / 0.6))
			local pos = from:Lerp(to, s) + m.dir * drift + Vector3.new(0, height, 0)
			-- The toes clear the ground however long the foot (big avatar feet would drag).
			local toeDrop = if pitch < 0 then foot.toe * math.sin(-pitch) - foot.ankleH * (1 - math.cos(pitch)) else 0
			pos = Vector3.new(pos.X, math.max(pos.Y, toeDrop + 0.1 * math.sin(math.pi * u)), pos.Z)
			-- Keep the knee from folding shut: lower the foot if it comes too close to the hip.
			local hip = Vector3.new(offset.X, LEG - moveDrop, offset.Z)
			local flatGap = Vector3.new(pos.X - hip.X, 0, pos.Z - hip.Z).Magnitude
			local minD = MIN_FOLD * LEG
			if flatGap < minD then
				pos = Vector3.new(pos.X, math.min(pos.Y, hip.Y - math.sqrt(minD * minD - flatGap * flatGap)), pos.Z)
			end
			cyc[side] = { pos = pos, yaw = yaw, pitch = pitch, planted = 0, landed = false }
		end
		if m.authored < 0.5 then -- (otherwise the Animator reports the authored feet: observeFoot)
			f.lastPos = Vector3.new(cyc[side].pos.X, 0, cyc[side].pos.Z)
			f.lastYaw = yaw
		end
	end

	-- Standing places, blended with the cycle by how much the body is moving.
	local want = {
		Right = IDLE_RELAXED.right:Lerp(IDLE_COMBAT.right, c),
		Left = IDLE_RELAXED.left:Lerp(IDLE_COMBAT.left, c),
	}
	local wantYaw = {
		Right = lerp(IDLE_RELAXED.rightYaw, IDLE_COMBAT.rightYaw, c),
		Left = lerp(IDLE_RELAXED.leftYaw, IDLE_COMBAT.leftYaw, c),
	}
	m.stepLanded = nil
	local standPos, standYaw, standLift = standing(m, dt, at, facing, want, wantYaw, owned == true)
	local out: { [string]: Foot } = {}
	for side, f in cyc do
		local still = Vector3.new(standPos[side].X, standLift[side], standPos[side].Z)
		out[side] = {
			pos = still:Lerp(f.pos, w),
			yaw = rad(lerp(standYaw[side], f.yaw, w)),
			pitch = f.pitch * w,
			planted = if w > 0.5 then f.planted else (if standLift[side] > 0 then 0 else 1),
			landed = if w > 0.5 then f.landed else m.stepLanded == side,
		}
	end

	-- Hips: low in a fight, a little lower walking guarded; the bob is highest mid-stance walking
	-- (vaulting over a straight-ish leg) and lowest mid-stance running (landing compresses it).
	local idleDrop = lerp(IDLE_RELAXED.drop, IDLE_COMBAT.drop, c)
	local bobScale = lerp(MOVE_RELAXED.bob, MOVE_COMBAT.bob, c)
	local bobAmp = lerp(-0.035, 0.085 * math.min(v / 12, 1), run) * bobScale
	local mid = m.phase - duty / 2 -- the right foot's mid-stance
	local bob = bobAmp * w * math.cos(TAU * 2 * mid)
	local breathWave = math.sin(TAU * 0.3 * m.clock)
	local breath = lerp(BREATH, 0.016, c) * (1 - w) * breathWave
	-- Standing relaxed, the weight rests on one foot, then shifts across to the other.
	local shift = math.clamp(math.sin(math.pi * m.clock / IDLE_SHIFT) * 2.5, -1, 1) * (1 - w) * (1 - c)
	local brake = 0
	if m.brakeT < BRAKE_TIME then
		local u = m.brakeT / BRAKE_TIME
		brake = math.sin(math.pi * math.min(u / 0.3, 1) * 0.5) * (1 - smooth((u - 0.3) / 0.7)) * m.brakeAmt
	end
	local drop = lerp(idleDrop, moveDrop, w) + bob - breath + BRAKE_DROP * brake
	local sway = 0.045 * walk * w * math.cos(TAU * mid) * (1 - 0.6 * c) + IDLE_SWAY * shift

	-- The pelvis turns with the legs (right hip forward with the right foot) and drops on the
	-- swinging side; the chest turns against it; arms swing against the legs.
	local along = math.abs(inHips.Z)
	local swingScale = lerp(MOVE_RELAXED.swing, MOVE_COMBAT.swing, c)
	local legSwing = math.cos(TAU * m.phase)
	local hipOsc = lerp(5, 8, run) * w * along * legSwing * lerp(1, 0.6, c)
	local chestOsc = -lerp(4, 9, run) * w * along * legSwing * swingScale
	local roll = lerp(4, 2.5, run) * w * math.cos(TAU * mid) * (1 - 0.5 * c) - 2 * shift

	-- Leaning: into a run (with the travel's forward share), into speeding up, into a turn.
	local forward = -m.dir.Z
	local leanAlong = if forward >= 0 then forward else -0.3 * forward -- backpedalling still leans in a little
	local runLean = lerp(MOVE_RELAXED.lean, MOVE_COMBAT.lean, c) * run * w * leanAlong
	local accelLean = math.clamp(m.accel * 0.22, -6, 6) * w
	local walkLean = 2 * walk * w
	local lean = -(runLean + accelLean + walkLean)
		- 3 * c * (1 - w)
		+ BREATH_PITCH * (1 - c) * (1 - w) * breathWave
		+ BRAKE_LEAN * brake
	local bankDeg = math.clamp(math.deg(math.atan(v * rad(m.yawRate) / GRAVITY)) * 0.8 * w, -12, 12)

	return {
		drop = drop,
		sway = sway,
		hipYaw = rad(hipYaw + hipOsc),
		hipRoll = rad(roll + bankDeg),
		hipPitch = rad(lean * 0.35),
		lean = rad(lean * 0.65),
		bank = rad(bankDeg),
		chestYaw = rad(chestOsc + m.hipTurn * CHEST_FOLLOW),
		right = out.Right,
		left = out.Left,
		-- A jogger's arm, not a sprinter's: the hand stays at chest height.
		armSwing = rad(lerp(14, 26, run) * w * swingScale) * legSwing,
		armBend = rad(lerp(20, 70, run * w)),
		moveW = w,
		run = run,
		combat = c,
		authored = m.authored,
	}
end

return Gait
