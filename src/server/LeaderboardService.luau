--!strict
-- The lobby's two boards (Total Wins, Ranked Rating) and the titles over players' heads.
--
-- Boards read OrderedDataStores, refreshed every couple of minutes; each player's values
-- are written at most once a minute. Where DataStores are unavailable (an unpublished
-- place) the boards show the players in this server instead, so they never sit blank.
-- Titles ("12 Wins" over the rank name) are BillboardGuis on each player's head.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Palette = require(ReplicatedStorage.Shared.Palette)
local Ranks = require(ReplicatedStorage.Shared.Ranks)
local StatsService = require(script.Parent.StatsService)

local REFRESH_INTERVAL = 120
local WRITE_INTERVAL = 60
local ROWS = 10

local BOARDS = {
	{ title = "TOTAL WINS", store = "LB_Wins_v1", field = "Wins" },
	{ title = "RANKED RATING", store = "LB_Rating_v1", field = "Rating" },
}

local LeaderboardService = {}

local stores: { [string]: OrderedDataStore } = {}
local lastWrite: { [Player]: number } = {}
local names: { [number]: string } = {}

type Row = { name: string, value: number }

local function nameOf(userId: number): string
	local cached = names[userId]
	if cached then
		return cached
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	local result = if ok and name then name else `Player {userId}`
	names[userId] = result
	return result
end

local function localRows(field: string): { Row }
	local rows = {}
	for _, player in Players:GetPlayers() do
		local value = player:GetAttribute(field)
		if typeof(value) == "number" then
			table.insert(rows, { name = player.DisplayName, value = value })
		end
	end
	table.sort(rows, function(a, b)
		return a.value > b.value
	end)
	return rows
end

local function fetch(board): { Row }
	local store = stores[board.store]
	if store then
		local ok, pages = pcall(function()
			return store:GetSortedAsync(false, ROWS)
		end)
		if ok and pages then
			local rows = {}
			for _, entry in pages:GetCurrentPage() do
				local userId = tonumber(string.match(entry.key, "%d+"))
				table.insert(rows, { name = if userId then nameOf(userId) else entry.key, value = entry.value })
			end
			if #rows > 0 then
				return rows
			end
		end
	end
	return localRows(board.field)
end

local function render(part: BasePart, title: string, rows: { Row }, global: boolean)
	local gui = part:FindFirstChild("BoardGui") :: SurfaceGui?
	if not gui then
		local created = Instance.new("SurfaceGui")
		created.Name = "BoardGui"
		created.Face = Enum.NormalId.Front
		created.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		created.PixelsPerStud = 50
		created.LightInfluence = 0 -- readable even when the board is in shadow
		created.Brightness = 1.2
		created.MaxDistance = 120
		created.Parent = part
		gui = created
	end
	local surface = gui :: SurfaceGui
	surface:ClearAllChildren()

	local heading = Instance.new("TextLabel")
	heading.BackgroundTransparency = 1
	heading.Size = UDim2.fromScale(1, 0.13)
	heading.Font = Enum.Font.Garamond
	heading.TextScaled = true
	heading.TextColor3 = Palette.Crimson
	heading.Text = title
	heading.Parent = surface
	local note = heading:Clone()
	note.Position = UDim2.fromScale(0, 0.12)
	note.Size = UDim2.fromScale(1, 0.05)
	note.TextColor3 = Palette.Bronze
	note.Text = if global then "All players" else "This server"
	note.Parent = surface

	for i = 1, ROWS do
		local row = rows[i]
		local y = 0.19 + (i - 1) * 0.079
		local name = Instance.new("TextLabel")
		name.BackgroundTransparency = 1
		name.Position = UDim2.fromScale(0.06, y)
		name.Size = UDim2.fromScale(0.66, 0.065)
		name.Font = Enum.Font.SourceSansSemibold
		name.TextScaled = true
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextColor3 = if i <= 3 then Color3.fromRGB(232, 190, 92) else Palette.Parchment
		name.Text = if row then `{i}.  {row.name}` else `{i}.  —`
		name.Parent = surface
		local value = name:Clone()
		value.Position = UDim2.fromScale(0.7, y)
		value.Size = UDim2.fromScale(0.24, 0.065)
		value.TextXAlignment = Enum.TextXAlignment.Right
		value.Text = if row then tostring(math.floor(row.value)) else ""
		value.Parent = surface
	end
end

