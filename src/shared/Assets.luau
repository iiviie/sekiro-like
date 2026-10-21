--!strict
-- Every external asset id in one place. All of these were checked to load in Studio.
--   Katana mesh (all blades, see Shared/Weapons): Creator Store "Katana" (asset 105044896803684).
--   Locomotion: Roblox's own Ninja Animation Package, usable in any experience.
--   Sounds: mostly the ProSoundEffects library Roblox licenses for the Creator Store.

local Assets = {
	-- Straw kasa for the ronin bots: made with Roblox's own mesh generator (free, ours to use).
	Kasa = {
		MeshId = "rbxassetid://109129135721194",
		TextureId = "rbxassetid://123248396899497",
		NativeSize = Vector3.new(2.165, 0.9, 2.157),
	},

	-- Weapon meshes and their sizes live with each weapon in Shared/Weapons.

	-- Roblox Ninja Animation Package.
	-- Roblox's standard R15 animations: an upright, natural walk. (The Ninja pack's low,
	-- hunched stances made every character look like it was crouching.)
	Locomotion = {
		Idle = "rbxassetid://507766388",
		IdleAlt = "rbxassetid://507766666",
		Walk = "rbxassetid://507777826",
		Run = "rbxassetid://507767714",
		Jump = "rbxassetid://507765000",
		Fall = "rbxassetid://507767968",
		Climb = "rbxassetid://507765644",
	},

	Sounds = {
		Swing = "rbxassetid://5789211405", -- fast blade whoosh
		HeavySwing = "rbxassetid://9119691738", -- PSE: airy sharp sword swish
		Deflect = "rbxassetid://5763723309", -- sword parry / clash
		DeflectAlt = "rbxassetid://9113449672", -- PSE: blade hits metal
		PerfectDeflect = "rbxassetid://9125669419", -- PSE: metal hit with ring-off
		Guard = "rbxassetid://9116673944", -- PSE: heavy clunk
		Hit = "rbxassetid://6881026094", -- quick cut
		HitAlt = "rbxassetid://130345020654442", -- sword slash
		PostureBreak = "rbxassetid://9116673678", -- PSE: heavy metal impact
		Dodge = "rbxassetid://9120729005", -- PSE: whoosh
	},

	-- HUD art rendered by art/ui/generate.py and uploaded to Roblox. White or neutral
	-- art is tinted in game with ImageColor3.
	UI = {
		BarFrame = "rbxassetid://102708528564230", -- 256x40, 9-slice, inset 10
		BarFill = "rbxassetid://73139334508183",
		BarGlow = "rbxassetid://129118109109326",
		PostureOrnament = "rbxassetid://139926943451578",
		Glow = "rbxassetid://113667814830714",
		DeathblowDot = "rbxassetid://113601375102346",
		Reticle = "rbxassetid://110858671573862",
		Vignette = "rbxassetid://94405813487817",
		InkBand = "rbxassetid://97700002818560", -- hand-painted sumi-e stroke (art/icons/png/ink_band.png)
		Gourd = "rbxassetid://87760799953372",
		KanjiPeril = "rbxassetid://138132976031959", -- 危
		KanjiDeath = "rbxassetid://85340426609348", -- 死
		KanjiExecution = "rbxassetid://139672111360350", -- 忍殺
		KanjiVictory = "rbxassetid://125311348467034", -- 勝
		KanjiEnd = "rbxassetid://101271872236368", -- 終
		KanjiDuel = "rbxassetid://85475507363200", -- 決闘
		KanjiResurrect = "rbxassetid://114837188146937", -- 回生
		KanjiSlay = "rbxassetid://128301594623178", -- 斬
		KanjiFinal = "rbxassetid://124464095662074", -- 一騎討 (the final duel)
		-- Omens (Config.Omens), keyed by omen id.
		Omens = {
			BloodMoon = "rbxassetid://81380191024597", -- 紅月
			IronWill = "rbxassetid://91335488248400", -- 鉄心
			RushingMist = "rbxassetid://115682411636483", -- 霧
		} :: { [string]: string },
		-- Menu chrome (art/ui/chrome.py, ui_*.png): 9-slice panels and buttons, brush strokes,
		-- seals, rings and reveal pieces. Read by client/UI.luau; slice rects live there.
		Chrome = {
			PanelLacquer = "rbxassetid://94188179801260", -- 256, Rect(40,40,216,216)
			PanelPlain = "rbxassetid://140077456638811", -- 256, Rect(40,40,216,216)
			PanelInset = "rbxassetid://82641051910622", -- 128 neutral, Rect(24,24,104,104), tinted
			PanelWashi = "rbxassetid://99808286014158", -- 256, Rect(36,36,220,220)
			PaperGrain = "rbxassetid://87124825386883", -- 256 tile
			ButtonBase = "rbxassetid://123666478281776", -- 192x64 neutral, Rect(24,20,168,44), tinted
			Pill = "rbxassetid://85636818227882", -- 160x48, Rect(24,0,136,48)
			SelectRing = "rbxassetid://128621202686013",
			TouchRing = "rbxassetid://123309743149310",
			IconClose = "rbxassetid://120715760770615",
			IconPlus = "rbxassetid://109733084810516",
			IconPrev = "rbxassetid://96370280083563",
			IconNext = "rbxassetid://114914842498631",
			BrushUnderline = "rbxassetid://93649272670693", -- white, tinted
			BrushSwipe = "rbxassetid://74568738605356", -- white, tinted
			HankoNew = "rbxassetid://116887751362451", -- 新 seal
			HankoCheck = "rbxassetid://76706490673326", -- jade done seal
			Shine = "rbxassetid://85723955666847",
			LifePip = "rbxassetid://113965690042594",
			Tomoe = "rbxassetid://107707225620615",
			CardBack = "rbxassetid://72641545375118",
			RevealSlip = "rbxassetid://91574914812126", -- 512x160, Rect(48,40,464,120)
			RevealStick = "rbxassetid://122151871803338",
			RevealTip = "rbxassetid://100069941422576", -- white, tinted to the rarity
			RevealBox = "rbxassetid://72246913018679", -- omikuji box (art/icons/png/reveal_box.png)
			KanjiCommon = "rbxassetid://112427498481709", -- 並
			KanjiUncommon = "rbxassetid://133300735315254", -- 良
			KanjiRare = "rbxassetid://86202842054599", -- 稀
			KanjiEpic = "rbxassetid://111497332918162", -- 秀
			KanjiLegendary = "rbxassetid://113748455336743", -- 極
			KanjiTitle = "rbxassetid://84190621069944", -- 最後の刃, vertical
			-- Boss names in brush kanji, keyed by boss id (Shared/Bosses nameJP).
			BossNames = {
				Enemy01 = "rbxassetid://119643877629421",
				Enemy02 = "rbxassetid://105032761070984",
				Enemy03 = "rbxassetid://116211708869516",
				Enemy04 = "rbxassetid://77463795800859",
				Enemy05 = "rbxassetid://126011615174295",
				Enemy06 = "rbxassetid://91645956930538",
				Enemy07 = "rbxassetid://85957877289856",
				Enemy08 = "rbxassetid://90464489169464",
				Enemy09 = "rbxassetid://136882575222477",
			} :: { [string]: string },
		} :: { [string]: any },
	},

	-- Painted icons (art/icons: made with ChatGPT image generation from STYLE.md, cut out
	-- by cutout.py, 512x512 with alpha).
	Icons = {
		Coin = "rbxassetid://138650594432073", -- gold mon coin
		Gem = "rbxassetid://97874635512621", -- jade magatama
		Trophy = "rbxassetid://86591058891267", -- nobori banner and katana
		Guide = "rbxassetid://93601496881335", -- scroll
		Profile = "rbxassetid://119813785708624", -- kabuto
		Trials = "rbxassetid://72264263793459", -- ema plaque with a check
		Rewards = "rbxassetid://124129411305519", -- lacquer chest
		Settings = "rbxassetid://72348939022727", -- tsuba
		Store = "rbxassetid://112971328574864", -- coin pouch
		Weapons = "rbxassetid://85570251895221", -- katana
		Katana = "rbxassetid://85570251895221",
		Odachi = "rbxassetid://135455492450465",
		Kill = "rbxassetid://116673045229952", -- cracked oni mask
		Deathblow = "rbxassetid://73839084534890", -- blade through an enso
		Resurrect = "rbxassetid://90992805174516", -- crimson lotus
		Level = "rbxassetid://122647416701873", -- tomoe medallion
		Lock = "rbxassetid://113696248618534",
		Streak = "rbxassetid://121273399733221", -- three ink slashes
		Skin = "rbxassetid://96083641263939", -- glowing blade

		-- Economy (batch4.txt)
		Whetstone = "rbxassetid://102705465501821", -- earned upgrade currency: toishi on a stand
		Shard = "rbxassetid://74611235619227", -- duplicate currency: spirit-glass shard, jade core
		-- Gem packs, smallest to largest (Config gem pack tiers 1..6).
		GemPacks = {
			"rbxassetid://113268941765880", -- 3 magatama
			"rbxassetid://70434890876514", -- a small heap
			"rbxassetid://74743360936548", -- a spilling silk pouch
			"rbxassetid://124864277479259", -- an overflowing masu box
			"rbxassetid://89295657140604", -- an open crimson lacquer chest
			"rbxassetid://103032909771957", -- a lavish gold-kamon chest with light rays
		} :: { string },
		PassXP = "rbxassetid://100639332554472", -- crimson token, gold rim, up-chevron

		-- Store, draws and pass offers (batch4.txt)
		ShrineDraw = "rbxassetid://111176373963851", -- omamori charm
		ShrineCapsule = "rbxassetid://110576640924485", -- black/crimson lacquer capsule leaking jade light
		InitiateBundle = "rbxassetid://98698102049795", -- katana, jade pile, sealed scroll
		SeasonPass = "rbxassetid://79772936816732", -- Path of the Blade crest, season 1
		TierSkip = "rbxassetid://93630146966677", -- gold double chevron
		VIP = "rbxassetid://97497092234867", -- kasa over crossed katana on a gold hex crest
		LoadoutPresets = "rbxassetid://101099394841263", -- three fuda tags
		VictoryCry = "rbxassetid://123840976974376", -- horagai conch horn

		-- Deathblow finishers, keyed by Catalog finisher ref. The blade-line finales
		-- (Yozakura/Raijin/Karasu) have no icon of their own.
		Finishers = {
			Default = "rbxassetid://102058521467001", -- katana through an enso, crimson splash
			InkBrush = "rbxassetid://140080934861324",
			SakuraScatter = "rbxassetid://115851893873984",
			CrowFeathers = "rbxassetid://111023273299574",
			LightningSheath = "rbxassetid://76791681606281",
			MoonCrescent = "rbxassetid://77980167870750",
		} :: { [string]: string },
		-- Blade lines, keyed by Catalog bladeLine ref (SakuraStorm and Crow are the names
		-- part_A.md planned; kept as aliases).
		BladeLines = {
			Yozakura = "rbxassetid://136777104135857", -- sakura katana
			Raijin = "rbxassetid://122044457022099", -- lightning katana, taiko tsuba
			Karasu = "rbxassetid://112784990323220", -- black blade, crow-wing tsuba
			SakuraStorm = "rbxassetid://136777104135857",
			Crow = "rbxassetid://112784990323220",
		} :: { [string]: string },
		-- Locker / Store tab icons.
		Tabs = {
			Outfits = "rbxassetid://85085136038540", -- folded gi, obi, kasa
			Finishers = "rbxassetid://88625871551799", -- katana through an ink burst
			Titles = "rbxassetid://76225121385769", -- kakejiku scroll
			Banners = "rbxassetid://109430683068315", -- sashimono flag
			Season = "rbxassetid://130273536542140", -- sun/moon medallion
		} :: { [string]: string },

		-- Rarity frames (art/icons/frames.py): 512x512, transparent centre, drawn over an
		-- item card. Ornaments stay in the outer 96 px: SliceCenter Rect(96, 96, 416, 416).
		RarityFrames = {
			Common = "rbxassetid://75591611085355",
			Uncommon = "rbxassetid://99675224762785", -- jade band, bone corner pips
			Rare = "rbxassetid://84041968321288",
			Epic = "rbxassetid://98529384607353",
			Legendary = "rbxassetid://118071288044032",
			Mythic = "rbxassetid://107070208603815",
		} :: { [string]: string },
	},

	-- Painted lobby boards (art/icons/gen_board.sh, boards.txt): 1024x512, no text.
	Boards = {
		Store = "rbxassetid://120289451019186", -- merchant stall, chest of jade gems
		Season = "rbxassetid://110824746436682", -- torii stairway to a peak shrine (Path of the Blade)
	},

	-- Cosmetics (part C): finisher and blade-line particles, beams, brush kanji stamps, banner
	-- patterns and frames. Drawn white by art/cosmetics/generate.py (Pillow) and tinted in game;
	-- ids in art/cosmetics/ids.json.
	Cosmetics = {
		Petal = "rbxassetid://126792036538103", -- sakura petal, tip up
		Feather = "rbxassetid://127904119333708", -- crow flight feather, tip up
		InkSplats = "rbxassetid://133803757591718", -- 2x2 flipbook of ink splats
		Crescent = "rbxassetid://98184169300786", -- crescent moon with a halo
		BoltA = "rbxassetid://73070513529820", -- lightning bolt strip (Beam texture, stretch)
		BoltB = "rbxassetid://98390385631384",
		-- Brush kanji stamps (same brush as Assets.UI.Kanji*).
		Kanji = {
			Ink = "rbxassetid://78100734092328", -- 墨
			Sakura = "rbxassetid://104158533787446", -- 桜
			Crow = "rbxassetid://102567344055605", -- 鴉
			Thunder = "rbxassetid://118190542505386", -- 雷
			Moon = "rbxassetid://128154559283575", -- 月
			Yozakura = "rbxassetid://93304148377219", -- 夜桜
			Raijin = "rbxassetid://123430697483634", -- 雷神
			Karasu = "rbxassetid://84698114541136", -- 烏
			Crane = "rbxassetid://122434294661277", -- 鶴
			Wave = "rbxassetid://84863099216334", -- 波
			Mountain = "rbxassetid://131795628713965", -- 山
			Bamboo = "rbxassetid://112202378064890", -- 竹
			Dragon = "rbxassetid://120164688243644", -- 龍
			Tiger = "rbxassetid://91496308744763", -- 虎
			Oni = "rbxassetid://80486239470079", -- 鬼
			Thousand = "rbxassetid://126129664399872", -- 千
			Gold = "rbxassetid://140544555980028", -- 金
			Jade = "rbxassetid://97610545219778", -- 翠
			Crimson = "rbxassetid://116632938795939", -- 紅
			Shogun = "rbxassetid://110125898057346", -- 将軍
			Path = "rbxassetid://104475987167439", -- 道
			Ronin = "rbxassetid://95630061646070", -- 浪人
		} :: { [string]: string },
		-- Tileable 256px patterns (pat_mountains is 512x256 and best cropped, not tiled).
		Patterns = {
			Seigaiha = "rbxassetid://104983715491832", -- waves
			Asanoha = "rbxassetid://137642212839919", -- hemp leaf
			Kikko = "rbxassetid://80858830277486", -- tortoise shell
			Bamboo = "rbxassetid://75330847723519",
			Mountains = "rbxassetid://80846596960823",
			Uroko = "rbxassetid://90509244904989", -- scales
			Tora = "rbxassetid://130002419549230", -- tiger stripes
			Hishi = "rbxassetid://75146617055120", -- small diamonds
			Cloth = "rbxassetid://123655543305020", -- linen weave
		} :: { [string]: string },
		BannerFrame = "rbxassetid://106730658274164", -- 256x512, 9-slice Rect(48,48,208,464)
		PlatePlain = "rbxassetid://124238483635933", -- 512x128, 9-slice Rect(64,40,448,88)
		PlateOrnate = "rbxassetid://136241008300992",
		Sounds = {
			InkSwish = "rbxassetid://9119690582", -- PSE: dowel swish
			InkSplash = "rbxassetid://9119481909", -- PSE: splash, thunking impact
			Chimes = "rbxassetid://9119447936", -- PSE: bell tree, wind chimes
			LineChime = "rbxassetid://9120752412", -- PSE: wind chimes, ceramic clinks
			Wings = "rbxassetid://9125386815", -- PSE: bursts of wings flapping
			LineWings = "rbxassetid://9125386815",
			Caw = "rbxassetid://5829815715", -- crow caw
			Thunder = "rbxassetid://9126082854", -- PSE: synth thunder crack
			Zap = "rbxassetid://9114277757", -- PSE: electric zaps
			LineZap = "rbxassetid://9114277757",
			TempleBell = "rbxassetid://9125597663", -- PSE: small cast-iron temple bell
			MoonHum = "rbxassetid://9120118396", -- PSE: tonal ring, glowing hum
		} :: { [string]: string },
	},

	-- Touch button glyphs (mobile), keyed by CombatInput action name.
	Touch = {
		Attack = "rbxassetid://124769771778245",
		Block = "rbxassetid://93489767839352",
		Dodge = "rbxassetid://134290110033381",
		Perilous = "rbxassetid://113244735035617",
		Sweep = "rbxassetid://106887890712811",
		Heal = "rbxassetid://86045100554056",
		LockOn = "rbxassetid://122871529142994",
	} :: { [string]: string },

	-- Rank crests, keyed by Ranks tier name.
	RankCrests = {
		Bronze = "rbxassetid://106811706572098",
		Silver = "rbxassetid://127769403872663",
		Gold = "rbxassetid://81433802229148",
		Jade = "rbxassetid://137651697741441",
		Crimson = "rbxassetid://96125857372944",
		Shogun = "rbxassetid://103296295108422",
	} :: { [string]: string },

	Ambience = {
		Bed = "rbxassetid://9112832288", -- PSE: distant mountain birds, heavy air (loop)
		MatchMusic = "rbxassetid://1841476670", -- APM: "Drums of Combat"
	},
}

return Assets
