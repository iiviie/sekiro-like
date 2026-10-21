--!strict
-- Every item a player can own, in one place: id, category, rarity, price, unlock rule, where
-- it comes from and how it's shown. The server (server/Economy) is the only thing that
-- evaluates rules, prices and ownership; the client reads this table for names, prices and
-- rule texts and the server-published state (attributes) for what the player has.
--
-- Ids are `<prefix>.<Ref>` and are what the save stores (Inventory, Loadout), so never
-- rename or reuse one: a removed id stays in players' inventories, hidden. `ref` is the
-- runtime key the visuals and combat use (a Shared/Weapons id, a Shared/Progression skin id,
-- a Shared/Clothing set name, a finisher / line key for part C).
--
-- Rules (`rule`) are data: { stat, atLeast } (a saved stat such as Level, HumanWins,
-- Deathblows, Perfects, Mikiris, DuelWins), { boss } (cleared that boss once),
-- { stars, count } (cleared `count` different bosses of that star tier), { allBosses }.
-- With a price, the rule gates buying; without one, `auto` items are granted the moment the
-- rule is met (achievements). `status = "soon"` items exist for saves and grants but can't be
-- bought until their visuals ship (Catalog.Ready per category, or per item).
--
-- Robux never buys power: weapons have no product key, ever, and the most prestigious
-- cosmetics (ranked, boss clears, achievements, Mastery evolutions) have no price at all.

export type Category =
	"weapon"
	| "bladeSkin"
	| "bladeLine"
	| "finisher"
	| "outfit"
	| "title"
	| "banner"
	| "nameplate"
	| "bundle"
	| "gemPack"
	| "pass"
export type Slot = "weapon" | "bladeSkin" | "finisher" | "outfit" | "title" | "banner" | "nameplate"
export type Rarity = "common" | "uncommon" | "rare" | "epic" | "legendary"
export type Price = { coins: number?, gems: number?, product: string? }
export type Rule = {
	text: string,
	stat: string?,
	atLeast: number?,
	boss: string?,
	stars: number?,
	count: number?,
	allBosses: boolean?,
}
export type LineLevel = { level: number, whetstones: number, text: string }
export type Contents = { items: { string }?, coins: number?, gems: number?, lineLevel: number? }
export type Item = {
	id: string,
	category: Category,
	ref: string,
	name: string,
	blurb: string?,
	rarity: Rarity,
	price: Price?,
	rule: Rule?,
	auto: boolean?, -- granted once `rule` is met
	default: boolean?, -- everyone owns it from the start
	sources: { string },
	icon: string?, -- an Assets.Icons key
	status: ("live" | "soon")?,
	season: string?,
	levels: { LineLevel }?, -- blade lines: L1 is the purchase, L2-L4 cost Whetstones
	finisher: string?, -- blade lines: the finisher unlocked at L4
	contents: Contents?, -- bundles and gem packs
	once: boolean?, -- bundles: one purchase per account
	order: number,
}
export type Product = { kind: "product" | "gamepass", id: number, robux: number }

local Catalog = {}

Catalog.Prefix = {
	weapon = "weapon",
	bladeSkin = "skin",
	bladeLine = "line",
	finisher = "finisher",
	outfit = "outfit",
	title = "title",
	banner = "banner",
	nameplate = "plate",
	bundle = "bundle",
	gemPack = "gems",
	pass = "pass",
} :: { [Category]: string }

-- Which loadout slot an item of each category goes in (a blade line is a blade skin).
Catalog.SlotOf = {
	weapon = "weapon",
	bladeSkin = "bladeSkin",
	bladeLine = "bladeSkin",
	finisher = "finisher",
	outfit = "outfit",
	title = "title",
	banner = "banner",
	nameplate = "nameplate",
} :: { [Category]: Slot }

Catalog.Slots = { "weapon", "bladeSkin", "finisher", "outfit", "title", "banner", "nameplate" } :: { Slot }

