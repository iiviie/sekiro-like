--!strict
-- The loading gate behind the title card: waits until the server has finished building the
-- world (ReplicatedStorage "WorldReady", set by server/init after MapBuilder, LobbyBuilder
-- and every service have started), until this client has received it (the lobby's parts and
-- the terrain under its key points), then preloads the textures and meshes the player sees
-- first: the lobby and castle props, the lobby boards, the menu chrome and icons.
--
-- WorldGate.run(onProgress) reports progress 0..1 with a short status line and returns once
-- it's done, or after the timeout (a slow asset never keeps a player out of the game).

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Assets = require(ReplicatedStorage.Shared.Assets)

local WorldGate = {}

local WORLD_TIMEOUT = 25 -- seconds to wait for the world before giving up on it
local PRELOAD_TIMEOUT = 15 -- seconds for the preload once the world is there
local WORLD_SHARE = 0.45 -- share of the progress bar for the world arriving

local function addId(list: { string }, seen: { [string]: boolean }, id: any)
	if typeof(id) == "string" and string.find(id, "^rbxasset") and not seen[id] then
		seen[id] = true
		table.insert(list, id)
	end
end

-- What under `root` needs loading: image ids go in `list` (PreloadAsync takes a bare id as an
-- image), and one instance per distinct mesh in `instances` (a mesh has to be preloaded through
-- its instance, which also brings its texture; so do SurfaceAppearances, whose maps scripts
-- can't read).
local function collect(root: Instance, list: { string }, seen: { [string]: boolean }, instances: { Instance })
	for _, d in root:GetDescendants() do
		if d:IsA("MeshPart") or d:IsA("SpecialMesh") then
			local mesh = (d :: any).MeshId
			if typeof(mesh) == "string" and mesh ~= "" and not seen[mesh] then
				seen[mesh] = true
				table.insert(instances, d)
			end
		elseif d:IsA("Decal") then -- and Texture
			addId(list, seen, d.Texture)
		elseif d:IsA("SurfaceAppearance") then
			table.insert(instances, d)
		elseif d:IsA("ImageLabel") or d:IsA("ImageButton") then
			addId(list, seen, d.Image)
		end
	end
end

local function collectTable(t: any, list: { string }, seen: { [string]: boolean })
	for _, v in t do
		if typeof(v) == "table" then
			collectTable(v, list, seen)
		else
			addId(list, seen, v)
		end
	end
end

-- True once the terrain under each of the lobby's key points has arrived.
local function terrainHere(lobby: Instance): boolean
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	for _, key in { "SpawnPoint", "QueuePad", "TrainerHome" } do
		local at = lobby:GetAttribute(key)
		if typeof(at) == "Vector3" then
			if not workspace:Raycast(at + Vector3.new(0, 8, 0), Vector3.new(0, -24, 0), params) then
				return false
			end
		end
	end
	return true
end

-- Yields until the world is built here (or the timeout); returns whether it is.
local function waitForWorld(onProgress: (number, string) -> ()): boolean
	local started = os.clock()
	while os.clock() - started < WORLD_TIMEOUT do
		local lobby = workspace:FindFirstChild("Lobby")
		-- Studio aid: workspace attribute SlowWorldGate = seconds holds the gate shut that long,
		-- to see the loading state on a fast machine.
		local hold = if RunService:IsStudio() then workspace:GetAttribute("SlowWorldGate") else nil
		local held = typeof(hold) == "number" and os.clock() - started < hold
		if ReplicatedStorage:GetAttribute("WorldReady") == true and lobby and not held then
			local expected = ReplicatedStorage:GetAttribute("WorldParts")
			local have = #lobby:GetDescendants()
			-- A little slack: the lobby changes after the count (bots come and go).
			local arrived = typeof(expected) ~= "number" or have >= expected * 0.95
			if arrived and terrainHere(lobby) then
				return true
			end
			if typeof(expected) == "number" and expected > 0 then
				onProgress(WORLD_SHARE * math.clamp(have / expected, 0, 0.99), "Raising the island")
			end
		else
			-- The server is still building: creep forward so the bar never looks stuck.
			local t = (os.clock() - started) / WORLD_TIMEOUT
			onProgress(WORLD_SHARE * 0.8 * (1 - (1 - t) ^ 3), "Raising the island")
		end
		task.wait(0.1)
	end
	return false
end

-- Runs the gate. Returns how it went: "ready", or "timeout" when it gave up waiting.
function WorldGate.run(onProgress: (number, string) -> ()): string
	local worldOk = waitForWorld(onProgress)
	onProgress(WORLD_SHARE, "Gathering the blades")

	local list: { string } = {}
	local seen: { [string]: boolean } = {}
	local instances: { Instance } = {}
	for _, name in { "Lobby", "Castle" } do
		local root = workspace:FindFirstChild(name)
		if root then
			collect(root, list, seen, instances)
		end
	end
	local assets = Assets :: any
	for _, key in { "UI", "Icons", "Boards", "Touch", "RankCrests" } do
		if typeof(assets[key]) == "table" then
			collectTable(assets[key], list, seen)
		end
	end

	local total = math.max(#list + #instances, 1)
	local done = 0
	local finished = false
	local function step()
		done += 1
		onProgress(WORLD_SHARE + (1 - WORLD_SHARE) * math.min(done / total, 1), "Gathering the blades")
	end
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(list, step)
		end)
		-- Meshes in parallel batches, each batch counted as it lands.
		local pending = 0
		for i = 1, #instances, 6 do
			local batch = table.move(instances, i, math.min(i + 5, #instances), 1, {})
			pending += 1
			task.spawn(function()
				pcall(function()
					ContentProvider:PreloadAsync(batch)
				end)
				for _ = 1, #batch do
					step()
				end
				pending -= 1
			end)
		end
		while pending > 0 do
			task.wait()
		end
		finished = true
	end)
	local started = os.clock()
	while not finished and os.clock() - started < PRELOAD_TIMEOUT do
		task.wait(0.1)
	end
	onProgress(1, "Ready")
	WorldGate.stats = {
		world = worldOk,
		assets = #list,
		loaded = math.min(done, total),
		preloadSeconds = os.clock() - started,
		timedOut = not finished,
	}
	return if worldOk and finished then "ready" else "timeout"
end

WorldGate.stats = {} :: { [string]: any }

return WorldGate
