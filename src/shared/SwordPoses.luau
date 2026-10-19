--!strict
-- Weld.C0 offsets (relative to the RightHand) for the greybox sword.
-- The blade runs along the grip's +Y axis, so each pose just aims that axis.
-- These stand in for real animations until the combat loop is proven fun.

local rad = math.rad
local grip = CFrame.new(0, -0.15, 0)

local SwordPoses = {
	Rest = grip * CFrame.Angles(rad(-107), 0, 0), -- forward and down
	Guard = grip * CFrame.Angles(0, 0, rad(80)), -- across the body
	Windup = grip * CFrame.Angles(rad(25), 0, 0), -- raised up and back
	Strike = grip * CFrame.Angles(rad(-140), 0, 0),
	ThrustWindup = CFrame.new(0, -0.15, 0.8) * CFrame.Angles(rad(-90), 0, 0), -- pulled back, aimed forward
	Thrust = CFrame.new(0, -0.15, -1.4) * CFrame.Angles(rad(-90), 0, 0),
	Broken = grip * CFrame.Angles(rad(-175), 0, 0), -- hanging limp
}

return SwordPoses