-- What every slot holds on a fresh save ("" = nothing equipped).
Catalog.Defaults = {
	weapon = "weapon.Katana",
	bladeSkin = "skin.Steel",
	finisher = "finisher.Default",
	outfit = "outfit.Avatar",
	title = "",
	banner = "banner.Plain",
	nameplate = "plate.Plain",
} :: { [Slot]: string }

-- Categories whose visuals have shipped, so their priced items can be bought. Parts C and U
-- flip these as they land (or set `status` per item).
Catalog.Ready = {
	weapon = true,
	bladeSkin = true,
	bladeLine = true, -- part C: line looks, L2 smears, L3 deflects, L4 finishers
	finisher = true, -- part C: client/CosmeticFX
	outfit = true, -- part C: server/CosmeticService + Shared/Cosmetics/Wear
	title = true, -- part U: nameplate over the head, duel intro card, Locker
	banner = true, -- part U: duel intro card, Locker (Shared/Flair + part C's FlairArt)
	nameplate = true, -- part U: the nameplate frame over the head
	bundle = true,
	gemPack = true,
	pass = true,
} :: { [Category]: boolean }

Catalog.Rarities = { "common", "uncommon", "rare", "epic", "legendary" } :: { Rarity }

-- Developer products and game passes. Ids are 0 until the place is published and the
-- products are created in the Creator Dashboard; then paste them here (and nothing else).
-- In Studio a 0 id (or the MockPurchases attribute) takes the mock purchase path.
Catalog.Products = {
	["gems.80"] = { kind = "product", id = 0, robux = 79 },
	["gems.210"] = { kind = "product", id = 0, robux = 199 },
	["gems.440"] = { kind = "product", id = 0, robux = 399 },
	["gems.920"] = { kind = "product", id = 0, robux = 799 },
	["gems.1920"] = { kind = "product", id = 0, robux = 1599 },
	["gems.5000"] = { kind = "product", id = 0, robux = 3999 },
	["bundle.Initiate"] = { kind = "product", id = 0, robux = 149 },
	["bundle.LineYozakura"] = { kind = "product", id = 0, robux = 1499 },
	["bundle.LineRaijin"] = { kind = "product", id = 0, robux = 1499 },
	["bundle.LineKarasu"] = { kind = "product", id = 0, robux = 1499 },
	["pass.Premium"] = { kind = "product", id = 0, robux = 449 },
	["pass.TierSkip"] = { kind = "product", id = 0, robux = 49 },
	["pass.Tiers10"] = { kind = "product", id = 0, robux = 399 },
	["pass.VIP"] = { kind = "gamepass", id = 0, robux = 299 },
	["pass.Loadouts"] = { kind = "gamepass", id = 0, robux = 99 },
	["pass.TitleSlot"] = { kind = "gamepass", id = 0, robux = 99 },
	["pass.VictoryCry"] = { kind = "gamepass", id = 0, robux = 149 },
} :: { [string]: Product }

local items: { Item } = {}
local byId: { [string]: Item } = {}

local function add(category: Category, ref: string, item: { [string]: any })
	local entry = item :: any
	entry.id = `{Catalog.Prefix[category]}.{ref}`
	entry.category = category
	entry.ref = ref
	entry.rarity = entry.rarity or "common"
	entry.sources = entry.sources or {}
	entry.order = #items + 1
	assert(not byId[entry.id], `[Catalog] duplicate id {entry.id}`)
	table.insert(items, entry :: Item)
	byId[entry.id] = entry :: Item
end

local function level(n: number): Rule
	return { stat = "Level", atLeast = n, text = `Reach Mastery {n}` }
end

--------------------------------------------------------------------------------------------
-- Weapons: coins plus a Mastery gate, never Robux.
add("weapon", "Katana", { name = "Katana", default = true, sources = { "default" }, icon = "Katana" })
add("weapon", "Odachi", {
	name = "Odachi",
	rarity = "uncommon",
	price = { coins = 1500 },
	rule = level(5),
	sources = { "coins" },
	icon = "Odachi",
})

--------------------------------------------------------------------------------------------
-- Blade skins (visuals: Shared/Progression.Skins by ref). The base six keep their prices.
add("bladeSkin", "Steel", { name = "Tamahagane", default = true, sources = { "default" } })
add("bladeSkin", "Crimson", { name = "Crimson Lacquer", price = { coins = 400 }, sources = { "coins" } })
add("bladeSkin", "Jade", { name = "Jade River", price = { coins = 600 }, rule = level(3), sources = { "coins" } })
add("bladeSkin", "Sakura", {
	name = "Sakura Storm",
	rarity = "uncommon",
	price = { coins = 1200 },
	rule = level(6),
	sources = { "coins" },
})
add("bladeSkin", "Gold", {
	name = "Gold Leaf",
	rarity = "rare",
	price = { coins = 1500 },
	rule = { stat = "Wins", atLeast = 5, text = "Win 5 royales" },
	sources = { "coins" },
})
add("bladeSkin", "Obsidian", {
	name = "Obsidian Oni",
	rarity = "rare",
	price = { coins = 2000 },
	rule = { stat = "Deathblows", atLeast = 25, text = "Land 25 deathblows" },
	sources = { "coins" },
})
add("bladeSkin", "Moon", {
	name = "Moonlit Edge",
	rarity = "epic",
	price = { coins = 2500 },
	rule = { stat = "Perfects", atLeast = 150, text = "150 perfect deflects" },
	sources = { "coins" },
})
-- New coin skins: the long coin sink, gated by Mastery.
add("bladeSkin", "Aizome", {
	name = "Aizome",
	rarity = "uncommon",
	price = { coins = 3500 },
	rule = level(10),
	sources = { "coins" },
})
add("bladeSkin", "Bamboo", {
	name = "Green Bamboo",
	rarity = "uncommon",
	price = { coins = 5000 },
	rule = level(15),
	sources = { "coins" },
})
add("bladeSkin", "Amber", {
	name = "Kohaku Amber",
	rarity = "rare",
	price = { coins = 6500 },
	rule = level(20),
	sources = { "coins" },
})
add("bladeSkin", "Fuji", {
	name = "Fuji Snow",
	rarity = "rare",
	price = { coins = 8000 },
	rule = level(25),
	sources = { "coins" },
})
add("bladeSkin", "Thunderhead", {
	name = "Thunderhead",
	rarity = "epic",
	price = { coins = 10000 },
	rule = level(30),
	sources = { "coins" },
})
add("bladeSkin", "Kintsugi", {
	name = "Kintsugi",
	rarity = "epic",
	price = { coins = 12500 },
	rule = level(40),
	sources = { "coins" },
})
-- Boss-trial skins: earned, never sold. Two per star tier, plus the trainer's.
add("bladeSkin", "Washi", {
	name = "Washi Talisman",
	rule = { boss = "Enemy03", text = "Clear the Shikigami trial" },
	auto = true,
	sources = { "boss" },
})
add("bladeSkin", "Nameless", {
	name = "Nameless Edge",
	rarity = "uncommon",
	rule = { stars = 1, count = 1, text = "Clear a 1-star boss" },
	auto = true,
	sources = { "boss" },
})
add("bladeSkin", "CatClaw", {
	name = "Cat's Claw",
	rarity = "rare",
	rule = { stars = 1, count = 2, text = "Clear both 1-star bosses" },
	auto = true,
	sources = { "boss" },
})
add("bladeSkin", "Mistveil", {
	name = "Mistveil",
	rarity = "rare",
	rule = { stars = 2, count = 1, text = "Clear a 2-star boss" },
	auto = true,
	sources = { "boss" },
})
add("bladeSkin", "DemonHorn", {
	name = "Demon Horn",
	rarity = "epic",
	rule = { stars = 2, count = 2, text = "Clear both 2-star bosses" },
	auto = true,
	sources = { "boss" },
})
add("bladeSkin", "FoxFire", {
	name = "Fox Fire",
	rarity = "epic",
	rule = { stars = 3, count = 1, text = "Clear a 3-star boss" },
	auto = true,
	sources = { "boss" },
})
add("bladeSkin", "Niten", {
	name = "Niten Twin",
	rarity = "legendary",
	rule = { stars = 3, count = 4, text = "Clear all four 3-star bosses" },
	auto = true,
	sources = { "boss" },
})
-- The Initiate's Bundle exclusive.
add("bladeSkin", "Initiate", { name = "Initiate's Vow", rarity = "rare", sources = { "bundle" } })
-- Path of the Blade, season 1 (Shared/Season track): earned on the pass, never sold.
add("bladeSkin", "S1Cedar", { name = "Pilgrim's Cedar", rarity = "uncommon", sources = { "pass" }, season = "S1" })
add("bladeSkin", "S1Vermilion", { name = "Torii Vermilion", rarity = "rare", sources = { "pass" }, season = "S1" })
add("bladeSkin", "S1Hanafubuki", {
	name = "Hanafubuki",
	blurb = "The season's blade: a storm of petals at the summit.",
	rarity = "legendary",
	sources = { "pass" },
	season = "S1",
})

--------------------------------------------------------------------------------------------
-- Premium blade lines: L1 for gems (or the line bundle), L2-L4 with earned Whetstones.
local LINE_LEVELS: { LineLevel } = {
	{ level = 1, whetstones = 0, text = "The blade's look" },
	{ level = 2, whetstones = 20, text = "Its own swing trail" },
	{ level = 3, whetstones = 40, text = "A custom deflect spark and sound" },
	{ level = 4, whetstones = 60, text = "The matching deathblow finisher" },
}
for _, line in
	{
		{ "Yozakura", "Yozakura", "Night cherry: petals that glow in the dark." },
		{ "Raijin", "Raijin", "The thunder god's blade: every cut cracks the air." },
		{ "Karasu", "Karasu", "Crow-black steel that sheds feathers." },
	}
do
	add("bladeLine", line[1], {
		name = line[2],
		blurb = line[3],
		rarity = "legendary",
		price = { gems = 650 },
		sources = { "gems", "robux" },
		levels = LINE_LEVELS,
		finisher = `finisher.{line[1]}`,
	})
end

--------------------------------------------------------------------------------------------
-- Deathblow finishers: same duration and i-frames as the default, only the look differs.
add("finisher", "Default", { name = "Clean Cut", default = true, sources = { "default" } })
add("finisher", "InkBrush", { name = "Ink Brush", rarity = "rare", price = { gems = 400 }, sources = { "gems" } })
add("finisher", "CrowFeathers", {
	name = "Crow Feathers",
	rarity = "epic",
	price = { gems = 650 },
	sources = { "gems" },
})
add("finisher", "LightningSheath", {
	name = "Lightning Sheath",
	rarity = "epic",
	price = { gems = 650 },
	sources = { "gems" },
})
add("finisher", "SakuraScatter", {
	name = "Sakura Scatter",
	rarity = "epic",
	sources = { "pass" },
	season = "S1",
})
add("finisher", "MoonCrescent", {
	name = "Moon Crescent",
	rarity = "legendary",
	rule = { stat = "Deathblows", atLeast = 250, text = "Land 250 deathblows" },
	auto = true,
	sources = { "achievement" },
})
for _, line in { "Yozakura", "Raijin", "Karasu" } do
	add("finisher", line, { name = `{line} Finale`, rarity = "legendary", sources = { "line" } })
end

--------------------------------------------------------------------------------------------
-- Player outfits (Shared/Clothing sets by ref, worn over the avatar; part C dresses them).
add("outfit", "Avatar", { name = "Your avatar", default = true, sources = { "default" } })
add("outfit", "indigo", { name = "Indigo Gi", default = true, sources = { "default" } })
add("outfit", "slate", { name = "Slate Gi", rule = level(2), auto = true, sources = { "achievement" } })
add("outfit", "moss", { name = "Moss Gi", price = { coins = 500 }, sources = { "coins" } })
add("outfit", "ash", { name = "Ash Gi", rarity = "uncommon", price = { coins = 3000 }, sources = { "coins" } })
add("outfit", "oxblood", {
	name = "Oxblood Gi",
	rarity = "uncommon",
	price = { coins = 5000 },
	sources = { "coins" },
})
add("outfit", "dove", { name = "Dove Gi", rarity = "rare", price = { coins = 7500 }, sources = { "coins" } })
-- Three more coin colourways (art/clothing/build.py, part C).
add("outfit", "rust", {
	name = "Rust Gi",
	rarity = "rare",
	price = { coins = 9000 },
	sources = { "coins" },
})
add("outfit", "pine", {
	name = "Pine Gi",
	rarity = "rare",
	price = { coins = 11000 },
	sources = { "coins" },
})
add("outfit", "ink", { name = "Ink Gi", rarity = "epic", price = { coins = 13000 }, sources = { "coins" } })
-- Boss sets: earned by a first clear of that boss.
for _, boss in
	{
		{ "shikigami", "Enemy03", "Shikigami's Paper Robe", "uncommon" },
		{ "nameless", "Enemy01", "Nameless Sashiko", "rare" },
		{ "cat", "Enemy07", "Cat General's Gi", "rare" },
		{ "mist", "Enemy05", "Guard of Mist", "rare" },
		{ "demon", "Enemy04", "Little Demon's Gi", "epic" },
		{ "fox", "Enemy06", "Night Fox", "epic" },
		{ "niten", "Enemy09", "Niten's White", "legendary" },
	}
do
	add("outfit", boss[1], {
		name = boss[3],
		rarity = boss[4],
		rule = { boss = boss[2], text = `Clear the {boss[3]} trial` },
		auto = true,
		sources = { "boss" },
	})
end
-- Premium sets.
add("outfit", "miko", { name = "Shrine Maiden", rarity = "epic", price = { gems = 900 }, sources = { "gems" } })
add("outfit", "shadow", { name = "Crimson Shadow", rarity = "epic", price = { gems = 650 }, sources = { "gems" } })

--------------------------------------------------------------------------------------------
-- Titles: achievements (earn-only), ranked season tiers, the pass, the bundle, a few for coins.
local function achievement(ref: string, name: string, rarity: Rarity, rule: Rule)
	add("title", ref, { name = name, rarity = rarity, rule = rule, auto = true, sources = { "achievement" } })
end
achievement("Novice", "Novice", "common", level(3))
achievement("Adept", "Adept", "uncommon", level(10))
achievement("Veteran", "Veteran", "rare", level(25))
achievement("Sensei", "Sensei", "epic", level(50))
achievement("Duelist", "Duelist", "rare", { stat = "DuelWins", atLeast = 25, text = "Win 25 duels" })
achievement("LastBlade", "The Last Blade", "rare", {
	stat = "HumanWins",
	atLeast = 10,
	text = "Win 10 royales against other players",
})
achievement("Kensei", "Kensei", "legendary", {
	stat = "HumanWins",
	atLeast = 50,
	text = "Win 50 royales against other players",
})
achievement("Executioner", "Executioner", "rare", { stat = "Deathblows", atLeast = 100, text = "Land 100 deathblows" })
achievement("Unbroken", "Unbroken", "epic", { stat = "Perfects", atLeast = 500, text = "500 perfect deflects" })
achievement("Mikiri", "Mikiri Master", "epic", { stat = "Mikiris", atLeast = 25, text = "25 Mikiri Counters" })
achievement("Demonslayer", "Demonslayer", "legendary", { allBosses = true, text = "Clear every boss trial" })
for _, tier in { "Bronze", "Silver", "Gold", "Jade", "Crimson", "Shogun" } do
	add("title", `S1{tier}`, {
		name = `{tier} · Season 1`,
		rarity = if tier == "Shogun" then "legendary" elseif tier == "Crimson" or tier == "Jade" then "epic" else "rare",
		sources = { "ranked" },
		season = "S1",
	})
end
add("title", "S1Pilgrim", { name = "Pilgrim", rarity = "uncommon", sources = { "pass" }, season = "S1" })
add("title", "S1Wayfarer", { name = "Wayfarer", rarity = "epic", sources = { "pass" }, season = "S1" })
add("title", "Initiate", { name = "Initiate", rarity = "rare", sources = { "bundle" } })
add("title", "Wanderer", { name = "Wanderer", price = { coins = 1000 }, sources = { "coins" } })
add("title", "TeaMaster", { name = "Tea Master", rarity = "uncommon", price = { coins = 3000 }, sources = { "coins" } })
add("title", "Poet", { name = "Wandering Poet", rarity = "rare", price = { coins = 6000 }, sources = { "coins" } })

--------------------------------------------------------------------------------------------
-- Banners (the duel intro card's backdrop).
add("banner", "Plain", { name = "Plain Cloth", default = true, sources = { "default" } })
add("banner", "Crane", { name = "Crane", price = { coins = 1500 }, sources = { "coins" } })
add("banner", "Wave", { name = "Great Wave", rarity = "uncommon", price = { coins = 3000 }, sources = { "coins" } })
add("banner", "Mountain", { name = "Mountain", rarity = "uncommon", price = { coins = 5000 }, sources = { "coins" } })
add("banner", "Bamboo", { name = "Bamboo Grove", rarity = "rare", price = { coins = 7500 }, sources = { "coins" } })
add("banner", "Dragon", { name = "Dragon", rarity = "epic", price = { gems = 400 }, sources = { "gems" } })
add("banner", "Tiger", { name = "Tiger", rarity = "epic", price = { gems = 400 }, sources = { "gems" } })
add("banner", "Oni", {
	name = "Oni Mask",
	rarity = "epic",
	rule = { stars = 3, count = 4, text = "Clear all four 3-star bosses" },
	auto = true,
	sources = { "boss" },
})
add("banner", "Thousand", {
	name = "Thousand Deflects",
	rarity = "epic",
	rule = { stat = "Perfects", atLeast = 1000, text = "1,000 perfect deflects" },
	auto = true,
	sources = { "achievement" },
})
for _, tier in { "Gold", "Jade", "Crimson", "Shogun" } do
	add("banner", `S1{tier}`, {
		name = `{tier} Standard · S1`,
		rarity = if tier == "Shogun" then "legendary" else "epic",
		sources = { "ranked" },
		season = "S1",
	})
end
add("banner", "S1Path", { name = "Path of the Blade · S1", rarity = "epic", sources = { "pass" }, season = "S1" })

--------------------------------------------------------------------------------------------
-- Nameplate frames: ranked season rewards and VIP.
add("nameplate", "Plain", { name = "Plain", default = true, sources = { "default" } })
add("nameplate", "Ronin", { name = "Ronin", rarity = "epic", sources = { "vip" } })
for _, tier in { "Gold", "Jade", "Crimson", "Shogun" } do
	add("nameplate", `S1{tier}`, {
		name = `{tier} Frame · S1`,
		rarity = if tier == "Shogun" then "legendary" else "epic",
		sources = { "ranked" },
		season = "S1",
	})
end
add("nameplate", "S1Path", { name = "Path of the Blade · S1", rarity = "epic", sources = { "pass" }, season = "S1" })

--------------------------------------------------------------------------------------------
-- Gem packs (plain bonus curve, 0-25%).
for _, pack in { 80, 210, 440, 920, 1920, 5000 } do
	add("gemPack", tostring(pack), {
		name = `{pack} Gems`,
		price = { product = `gems.{pack}` },
		contents = { gems = pack },
		sources = { "robux" },
		icon = "Gem",
	})
end

--------------------------------------------------------------------------------------------
-- Bundles.
add("bundle", "Initiate", {
	name = "Initiate's Bundle",
	blurb = "An exclusive blade, 300 gems, 1,500 coins and the Initiate title. Once per account, for 72 hours after your first visit.",
	rarity = "rare",
	price = { product = "bundle.Initiate" },
	contents = { items = { "skin.Initiate", "title.Initiate" }, gems = 300, coins = 1500 },
	once = true,
	sources = { "robux" },
})
for _, line in { "Yozakura", "Raijin", "Karasu" } do
	add("bundle", `Line{line}`, {
		name = `{line} line, all levels`,
		rarity = "legendary",
		price = { product = `bundle.Line{line}` },
		contents = { items = { `line.{line}`, `finisher.{line}` }, lineLevel = 4 },
		once = true,
		sources = { "robux" },
	})
end

--------------------------------------------------------------------------------------------
-- Passes: the season pass products and the game passes (cosmetic and convenience only).
add("pass", "Premium", {
	name = "Path of the Blade: Premium",
	rarity = "epic",
	price = { product = "pass.Premium" },
	sources = { "robux" },
	season = "S1",
})
add("pass", "TierSkip", { name = "Tier skip", price = { product = "pass.TierSkip" }, sources = { "robux" } })
add("pass", "Tiers10", { name = "+10 tiers", price = { product = "pass.Tiers10" }, sources = { "robux" } })
add("pass", "VIP", {
	name = "Ronin VIP",
	blurb = "A Ronin nameplate and chat tag, an exclusive sheath. No boosts.",
	rarity = "epic",
	price = { product = "pass.VIP" },
	contents = { items = { "plate.Ronin" } },
	sources = { "robux" },
})
add(
	"pass",
	"Loadouts",
	{ name = "Loadout presets (3 → 6)", price = { product = "pass.Loadouts" }, sources = { "robux" } }
)
add("pass", "TitleSlot", { name = "Second title slot", price = { product = "pass.TitleSlot" }, sources = { "robux" } })
add("pass", "VictoryCry", { name = "Victory cry", price = { product = "pass.VictoryCry" }, sources = { "robux" } })

--------------------------------------------------------------------------------------------

Catalog.Items = items

function Catalog.get(id: string?): Item?
	return if id then byId[id] else nil
end

-- The id of `ref` in `category` (e.g. idOf("bladeSkin", "Crimson") == "skin.Crimson").
function Catalog.idOf(category: Category, ref: string): string
	return `{Catalog.Prefix[category]}.{ref}`
end

function Catalog.slotOf(item: Item): Slot?
	return Catalog.SlotOf[item.category]
end

-- Every item of a category, in catalogue order.
function Catalog.list(category: Category): { Item }
	local out = {}
	for _, item in items do
		if item.category == category then
			table.insert(out, item)
		end
	end
	return out
end

-- Whether a priced item can be bought now (its visuals have shipped).
function Catalog.isReady(item: Item): boolean
	if item.status then
		return item.status == "live"
	end
	return Catalog.Ready[item.category] == true
end

-- The catalogue key of a product id (ProcessReceipt / PromptGamePassPurchaseFinished).
function Catalog.productKey(kind: "product" | "gamepass", id: number): string?
	if id == 0 then
		return nil
	end
	for key, product in Catalog.Products do
		if product.kind == kind and product.id == id then
			return key
		end
	end
	return nil
end

-- Sanity checks at require time: every product key resolves, every product-priced item has
-- a product, and no weapon is ever sold for Robux or gems.
for key in Catalog.Products do
	assert(byId[key], `[Catalog] product {key} has no item`)
end
for _, item in items do
	local price = item.price
	if price and price.product then
		assert(Catalog.Products[price.product], `[Catalog] {item.id}: unknown product {price.product}`)
	end
	if item.category == "weapon" then
		assert(not price or (price.product == nil and price.gems == nil), `[Catalog] {item.id}: weapons are coins only`)
	end
	if item.levels then
		assert(#item.levels == 4, `[Catalog] {item.id}: a blade line has 4 levels`)
	end
end

return Catalog
