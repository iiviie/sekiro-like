--!strict
-- Classic Shirt (gi) and Pants (hakama) templates for the bots and bosses: painted by
-- art/clothing/build.py onto the 585x559 template layout and uploaded as images. Each set
-- also carries its colours so the body and the welded obi match the cloth even while a
-- fresh texture is still streaming in. Never reuse one image as both a Shirt and a Pants:
-- Roblox caches the composited body texture by image id.

export type Set = {
	shirt: string,
	pants: string,
	gi: Color3,
	hakama: Color3,
	obi: Color3,
}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local function set(shirt: number, pants: number, gi: Color3, hakama: Color3, obi: Color3): Set
	return {
		shirt = `rbxassetid://{shirt}`,
		pants = `rbxassetid://{pants}`,
		gi = gi,
		hakama = hakama,
		obi = obi,
	}
end

local Clothing = {}

Clothing.Sets = {
	-- Printed by `art/clothing/build.py --luau` from its colourways and ids.json.
	-- Bots: mid-tone colourways that read in daylight.
	indigo = set(110797153136516, 128739961680161, rgb(62, 76, 128), rgb(80, 86, 108), rgb(168, 44, 44)),
	slate = set(115540805126236, 82735952171343, rgb(92, 112, 138), rgb(92, 98, 112), rgb(150, 52, 46)),
	moss = set(131790916582641, 136171148407637, rgb(96, 112, 74), rgb(104, 96, 82), rgb(176, 128, 58)),
	ash = set(104393994802980, 125217363795838, rgb(132, 112, 92), rgb(106, 100, 96), rgb(64, 84, 104)),
	oxblood = set(111909768698876, 138532302461412, rgb(124, 52, 50), rgb(98, 90, 96), rgb(196, 160, 86)),
	dove = set(70898554975562, 95488731884119, rgb(168, 168, 166), rgb(96, 106, 128), rgb(132, 46, 46)),
	-- Bosses (see Clothing.Boss).
	nameless = set(99881287256629, 78963930919062, rgb(74, 84, 118), rgb(82, 86, 102), rgb(214, 206, 190)),
	miko = set(93103647860858, 112513227039510, rgb(236, 232, 226), rgb(176, 38, 42), rgb(178, 36, 40)),
	shikigami = set(140502247080155, 114179705404786, rgb(238, 234, 224), rgb(206, 196, 178), rgb(190, 44, 40)),
	demon = set(104606660017289, 77431450568040, rgb(132, 64, 46), rgb(190, 150, 70), rgb(74, 62, 60)),
	mist = set(133041291182176, 100666074455458, rgb(156, 168, 178), rgb(92, 102, 118), rgb(226, 230, 236)),
	fox = set(100455017944600, 91434610151187, rgb(96, 72, 118), rgb(84, 70, 104), rgb(210, 160, 70)),
	cat = set(131421260197655, 139787696481277, rgb(164, 98, 52), rgb(100, 74, 56), rgb(214, 170, 60)),
	shadow = set(77349963516879, 131725267293865, rgb(112, 40, 44), rgb(88, 80, 88), rgb(186, 30, 36)),
	niten = set(122328930846464, 80773856376409, rgb(232, 232, 238), rgb(70, 86, 134), rgb(66, 82, 128)),
	-- Player coin colourways (Shared/Catalog outfit.rust / .pine / .ink).
	rust = set(81189668473894, 88746951032146, rgb(150, 78, 44), rgb(72, 68, 66), rgb(222, 200, 150)),
	pine = set(93619876201454, 90712869816918, rgb(46, 82, 64), rgb(84, 90, 96), rgb(204, 164, 82)),
	ink = set(100993721078657, 127191968092355, rgb(34, 34, 42), rgb(44, 44, 52), rgb(150, 34, 46)),
}

-- Bots cycle through these by spawn index.
Clothing.Bots = { "indigo", "slate", "moss", "ash", "oxblood", "dove" }

-- Each boss's set, by Shared/Bosses id; the colours follow its look.
Clothing.Boss = {
	Enemy01 = "nameless", -- Nameless Warrior: worn indigo sashiko, bone obi
	Enemy02 = "miko", -- Puppet Maiden: shrine white over scarlet hakama
	Enemy03 = "shikigami", -- Rabbit Shikigami: paper white, red collar and cords
	Enemy04 = "demon", -- Little Demon: rust gi over mustard hakama
	Enemy05 = "mist", -- Guard of Mist: dove-grey sashiko, slate hakama
	Enemy06 = "fox", -- Night Fox: plum gi, gold obi
	Enemy07 = "cat", -- Cat General: ginger gi, gold obi
	Enemy08 = "shadow", -- Crimson Shadow: oxblood gi, crimson obi
	Enemy09 = "niten", -- Niten Usagi: white gi over indigo hakama
} :: { [string]: string }

function Clothing.get(name: string?): Set?
	return if name then (Clothing.Sets :: any)[name] else nil
end

return Clothing
