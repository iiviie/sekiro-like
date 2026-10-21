--!strict
-- Every sound in the game goes through here (research_notes/sound/sound_plan.md).
--
--   * Sound groups: SoundService.Master holds Music, SFX, UI and Ambience. The Settings
--     panel's sliders (player attributes SettingMasterVolume / SettingMusicVolume /
--     SettingSFXVolume / SettingUIVolume, 0..1) scale them; Ambience follows Effects.
--   * Cues by id (DEFS below, the same ids as art/sound/cues.json). A cue plays its generated
--     takes from Shared/AudioIds once art/sound/sound.py has uploaded them, else its library
--     placeholders (Shared/Assets), else its `fallback` cue's, else nothing: generated-only
--     cues are silent until they exist, so new moments can be wired before the audio is made.
--   * Variation: a random take that isn't the last one (round-robin without repeats), with
--     pitch and volume jitter. Combat sounds are 3D from a pool of voices (per-cue voice
--     limits, the oldest is stolen); UI sounds and stingers are 2D.
--   * Music: a state machine (title, lobby, royale, final duel, duel, boss by tier and
--     phase) read from the round phase, character attributes and the Round/Duel/Boss
--     remotes, with crossfades, stingers that hush the bed, ducking under big moments (and
--     while an intro or a shrine reveal is on screen) and a muffle while you spectate.
--   * Footsteps by floor material for every fighter near the camera; `Audio.footstep` lets
--     the walk cycle (Shared/Gait) place them on the real foot plants instead.
--   * World sounds nobody grouped (the lobby's waterfalls, Roblox's character sounds,
--     effects made elsewhere) are put in Ambience (looped) or SFX so the sliders reach them.

local CollectionService = game:GetService("CollectionService")
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Assets = require(ReplicatedStorage.Shared.Assets)
local AudioIds = require(ReplicatedStorage.Shared.AudioIds)
local Bosses = require(ReplicatedStorage.Shared.Bosses)
local LockOn = require(script.Parent.LockOn)
local Round = require(ReplicatedStorage.Shared.Round)
local Types = require(ReplicatedStorage.Shared.Types)
local Weapons = require(ReplicatedStorage.Shared.Weapons)

local player = Players.LocalPlayer

export type GroupName = "Music" | "SFX" | "UI" | "Ambience"
type Layer = { id: string, volume: number, pitch: number, from: number?, to: number? }
type Variation = { Layer }

