--!strict
-- Pre-fight intros (登場): the short showpiece each fighter plays before round 1 of a duel and at the
-- start of a boss trial. One per fighter, chosen in the Locker (Catalog category "intro", slot
-- "intro"); bosses have their own. Pure presentation: the server only freezes and protects both
-- fighters for the intro's length and says when it starts and ends; the clips (Shared/BakedIntros,
-- authored in art/intros/intros.blend), the camera, the cards and the effects are client-side
-- (client/IntroCinematic).
--
-- Every intro is the same length on screen whatever it shows, so no intro is "faster" than
-- another, and an intro never changes combat timing: the round countdown starts after it.

export type Intro = {
	ref: string, -- Catalog ref (id "intro.<ref>") and the clip "Intro_<ref>"
	name: string,
	blurb: string,
	kanji: string, -- an Assets.Cosmetics.Kanji key (or "Slay" for Assets.UI.KanjiSlay)
	accent: Color3, -- card edge, icon tint, effect colour
	climax: number, -- clip seconds of the big beat (the camera leans in)
	flourish: { number }, -- { from, to } clip seconds: the royale's one-second flourish
}

export type BossIntro = {
	clip: string, -- which intro clip the boss plays
	accent: Color3,
	line: string, -- the boss's line on its card
}

local Intros = {}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- Catalogue order. Names and themes; prices and sources live in Shared/Catalog.
Intros.List = {
	{
		ref = "Rei",
		name = "Kneeling Bow",
		blurb = "Kneel, bow to your opponent, rise into the guard.",
		kanji = "Path",
		accent = rgb(226, 214, 190),
		climax = 1.12,
		flourish = { 1.0, 2.02 }, -- the bow and the rise (the rise alone barely shows in a crowd)
	},
	{
		ref = "Chiburi",
		name = "Chiburi",
		blurb = "Flick the blade clean; it slides home with a click.",
		kanji = "Wave",
		accent = rgb(150, 196, 220),
		climax = 0.6,
		flourish = { 0.3, 1.0 },
	},
	{
		ref = "Iai",
		name = "Iai Draw",
		blurb = "A long, still crouch over the sheathed blade, then the draw in one flash.",
		kanji = "Slay",
		accent = rgb(236, 240, 255),
		climax = 0.8,
		flourish = { 0.72, 1.5 },
	},
	{
		ref = "Kasa",
		name = "Wanderer's Kasa",
		blurb = "Head bowed under a straw hat; tip it up, flick it away.",
		kanji = "Ronin",
		accent = rgb(214, 178, 112),
		climax = 0.98,
		flourish = { 1.2, 1.96 },
	},
	{
		ref = "Plant",
		name = "Planted Blade",
		blurb = "Drive the blade into the ground and stare over the pommel.",
		kanji = "Mountain",
		accent = rgb(176, 168, 150),
		climax = 0.68,
		flourish = { 0.4, 1.1 },
	},
	{
		ref = "Sakura",
		name = "Sakura Gust",
		blurb = "One wide sweep that throws a gust of petals, then a salute.",
		kanji = "Sakura",
		accent = rgb(255, 178, 206),
		climax = 0.6,
		flourish = { 0.4, 1.1 },
	},
	{
		ref = "Tessen",
		name = "War Fan",
		blurb = "A general's iron fan snaps open, veils the face, snaps shut.",
		kanji = "Shogun",
		accent = rgb(222, 72, 64),
		climax = 0.6,
		flourish = { 1.45, 2.0 },
	},
	{
		ref = "Crow",
		name = "Crow's Perch",
		blurb = "A crow lands on your outstretched arm, then takes wing.",
		kanji = "Crow",
		accent = rgb(150, 120, 196),
		climax = 0.86,
		flourish = { 1.32, 2.0 },
	},
	{
		ref = "Raiko",
		name = "Lightning Call",
		blurb = "Raise the blade to the sky and call the lightning down onto it.",
		kanji = "Thunder",
		accent = rgb(196, 176, 255),
		climax = 0.7,
		flourish = { 0.34, 1.12 },
	},
	{
		ref = "Shodo",
		name = "Ink Stroke",
		blurb = "The tip writes one brush stroke in the air, and it stays.",
		kanji = "Ink",
		accent = rgb(176, 170, 190), -- a pale ink wash: dark ink vanished on the dark cards (the effects use real ink)
		climax = 1.12,
		flourish = { 0.36, 1.12 },
	},
	{
		ref = "Tsukimi",
		name = "Moon Gaze",
		blurb = "The blade on your shoulder, eyes on the moon, then on your foe.",
		kanji = "Moon",
		accent = rgb(190, 214, 255),
		climax = 1.02,
		flourish = { 1.3, 2.0 },
	},
	{
		ref = "Ryu",
		name = "Dragon Coil",
		blurb = "The blade wheels overhead, faster and faster, and slams into a low stance.",
		kanji = "Dragon",
		accent = rgb(255, 196, 92),
		climax = 1.12,
		flourish = { 0.3, 1.2 },
	},
} :: { Intro }

