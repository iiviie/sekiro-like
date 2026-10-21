--!strict
-- The torii prop's two pillars are a single MeshPart with box collision, so its collision
-- box fills the opening between them and the gate is an invisible wall (its base slab is
-- another full-width box). `openGate` makes a torii walk-through: every piece that reaches
-- below head height stops colliding, and an invisible post stands in for each pillar.
-- The beams overhead keep their collision.

local Torii = {}

local HEAD_ROOM = 6 -- pieces whose bottom is lower than this above the ground are opened

function Torii.openGate(model: Model)
	local box, size = model:GetBoundingBox()
	local ground = box.Position.Y - size.Y / 2
	-- The pillars are the tallest piece.
	local pillars: BasePart? = nil
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and (pillars == nil or d.Size.Y > pillars.Size.Y) then
			pillars = d
		end
	end
	if not pillars then
		return
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d.Position.Y - d.Size.Y / 2 < ground + HEAD_ROOM then
			d.CanCollide = false
		end
	end
	local top = pillars.Position.Y + pillars.Size.Y / 2
	local thick = pillars.Size.Z
	for _, side in { -1, 1 } do
		local at = pillars.CFrame * Vector3.new(side * (pillars.Size.X / 2 - thick / 2), 0, 0)
		local post = Instance.new("Part")
		post.Name = "PillarCollider"
		post.Anchored = true
		post.CanTouch = false
		post.CastShadow = false
		post.Transparency = 1
		post.Size = Vector3.new(thick, top - ground, thick)
		post.CFrame = CFrame.new(at.X, (top + ground) / 2, at.Z) * pillars.CFrame.Rotation
		post.Parent = model
	end
end

return Torii
