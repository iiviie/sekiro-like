-- Records a fighter's skeleton (joint pivots in world space) every render frame into
-- ReplicatedStorage.WalkRec_<tag> (a StringValue, client-only). Paste with MODEL/TAG/DURATION set.
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function r(x: number): number
	return math.floor(x * 100 + 0.5) / 100
end
local function p3(v: Vector3)
	return { r(v.X), r(v.Y), r(v.Z) }
end

local function record(model: Model, tag: string, duration: number)
	local joints = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") then
			table.insert(joints, d)
		end
	end
	local frames = {}
	local parts: { BasePart } = {}
	local sizes = {}
	for _, d in model:GetChildren() do
		if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
			table.insert(parts, d)
			sizes[d.Name] = p3(d.Size)
		end
	end
	local t0 = os.clock()
	local conn
	conn = RunService.RenderStepped:Connect(function()
		local t = os.clock() - t0
		local f: { [string]: any } = { t = math.floor(t * 1000) / 1000 }
		local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
		if root then
			f.root = p3(root.Position)
			f.look = p3(root.CFrame.LookVector)
			f.vel = p3(root.AssemblyLinearVelocity)
		end
		for _, m in joints do
			if m.Part0 and m.Part1 then
				f[m.Name] = p3((m.Part0.CFrame * m.C0).Position)
			end
		end
		for _, side in { "Left", "Right" } do
			local foot = model:FindFirstChild(side .. "Foot") :: BasePart?
			if foot then
				f[side .. "Toe"] = p3((foot.CFrame * CFrame.new(0, -foot.Size.Y / 2, -foot.Size.Z / 2)).Position)
				f[side .. "Heel"] = p3((foot.CFrame * CFrame.new(0, -foot.Size.Y / 2, foot.Size.Z / 2)).Position)
			end
			local hand = model:FindFirstChild(side .. "Hand") :: BasePart?
			if hand then
				f[side .. "HandEnd"] = p3((hand.CFrame * CFrame.new(0, -hand.Size.Y / 2, 0)).Position)
			end
		end
		local head = model:FindFirstChild("Head") :: BasePart?
		if head then
			f.HeadTop = p3((head.CFrame * CFrame.new(0, head.Size.Y / 2, 0)).Position)
		end
		local sword = model:FindFirstChild("Sword") :: BasePart?
		if sword then
			local s = sword.Size
			local axis = if s.Z >= s.X and s.Z >= s.Y
				then Vector3.zAxis * s.Z / 2
				elseif s.Y >= s.X then Vector3.yAxis * s.Y / 2
				else Vector3.xAxis * s.X / 2
			f.SwordA = p3(sword.CFrame:PointToWorldSpace(axis))
			f.SwordB = p3(sword.CFrame:PointToWorldSpace(-axis))
		end
		local pc = {}
		for _, part in parts do
			local cf = part.CFrame
			local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
			pc[part.Name] = { r(x), r(y), r(z), r(r00), r(r01), r(r02), r(r10), r(r11), r(r12), r(r20), r(r21), r(r22) }
		end
		f.parts = pc
		table.insert(frames, f)
		if t >= duration then
			conn:Disconnect()
			local body = HttpService:JSONEncode({ sizes = sizes, frames = frames })
			local ev = ReplicatedStorage:FindFirstChild("WalkRecUp") :: RemoteEvent
			local size = 30000
			local n = math.ceil(#body / size)
			task.spawn(function()
				for i = 1, n do
					ev:FireServer(tag, i, n, string.sub(body, (i - 1) * size + 1, i * size))
					task.wait(0.05)
				end
			end)
		end
	end)
end

