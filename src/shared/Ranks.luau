--!strict
-- Ranked tiers from rating: six tiers of three divisions, each division Config.Rating.Division
-- points wide (RIVALS-style ladder). The top of the ladder is open-ended.

local Config = require(script.Parent.Config)

local TIERS = {
	{ name = "Bronze", color = Color3.fromRGB(176, 120, 78) },
	{ name = "Silver", color = Color3.fromRGB(196, 200, 208) },
	{ name = "Gold", color = Color3.fromRGB(232, 190, 92) },
	{ name = "Jade", color = Color3.fromRGB(96, 176, 132) },
	{ name = "Crimson", color = Color3.fromRGB(200, 50, 44) },
	{ name = "Shogun", color = Color3.fromRGB(236, 226, 206) },
}
local DIVISIONS = { "III", "II", "I" }

export type Rank = {
	name: string, -- "Bronze II"
	tier: string,
	color: Color3,
	floor: number, -- rating where this division starts
	ceiling: number, -- rating where the next one starts
}

local Ranks = {}

function Ranks.of(rating: number): Rank
	local width = Config.Rating.Division
	local index = math.clamp(math.floor(math.max(rating, 0) / width), 0, #TIERS * #DIVISIONS - 1)
	local tier = TIERS[index // #DIVISIONS + 1]
	local division = DIVISIONS[index % #DIVISIONS + 1]
	return {
		name = `{tier.name} {division}`,
		tier = tier.name,
		color = tier.color,
		floor = index * width,
		ceiling = (index + 1) * width,
	}
end

return Ranks
