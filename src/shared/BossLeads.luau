--!strict
-- Impact leads for the baked boss clips (Clips.Clip.impactLead): how much earlier than the server's
-- hit a clip's windup segments must end so its blade first reaches a player standing at contact
-- (tip 2.6+ studs ahead of the boss at body height) 0-15 ms after the hit. Clips missing here
-- already connect within 15 ms with no lead, or early (a thrust held pointing at you, a sweep
-- already circling) and keep 0. Niten's (Boss09) cuts are measured on whichever of his two blades
-- arrives first. Measured in Studio's Edit datamodel with
-- ~/re/kannagi-usagi/scripts/anim/boss_leads.luau (re-run it after re-baking the boss clips and paste
-- its output here). Applied by client/BossVisuals when a boss's clips register.
return {
	Boss01_Attack02 = 0.020,
	Boss01_Attack02G = 0.020,
	Boss01_Attack06 = 0.005,
	Boss01_Attack08 = 0.030,
	Boss01_Attack10 = 0.050,
	Boss02_Attack02 = 0.015,
	Boss02_Attack03 = 0.105,
	Boss02_Attack04 = 0.030,
	Boss02_Attack05 = 0.120,
	Boss02_Attack07 = 0.060,
	Boss02_Attack12 = 0.055,
	Boss02_Attack20 = 0.005,
	Boss03_Attack12 = 0.020,
	Boss04_Attack06 = 0.015,
	Boss05_Attack04 = 0.010,
	Boss06_Attack10 = 0.135,
	Boss06_Attack11G = 0.105,
	Boss07_Attack04 = 0.025,
	Boss07_Attack05 = 0.020,
	Boss07_Attack08 = 0.005,
	Boss08_Attack05 = 0.025,
	Boss08_Attack05B = 0.025,
	Boss08_Attack06 = 0.015,
	Boss08_Attack07 = 0.010,
	Boss08_Attack09C = 0.020,
	Boss09_Attack03 = 0.060,
} :: { [string]: number }