export type Def = {
	ph: { Variation }?, -- library placeholder takes, until AudioIds has generated ones
	fallback: string?, -- a cue whose takes play (at this cue's levels) while this one has none
	skipIf: string?, -- silent once that cue is generated (a placeholder layer it replaces)
	group: GroupName?, -- SFX by default
	volume: number?,
	pitch: number?,
	jitter: number?, -- ± fraction of pitch per play (SFX 0.06, others 0)
	volJitter: number?, -- ± fraction of volume per play
	near: number?, -- RollOffMinDistance (studs)
	far: number?, -- RollOffMaxDistance
	cooldown: number?, -- seconds between two plays of this cue (0.03)
	voices: number?, -- at most this many of this cue at once (4)
	length: number?, -- cut (0.3 s fade) after this long
	duck: { number }?, -- { music level, seconds } when it plays for you (focus)
	hush: number?, -- stingers: the music bed stays out this long
}

export type PlayOpts = {
	at: (BasePart | Attachment | Vector3)?, -- 3D source; nil plays it 2D
	follow: boolean?, -- parent the sound to `at` (a part) so it travels with it
	volume: number?, -- multiplier
	pitch: number?, -- multiplier
	length: number?,
	focus: boolean?, -- involves the local player: ducks the music if the cue says so
}

local Audio = {}

---------------------------------------------------------------------------------------
-- Cues

local S = Assets.Sounds
local FOOT = "rbxasset://sounds/action_footsteps_plastic.mp3" -- Roblox's own, always there
local SPLASH = "rbxasset://sounds/impact_water.mp3"

local function v(id: string, volume: number?, pitch: number?): Layer
	return { id = id, volume = volume or 1, pitch = pitch or 1 }
end
-- One take of one layer.
local function one(id: string, volume: number?, pitch: number?): { Variation }
	return { { v(id, volume, pitch) } }
end
-- Takes to pick from.
local function pick(...: string): { Variation }
	local list = {}
	for _, id in { ... } do
		table.insert(list, { v(id) })
	end
	return list
end
-- One take of layers played together.
local function stack(...: Layer): { Variation }
	return { { ... } }
end

local DEFS: { [string]: Def } = {
	-- Combat (3D at the fighter). Volumes and pitches are the ones CombatVisuals used.
	SwingLight = { ph = one(S.Swing), volume = 0.55, voices = 6 },
	SwingHeavy = { ph = one(S.HeavySwing), volume = 0.7, voices = 4 },
	SwingOdachiLight = { fallback = "SwingLight", volume = 0.6, pitch = 0.9 },
	SwingOdachiHeavy = { fallback = "SwingHeavy", volume = 0.75, pitch = 0.88 },
	SwingNaginataLight = { fallback = "SwingLight", volume = 0.58, pitch = 0.95 },
	SwingNaginataHeavy = { fallback = "SwingHeavy", volume = 0.72, pitch = 0.92 },
	SwingDual = { fallback = "SwingLight", volume = 0.55, pitch = 1.06 },
	Thrust = { fallback = "SwingHeavy", volume = 0.7 },
	SweepLow = { fallback = "SwingHeavy", volume = 0.7, pitch = 0.92 },
	PerilousWarn = { ph = one(S.PerfectDeflect, 1, 1.7), volume = 0.75, duck = { 0.7, 0.6 } },
	Deflect = { ph = pick(S.Deflect, S.DeflectAlt), volume = 0.85, voices = 6 },
	PerfectDeflect = { ph = one(S.PerfectDeflect, 1, 1.1), volume = 0.9, duck = { 0.8, 0.4 } },
	Guard = { ph = one(S.Guard, 1, 0.85), volume = 0.5, jitter = 0.08 },
	Hit = { ph = pick(S.Hit, S.HitAlt), volume = 0.7, voices = 6 },
	HitHeavy = {
		ph = { { v(S.Hit, 1, 0.86) }, { v(S.HitAlt, 1, 0.86) } },
		fallback = "Hit",
		volume = 0.7,
	},
	PostureBreak = { ph = one(S.PostureBreak), volume = 0.8, duck = { 0.6, 0.8 } },
	Deathblow = {
		ph = stack(v(S.PostureBreak, 1, 0.8), v(S.HitAlt, 1, 0.85)),
		volume = 0.9,
		duck = { 0.35, 1.4 },
	},
	CutDown = { ph = one(S.PostureBreak, 1, 0.6), volume = 0.7 },
	Resurrect = { ph = one(S.PerfectDeflect, 1, 0.55), volume = 0.9, duck = { 0.5, 1.5 } },
	Stomp = { ph = stack(v(S.Guard, 1, 0.75), v(S.PostureBreak, 0.7, 1.3)), volume = 0.85 },
	Mikiri = { ph = stack(v(S.PerfectDeflect, 1, 0.9), v(S.PostureBreak, 0.75, 1.2)), volume = 0.8 },
	Dodge = { ph = one(S.Dodge), volume = 0.45 },
	GourdSip = { volume = 0.6 },
	KillConfirm = { group = "UI", volume = 0.7 },
	VictoryCry = { volume = 1, near = 30, far = 600, duck = { 0.3, 4 } },

	-- Footsteps and landings by floor material (placeholders: Roblox's footstep, pitched).
	FootStone = { ph = one(FOOT), volume = 0.32, near = 6, far = 60, voices = 8, cooldown = 0 },
	FootWood = {
		ph = one(FOOT, 1, 0.85),
		fallback = "FootStone",
		volume = 0.34,
		near = 6,
		far = 60,
		voices = 8,
		cooldown = 0,
	},
	FootGrass = {
		ph = one(FOOT, 1, 1.15),
		fallback = "FootStone",
		volume = 0.22,
		near = 6,
		far = 50,
		voices = 8,
		cooldown = 0,
	},
	FootDirt = {
		ph = one(FOOT, 1, 0.95),
		fallback = "FootStone",
		volume = 0.26,
		near = 6,
		far = 50,
		voices = 8,
		cooldown = 0,
	},
	FootSand = {
		ph = one(FOOT, 1, 1.1),
		fallback = "FootDirt",
		volume = 0.24,
		near = 6,
		far = 50,
		voices = 8,
		cooldown = 0,
	},
	FootGravel = {
		ph = one(FOOT, 1, 1.05),
		fallback = "FootStone",
		volume = 0.3,
		near = 6,
		far = 60,
		voices = 8,
		cooldown = 0,
	},
	FootWater = {
		ph = one(SPLASH, 0.5, 1.4),
		fallback = "FootStone",
		volume = 0.3,
		near = 6,
		far = 60,
		voices = 8,
		cooldown = 0,
	},
	FootSnow = {
		ph = one(FOOT, 1, 1.2),
		fallback = "FootDirt",
		volume = 0.2,
		near = 6,
		far = 50,
		voices = 8,
		cooldown = 0,
	},
	FootMetal = {
		ph = one(FOOT, 1, 0.8),
		fallback = "FootStone",
		volume = 0.3,
		near = 6,
		far = 60,
		voices = 8,
		cooldown = 0,
	},
	Land = { volume = 0.5, near = 8, far = 70 },

	-- Finisher and intro signatures (generated only; client/CosmeticFX, client/IntroFX).
	FinisherInkBrush = { volume = 0.9, near = 14, far = 180 },
	FinisherSakuraScatter = { volume = 0.9, near = 14, far = 180 },
	FinisherCrowFeathers = { volume = 0.9, near = 14, far = 180 },
	FinisherLightningSheath = { volume = 0.9, near = 14, far = 180 },
	FinisherMoonCrescent = { volume = 0.9, near = 14, far = 180 },
	FinisherYozakura = { volume = 0.9, near = 14, far = 180 },
	FinisherRaijin = { volume = 0.9, near = 14, far = 180 },
	FinisherKarasu = { volume = 0.9, near = 14, far = 180 },
	IntroRei = { volume = 0.8, near = 16, far = 200 },
	IntroChiburi = { volume = 0.8, near = 16, far = 200 },
	IntroIai = { volume = 0.8, near = 16, far = 200 },
	IntroKasa = { volume = 0.8, near = 16, far = 200 },
	IntroPlant = { volume = 0.8, near = 16, far = 200 },
	IntroSakura = { volume = 0.8, near = 16, far = 200 },
	IntroTessen = { volume = 0.8, near = 16, far = 200 },
	IntroCrow = { volume = 0.8, near = 16, far = 200 },
	IntroRaiko = { volume = 0.8, near = 16, far = 200 },
	IntroShodo = { volume = 0.8, near = 16, far = 200 },
	IntroTsukimi = { volume = 0.8, near = 16, far = 200 },
	IntroRyu = { volume = 0.8, near = 16, far = 200 },

	-- UI cues that aren't UI.sound names (UI.sound("Press") plays cue "UIPress"; its
	-- placeholders stay in client/UI). Toasts' banners were full volume outside the UI group
	-- (0.6), hence the higher levels.
	UIBanner = { group = "UI", ph = one(S.PerfectDeflect, 1, 1.2), volume = 0.83 },
	UIUnlock = { group = "UI", ph = one(S.PerfectDeflect, 1, 1.1), volume = 0.83 },
	UIPassTier = { group = "UI", ph = one(S.PerfectDeflect, 1, 0.85), volume = 1 },
	UILevelUpRing = { group = "UI", ph = one(S.PerfectDeflect, 1, 1.2), volume = 0.75, skipIf = "UILevelUp" },
	UILevelUp = { group = "UI", duck = { 0.5, 2 } },
	UIHum = { group = "UI", duck = { 0.55, 2.5 } },
	UIRevealLegendary = { group = "UI", duck = { 0.3, 3 } },
	CountTick = { group = "UI", volume = 0.6, cooldown = 0.3 },
	CountGo = { group = "UI", volume = 0.8 },
	LockOn = { group = "UI", volume = 0.4 },

	-- Stingers (2D, Music group): they hush the bed for `hush` seconds.
	StingMatchStart = { group = "Music", volume = 0.8, hush = 3.5 },
	StingFinalDuel = { group = "Music", volume = 0.8, hush = 4 },
	StingVictory = { group = "Music", volume = 0.85, hush = 7 },
	StingDefeat = { group = "Music", volume = 0.8, hush = 6 },
	StingDeath = { group = "Music", volume = 0.75, hush = 3 },
	StingRoundWin = { group = "Music", volume = 0.7, hush = 2.5 },
	StingRoundLoss = { group = "Music", volume = 0.7, hush = 2.5 },
	StingPhase2 = { group = "Music", volume = 0.85, hush = 3.5 },
	StingBossVictory = { group = "Music", fallback = "StingVictory", volume = 0.85, hush = 8 },

	-- Music beds (looped, Music group). MusicRoyale's placeholder is today's match drums.
	MusicTitle = { group = "Music", volume = 0.5 },
	MusicLobby = { group = "Music", volume = 0.4 },
	MusicRoyale = { group = "Music", ph = one(Assets.Ambience.MatchMusic), volume = 0.32 },
	MusicFinalDuel = { group = "Music", fallback = "MusicRoyale", volume = 0.36 },
	MusicDuel = { group = "Music", fallback = "MusicRoyale", volume = 0.34 },
	MusicBossTutorial = { group = "Music", fallback = "MusicDuel", volume = 0.34 },
	MusicBossT1 = { group = "Music", fallback = "MusicRoyale", volume = 0.36 },
	MusicBossT2 = { group = "Music", fallback = "MusicBossT1", volume = 0.36 },
	MusicBossT3 = { group = "Music", fallback = "MusicBossT2", volume = 0.38 },
	MusicBossFinal = { group = "Music", fallback = "MusicBossT3", volume = 0.38 },
	MusicBossFinalP2 = { group = "Music", fallback = "MusicBossFinal", volume = 0.4 },

	-- Ambience beds (looped, Ambience group) and world loops.
	AmbLobby = { group = "Ambience", ph = one(Assets.Ambience.Bed), volume = 0.28 },
	AmbArena = { group = "Ambience", fallback = "AmbLobby", volume = 0.28 },
	AmbBoss = { group = "Ambience", fallback = "AmbLobby", volume = 0.28 },
	AmbWaterfall = { group = "Ambience", volume = 0.25, near = 10, far = 70 },
	-- Placeholder until the generated mist bed: the moon hum pitched down to a low drone, so
	-- stepping outside the ring is heard as well as seen.
	AmbMist = { group = "Ambience", ph = one(Assets.Cosmetics.Sounds.MoonHum, 1, 0.6), volume = 0.18 },
}
Audio.Defs = DEFS

-- Generated takes (Shared/AudioIds) as variations.
local generated: { [string]: { Variation } } = {}
for key, takes in AudioIds do
	local list = {}
	for _, take in takes do
		if typeof(take.id) == "string" and take.id ~= "" then
			table.insert(list, { { id = take.id, volume = 1, pitch = 1, from = take.from, to = take.to } })
		end
	end
	if #list > 0 then
		generated[key] = list
	end
end

-- The takes a cue plays: generated ones anywhere along its fallback chain beat placeholders.
local function takesOf(key: string): ({ Variation }?, boolean)
	local chain = {}
	local k: string? = key
	while k and #chain < 6 do
		table.insert(chain, k)
		local def = DEFS[k]
		k = def and def.fallback
	end
	for _, name in chain do
		if generated[name] then
			return generated[name], true
		end
	end
	for _, name in chain do
		local def = DEFS[name]
		if def and def.ph and #def.ph > 0 then
			return def.ph, false
		end
	end
	return nil, false
end

-- Whether the cue would make a sound now; `generatedOnly` asks for generated takes.
function Audio.has(key: string, generatedOnly: boolean?): boolean
	local takes, isGenerated = takesOf(key)
	return takes ~= nil and (isGenerated or not generatedOnly)
end

local lastPick: { [string]: number } = {}
local function choose(key: string, takes: { Variation }): Variation
	local n = #takes
	if n == 1 then
		return takes[1]
	end
	local i = math.random(1, n - 1)
	local last = lastPick[key]
	if last and i >= last then
		i += 1
	end
	lastPick[key] = i
	return takes[i]
end

---------------------------------------------------------------------------------------
-- Groups and settings

local BASE: { [string]: number } = { Music = 1, SFX = 1, UI = 0.6, Ambience = 1 }
local SETTING: { [string]: string } = {
	Master = "SettingMasterVolume",
	Music = "SettingMusicVolume",
	SFX = "SettingSFXVolume",
	UI = "SettingUIVolume",
}
Audio.Settings = SETTING

local groups: { [string]: SoundGroup } = {}
local duckValue: NumberValue? = nil
local muffle: EqualizerSoundEffect? = nil

local function setting(name: string): number
	local value = player:GetAttribute(SETTING[name])
	return if typeof(value) == "number" then math.clamp(value, 0, 1) else 1
end

local function applyVolumes()
	if not groups.Master then
		return
	end
	local master = setting("Master")
	local duck = if duckValue then duckValue.Value else 1
	groups.Music.Volume = BASE.Music * setting("Music") * master * duck
	groups.SFX.Volume = BASE.SFX * setting("SFX") * master
	groups.UI.Volume = BASE.UI * setting("UI") * master
	groups.Ambience.Volume = BASE.Ambience * setting("SFX") * master * math.sqrt(duck)
end

local function ensureGroups()
	if groups.Master and groups.Master.Parent then
		return
	end
	local function make(name: string, parent: Instance): SoundGroup
		local existing = parent:FindFirstChild(name)
		if existing and existing:IsA("SoundGroup") then
			return existing
		end
		local g = Instance.new("SoundGroup")
		g.Name = name
		g.Parent = parent
		return g
	end
	-- Master stays at 1: each child's volume carries the master slider itself, so it's the
	-- same whether or not the engine multiplies nested groups.
	groups.Master = make("Master", SoundService)
	groups.Master.Volume = 1
	for name in BASE do
		groups[name] = make(name, groups.Master)
	end
	local eq = Instance.new("EqualizerSoundEffect")
	eq.Name = "Muffle"
	eq.LowGain, eq.MidGain, eq.HighGain = 0, 0, 0
	eq.Parent = groups.Music
	muffle = eq
	local value = Instance.new("NumberValue")
	value.Name = "Duck"
	value.Value = 1
	value.Parent = groups.Master
	value.Changed:Connect(applyVolumes)
	duckValue = value
	applyVolumes()
end

function Audio.group(name: string): SoundGroup
	ensureGroups()
	return groups[name] or groups.SFX
end

---------------------------------------------------------------------------------------
-- Ducking and muffle

local ducks: { [any]: number } = {}

local function retarget(time: number)
	ensureGroups()
	local level = 1
	for _, l in ducks do
		level = math.min(level, l)
	end
	TweenService:Create(duckValue :: NumberValue, TweenInfo.new(time, Enum.EasingStyle.Sine), { Value = level }):Play()
end

-- Dips the music to `level` for `seconds` (the deepest duck wins).
function Audio.duck(level: number, seconds: number, attack: number?, release: number?)
	local token = {}
	ducks[token] = level
	retarget(attack or 0.06)
	task.delay(seconds, function()
		ducks[token] = nil
		retarget(release or 0.9)
	end)
end

-- Holds a named duck until `Audio.release(name)` (an intro, a reveal).
function Audio.hold(name: string, level: number?, time: number?)
	ducks[name] = level or 0.4
	retarget(time or 0.4)
end

function Audio.release(name: string, time: number?)
	if ducks[name] then
		ducks[name] = nil
		retarget(time or 0.8)
	end
end

-- Muffles the music (spectating after your last death).
function Audio.muffle(on: boolean)
	ensureGroups()
	TweenService:Create(muffle :: EqualizerSoundEffect, TweenInfo.new(if on then 0.8 else 1.2), {
		HighGain = if on then -22 else 0,
		MidGain = if on then -8 else 0,
	}):Play()
end

---------------------------------------------------------------------------------------
-- Voices

type Voice = { sound: Sound, anchor: Attachment, key: string, busyUntil: number, token: number }
local MAX_VOICES = 40
local voices: { Voice } = {}

local function newVoice(): Voice
	local anchor = Instance.new("Attachment")
	anchor.Name = "AudioVoice"
	anchor.Parent = workspace.Terrain
	local sound = Instance.new("Sound")
	sound.Parent = anchor
	return { sound = sound, anchor = anchor, key = "", busyUntil = 0, token = 0 }
end

local function acquire(key: string, limit: number): Voice
	local t = os.clock()
	local free: Voice? = nil
	local oldest: Voice? = nil
	local oldestOfKey: Voice? = nil
	local count = 0
	for _, voice in voices do
		if voice.busyUntil <= t then
			free = free or voice
		else
			if voice.key == key then
				count += 1
				if not oldestOfKey or voice.busyUntil < oldestOfKey.busyUntil then
					oldestOfKey = voice
				end
			end
			if not oldest or voice.busyUntil < oldest.busyUntil then
				oldest = voice
			end
		end
	end
	if count >= limit and oldestOfKey then
		return oldestOfKey
	end
	if free then
		return free
	end
	if #voices < MAX_VOICES then
		local voice = newVoice()
		table.insert(voices, voice)
		return voice
	end
	return oldest :: Voice
end

local function positionOf(at: BasePart | Attachment | Vector3): Vector3
	if typeof(at) == "Vector3" then
		return at
	elseif at:IsA("Attachment") then
		return at.WorldPosition
	end
	return (at :: BasePart).Position
end

local function setRegion(sound: Sound, layer: Layer)
	if layer.from and layer.to and layer.to > layer.from then
		sound.PlaybackRegionsEnabled = true
		sound.PlaybackRegion = NumberRange.new(layer.from, layer.to)
		sound.TimePosition = layer.from
	else
		sound.PlaybackRegionsEnabled = false
		sound.TimePosition = 0
	end
end

local function lengthOf(sound: Sound, layer: Layer, speed: number): number
	local span = if layer.from and layer.to
		then layer.to - layer.from
		elseif sound.TimeLength > 0 then sound.TimeLength
		else 3
	return span / math.max(speed, 0.05)
end

local function fadeStop(sound: Sound, after: number, check: () -> boolean, destroy: boolean)
	task.delay(after, function()
		if not check() then
			return
		end
		local tween = TweenService:Create(sound, TweenInfo.new(0.3), { Volume = 0 })
		tween.Completed:Once(function()
			if check() then
				sound:Stop()
				if destroy then
					sound:Destroy()
				end
			end
		end)
		tween:Play()
	end)
end

type Resolved = { volume: number, speed: number, group: SoundGroup, near: number, far: number, cut: number? }

local function playLayer(key: string, layer: Layer, r: Resolved, o: PlayOpts): Sound
	local speed = r.speed * layer.pitch
	local volume = r.volume * layer.volume
	local at = o.at
	if at == nil or (o.follow and typeof(at) == "Instance" and at:IsA("BasePart")) then
		-- 2D, or riding on a part: a sound of its own, destroyed when done.
		local sound = Instance.new("Sound")
		sound.SoundId = layer.id
		sound.Volume = volume
		sound.PlaybackSpeed = speed
		sound.SoundGroup = r.group
		sound.RollOffMinDistance = r.near
		sound.RollOffMaxDistance = r.far
		setRegion(sound, layer)
		sound.Parent = if at == nil then r.group else at :: Instance
		sound:Play()
		local life = math.min(lengthOf(sound, layer, speed), r.cut or math.huge)
		if r.cut then
			fadeStop(sound, r.cut, function()
				return sound.Parent ~= nil
			end, true)
		end
		sound.Ended:Once(function()
			sound:Destroy()
		end)
		task.delay(math.max(life, 0) + 8, function()
			if sound.Parent then
				sound:Destroy()
			end
		end)
		return sound
	end
	local def = DEFS[key]
	local voice = acquire(key, (def and def.voices) or 4)
	voice.token += 1
	local token = voice.token
	local sound = voice.sound
	sound:Stop()
	voice.anchor.WorldPosition = positionOf(at :: any)
	voice.key = key
	sound.SoundId = layer.id
	sound.Volume = volume
	sound.PlaybackSpeed = speed
	sound.Looped = false
	sound.SoundGroup = r.group
	sound.RollOffMinDistance = r.near
	sound.RollOffMaxDistance = r.far
	setRegion(sound, layer)
	sound:Play()
	local life = lengthOf(sound, layer, speed)
	if r.cut and r.cut < life then
		life = r.cut + 0.3
		fadeStop(sound, r.cut, function()
			return voice.token == token
		end, false)
	end
	voice.busyUntil = os.clock() + life + 0.05
	return sound
end

local lastPlayed: { [string]: number } = {}

local function resolve(def: Def, o: PlayOpts): Resolved
	local groupName = def.group or "SFX"
	local jitter = def.jitter or (if groupName == "SFX" then 0.06 else 0)
	local volJitter = def.volJitter or 0
	return {
		volume = (def.volume or 0.6) * (o.volume or 1) * (1 + (math.random() * 2 - 1) * volJitter),
		speed = (def.pitch or 1) * (o.pitch or 1) * (1 + (math.random() * 2 - 1) * jitter),
		group = Audio.group(groupName),
		near = def.near or 12,
		far = def.far or 140,
		cut = o.length or def.length,
	}
end

local EMPTY: Def = {}

-- Plays cue `key`. Returns its first sound, or nil when the cue has nothing to play (yet).
function Audio.play(key: string, opts: PlayOpts?): Sound?
	local def = DEFS[key] or EMPTY
	if def.skipIf and generated[def.skipIf] then
		return nil
	end
	local takes = takesOf(key)
	if not takes then
		return nil
	end
	local now = os.clock()
	local last = lastPlayed[key]
	if last and now - last < (def.cooldown or 0.03) then
		return nil
	end
	lastPlayed[key] = now
	local o = opts or {}
	local r = resolve(def, o)
	if r.volume <= 0 or r.group.Volume <= 0 then
		return nil
	end
	local first: Sound? = nil
	for _, layer in choose(key, takes) do
		local sound = playLayer(key, layer, r, o)
		first = first or sound
	end
	if def.duck and (o.focus or o.at == nil) then
		Audio.duck(def.duck[1], def.duck[2])
	end
	return first
end

-- Plays a library id that isn't a cue (the cosmetic effects' sound layers) through a group.
function Audio.playId(
	id: string?,
	opts: PlayOpts & { group: GroupName?, near: number?, far: number?, jitter: number? }
): Sound?
	if not id or id == "" then
		return nil
	end
	local r: Resolved = {
		volume = opts.volume or 0.6,
		speed = (opts.pitch or 1) * (1 + (math.random() * 2 - 1) * (opts.jitter or 0.04)),
		group = Audio.group(opts.group or "SFX"),
		near = opts.near or 12,
		far = opts.far or 140,
		cut = opts.length,
	}
	if r.group.Volume <= 0 then
		return nil
	end
	return playLayer("_" .. id, v(id), r, { at = opts.at, follow = opts.follow })
