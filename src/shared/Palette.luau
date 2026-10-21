--!strict
-- The game's colours in one place, shared by the map and the HUD so the world and the
-- UI read as one style: ink, parchment, timber and crimson in the HUD; a calm, bright
-- daylight world (warm stone, fresh grass, lacquered vermilion) where the fighters are
-- the strongest thing on screen.

return {
	-- Core
	Ink = Color3.fromRGB(28, 22, 24),
	Parchment = Color3.fromRGB(232, 222, 200),
	Crimson = Color3.fromRGB(176, 34, 30),
	Bronze = Color3.fromRGB(150, 122, 82),
	Ash = Color3.fromRGB(110, 104, 98),

	-- World materials (tuned for the midday LightingProfile: mid values, low saturation)
	Plaster = Color3.fromRGB(214, 206, 190),
	Timber = Color3.fromRGB(60, 44, 34),
	Stone = Color3.fromRGB(134, 126, 114),
	Roof = Color3.fromRGB(58, 62, 70),
	Vermilion = Color3.fromRGB(162, 52, 38), -- shrine lacquer, a touch orange, not signal red
	Lacquer = Color3.fromRGB(32, 28, 28), -- black lacquer caps and bands
	Deck = Color3.fromRGB(124, 90, 62),
	Earth = Color3.fromRGB(150, 128, 100),
	Flagstone = Color3.fromRGB(156, 146, 128),
	-- A notch darker than before: at midday with bloom the old (164, 148, 120) went near white and
	-- the white slash smears vanished against it.
	Paving = Color3.fromRGB(146, 128, 100), -- fighting floors (terrain sand): quiet, so characters pop
	Sand = Color3.fromRGB(172, 154, 124), -- sand-material parts (pads, the courtyard's duel circle)
	Rock = Color3.fromRGB(140, 128, 98),
	-- Terrain Rock (the island cliffs): near-neutral, since any warm tint turns the 2022 Rock
	-- texture's lichen speckle lilac under midday light.
	Cliff = Color3.fromRGB(122, 119, 110),
	LanternStone = Color3.fromRGB(184, 170, 146),
	Grass = Color3.fromRGB(104, 136, 70),
	Moss = Color3.fromRGB(92, 120, 60),
	Straw = Color3.fromRGB(196, 174, 124), -- shimenawa rope
	Ember = Color3.fromRGB(255, 150, 70),
}
