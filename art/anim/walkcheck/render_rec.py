"""Blender (background) renderer for WalkRec JSON: blocky R15 frames from the side and the back.

blender --background --factory-startup --python render_rec.py -- rec.json outdir N [start span] [tag]
Writes outdir/<tag>_<view>_<i>.png for N frames evenly over [start, start+span].
"""
import bpy, json, sys, math, os
from mathutils import Matrix, Vector

argv = sys.argv[sys.argv.index("--") + 1:]
rec_path, outdir, n = argv[0], argv[1], int(argv[2])
start = float(argv[3]) if len(argv) > 3 else None
span = float(argv[4]) if len(argv) > 4 else None
tag = argv[5] if len(argv) > 5 else "f"
data = json.load(open(rec_path))
sizes, frames = data["sizes"], data["frames"]
frames = [f for f in frames if "parts" in f and "root" in f]
if start is not None:
    frames = [f for f in frames if f["t"] >= start and (span is None or f["t"] <= start + span)]
idx = [round(i * (len(frames) - 1) / max(n - 1, 1)) for i in range(n)]

A = Matrix(((1, 0, 0), (0, 0, -1), (0, 1, 0)))
def bv(p): return A @ Vector(p)

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = "BLENDER_WORKBENCH"
scene.display.shading.light = "STUDIO"
scene.display.shading.color_type = "OBJECT"
scene.display.shading.show_shadows = True
scene.display.shading.show_cavity = False
scene.render.resolution_x, scene.render.resolution_y = 340, 440
scene.render.film_transparent = False
world = bpy.data.worlds.new("w"); scene.world = world
world.color = (0.93, 0.91, 0.86)

def color_for(name):
    if name == "Sword": return (0.75, 0.78, 0.82, 1)
    if name == "Head": return (0.85, 0.7, 0.55, 1)
    if "Torso" in name: return (0.22, 0.22, 0.26, 1)
    if name.startswith("Right"): return (0.75, 0.25, 0.2, 1)
    if name.startswith("Left"): return (0.2, 0.35, 0.75, 1)
    return (0.5, 0.5, 0.5, 1)

objs = {}
for name, s in sizes.items():
    if name not in frames[0]["parts"]: continue
    bpy.ops.mesh.primitive_cube_add(size=1)
    o = bpy.context.active_object
    o.name = name
    o.color = color_for(name)
    objs[name] = (o, Vector((s[0], s[2], s[1])))  # Roblox size (x,y,z) -> Blender (x, z->y, y->z)

# Ground: a checker of 1-stud tiles around the start, world-fixed.
ground_y = min(min(f["parts"][p][1] for p in ("LeftFoot", "RightFoot") if p in f["parts"]) for f in frames) - 0.15
r0 = frames[0]["root"]
for i in range(-30, 31):
    for j in range(-30, 31):
        if (i + j) % 2 == 0: continue
        pass
bpy.ops.mesh.primitive_plane_add(size=400, location=bv((r0[0], ground_y, r0[2])))
g = bpy.context.active_object
g.color = (0.92, 0.9, 0.84, 1)
# grid lines every 2 studs as thin boxes
lines = []
for k in range(-30, 31):
    for axis in (0, 1):
        bpy.ops.mesh.primitive_cube_add(size=1)
        o = bpy.context.active_object
        if axis == 0:
            o.location = bv((r0[0] + k * 4, ground_y + 0.01, r0[2]))
            o.scale = (0.05, 240, 0.01)
        else:
            o.location = bv((r0[0], ground_y + 0.01, r0[2] + k * 4))
            o.scale = (240, 0.05, 0.01)
        o.color = (0.55, 0.5, 0.42, 1)

cam_data = bpy.data.cameras.new("cam")
cam_data.type = "ORTHO"
cam_data.ortho_scale = float(os.environ.get("ORTHO", "7.5"))
cam = bpy.data.objects.new("cam", cam_data)
scene.collection.objects.link(cam)
scene.camera = cam

os.makedirs(outdir, exist_ok=True)
for i, fi in enumerate(idx):
    f = frames[fi]
    for name, (o, sz) in objs.items():
        c = f["parts"].get(name)
        if not c:
            o.hide_render = True; continue
        o.hide_render = False
        R = Matrix(((c[3], c[4], c[5]), (c[6], c[7], c[8]), (c[9], c[10], c[11])))
        M = A @ R @ A.transposed()
        sx, sy, sz = sizes[name]
        if name == "Sword":  # the part is the mesh's box: draw a thin blade along its long axis
            L = max(sx, sy, sz)
            sx, sy, sz = (L if sx == L else 0.12), (L if sy == L and sx != L else 0.35), (L if sz == L and sx != L and sy != L else 0.12)
        o.matrix_world = Matrix.Translation(bv(c[0:3])) @ M.to_4x4() @ Matrix.Diagonal((sx, sz, sy, 1))
    look = Vector((f["look"][0], 0, f["look"][2])).normalized()
    right = Vector((-look.z, 0, look.x))
    root = Vector(f["root"])
    target = Vector((root.x, ground_y + 2.9, root.z))
    for view in ("side", "back"):
        if view == "side":
            eye = target + right * 30  # from the fighter's right: they face left on screen
        else:
            eye = target - look * 30
        eye = eye + Vector((0, 3, 0))  # a little above: the ground grid shows foot slide
        cam.location = bv(eye)
        d = (bv(target) - bv(eye)).normalized()
        cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
        scene.render.filepath = os.path.join(outdir, f"{tag}_{view}_{i:02d}.png")
        bpy.ops.render.render(write_still=True)
print("rendered", len(idx))