end

-- UI.sound's path: cue "UI<name>", generated if it exists, else the placeholder UI passes
-- (`id`, `volume`, `basePitch`). `pitch` is the pitch asked for; a generated take plays at
-- pitch / basePitch (its own pitch is right as made).
function Audio.ui(key: string, id: string?, volume: number, pitch: number, basePitch: number): Sound?
	local takes = generated[key]
	local layer: Layer
	local speed = pitch
	if takes then
		layer = choose(key, takes)[1]
		speed = pitch / math.max(basePitch, 0.05)
	elseif id and id ~= "" then
		layer = v(id)
	else
		return nil
	end
	local group = Audio.group("UI")
	if group.Volume <= 0 then
		return nil
	end
	local def = DEFS[key]
	if def and def.duck then
		Audio.duck(def.duck[1], def.duck[2])
	end
	return playLayer(key, layer, {
		volume = volume,
		speed = speed,
		group = group,
		near = 10,
		far = 100,
		cut = nil,
	}, {})
end

-- The swing cue for a fighter's attack: by weapon and weight (bosses by their weapon).
function Audio.swingKey(model: Model, kind: string, heavy: boolean): string
	if kind == "Perilous" then
		return "Thrust"
	elseif kind == "Sweep" then
		return "SweepLow"
	end
	local weapon = Weapons.of(model)
	local bossId = model:GetAttribute("Boss")
	local boss = if typeof(bossId) == "string" then Bosses.Defs[bossId] else nil
	if boss then
		weapon = boss.weapon
	end
	if weapon == "Dual" then
		return "SwingDual"
	end
	local key = `Swing{weapon}{if heavy then "Heavy" else "Light"}`
	if DEFS[key] then
		return key
	end
	return if heavy then "SwingHeavy" else "SwingLight"
