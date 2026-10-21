--!strict
-- The lobby's two boards (Total Wins, Ranked Rating) and the titles over players' heads.
-- Wins on the board and the title count royales won against other players (HumanWins):
-- a win in a match of bots only doesn't count there (anti-farm).
--
-- Boards read OrderedDataStores, refreshed every couple of minutes; each player's values
-- are written at most once a minute. Where DataStores are unavailable (an unpublished
-- place) the boards show the players in this server instead, so they never sit blank.
-- Nameplates (equipped title, name on the equipped nameplate frame, wins and rank) are
-- BillboardGuis on each player's head.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Catalog = require(ReplicatedStorage.Shared.Catalog)
local Flair = require(ReplicatedStorage.Shared.Flair)
local Palette = require(ReplicatedStorage.Shared.Palette)
local Ranks = require(ReplicatedStorage.Shared.Ranks)
local StatsService = require(script.Parent.StatsService)

local REFRESH_INTERVAL = 120
local WRITE_INTERVAL = 60
local ROWS = 10

local BOARDS = {
	{ title = "TOTAL WINS", store = "LB_HumanWins_v1", field = "HumanWins" },
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

-- The nameplate over the player's head: their equipped title (in its rarity colour) over
-- their name on the equipped nameplate frame, and "12 Wins · Gold II" under it. The
-- default Roblox name is hidden since the plate carries the name.
local function label(name: string, parent: Instance): TextLabel
	local text = Instance.new("TextLabel")
	text.Name = name
	text.BackgroundTransparency = 1
	text.TextScaled = true
	text.TextStrokeTransparency = 0.4
	text.Parent = parent
	return text
end

local function loadoutOf(player: Player): { [string]: string }
	local raw = player:GetAttribute("Loadout")
	if typeof(raw) ~= "string" then
		return {}
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	return if ok and typeof(decoded) == "table" then decoded else {}
end

local function title(player: Player)
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
	local gui = head:FindFirstChild("Title") :: BillboardGui?
	if not gui then
		local created = Instance.new("BillboardGui")
		created.Name = "Title"
		created.Size = UDim2.fromOffset(200, 74)
		created.StudsOffset = Vector3.new(0, 3.4, 0)
		created.MaxDistance = 70
		created.LightInfluence = 0
		created.ResetOnSpawn = false
		-- Your own title would float in the middle of your own view.
		created.PlayerToHideFrom = player
		local heading = label("Heading", created)
		heading.Size = UDim2.fromScale(1, 0.26)
		heading.Font = Enum.Font.Garamond
		local plate = Instance.new("Frame")
		plate.Name = "Plate"
		plate.AnchorPoint = Vector2.new(0.5, 0)
		plate.Position = UDim2.fromScale(0.5, 0.28)
		plate.Size = UDim2.fromScale(0.86, 0.36)
		plate.BorderSizePixel = 0
		plate.BackgroundTransparency = 0.15
		plate.Parent = created
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.3, 0)
		corner.Parent = plate
		local edge = Instance.new("UIStroke")
		edge.Name = "Edge"
		edge.Thickness = 1.5
		edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		edge.Parent = plate
		local name = label("PlayerName", plate)
		name.AnchorPoint = Vector2.new(0.5, 0.5)
		name.Position = UDim2.fromScale(0.5, 0.5)
		name.Size = UDim2.fromScale(0.92, 0.8)
		name.Font = Enum.Font.SourceSansBold
		name.ZIndex = 3 -- over part C's painted frame and watermark
		local wins = label("Wins", created)
		wins.Position = UDim2.fromScale(0, 0.68)
		wins.Size = UDim2.fromScale(1, 0.3)
		wins.Font = Enum.Font.SourceSansSemibold
		created.Parent = head
		gui = created
	end
	local billboard = gui :: BillboardGui
	local wins = player:GetAttribute("HumanWins") or 0
	local rank = Ranks.of(player:GetAttribute("Rating") or 0)
	local loadout = loadoutOf(player)
	local titleItem = Catalog.get(loadout.title)
	local plateLook = Flair.plate(Flair.ref(loadout.nameplate))
	local heading = billboard:FindFirstChild("Heading") :: TextLabel
	local plate = billboard:FindFirstChild("Plate") :: Frame
	local name = plate:FindFirstChild("PlayerName") :: TextLabel
	local edge = plate:FindFirstChild("Edge") :: UIStroke
	local winsLabel = billboard:FindFirstChild("Wins") :: TextLabel
	heading.Visible = titleItem ~= nil
	heading.Text = if titleItem then titleItem.name else ""
	heading.TextColor3 = if titleItem then Flair.Rarity[titleItem.rarity] or Palette.Parchment else Palette.Parchment
	plate.BackgroundColor3 = plateLook.fill
	edge.Color = plateLook.edge
	local plateRef = Flair.ref(loadout.nameplate) or "Plain"
	if billboard:GetAttribute("PlateRef") ~= plateRef then
		billboard:SetAttribute("PlateRef", plateRef)
		edge.Enabled = not Flair.decoratePlate(plate, plateRef) -- part C's painted frame replaces the stroke
	end
	name.Text = player.DisplayName
	name.TextColor3 = plateLook.text
	winsLabel.Text = `{if wins == 1 then "1 Win" else `{wins} Wins`}  ·  {rank.name}`
	winsLabel.TextColor3 = rank.color
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
		player:GetAttributeChangedSignal("Loadout"):Connect(function()
			title(player)
		end)
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
