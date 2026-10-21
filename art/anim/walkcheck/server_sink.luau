local RS = game:GetService("ReplicatedStorage")
local Http = game:GetService("HttpService")
pcall(function() Http.HttpEnabled = true end)
local ev = RS:FindFirstChild("WalkRecUp") or Instance.new("RemoteEvent")
ev.Name = "WalkRecUp"
ev.Parent = RS
local buf = {}
ev.OnServerEvent:Connect(function(_, tag, i, n, chunk)
	buf[tag] = buf[tag] or {}
	buf[tag][i] = chunk
	for k = 1, n do
		if not buf[tag][k] then
			return
		end
	end
	local body = table.concat(buf[tag])
	buf[tag] = nil
	local ok, err = pcall(function()
		Http:PostAsync("http://127.0.0.1:8766/" .. tag, body)
	end)
	RS:SetAttribute("WalkRecLast", tag .. (if ok then " ok " .. #body else " fail " .. tostring(err)))
end)
return "sink ready, http " .. tostring(Http.HttpEnabled)