end

---------------------------------------------------------------------------------------
-- Music and ambience

type Track = { sig: string, sound: Sound }
local tracks: { [string]: Track? } = {}

local function signature(takes: { Variation }): string
	local ids = {}
	for _, take in takes do
		table.insert(ids, take[1].id)
	end
	return table.concat(ids, "|")
end

-- Crossfades `channel` (a loop slot: "Music", "Ambience", "Mist") to cue `key` (nil fades to
-- silence), played in the cue's group. A cue that resolves to what's already playing (a
-- fallback) keeps playing.
local function switch(channel: string, key: string?, fadeIn: number, fadeOut: number)
	local current = tracks[channel]
	local takes = if key then takesOf(key) else nil
	local sig = if takes then signature(takes) else ""
	if current and current.sig == sig then
		return
	end
	if current then
		local old = current.sound
		local tween = TweenService:Create(old, TweenInfo.new(fadeOut, Enum.EasingStyle.Sine), { Volume = 0 })
		tween.Completed:Once(function()
			old:Destroy()
		end)
		tween:Play()
		tracks[channel] = nil
	end
	if not takes or not key then
		return
	end
	local def = DEFS[key] or EMPTY
	local layer = choose(key, takes)[1]
	local sound = Instance.new("Sound")
	sound.Name = key
	sound.SoundId = layer.id
	sound.Looped = true
	sound.Volume = 0
	sound.PlaybackSpeed = layer.pitch
	sound.SoundGroup = Audio.group(def.group or "Ambience")
	sound.Parent = sound.SoundGroup
	sound:Play()
	TweenService:Create(sound, TweenInfo.new(fadeIn, Enum.EasingStyle.Sine), {
		Volume = (def.volume or 0.4) * layer.volume,
	}):Play()
	tracks[channel] = { sig = sig, sound = sound }
