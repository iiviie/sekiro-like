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
