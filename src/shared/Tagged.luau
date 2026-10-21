--!strict
-- Live lists of tagged instances, kept in step with CollectionService's added and removed
-- signals, so per-frame code (lock-on probes, occlusion, spacing) reads one shared array
-- instead of allocating a fresh `GetTagged` copy every frame. Read-only for callers: don't
-- change the array, and don't yield while iterating it.

local CollectionService = game:GetService("CollectionService")

local Tagged = {}

local lists: { [string]: { Instance } } = {}

function Tagged.list(tag: string): { Instance }
	local list = lists[tag]
	if list then
		return list
	end
	local live = CollectionService:GetTagged(tag)
	lists[tag] = live
	CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance)
		if not table.find(live, instance) then
			table.insert(live, instance)
		end
	end)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(function(instance)
		local index = table.find(live, instance)
		if index then
			table.remove(live, index)
		end
	end)
	return live
end

return Tagged