end

local entered = false
local hushUntil = 0
local boss: { key: string, phase: number }? = nil
local refresh: () -> () = function() end

local function character(): Model?
	return player.Character
end

local function attr(name: string): any
	local c = character()
	return c and c:GetAttribute(name)
end

-- The music and ambience the moment calls for.
local function wanted(): (string?, string?)
	if not entered then
		return "MusicTitle", "AmbLobby"
	end
	local music: string?, amb: string? = "MusicLobby", "AmbLobby"
	if attr("InBoss") == true then
		local key = if boss then boss.key else "MusicBossT1"
		music = if boss and boss.phase >= 2 and DEFS[key .. "P2"] then key .. "P2" else key
		amb = "AmbBoss"
	elseif attr("InDuel") == true then
		music, amb = "MusicDuel", "AmbLobby"
	elseif attr("InMatch") == true then
		amb = "AmbArena"
		if Round.phase() == "Match" then
			music = if Round.state():GetAttribute("Alive") == 2 then "MusicFinalDuel" else "MusicRoyale"
		else
			music = nil
		end
	end
	if os.clock() < hushUntil then
		music = nil
	end
	return music, amb
end

refresh = function()
	local music, amb = wanted()
	switch("Music", music, if music == "MusicRoyale" then 2.5 else 2, if music == nil then 1.2 else 2.5)
	switch("Ambience", amb, 3, 3)
