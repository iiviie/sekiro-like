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
		InkBand = "rbxassetid://85181838043049",
		Gourd = "rbxassetid://87760799953372",
		KanjiPeril = "rbxassetid://138132976031959", -- 危
		KanjiDeath = "rbxassetid://85340426609348", -- 死
		KanjiExecution = "rbxassetid://139672111360350", -- 忍殺
		KanjiVictory = "rbxassetid://125311348467034", -- 勝
		KanjiEnd = "rbxassetid://101271872236368", -- 終
		KanjiDuel = "rbxassetid://85475507363200", -- 決闘
	},

	Ambience = {
		Bed = "rbxassetid://9112832288", -- PSE: distant mountain birds, heavy air (loop)
		MatchMusic = "rbxassetid://1841476670", -- APM: "Drums of Combat"
	},
}

return Assets
