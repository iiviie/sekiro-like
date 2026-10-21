--!strict
-- Swordsman stance and footwork for every R15 fighter, procedural: client/Animator turns these
-- targets into joint Transforms with leg IK, under the stance poses and clips.
--
-- Kannagi Usagi's own locomotion doesn't fit (an upright idle with the sword hanging, Paragon
-- jogs with the blade trailing, and the jog folds the R15 block torso into a heap when
-- retargeted), so the stance and cycles are authored here instead:
--   idle   knees bent, feet wide, the right foot forward and the hips turned ~38 degrees off the
--          facing (right hip forward); the stance poses turn the chest back toward the facing
--   moving the feet step along the real ground velocity: a planted foot moves back under the
--          body at exactly the ground speed (phase advances with distance travelled), so feet
--          never slide, whatever the speed. The hips turn toward the direction of travel (up to
--          55 degrees, or away from it when backing off), so lock-on strafes step instead of
--          shuffling sideways at a frantic cadence; the chest keeps facing the target.
-- Distances are for a 1x R15 body (leg 1.8 studs, hip to ankle); the Animator scales them by
-- the actual leg length, so bosses (BodyScale 1.3-1.4) step in proportion.

local Gait = {}

local rad = math.rad
local TAU = 2 * math.pi

-- Where the ankles stand at rest (root space: x right, z back; y = height off the ground), how
-- low the hips sit and how far they turn left of the facing (degrees), and which way each foot
-- points (degrees left of the facing).
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
	drop = 0.6,
	hipYaw = 38,
	right = Vector3.new(0.5, 0, -0.95),
	left = Vector3.new(-0.74, 0, 0.62),
	rightYaw = 6,
	leftYaw = 58,
}
-- Out of a fight: the same stance, standing taller and narrower.
local IDLE_RELAXED: Shape = {
	drop = 0.14,
	hipYaw = 20,
	right = Vector3.new(0.5, 0, -0.32),
	left = Vector3.new(-0.56, 0, 0.26),
	rightYaw = 4,
	leftYaw = 30,
}
-- How the stance carries into a stride (the hips' own turn comes from the travel direction).
local MOVE_COMBAT = { drop = 0.4, runDrop = 0.18, hipYaw = 14, width = 0.5, stagger = 0.16, toeOut = 8 }
local MOVE_RELAXED = { drop = 0.1, runDrop = 0.08, hipYaw = 0, width = 0.44, stagger = 0, toeOut = 4 }

-- The stride by ground speed (1x studs/s). duty = share of the cycle a foot is planted (a
-- run spends more of it in the air); stride = studs travelled per cycle (two steps). Strides are
-- capped by what a bent leg can reach: a planted foot travels duty x stride under the hips.
local SPEEDS = { 0, 4, 9, 16, 26 }
local DUTY = { 0.66, 0.6, 0.45, 0.26, 0.22 }
local STRIDE = { 2.2, 2.7, 4.3, 6.4, 8.6 }
local LIFT = { 0.16, 0.2, 0.28, 0.36, 0.42 }
local BOB = { 0.02, 0.03, 0.05, 0.08, 0.09 }

local TURN_LIMIT = 55 -- degrees the hips turn toward the travel direction
-- Turning on the spot: the planted feet hold their world angle while the body turns over them;
-- past TURN_STEP degrees they step round to it, the furthest foot first, STEP_TIME seconds each.
local TURN_STEP = 20
local STEP_TIME = 0.15
local STEP_LIFT = 0.16
local HIP_TURN_RATE = 7
local MOVE_RATE = 7
local COMBAT_RATE = 4

export type Memory = {
	phase: number, -- 0..1 along the stride cycle; the right foot touches down at 0, the left at 0.5
	speed: number, -- smoothed ground speed (1x studs/s)
	dir: Vector3, -- smoothed travel direction (root space, unit, y = 0)
	moveW: number, -- 0 standing .. 1 moving
	combat: number, -- 0 relaxed .. 1 fight stance
	hipTurn: number, -- smoothed turn toward travel (degrees)
	backing: boolean, -- travelling backward: the hips turn away from the travel direction
	clock: number,
	feet: { [string]: number }?, -- world yaw (degrees) each planted foot stands at
	stepping: string?, -- the foot stepping round to the body's facing ("Right" / "Left")
	stepFrom: number, -- its angle off the body when the step started
	stepT: number, -- 0..1 through the step
	stepsLeft: number,
}

export type Foot = { pos: Vector3, yaw: number, pitch: number, planted: number }

export type Targets = {
	drop: number, -- studs the hips sit below standing (bob included)
	hipYaw: number, -- radians, + = left (right hip forward)
	hipRoll: number, -- radians
	lean: number, -- radians of forward torso pitch on top of the stance
	right: Foot,
	left: Foot,
	armSwing: number, -- radians, + = left arm forward
	moveW: number,
	combat: number,
}

function Gait.new(): Memory
	return {
		phase = 0,
		speed = 0,
		dir = Vector3.new(0, 0, -1),
		moveW = 0,
		combat = 0,
		hipTurn = 0,
		backing = false,
		clock = 0,
		feet = nil,
		stepping = nil,
		stepFrom = 0,
		stepT = 0,
		stepsLeft = 0,
	}
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

-- Rotates a root-space vector `degrees` to the left about the vertical.
local function turn(v: Vector3, degrees: number): Vector3
	local r = rad(degrees)
	local c, s = math.cos(r), math.sin(r)
	return Vector3.new(v.X * c + v.Z * s, v.Y, -v.X * s + v.Z * c)
end

local function smooth(u: number): number
	return u * u * (3 - 2 * u)
end

local function wrap(degrees: number): number
	return (degrees + 180) % 360 - 180
end

-- Turning on the spot: returns each foot's angle off the body (degrees, + = left) and lift.
-- `facing` is the body's world yaw (degrees); feet that are moving follow it at once.
local function turnSteps(m: Memory, dt: number, facing: number): ({ [string]: number }, { [string]: number })
	local feet: { [string]: number } = m.feet or { Right = facing, Left = facing }
	if m.moveW > 0.5 then
		feet = { Right = facing, Left = facing }
		m.stepping = nil
	end
	m.feet = feet
	local lift = { Right = 0, Left = 0 }
	if not m.stepping then
		local right, left = wrap(feet.Right - facing), wrap(feet.Left - facing)
		if math.max(math.abs(right), math.abs(left)) > TURN_STEP then
			m.stepping = if math.abs(right) >= math.abs(left) then "Right" else "Left"
			m.stepFrom = if m.stepping == "Right" then right else left
			m.stepT = 0
			m.stepsLeft = 2
		end
	end
	local side = m.stepping
	if side then
		m.stepT = math.min(m.stepT + dt / STEP_TIME, 1)
		feet[side] = facing + m.stepFrom * (1 - smooth(m.stepT))
		lift[side] = STEP_LIFT * math.sin(math.pi * m.stepT)
		if m.stepT >= 1 then
			m.stepsLeft -= 1
			local other = if side == "Right" then "Left" else "Right"
			local otherLag = wrap(feet[other] - facing)
			if m.stepsLeft > 0 and math.abs(otherLag) > 3 then
				m.stepping = other
				m.stepFrom = otherLag
				m.stepT = 0
			else
				m.stepping = nil
			end
		end
	end
	return { Right = wrap(feet.Right - facing), Left = wrap(feet.Left - facing) }, lift
end

-- One foot along the cycle. `offset` = where the foot stands (root space), `travel` = the stride
-- direction, `reach` = half the planted travel. Planted: moves back under the body at ground
-- speed. Swinging: lifts and carries forward to the next touchdown.
local function foot(
	p: number,
	duty: number,
	offset: Vector3,
	travel: Vector3,
	reach: number,
	lift: number
): (Vector3, number, number)
	if p < duty then
		local u = p / duty
		return offset + travel * (reach * (1 - 2 * u)), 0, 1
	end
	local u = (p - duty) / (1 - duty)
	local along = -1 + 2 * smooth(u)
	local height = lift * math.sin(math.pi * u) ^ 0.8
	-- Toe pushes off as the foot lifts, heel leads it back down.
	local pitch = -rad(22) * math.sin(math.pi * math.min(u * 1.6, 1)) * (1 - u) + rad(12) * math.sin(math.pi * u) * u
	return offset + travel * (reach * along) + Vector3.new(0, height, 0), pitch, 0
end

-- Advances the memory by dt for a body moving at `velocity` (root space, 1x studs/s) and facing
-- `facing` (world yaw, degrees), and returns this frame's targets. `combat` is the stance wanted
-- (1 = fight stance, 0 = relaxed).
function Gait.step(m: Memory, dt: number, velocity: Vector3, combat: number, facing: number): Targets
	m.clock += dt
	local flat = Vector3.new(velocity.X, 0, velocity.Z)
	local speed = flat.Magnitude
	local kMove = 1 - math.exp(-dt * MOVE_RATE)
	m.speed += (speed - m.speed) * kMove
	m.moveW += (math.clamp((speed - 0.6) / 2.4, 0, 1) - m.moveW) * kMove
	m.combat += (combat - m.combat) * (1 - math.exp(-dt * COMBAT_RATE))
	if speed > 0.5 then
		local d = flat.Unit
		-- Turn the smoothed direction toward the new one (a reversal passes through the side).
		local blended = m.dir:Lerp(d, math.min(kMove * 1.5, 1))
		m.dir = if blended.Magnitude > 1e-3 then blended.Unit else d
	end
	local c = m.combat
	local w = m.moveW
	local v = m.speed

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
	local moveHip = math.clamp(m.hipTurn + lerp(MOVE_RELAXED.hipYaw, MOVE_COMBAT.hipYaw, c), -60, 70)
	local hipYaw = lerp(idleHip, moveHip, w)

	-- Stride by speed; a stride that runs across the hips is shortened (legs would cross).
	local duty = bySpeed(DUTY, v)
	local inHips = turn(m.dir, -hipYaw)
	local stride = bySpeed(STRIDE, v) * (1 - 0.3 * math.abs(inHips.X))
	if v > 0.05 then
		m.phase = (m.phase + v * dt / stride) % 1
	end
	local reach = duty * stride / 2
	local lift = bySpeed(LIFT, v)
	local run = math.clamp((v - 6) / 8, 0, 1)

	-- Where the feet stand: idle shape, or under the turned hips while moving.
	local width = lerp(MOVE_RELAXED.width, MOVE_COMBAT.width, c)
	local stagger = lerp(MOVE_RELAXED.stagger, MOVE_COMBAT.stagger, c) * (1 - run)
	local toeOut = lerp(MOVE_RELAXED.toeOut, MOVE_COMBAT.toeOut, c)
	local moveRight = turn(Vector3.new(width, 0, -stagger), hipYaw)
	local moveLeft = turn(Vector3.new(-width, 0, stagger), hipYaw)
	-- Standing feet keep their place in the world while the body turns over them.
	local lag, stepLift = turnSteps(m, dt, facing)
	local still = 1 - w
	local idleRight = turn(IDLE_RELAXED.right:Lerp(IDLE_COMBAT.right, c), lag.Right * still)
	local idleLeft = turn(IDLE_RELAXED.left:Lerp(IDLE_COMBAT.left, c), lag.Left * still)
	local rightAt = idleRight:Lerp(moveRight, w) + Vector3.new(0, stepLift.Right * still, 0)
	local leftAt = idleLeft:Lerp(moveLeft, w) + Vector3.new(0, stepLift.Left * still, 0)

	local rp, rPitch, rPlanted = foot(m.phase, duty, rightAt, m.dir, reach * w, lift * w)
	local lp, lPitch, lPlanted = foot((m.phase + 0.5) % 1, duty, leftAt, m.dir, reach * w, lift * w)

	local rightYaw = lerp(lerp(IDLE_RELAXED.rightYaw, IDLE_COMBAT.rightYaw, c) + lag.Right, hipYaw - toeOut, w)
	local leftYaw = lerp(lerp(IDLE_RELAXED.leftYaw, IDLE_COMBAT.leftYaw, c) + lag.Left, hipYaw + toeOut, w)

	-- Hips: low in a fight, rising with the pace; lowest mid-stance, a slow breath at rest.
	local idleDrop = lerp(IDLE_RELAXED.drop, IDLE_COMBAT.drop, c)
	local moveDrop =
		lerp(lerp(MOVE_RELAXED.drop, MOVE_COMBAT.drop, c), lerp(MOVE_RELAXED.runDrop, MOVE_COMBAT.runDrop, c), run)
	local bob = bySpeed(BOB, v) * w * math.cos(TAU * 2 * (m.phase - duty / 2))
	local breath = 0.018 * (1 - w) * math.sin(TAU * 0.33 * m.clock)
	local drop = lerp(idleDrop, moveDrop, w) + bob + breath

	-- The pelvis swings with the legs (the right hip forward with the right foot), the torso
	-- leans into a run; the stance poses keep the chest on the facing.
	local along = math.abs(turn(m.dir, -hipYaw).Z)
	local swing = math.cos(TAU * m.phase)
	return {
		drop = drop,
		hipYaw = rad(hipYaw + 7 * w * along * swing),
		hipRoll = rad(3 * w * math.sin(TAU * m.phase)),
		lean = rad(-(2 + 10 * run * along) * w - 3 * c * (1 - w)),
		right = { pos = rp, yaw = rad(rightYaw), pitch = rPitch, planted = rPlanted },
		left = { pos = lp, yaw = rad(leftYaw), pitch = lPitch, planted = lPlanted },
		armSwing = rad(lerp(4, 28, run) * w * swing),
		moveW = w,
		combat = c,
	}
end

return Gait
