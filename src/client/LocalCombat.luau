--!strict
-- What the local player's block button has been doing, mirrored from the server's rules,
-- so an incoming swing's outcome can be shown on screen the instant it lands instead of
-- a round trip later. The server still decides; this only drives effects.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

export type Defence = "Perfect" | "Deflect" | "Guard"

local LocalCombat = {
	deflectStamp = -math.huge, -- server-clock time of the last press that armed a deflect
	lastPressAt = -math.huge,
	blocking = false,
}

function LocalCombat.pressBlock(stamp: number)
	-- Same spam lockout as the server: mashing doesn't re-arm the deflect.
	if stamp - LocalCombat.lastPressAt >= Config.Deflect.SpamLockout then
		LocalCombat.deflectStamp = stamp
	end
	LocalCombat.lastPressAt = stamp
	LocalCombat.blocking = true
end

function LocalCombat.releaseBlock()
	LocalCombat.blocking = false
end

-- How a blockable swing landing at `hitAt` would be met, or nil for a clean hit.
function LocalCombat.predictDefence(hitAt: number): Defence?
	local since = hitAt - LocalCombat.deflectStamp
	if since >= -Config.Deflect.LateTolerance then
		if since <= Config.Deflect.PerfectWindow then
			return "Perfect"
		elseif since <= Config.Deflect.Window then
			return "Deflect"
		end
	end
	return if LocalCombat.blocking then "Guard" else nil
end

return LocalCombat