local byRef: { [string]: Intro } = {}
for _, intro in Intros.List do
	byRef[intro.ref] = intro
end

Intros.Default = "Rei"

function Intros.get(ref: string?): Intro?
	return if ref then byRef[ref] else nil
end

-- What everyone plays when nothing (or something unknown) is equipped.
function Intros.resolve(ref: string?): Intro
	return byRef[ref or ""] or byRef[Intros.Default]
end

-- Each boss has its own, themed: the clip, the effects' colour and a line on its card.
Intros.Bosses = {
	Enemy01 = { clip = "Plant", accent = rgb(196, 186, 160), line = "Another name to carve in the stone." },
	Enemy02 = { clip = "Sakura", accent = rgb(255, 160, 196), line = "The strings pull. I follow." },
	Enemy03 = { clip = "Rei", accent = rgb(236, 232, 220), line = "Bow. Then begin the lesson." },
	Enemy04 = { clip = "Ryu", accent = rgb(255, 150, 70), line = "Little? Come closer and say it." },
	Enemy05 = { clip = "Kasa", accent = rgb(170, 200, 210), line = "None pass the mist." },
	Enemy06 = { clip = "Tsukimi", accent = rgb(150, 210, 255), line = "The moon is mine tonight." },
	Enemy07 = { clip = "Tessen", accent = rgb(240, 196, 90), line = "Ranks! ...Fine. I'll do it myself." },
	Enemy08 = { clip = "Iai", accent = rgb(200, 60, 72), line = "You won't see the second cut." },
	Enemy09 = { clip = "Raiko", accent = rgb(210, 190, 255), line = "Two blades. One heaven." },
} :: { [string]: BossIntro }

-- Bots pick from these (seeded by their name, so a bot keeps its intro).
Intros.BotPool = { "Rei", "Chiburi", "Kasa", "Plant", "Sakura", "Iai", "Tessen" }

function Intros.forBot(name: string): string
	local h = 0
	for i = 1, #name do
		h = (h * 31 + string.byte(name, i)) % 1000003
	end
	return Intros.BotPool[h % #Intros.BotPool + 1]
end

-- Timing (seconds). Full: fighter 1's shot, fighter 2's shot, then the VS beat. Short (the same
-- two fighters met in the last RepeatWindow seconds): both at once in one wide shot. The server
-- waits Lead + the mode's length, then starts the usual round countdown.
Intros.Timing = {
	Lead = 0.25, -- sent this far ahead so both clients start together
	Shot = 2.0, -- each fighter's shot in the full intro
	ClipLead = 0.1, -- a fighter's clip starts this far before their shot
	VS = 0.7,
	Full = 4.7, -- 2 shots + VS
	Short = 2.5,
	RepeatWindow = 20 * 60,
	Royale = 1.0, -- the royale flourish: no freeze, no camera, just the clip's best second
}

return Intros
