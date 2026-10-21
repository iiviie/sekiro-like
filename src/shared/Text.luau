--!strict
-- Small helpers for player-facing copy, so counts read right ("1 game", "2 games") instead of
-- hard-coding a plural or stripping an "s". English only for now: if the game is localised,
-- these are the one place plural rules change.
--   Text.plural(1, "game")            -> "game"
--   Text.plural(3, "draw")            -> "draws"
--   Text.plural(2, "Shrine Draw")     -> "Shrine Draws"
--   Text.plural(2, "child", "children")
--   Text.count(1, "reward")           -> "1 reward"
--   Text.count(1500, "coin")          -> "1,500 coins"
--   Text.number(1500)                 -> "1,500"
--   Text.days(56)                     -> "8 weeks" (whole weeks when it divides by 7, else "N days")

local Text = {}

-- The one wording for "the profile didn't load" (StatsService's DataError, the Store, the
-- purchase refusals, the lobby banner), so players see the same sentence everywhere.
Text.ProgressFailed =
	"Your progress couldn't load, so this session won't save and purchases are off. Rejoin to try again."

-- The word for `n` things: `singular` when n is 1, else `pluralForm` or singular + "s".
function Text.plural(n: number, singular: string, pluralForm: string?): string
	if n == 1 then
		return singular
	end
	return pluralForm or `{singular}s`
end

-- A whole number with thousands separators: 1500 -> "1,500".
function Text.number(n: number): string
	local whole = math.floor(math.abs(n) + 0.5)
	local digits = tostring(whole)
	local out = string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")))
	if string.sub(out, 1, 1) == "," then
		out = string.sub(out, 2)
	end
	return if n < 0 then `-{out}` else out
end

-- "{n} {word}" with the right plural: Text.count(1, "game") -> "1 game".
function Text.count(n: number, singular: string, pluralForm: string?): string
	return `{Text.number(n)} {Text.plural(n, singular, pluralForm)}`
end

-- A span of days as players read it: whole weeks when it divides by 7 ("8 weeks"), else days.
function Text.days(days: number): string
	if days >= 14 and days % 7 == 0 then
		return Text.count(days // 7, "week")
	end
	return Text.count(days, "day")
end

return Text
