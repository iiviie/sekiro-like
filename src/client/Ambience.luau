--!strict
-- Background sound: a quiet bed of distant birds and air at all times, and taiko
-- drums that swell in when a match starts and fade when it ends. Reacts to the round
-- phase attribute; nothing polls.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Assets = require(ReplicatedStorage.Shared.Assets)
local Round = require(ReplicatedStorage.Shared.Round)

local BED_VOLUME = 0.28
local MUSIC_VOLUME = 0.32

local Ambience = {}

local function loop(id: string): Sound
	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.Looped = true
	sound.Volume = 0
	sound.Parent = SoundService
	return sound
end

local function fade(sound: Sound, volume: number, time: number)
	if volume > 0 and not sound.IsPlaying then
		sound:Play()
	end
	local tween = TweenService:Create(sound, TweenInfo.new(time), { Volume = volume })
	tween.Completed:Once(function()
		if volume == 0 and sound.Volume == 0 then
			sound:Stop()
		end
	end)
	tween:Play()
end

function Ambience.start()
	local bed = loop(Assets.Ambience.Bed)
	local music = loop(Assets.Ambience.MatchMusic)
	fade(bed, BED_VOLUME, 3)

	local state = Round.state()
	local function onPhase()
		if Round.phase() == "Match" then
			music.TimePosition = 0
			fade(music, MUSIC_VOLUME, 2.5)
		else
			fade(music, 0, 3)
		end
	end
	state:GetAttributeChangedSignal("Phase"):Connect(onPhase)
	onPhase()
end

return Ambience
