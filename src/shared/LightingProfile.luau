--!strict
-- The game's daylight: a bright, soft early afternoon so faces and clothes read at duel
-- range, with only the far mountains fading into a pale haze. The server applies it at
-- startup over the golden-hour look in default.project.json, reusing the Lighting
-- children by name. Moment grades (deathblow, mist, Blood Moon) are ColorCorrectionEffects
-- under the camera, so they stack on top of this and nothing here touches them.
--
-- Lighting.Technology and LightingStyle can't be set from a script (they need RobloxScript /
-- plugin capability), so the place keeps them: default.project.json sets LightingStyle
-- Realistic with PrioritizeLightingQuality, the Future-class path.

local Lighting = game:GetService("Lighting")

local LightingProfile = {}

LightingProfile.Lighting = {
	ClockTime = 14.2,
	GeographicLatitude = 28,
	-- A moderate sun and a bright, neutral-warm sky fill: faces turned away from the sun still
	-- read, and the sun side of a straw hat doesn't blow out.
	Brightness = 2.4,
	ExposureCompensation = 0.05,
	Ambient = Color3.fromRGB(140, 134, 128),
	OutdoorAmbient = Color3.fromRGB(184, 178, 170),
	ColorShift_Top = Color3.fromRGB(255, 248, 236),
	ColorShift_Bottom = Color3.fromRGB(0, 0, 0),
	EnvironmentDiffuseScale = 1,
	EnvironmentSpecularScale = 0.3,
	GlobalShadows = true,
	ShadowSoftness = 0.6,
}

-- Light, far haze: clear at duel range, the mountains and the horizon go soft and pale.
LightingProfile.Atmosphere = {
	Density = 0.26,
	Offset = 0.25,
	Color = Color3.fromRGB(220, 228, 238),
	Decay = Color3.fromRGB(200, 196, 188), -- neutral warm: a lilac decay cast lavender on grass sides and cliffs
	Glare = 0.1,
	Haze = 0.6,
}

-- Roblox's built-in daytime skybox (shipped with the client, so it always loads) in place
-- of the project's sunset sky, whose low orange clouds fought a midday sun.
local SKY_FACES =
	{ SkyboxBk = "bk", SkyboxDn = "dn", SkyboxFt = "ft", SkyboxLf = "lf", SkyboxRt = "rt", SkyboxUp = "up" }
LightingProfile.Sky = {
	CelestialBodiesShown = true,
	SunAngularSize = 14,
	StarCount = 0,
} :: { [string]: any }
for property, face in SKY_FACES do
	LightingProfile.Sky[property] = `rbxasset://textures/sky/sky512_{face}.tex`
end

LightingProfile.Grade = {
	Brightness = 0.02,
	Contrast = 0.02,
	Saturation = 0.06,
	TintColor = Color3.fromRGB(255, 252, 247),
}

LightingProfile.Bloom = {
	Intensity = 0.25,
	Size = 24,
	Threshold = 2.6,
}

LightingProfile.SunRays = {
	Intensity = 0.04,
	Spread = 0.55,
}

local function child(className: string, name: string): Instance
	local found = Lighting:FindFirstChild(name)
	if found and found.ClassName == className then
		return found
	end
	local made = Instance.new(className)
	made.Name = name
	made.Parent = Lighting
	return made
end

local function assign(target: Instance, values: { [string]: any })
	for key, value in values do
		(target :: any)[key] = value
	end
end

function LightingProfile.apply()
	assign(Lighting, LightingProfile.Lighting)
	assign(child("Atmosphere", "Atmosphere"), LightingProfile.Atmosphere)
	assign(child("Sky", "Sky"), LightingProfile.Sky)
	assign(child("ColorCorrectionEffect", "Grade"), LightingProfile.Grade)
	assign(child("BloomEffect", "Bloom"), LightingProfile.Bloom)
	assign(child("SunRaysEffect", "SunRays"), LightingProfile.SunRays)
end

return LightingProfile
