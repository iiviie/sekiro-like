--!strict
-- What the local player's block button has been doing, mirrored from the server's rules,
-- so an incoming swing's outcome can be shown on screen the instant it lands instead of
-- a round trip later. The server still decides; this only drives effects.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

export type Defence = "Perfect" | "Deflect" | "Guard"

local LocalCombat = {
	deflectStamp = -math.huge, -- server-clock time of the last press that armed a deflect
	deflectWindow = Config.Deflect.Window,
	lastPressAt = -math.huge,
	spamStacks = 0,
	blocking = false,
	riposteUntil = -math.huge, -- server-clock time a slash still counts as a Riposte
	lastSlashLanded = false, -- our previous swing hit cleanly, so the string speeds up
	idleSince = 0, -- os.clock() when our character last became free to act
	attackingUntil = 0, -- os.clock() until which our predicted swing slows us (see Movement)
}

function LocalCombat.pressBlock(stamp: number)
	-- Same mashing penalty as the server: each quick re-press shrinks the window.
	local rules = Config.Deflect
	LocalCombat.spamStacks = if stamp - LocalCombat.lastPressAt <= rules.SpamMemory
		then LocalCombat.spamStacks + 1
		else 0
	LocalCombat.lastPressAt = stamp
	LocalCombat.deflectStamp = stamp
	LocalCombat.deflectWindow =
		math.max(rules.MinWindow, rules.Window - LocalCombat.spamStacks * rules.SpamPenaltyPerPress)
	LocalCombat.blocking = true
end

-- A successful deflect clears the mashing penalty and opens the riposte (mirrors the server).
function LocalCombat.deflected()
	LocalCombat.spamStacks = 0
	LocalCombat.riposteUntil = workspace:GetServerTimeNow() + Config.Deflect.RiposteWindow
end

function LocalCombat.releaseBlock()
	LocalCombat.blocking = false
end

-- How a blockable swing landing at `hitAt` would be met, or nil for a clean hit.
function LocalCombat.predictDefence(hitAt: number): Defence?
	local since = hitAt - LocalCombat.deflectStamp
	local window = LocalCombat.deflectWindow
	if since >= -Config.Deflect.LateTolerance and since <= window then
		return if since <= math.min(Config.Deflect.PerfectWindow, window) then "Perfect" else "Deflect"
	end
	return if LocalCombat.blocking then "Guard" else nil
end

return LocalCombat