local function refreshBoards()
	local lobby = workspace:FindFirstChild("Lobby")
	if not lobby then
		return
	end
	for _, part in lobby:GetChildren() do
		local title = part:IsA("BasePart") and part:GetAttribute("Board")
		for _, board in BOARDS do
			if title == board.title then
				local rows = fetch(board)
				render(part :: BasePart, board.title, rows, stores[board.store] ~= nil)
			end
		end
	end
end

local function write(player: Player)
	local data = StatsService.get(player)
	if not data or next(stores) == nil then
		return
	end
	local now = os.clock()
	if now - (lastWrite[player] or -math.huge) < WRITE_INTERVAL then
		return
	end
	lastWrite[player] = now
	for _, board in BOARDS do
		local store = stores[board.store]
		local value = (data :: any)[board.field]
		if store and typeof(value) == "number" then
			task.spawn(pcall, function()
				store:SetAsync(`player_{player.UserId}`, math.floor(value))
			end)
		end
	end
end

-- "12 Wins" over the rank, on the player's head.
local function title(player: Player)
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	local gui = head:FindFirstChild("Title") :: BillboardGui?
	if not gui then
		local created = Instance.new("BillboardGui")
		created.Name = "Title"
		created.Size = UDim2.fromOffset(160, 44)
		created.StudsOffset = Vector3.new(0, 3.1, 0)
		created.MaxDistance = 70
		created.LightInfluence = 0
		created.ResetOnSpawn = false
		-- Your own title would float in the middle of your own view.
		created.PlayerToHideFrom = player
		local wins = Instance.new("TextLabel")
		wins.Name = "Wins"
		wins.BackgroundTransparency = 1
		wins.Size = UDim2.fromScale(1, 0.55)
		wins.Font = Enum.Font.Garamond
		wins.TextScaled = true
		wins.TextColor3 = Color3.fromRGB(232, 190, 92)
		wins.TextStrokeTransparency = 0.4
		wins.Parent = created
		local rank = wins:Clone()
		rank.Name = "Rank"
		rank.Position = UDim2.fromScale(0, 0.55)
		rank.Size = UDim2.fromScale(1, 0.4)
		rank.Font = Enum.Font.SourceSansSemibold
		rank.Parent = created
		created.Parent = head
		gui = created
	end
	local billboard = gui :: BillboardGui
	local wins = player:GetAttribute("Wins") or 0
	local rank = Ranks.of(player:GetAttribute("Rating") or 0)
	local winsLabel = billboard:FindFirstChild("Wins") :: TextLabel
	local rankLabel = billboard:FindFirstChild("Rank") :: TextLabel
	winsLabel.Text = if wins == 1 then "1 Win" else `{wins} Wins`
	rankLabel.Text = rank.name
	rankLabel.TextColor3 = rank.color
end

function LeaderboardService.start()
	for _, board in BOARDS do
		local ok, store = pcall(function()
			return DataStoreService:GetOrderedDataStore(board.store)
		end)
		if ok and store then
			stores[board.store] = store
		end
	end
	-- An unpublished place hands out stores that fail on use; probe once.
	for name, store in stores do
		local ok = pcall(function()
			store:GetSortedAsync(false, 1)
		end)
		if not ok then
			stores[name] = nil
		end
	end

	StatsService.onChanged(function(player)
		title(player)
		write(player)
	end)
	local function onPlayer(player: Player)
		-- Avatar loading replaces the head, so re-title whenever a new one appears.
		player.CharacterAdded:Connect(function(character)
			character:WaitForChild("Head", 5)
			title(player)
			character.ChildAdded:Connect(function(child)
				if child.Name == "Head" then
					task.defer(title, player)
				end
			end)
		end)
		player.CharacterAppearanceLoaded:Connect(function()
			title(player)
		end)
		local character = player.Character
		if character then
			title(player)
			character.ChildAdded:Connect(function(child)
				if child.Name == "Head" then
					task.defer(title, player)
				end
			end)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		lastWrite[player] = nil
		-- Without global stores the boards show this server; drop the leaver.
		if next(stores) == nil then
			task.defer(refreshBoards)
		end
	end)

	task.spawn(function()
		while true do
			refreshBoards()
			-- Without global stores the boards are cheap and local: keep them lively.
			task.wait(if next(stores) == nil then 15 else REFRESH_INTERVAL)
		end
	end)
end

return LeaderboardService