end

-- Plays stinger `key` and keeps the bed out for its `hush`.
function Audio.stinger(key: string)
	local def = DEFS[key] or EMPTY
	if not Audio.play(key) then
		return
	end
	if def.hush then
		hushUntil = math.max(hushUntil, os.clock() + def.hush)
		refresh()
		task.delay(def.hush + 0.05, refresh)
	end
end

-- The title card is gone: the lobby's music from here on.
function Audio.setEntered()
	entered = true
	refresh()
end

---------------------------------------------------------------------------------------
-- Footsteps

local FOOT_RANGE = 90
local MATERIAL: { [Enum.Material]: string } = {
	[Enum.Material.Wood] = "FootWood",
	[Enum.Material.WoodPlanks] = "FootWood",
	[Enum.Material.Grass] = "FootGrass",
	[Enum.Material.LeafyGrass] = "FootGrass",
	[Enum.Material.Ground] = "FootDirt",
	[Enum.Material.Mud] = "FootDirt",
	[Enum.Material.Fabric] = "FootDirt",
	[Enum.Material.Sand] = "FootSand",
	[Enum.Material.Salt] = "FootSand",
	[Enum.Material.Pebble] = "FootGravel",
	[Enum.Material.Water] = "FootWater",
	[Enum.Material.Snow] = "FootSnow",
	[Enum.Material.Glacier] = "FootSnow",
	[Enum.Material.Ice] = "FootSnow",
	[Enum.Material.Metal] = "FootMetal",
	[Enum.Material.DiamondPlate] = "FootMetal",
	[Enum.Material.CorrodedMetal] = "FootMetal",
	[Enum.Material.Foil] = "FootMetal",
}
Audio.FootMaterial = MATERIAL

type Walker = { root: BasePart, last: Vector3, dist: number, explicitUntil: number }
local walkers: { [Model]: Walker } = {}
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = false

local function floorUnder(model: Model, from: Vector3, depth: number): RaycastResult?
	rayParams.FilterDescendantsInstances = { model }
	return workspace:Raycast(from, Vector3.new(0, -depth, 0), rayParams)
end

local function scaleOf(model: Model): number
	local ok, s = pcall(function()
		return model:GetScale()
	end)
	return if ok and typeof(s) == "number" then s else 1
end

-- A footstep for `model` at `position` (a planted foot; nil: under its root). Calling this
-- turns the distance-based stepper off for that model for a moment.
function Audio.footstep(model: Model, position: Vector3?, speed: number?)
	local walker = walkers[model]
	if walker then
		walker.explicitUntil = os.clock() + 0.6
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local scale = scaleOf(model)
	local from = (position or root.Position) + Vector3.new(0, 1.5 * scale, 0)
	local hit = floorUnder(model, from, 6 * scale)
	if not hit then
		return
	end
	local key = MATERIAL[hit.Material] or "FootStone"
	local pace = math.clamp((speed or 16) / 16, 0.5, 1.15)
	Audio.play(key, {
		at = hit.Position,
		volume = pace * (if model == character() then 1 else 0.8),
	})
end

local function stepWalkers(dt: number)
	local camera = workspace.CurrentCamera
	local eye = if camera then camera.CFrame.Position else Vector3.zero
	local t = os.clock()
	for model, w in walkers do
		if not model.Parent or not w.root.Parent then
			walkers[model] = nil
			continue
		end
		local pos = w.root.Position
		local delta = pos - w.last
		w.last = pos
		local flat = Vector3.new(delta.X, 0, delta.Z).Magnitude
		if flat > 8 or (pos - eye).Magnitude > FOOT_RANGE or t < w.explicitUntil then
			w.dist = 0
			continue
		end
		local speed = flat / math.max(dt, 1e-3)
		if speed < 2.5 or math.abs(delta.Y) > flat * 1.5 then
			w.dist = math.min(w.dist, 1) -- standing, falling or rising: a fresh stride when it moves
			continue
		end
		local scale = scaleOf(model)
		local stride = math.clamp(speed * 0.36, 2.4, 5.5) * scale
		w.dist += flat
		if w.dist >= stride then
			w.dist = math.min(w.dist - stride, stride * 0.5)
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.FloorMaterial == Enum.Material.Air and model == character() then
				continue
			end
			Audio.footstep(model, nil, speed)
			w.explicitUntil = 0
		end
	end
end

-- Roblox's own looped "Running" sound on player characters gives way to these.
local function muteDefaultRunning(root: Instance)
	local function mute(child: Instance)
		if child:IsA("Sound") and child.Name == "Running" then
			child.Volume = 0
			child:GetPropertyChangedSignal("Volume"):Connect(function()
				if child.Volume ~= 0 then
					child.Volume = 0
				end
			end)
		elseif child:IsA("Sound") and child.Name == "Landing" and Audio.has("Land", true) then
			child.Volume = 0
		end
	end
	for _, child in root:GetChildren() do
		mute(child)
	end
	root.ChildAdded:Connect(mute)
end

local tracking: { [Instance]: boolean } = {}
local function track(model: Instance)
	if not model:IsA("Model") or tracking[model] then
		return
	end
	tracking[model] = true
	model.Destroying:Once(function()
		tracking[model] = nil
	end)
	task.spawn(function()
		local root = model:WaitForChild("HumanoidRootPart", 10)
		if not root or not root:IsA("BasePart") or not model.Parent then
			return
		end
		walkers[model] = { root = root, last = root.Position, dist = 0, explicitUntil = 0 }
		muteDefaultRunning(root)
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			local fellFrom: number? = nil
			humanoid.StateChanged:Connect(function(_, new)
				if new == Enum.HumanoidStateType.Freefall then
					fellFrom = root.Position.Y
				elseif new == Enum.HumanoidStateType.Landed then
					local drop = if fellFrom then fellFrom - root.Position.Y else 0
					fellFrom = nil
					if drop > 3 then
						Audio.play("Land", {
							at = root.Position - Vector3.new(0, 2.5, 0),
							volume = math.clamp(drop / 12, 0.4, 1),
						})
					end
				end
			end)
		end
	end)
end

---------------------------------------------------------------------------------------
-- World sounds made elsewhere

local function adopt(sound: Instance)
	if not sound:IsA("Sound") then
		return
	end
	task.defer(function()
		if sound.SoundGroup ~= nil or not sound.Parent then
			return
		end
		local inCharacter = sound:FindFirstAncestorWhichIsA("Model")
		local onCharacter = inCharacter ~= nil and inCharacter:FindFirstChildOfClass("Humanoid") ~= nil
		if sound.Looped and not onCharacter then
			sound.SoundGroup = Audio.group("Ambience")
			-- The lobby's waterfall loops (server/LobbyBuilder) take the generated rush.
			if sound.Name == "Rush" and generated.AmbWaterfall then
				local layer = generated.AmbWaterfall[1][1]
				sound.SoundId = layer.id
				sound.Volume = DEFS.AmbWaterfall.volume or sound.Volume
			end
		else
			sound.SoundGroup = Audio.group("SFX")
		end
	end)
end

---------------------------------------------------------------------------------------
-- Moments read from the remotes

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

-- The duel and boss countdown ticks, on the server's clock.
local countToken = 0
local function countdown(fightAt: any)
	if typeof(fightAt) ~= "number" then
		return
	end
	countToken += 1
	local token = countToken
	for i = 3, 0, -1 do
		local due = fightAt - i - serverNow()
		if due > 0.05 then
			task.delay(due, function()
				if countToken == token then
					Audio.play(if i == 0 then "CountGo" else "CountTick")
				end
			end)
		end
	end
end

local function bossKey(data: { [string]: any }): string
	local id = data.boss
	local def = if typeof(id) == "string" then Bosses.Defs[id] else nil
	if data.tutorial or (def and def.tutorial) or id == Bosses.Tutorial then
		return "MusicBossTutorial"
	elseif id == Bosses.Order[#Bosses.Order] then
		return "MusicBossFinal"
	end
	local stars = if def then def.stars else data.stars
	stars = if typeof(stars) == "number" then stars else 1
	return if stars >= 3 then "MusicBossT3" elseif stars >= 2 then "MusicBossT2" else "MusicBossT1"
end

local function victoryCry(winner: any)
	if typeof(winner) ~= "Instance" or not winner:IsA("Model") then
		return
	end
	local who = Players:GetPlayerFromCharacter(winner)
	local root = winner:FindFirstChild("HumanoidRootPart")
	if who and who:GetAttribute("VictoryCry") == true and root and root:IsA("BasePart") then
		task.delay(0.6, function()
			Audio.play("VictoryCry", { at = root, follow = true, focus = true })
		end)
	end
end

local fought = false
local finalPlayed = false

local function onRound(kind: string, data: { [string]: any })
	if (kind == "Eliminated" or kind == "CutDown") and data.killer == player.DisplayName then
		Audio.play("KillConfirm")
	end
	if kind == "MatchStart" then
		finalPlayed = false
		fought = attr("InMatch") == true
		if fought then
			Audio.stinger("StingMatchStart")
		end
	elseif kind == "Victory" then
		local mine = data.winner ~= nil and data.winner == character()
		if fought then
			Audio.stinger(if mine then "StingVictory" else "StingDefeat")
		end
		fought = false
		victoryCry(data.winner)
	end
	refresh()
end

local function onDuel(kind: string, data: { [string]: any })
	if kind == "Round" then
		countdown(data.fightAt)
	elseif kind == "Point" then
		if data.reason ~= "Draw" and data.reason ~= "Forfeit" then
			Audio.stinger(if data.you then "StingRoundWin" else "StingRoundLoss")
		end
	elseif kind == "End" then
		Audio.stinger(if data.won then "StingVictory" else "StingDefeat")
		if data.won then
			victoryCry(character())
		end
	end
	refresh()
end

local function onBoss(kind: string, data: { [string]: any })
	if kind == "Start" then
		boss = { key = bossKey(data), phase = 1 }
		countdown(data.fightAt)
	elseif kind == "Phase" then
		if data.phase == 2 and boss then
			boss.phase = 2
			Audio.stinger("StingPhase2")
		end
	elseif kind == "End" then
		if not data.left then
			Audio.stinger(if data.won then "StingBossVictory" else "StingDefeat")
		end
		boss = nil
	end
	refresh()
end

---------------------------------------------------------------------------------------

-- Loads every id the game can play, in the background.
function Audio.preload()
	task.spawn(function()
		local seen: { [string]: boolean } = {}
		local list: { Instance } = {}
		local function add(id: string)
			if not seen[id] then
				seen[id] = true
				local s = Instance.new("Sound")
				s.SoundId = id
				table.insert(list, s)
			end
		end
		for _, takes in generated do
			for _, take in takes do
				add(take[1].id)
			end
		end
		for _, def in DEFS do
			for _, take in def.ph or {} do
				for _, layer in take do
					add(layer.id)
				end
			end
		end
		for _, id in Assets.Cosmetics.Sounds do
			add(id)
		end
		pcall(function()
			ContentProvider:PreloadAsync(list)
		end)
	end)
end

function Audio.start()
	ensureGroups()
	for _, name in SETTING do
		player:GetAttributeChangedSignal(name):Connect(applyVolumes)
	end
	applyVolumes()
	Audio.preload()

	-- Music state.
	local state = Round.state()
	state:GetAttributeChangedSignal("Phase"):Connect(refresh)
	state:GetAttributeChangedSignal("Alive"):Connect(function()
		if
			not finalPlayed
			and Round.phase() == "Match"
			and state:GetAttribute("Alive") == 2
			and attr("InMatch") == true
			and attr("CombatState") ~= "Dead"
		then
			finalPlayed = true
			task.delay(1, function()
				Audio.stinger("StingFinalDuel")
			end)
		end
		refresh()
	end)
	local wasDead = false
	local function watch(c: Model)
		for _, name in { "InMatch", "InDuel", "InBoss" } do
			c:GetAttributeChangedSignal(name):Connect(refresh)
		end
		c:GetAttributeChangedSignal("CombatState"):Connect(function()
			local dead = c:GetAttribute("CombatState") == "Dead"
			if dead ~= wasDead then
				wasDead = dead
				if dead and c:GetAttribute("InMatch") == true then
					Audio.stinger("StingDeath")
				end
				Audio.muffle(dead)
			end
		end)
		if wasDead then
			wasDead = false
			Audio.muffle(false)
		end
		refresh()
	end
	player.CharacterAdded:Connect(watch)
	if player.Character then
		watch(player.Character)
	end
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	task.spawn(function()
		(remotes:WaitForChild("RoundEvent") :: RemoteEvent).OnClientEvent:Connect(onRound)
	end)
	task.spawn(function()
		(remotes:WaitForChild("Duel") :: RemoteEvent).OnClientEvent:Connect(onDuel)
	end)
	task.spawn(function()
		(remotes:WaitForChild("Boss") :: RemoteEvent).OnClientEvent:Connect(onBoss)
	end)

	-- Hold the music down under an intro (client/IntroCinematic) and a shrine reveal
	-- (client/Reveal), read from their ScreenGuis.
	local playerGui = player:WaitForChild("PlayerGui")
	local HOLDS: { [string]: number } = { IntroCinematic = 0.45, Reveal = 0.5 }
	local function guiAdded(gui: Instance)
		local level = HOLDS[gui.Name]
		if level and gui:IsA("ScreenGui") then
			Audio.hold(gui.Name, level)
			gui.Destroying:Once(function()
				Audio.release(gui.Name)
			end)
			gui.AncestryChanged:Connect(function()
				if not gui:IsDescendantOf(playerGui) then
					Audio.release(gui.Name)
				end
			end)
		end
	end
	playerGui.ChildAdded:Connect(guiAdded)
	for _, gui in playerGui:GetChildren() do
		guiAdded(gui)
	end

	-- The red mist's hiss while you stand outside the ring (generated only), and a tick when the
	-- camera locks on.
	task.spawn(function()
		while true do
			local root = character() and (character() :: Model):FindFirstChild("HumanoidRootPart")
			local outside = false
			if root and root:IsA("BasePart") and attr("InMatch") == true and Round.phase() == "Match" then
				local center, radius = Round.zone(serverNow())
				local offset = root.Position - center
				outside = Vector3.new(offset.X, 0, offset.Z).Magnitude > radius
			end
			switch("Mist", if outside then "AmbMist" else nil, 0.6, 1.2)
			task.wait(0.5)
		end
	end)
	LockOn.changed(function(model)
		if model then
			Audio.play("LockOn")
		end
	end)

	-- Footsteps for every fighter (players and bots carry the Combatant tag) and your own body.
	CollectionService:GetInstanceAddedSignal(Types.Tag):Connect(track)
	for _, model in CollectionService:GetTagged(Types.Tag) do
		track(model)
	end
	local function trackPlayer(p: Player)
		p.CharacterAdded:Connect(track)
		if p.Character then
			track(p.Character)
		end
	end
	Players.PlayerAdded:Connect(trackPlayer)
	for _, p in Players:GetPlayers() do
		trackPlayer(p)
	end
	RunService.Heartbeat:Connect(stepWalkers)

	-- Ungrouped sounds in the world.
	workspace.DescendantAdded:Connect(adopt)
	task.spawn(function()
		for _, d in workspace:GetDescendants() do
			if d:IsA("Sound") then
				adopt(d)
			end
		end
	end)

	refresh()
end

return Audio
