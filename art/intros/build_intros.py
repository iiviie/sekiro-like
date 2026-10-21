"""Pre-fight intro clips (LAST BLADE): keyposes on the katana.blend R15 rig -> baked joint
Transforms for the procedural Animator.

Run (headless, from anywhere):
  blender --background art/anim/katana.blend --python art/intros/build_intros.py -- [--render DIR] [--only Iai,Rei]

What it does:
  1. loads katana.blend's own authoring kit (text blocks anim_lib / anim_export / poses: key(), the R15
     rig with IK hands and feet, joints_at()) without touching its clips;
  2. adds a free left hand (CtrlHandL, blended with the two-hand grip per key: `gripw` 0..1), and the
     intro props parented to bones (saya at the left hip, kasa on the head, war fan in the left hand);
  3. keys every intro below on one timeline (Bezier between keyposes: anticipation, overshoot, settle
     are authored as keys), samples it at 30 fps, drops samples a straight blend reproduces within
     TOL degrees, and writes src/shared/BakedIntros/ (init + Poses* + Clips: the same compact rows as
     Baked/Decode, registered at runtime like BakedBoss, so Animator/BakedPoses stay untouched);
  4. saves the result as art/intros/intros.blend (the rig, props, the timeline with a marker per
     intro, and this script as the `build_intros` text block); katana.blend itself is not written;
  5. with --render DIR: a contact sheet per intro (8 frames, front 3/4) for review.

Coordinates are Roblox HumanoidRootPart space in studs (x right, y up, z back; the character
faces -z), as in katana.blend's `poses` block. Angles (hips/chest/head) are (yaw left, pitch
forward, roll right-shoulder-down) in degrees. The game plays the clips with
Animator.play(model, "Intro_<Ref>"); timing is authored, nothing stretches.
"""
import bpy, sys, os, math, json
from mathutils import Vector, Matrix, Quaternion

ARGS = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
GAME = '/Users/divyansh/cursor-projects/roblox/sekiro-like/'
OUT = GAME + 'src/shared/BakedIntros/'
RENDER = ARGS[ARGS.index('--render') + 1] if '--render' in ARGS else None
ONLY = set(ARGS[ARGS.index('--only') + 1].split(',')) if '--only' in ARGS else None
FPS = 60
STEP = 1 / 30
TOL = 1.2            # degrees: a sample a straight blend between its kept neighbours misses by more is kept
TOL_POS = 0.02       # studs (Root)
MAX_CHARS = 150000

# katana.blend's kit: rig, key(), joints_at(), POSES / G.
for name in ('anim_lib', 'anim_export', 'poses'):
    exec(bpy.data.texts[name].as_string(), globals())
K = {p[0]: dict(p[4]) for p in POSES}

scene = bpy.context.scene
scene.render.fps = FPS

def Rb(v):
    """Blender vector -> Roblox vector (B() is the other way)."""
    return Vector((-v.x, v.z, v.y))

# ---------------------------------------------------------------------------------------------
# The free left hand. TargetL = CtrlHandL blended toward GripL by `gripw`; the left arm's IK
# reaches TargetL. The hand's rotation copies the right hand (on the hilt) or CtrlHandL.
def obj_empty(name):
    o = bpy.data.objects.get(name)
    if not o:
        o = bpy.data.objects.new(name, None)
        scene.collection.objects.link(o)
        o.empty_display_size = 0.25
    return o

CTRL_L = obj_empty('CtrlHandL')
TARGET_L = obj_empty('TargetL')
for c in list(TARGET_L.constraints):
    TARGET_L.constraints.remove(c)
ct_free = TARGET_L.constraints.new('COPY_TRANSFORMS'); ct_free.name = 'Free'; ct_free.target = CTRL_L
ct_grip = TARGET_L.constraints.new('COPY_TRANSFORMS'); ct_grip.name = 'Grip'; ct_grip.target = bpy.data.objects['GripL']
IK_L = pb['LeftLowerArm'].constraints['IK']
IK_L.target = TARGET_L
CR_L = pb['LeftHand'].constraints['Copy Rotation']
FREE_ROT = pb['LeftHand'].constraints.get('FreeRot') or pb['LeftHand'].constraints.new('COPY_ROTATION')
FREE_ROT.name = 'FreeRot'; FREE_ROT.target = CTRL_L

LH_REST = rest['LeftHand'].to_3x3()
HANG_L = (-1.12, -0.86, -0.08)

def key2(t, base, gripw=1.0, handL=None, lrot=(0, 0, 0), props=None):
    """One keypose at clip time t (seconds from the timeline origin `base` frame)."""
    frame = BASE + t * FPS
    kw = dict(base)
    key(frame, grip=True, **kw)
    # left hand
    CTRL_L.location = B(*(handL or HANG_L))
    CTRL_L.rotation_mode = 'QUATERNION'
    _q(CTRL_L, 'handL', (E(*lrot) @ LH_REST).to_quaternion())
    CTRL_L.keyframe_insert('location', frame=frame); CTRL_L.keyframe_insert('rotation_quaternion', frame=frame)
    ct_grip.influence = gripw; TARGET_L.keyframe_insert('constraints["Grip"].influence', frame=frame)
    CR_L.influence = gripw; CR_L.keyframe_insert('influence', frame=frame)
    FREE_ROT.influence = 1 - gripw; FREE_ROT.keyframe_insert('influence', frame=frame)
    IK_L.influence = 1.0; IK_L.keyframe_insert('influence', frame=frame)

# ---------------------------------------------------------------------------------------------
# Props. Offsets are in Roblox axes from the joint pivot of the part they ride on (the game
# builds the same parts: Root pivot in LowerTorso, Neck pivot in Head, LeftWrist pivot in LeftHand).
SAYA_MOUTH = Vector((-0.56, 0.26, -0.7))          # from the Root pivot (LowerTorso)
SAYA_AXIS = Vector((-0.3, -0.35, 1.0)).normalized()  # mouth -> chape, back and down
SAYA_LEN = 3.3
KASA_AT = Vector((0, 1.02, 0.02))                   # from the Neck pivot: the crown sits on the head
FAN_AT = Vector((0, -0.42, 0))                       # from the LeftWrist pivot: the rivet in the palm

PROP_PARTS = {
    'Saya': dict(bone='LowerTorso', joint='Root', part='LowerTorso'),
    'Kasa': dict(bone='Head', joint='Neck', part='Head'),
    'Fan': dict(bone='LeftHand', joint='LeftWrist', part='LeftHand'),
}

def look_rot(axis_r):
    """Roblox rotation whose -Z looks along axis_r (Roblox CFrame.lookAt convention), as a Matrix."""
    f = axis_r.normalized()
    up = Vector((0, 1, 0))
    if abs(f.dot(up)) > 0.99: up = Vector((0, 0, 1))
    right = f.cross(up).normalized()
    up2 = right.cross(f)
    return Matrix((right, up2, -f)).transposed()   # columns: X=right, Y=up, Z=-forward

PROPS = {}   # name -> {part, joint, pos (Roblox), rot (Matrix, Roblox), size}
def define_props():
    sm = SAYA_MOUTH + SAYA_AXIS * (SAYA_LEN / 2)
    PROPS['Saya'] = dict(PROP_PARTS['Saya'], pos=sm, rot=look_rot(SAYA_AXIS), size=(0.3, 0.24, SAYA_LEN))
    PROPS['Kasa'] = dict(PROP_PARTS['Kasa'], pos=KASA_AT, rot=Matrix.Identity(3), size=(2.7, 0.55, 2.7))
    PROPS['Fan'] = dict(PROP_PARTS['Fan'], pos=FAN_AT, rot=Matrix.Identity(3), size=(1.5, 0.06, 0.8))
define_props()

M3 = Matrix(((-1, 0, 0), (0, 0, 1), (0, 1, 0)))   # Roblox <-> Blender (self-inverse)

def build_prop_meshes():
    """Simple stand-ins on the rig for review renders (the game builds its own parts)."""
    rig.data.pose_position = 'REST'; bpy.context.view_layer.update()
    for name, p in PROPS.items():
        old = bpy.data.objects.get('Prop' + name)
        if old: bpy.data.objects.remove(old, do_unlink=True)
        if name == 'Saya':
            bpy.ops.mesh.primitive_cylinder_add(radius=0.13, depth=SAYA_LEN, vertices=12)
            o = bpy.context.active_object
            o.color = (0.05, 0.04, 0.04, 1)
            local = Matrix.Identity(4)      # cylinder along its Z = Roblox -look... axis along Z either way
        elif name == 'Kasa':
            bpy.ops.mesh.primitive_cone_add(radius1=1.35, radius2=0.05, depth=0.55, vertices=24)
            o = bpy.context.active_object
            o.color = (0.76, 0.62, 0.38, 1)
        else:
            bpy.ops.mesh.primitive_cylinder_add(radius=0.75, depth=0.05, vertices=24)
            o = bpy.context.active_object
            o.color = (0.6, 0.08, 0.08, 1)
        o.name = 'Prop' + name
        # world rest matrix: pivot + offset, in Blender axes
        joint_bone = p['bone']
        pivot_b = rest[joint_bone].translation.copy()      # bone head = joint pivot
        pos_b = pivot_b + M3 @ p['pos']
        rot_r = p['rot']
        if name == 'Saya':
            rot_b = (M3 @ SAYA_AXIS).to_track_quat('Z', 'Y').to_matrix()   # the cylinder runs along the axis
        elif name == 'Kasa':
            rot_b = Matrix.Identity(3)                      # cone axis = Blender Z = Roblox up
        else:
            rot_b = Matrix.Rotation(math.radians(90), 3, 'X')   # fan plate facing forward
        o.parent = rig; o.parent_type = 'BONE'; o.parent_bone = joint_bone
        o.matrix_world = Matrix.Translation(pos_b) @ rot_b.to_4x4()
    rig.data.pose_position = 'POSE'; bpy.context.view_layer.update()

# ---------------------------------------------------------------------------------------------
# Poses
G0 = G
STAND = dict(footR=(0.5, G0, 0), footL=(-0.5, G0, 0))
READY = dict(K['Ready'], drop=0.18, hips=(0, 4, 0), footR=(0.55, G0, -0.45), footL=(-0.55, G0, 0.55))
RELAXED = dict(K['Relaxed'], drop=0.04, **STAND)
for k in ('grip',):
    RELAXED.pop(k, None)

def P(base, **kw):
    out = dict(base); out.update(kw); return out

def sheathed(base, depth=0.0, hand_nudge=(0, 0, 0)):
    """The blade in the saya: blade along the saya axis, the tsuba `depth` studs out of the mouth
    (0 = home). The wrist target is solved so the tsuba lands there (2 passes)."""
    kw = dict(base)
    return ('SHEATH', kw, depth, hand_nudge)

TSUBA = bpy.data.objects['Tsuba']

def place_sheathed(t, kw, depth, nudge, **extra):
    frame = BASE + t * FPS
    # blade direction in HRP space: the saya axis turned by the hips (LowerTorso)
    kw = dict(kw)
    hand = kw.get('hand', (-0.3, -0.9, -1.2))
    for _ in range(5):
        kw['hand'] = hand
        lt = None
        # pose torso + hand, then measure
        key2(t, kw, **extra)
        scene.frame_set(int(frame), subframe=frame - int(frame)); bpy.context.view_layer.update()
        ltm = pb['LowerTorso'].matrix                     # armature space (= world, rig at origin)
        pivot = ltm.translation
        R_lt = ltm.to_3x3() @ rest['LowerTorso'].to_3x3().inverted()   # world delta from rest
        mouth_b = pivot + R_lt @ (M3 @ SAYA_MOUTH)
        axis_b = R_lt @ (M3 @ SAYA_AXIS)
        want_tsuba = mouth_b - axis_b.normalized() * (depth + 0.04)
        kw['blade'] = tuple(Rb(axis_b.normalized()))
        kw['edge'] = tuple(Rb(R_lt @ (M3 @ Vector((0, 1, 0.4)))))   # edge up, as a katana is worn
        key2(t, kw, **extra)
        scene.frame_set(int(frame), subframe=frame - int(frame)); bpy.context.view_layer.update()
        got = TSUBA.matrix_world.translation
        err = want_tsuba - got
        h = Vector(hand)
        h = h + Rb(err)
        hand = tuple(h + Vector(nudge))
        if err.length < 0.01:
            break
    print('  sheathed t=%.2f depth %.2f  tsuba error %.3f studs' % (t, depth, err.length))
    kw['hand'] = hand
    key2(t, kw, **extra)

# ---------------------------------------------------------------------------------------------
# The intros. Each: keys [(t, kw or sheathed(...), extras)], hold, fade, props (shown while it plays),
# note. Extras: gripw (1 = both hands on the hilt), handL, lrot (left hand world angles from hanging).
def X(gripw=1.0, handL=None, lrot=(0, 0, 0)):
    return dict(gripw=gripw, handL=handL, lrot=lrot)

FREE = X(0.0)
INTROS = {}

# 1. Rei: kneel on one knee, bow, rise into the guard (default, everyone owns it).
KNEEL = dict(drop=0.9, shift=(0, 0.15), footL=(-0.5, G0, -0.78), footR=(0.5, G0 + 0.14, 1.25))
REI_HAND = dict(hand=(1.0, -0.78, 0.05), blade=(0.12, -0.55, 0.85), edge=(0, -0.85, -0.5))
INTROS['Rei'] = dict(hold=0.15, fade=0.35, props=[], note='kneeling bow, then rise into the guard', keys=[
    (0.12, P(RELAXED, **REI_HAND, chest=(0, 0, 0), head=(0, 0, 0)), FREE),
    (0.38, P(RELAXED, **REI_HAND, drop=-0.03, chest=(0, -3, 0), head=(0, -4, 0)), FREE),
    (0.74, P(RELAXED, **KNEEL, hand=(0.98, -1.5, 0.15), blade=(0.1, -0.22, 1), edge=(0, -1, 0.2),
             chest=(0, 10, 0), head=(0, 10, 0)), X(0, handL=(-0.62, -1.62, -0.62), lrot=(0, -70, 0))),
    (0.86, P(RELAXED, **dict(KNEEL, drop=0.98), hand=(0.98, -1.56, 0.15), blade=(0.1, -0.22, 1), edge=(0, -1, 0.2),
             chest=(0, 14, 0), head=(0, 14, 0)), X(0, handL=(-0.62, -1.7, -0.62), lrot=(0, -70, 0))),
    (1.12, P(RELAXED, **dict(KNEEL, drop=0.95), hand=(0.98, -1.5, 0.05), blade=(0.1, -0.22, 1), edge=(0, -1, 0.2),
             chest=(0, 40, 0), head=(0, 28, 0)), X(0, handL=(-0.6, -1.65, -0.75), lrot=(0, -70, 0))),
    (1.36, P(RELAXED, **dict(KNEEL, drop=0.95), hand=(0.98, -1.5, 0.05), blade=(0.1, -0.22, 1), edge=(0, -1, 0.2),
             chest=(0, 42, 0), head=(0, 30, 0)), X(0, handL=(-0.6, -1.65, -0.78), lrot=(0, -70, 0))),
    (1.6, P(RELAXED, drop=0.42, shift=(0, 0.05), footL=(-0.55, G0, -0.2), footR=(0.55, G0 + 0.32, 0.3),
            hand=(0.95, -0.62, -0.25), blade=(0.1, 0.9, 0.35), edge=(0, 0.35, -0.9), chest=(0, 6, 0), head=(0, 2, 0)),
     X(0.2, handL=(-0.4, -0.9, -0.85))),
    (1.78, P(READY, drop=-0.04, hand=(0.45, -0.1, -1.1), blade=(-0.02, 0.75, -0.65), edge=(0, -0.65, -0.75),
             chest=(-6, -5, 0), head=(2, -6, 0)), X(1.0)),
    (2.02, READY, X(1.0)),
])

# 2. Chiburi: flick the blade clean, slide it home in the saya with a click, hand stays on the hilt.
CHIBURI_UP = P(READY, drop=0.15, hand=(1.0, 0.95, -0.35), blade=(0.35, 0.75, 0.55), edge=(0.2, -0.6, -0.75),
               chest=(-18, -4, 0), head=(10, -2, 0))
INTROS['Chiburi'] = dict(hold=0.12, fade=0.45, props=['Saya'], note='blade flick (chiburi) and noto: slides home with a click', keys=[
    (0.12, READY, X(1.0)),
    (0.42, CHIBURI_UP, X(0, handL=(-0.72, -0.85, -0.7), lrot=(0, -60, 0))),
    (0.58, P(CHIBURI_UP, drop=0.3, hand=(1.32, -0.5, -0.85), blade=(0.5, -0.55, -0.65), edge=(0.2, -0.75, 0.6),
             chest=(-8, 6, 0)), X(0, handL=(-0.72, -0.85, -0.7), lrot=(0, -60, 0))),
    (0.66, P(CHIBURI_UP, drop=0.32, hand=(1.36, -0.74, -0.6), blade=(0.55, -0.8, -0.25), edge=(0.2, -0.3, 0.9),
             chest=(-6, 7, 0)), X(0, handL=(-0.72, -0.85, -0.7), lrot=(0, -60, 0))),
    (0.92, P(CHIBURI_UP, drop=0.28, hand=(1.3, -0.64, -0.74), blade=(0.5, -0.66, -0.55), edge=(0.2, -0.5, 0.8),
             chest=(-6, 5, 0), head=(4, 2, 0)), X(0, handL=(-0.72, -0.85, -0.7), lrot=(0, -60, 0))),
    (1.2, P(READY, drop=0.25, hand=(0.1, -0.5, -1.05), blade=(-0.6, -0.08, -0.8), edge=(0, -1, 0),
            chest=(14, 6, 0), head=(-12, 12, 0)), X(0, handL=(-0.66, -0.98, -0.72), lrot=(0, -60, 0))),
    (1.48, sheathed(P(READY, drop=0.25, hand=(-0.3, -0.8, -1.4), chest=(30, 10, 0), head=(-24, 12, 0)), depth=2.4),
     X(0, handL=(-0.66, -1.0, -0.66), lrot=(0, -60, 0))),
    (1.76, sheathed(P(READY, drop=0.22, hand=(-0.4, -0.9, -1.3), chest=(44, 18, 0), head=(-38, 4, 0)), depth=0.0),
     X(0, handL=(-0.66, -1.0, -0.66), lrot=(0, -60, 0))),
    (1.86, sheathed(P(READY, drop=0.24, hand=(-0.4, -0.9, -1.3), chest=(44, 18, 0), head=(-40, -5, 0)), depth=-0.03),
     X(0, handL=(-0.66, -1.0, -0.66), lrot=(0, -60, 0))),
    (2.1, sheathed(P(READY, drop=0.2, hand=(-0.4, -0.9, -1.3), chest=(44, 17, 0), head=(-40, -4, 0)), depth=0.0),
     X(0, handL=(-0.66, -1.0, -0.66), lrot=(0, -60, 0))),
])

# 3. Iai: crouched over the sheathed blade, a long still beat, then the draw-cut in one flash.
IAI_FEET = dict(footR=(0.62, G0, -0.75), footL=(-0.6, G0, 0.62))
IAI_LH = X(0, handL=(-0.68, -1.12, -0.6), lrot=(0, -55, 0))
INTROS['Iai'] = dict(hold=0.1, fade=0.4, props=['Saya'], note='iai: crouch over the sheathed blade, draw-cut in one flash', keys=[
    (0.14, sheathed(P(READY, drop=0.38, hips=(-6, 6, 0), chest=(46, 18, 0), head=(-40, 10, 0), hand=(-0.4, -0.9, -1.3), **IAI_FEET)), IAI_LH),
    (0.62, sheathed(P(READY, drop=0.52, hips=(-6, 8, 0), chest=(44, 20, 0), head=(-38, 14, 0), hand=(-0.4, -0.9, -1.3), **IAI_FEET), depth=0.08), IAI_LH),
    (0.72, sheathed(P(READY, drop=0.5, hips=(-8, 8, 0), chest=(30, 14, 0), head=(-26, 8, 0), hand=(-0.4, -0.9, -1.3), **IAI_FEET), depth=1.0), IAI_LH),
    (0.8, P(READY, drop=0.5, hips=(-14, 6, 0), chest=(-34, 5, 0), head=(26, 2, 0), hand=(1.2, -0.05, -1.3),
            blade=(1, 0.06, -0.3), edge=(0.25, 0, -1), **IAI_FEET), X(0, handL=(-0.8, -1.05, -0.2), lrot=(0, -55, 0))),
    (0.88, P(READY, drop=0.52, hips=(-18, 6, 0), chest=(-48, 4, 0), head=(36, 0, 0), hand=(1.45, 0.1, -0.5),
             blade=(0.95, 0.1, 0.35), edge=(-0.3, 0, 1), **IAI_FEET), X(0, handL=(-0.85, -1.0, -0.1), lrot=(0, -55, 0))),
    (1.24, P(READY, drop=0.5, hips=(-16, 6, 0), chest=(-42, 4, 0), head=(32, -2, 0), hand=(1.4, 0.05, -0.62),
             blade=(0.95, 0.05, 0.25), edge=(-0.25, 0, 1), **IAI_FEET), X(0, handL=(-0.85, -1.0, -0.1), lrot=(0, -55, 0))),
    (1.52, P(READY, drop=0.36, hips=(-6, 6, 0), chest=(-14, 6, 0), head=(10, 0, 0), hand=(1.22, -0.45, -0.9),
             blade=(0.5, -0.5, -0.7), edge=(0.2, -0.6, 0.7), **IAI_FEET), X(0, handL=(-0.6, -0.9, -0.6))),
    (1.96, READY, X(1.0)),
])

# 4. Kasa: head bowed under a straw hat, a finger tips it up, then it's flicked away.
KASA_HEAD = dict(RELAXED, chest=(0, 6, 0), head=(0, 28, 0))
INTROS['Kasa'] = dict(hold=0.15, fade=0.35, props=['Kasa'], note='head bowed under a kasa, tip it up, flick it away', keys=[
    (0.12, KASA_HEAD, FREE),
    (0.48, P(KASA_HEAD, head=(0, 26, 0)), X(0, handL=(-0.6, 0.6, -0.95), lrot=(0, -150, 0))),
    (0.72, P(KASA_HEAD, head=(0, 20, 0)), X(0, handL=(-0.35, 1.4, -1.0), lrot=(0, -160, 0))),
    (0.96, P(KASA_HEAD, chest=(0, -2, 0), head=(0, -14, 0)), X(0, handL=(-0.38, 1.95, -0.8), lrot=(0, -170, 0))),
    (1.06, P(KASA_HEAD, chest=(0, -3, 0), head=(0, -18, 0)), X(0, handL=(-0.4, 2.0, -0.75), lrot=(0, -170, 0))),
    (1.2, P(KASA_HEAD, chest=(8, -2, 0), head=(-4, -10, 0)), X(0, handL=(-1.62, 1.5, -0.15), lrot=(0, 0, 120))),
    (1.48, P(READY, drop=0.1, hand=(0.6, -0.35, -1.0), blade=(0, 0.45, -0.9), chest=(-4, 2, 0), head=(2, -4, 0)),
     X(0.3, handL=(-0.9, -0.4, -0.7))),
    (1.96, READY, X(1.0)),
])

# 5. Jizai: drive the blade point-first into the ground, stand over it and stare, pull it free.
PLANT = dict(READY, hand=(0.12, 0.1, -1.05), blade=(0, -1, 0.04), edge=(0, 0, -1))
INTROS['Plant'] = dict(hold=0.12, fade=0.35, props=[], note='sword planted point-down, a stare over the pommel', keys=[
    (0.12, READY, X(1.0)),
    (0.4, P(PLANT, drop=0.05, hand=(0.14, 1.1, -0.95), chest=(0, -6, 0), head=(0, -4, 0)), X(1.0)),
    (0.55, P(PLANT, drop=-0.05, hand=(0.14, 1.35, -0.9), chest=(0, -9, 0), head=(0, -6, 0)), X(1.0)),
    (0.66, P(PLANT, drop=0.38, hand=(0.12, 0.12, -1.05), chest=(0, 20, 0), head=(0, 10, 0)), X(1.0)),
    (0.74, P(PLANT, drop=0.46, hand=(0.12, 0.08, -1.05), chest=(0, 24, 0), head=(0, 12, 0)), X(1.0)),
    (1.02, P(PLANT, drop=-0.02, footR=(0.62, G0, -0.1), footL=(-0.62, G0, 0.2), chest=(0, -3, 0), head=(0, -8, 0)), X(1.0)),
    (1.5, P(PLANT, drop=0.0, footR=(0.62, G0, -0.1), footL=(-0.62, G0, 0.2), chest=(0, -1, 0), head=(0, -6, 0)), X(1.0)),
    (1.72, P(PLANT, drop=0.12, hand=(0.2, 0.95, -1.0), chest=(0, -4, 0), head=(0, -4, 0)), X(1.0)),
    (2.04, READY, X(1.0)),
])

# 6. Sakura gust: wind up, one wide sweep that throws petals, the blade raised in salute.
INTROS['Sakura'] = dict(hold=0.12, fade=0.35, props=[], note='a wide sweep that throws a gust of petals, then a salute', keys=[
    (0.12, READY, X(1.0)),
    (0.4, P(READY, drop=0.25, hand=(1.25, 0.45, 0.3), blade=(0.7, 0.25, 0.7), edge=(-0.5, 0, 0.8),
            chest=(-40, 2, 0), head=(30, 0, 0)), X(0, handL=(-1.35, 0.05, -0.55), lrot=(0, 0, 80))),
    (0.6, P(READY, drop=0.3, hand=(-0.6, 0.35, -1.2), blade=(-0.95, 0.15, -0.4), edge=(-0.3, 0, 1),
            chest=(35, 4, 0), head=(-25, 0, 0)), X(0, handL=(-1.2, -0.3, 0.3))),
    (0.7, P(READY, drop=0.32, hand=(-1.0, 0.3, -0.75), blade=(-0.95, 0.15, 0.2), edge=(0.2, 0, 1),
            chest=(48, 4, 0), head=(-36, 0, 0)), X(0, handL=(-1.15, -0.4, 0.4))),
    (1.04, P(READY, drop=0.08, hand=(0.1, 0.1, -0.72), blade=(0, 1, -0.08), edge=(0, 0.05, -1),
             chest=(0, -2, 0), head=(0, 4, 0)), X(1.0)),
    (1.5, P(READY, drop=0.08, hand=(0.1, 0.16, -0.72), blade=(0, 1, -0.06), edge=(0, 0.05, -1),
            chest=(0, -3, 0), head=(0, 2, 0)), X(1.0)),
    (1.96, READY, X(1.0)),
])

# 7. Tessen: a war fan snaps open in a sweep, hides the face, the sword points past it; snap shut.
SWORD_LOW = dict(hand=(1.05, -0.72, -0.25), blade=(0.15, -0.45, -1), edge=(0, -1, 0.35))
INTROS['Tessen'] = dict(hold=0.12, fade=0.35, props=['Fan'], note='a war fan snaps open, veils the face, snaps shut', keys=[
    (0.12, P(RELAXED, **SWORD_LOW), X(0, handL=(-0.4, -0.1, -0.8), lrot=(0, -90, 0))),
    (0.42, P(RELAXED, **SWORD_LOW, chest=(-15, 0, 0), head=(10, 0, 0)), X(0, handL=(0.35, 0.55, -0.75), lrot=(0, -90, -60))),
    (0.6, P(RELAXED, **SWORD_LOW, chest=(20, 0, 0), head=(-10, 0, 0)), X(0, handL=(-1.65, 0.55, -0.75), lrot=(0, -90, 60))),
    (0.7, P(RELAXED, **SWORD_LOW, chest=(24, 0, 0), head=(-12, 0, 0)), X(0, handL=(-1.75, 0.48, -0.45), lrot=(0, -90, 75))),
    (1.0, P(RELAXED, hand=(0.95, 0.35, -0.55), blade=(-0.35, 0.15, -1), edge=(0, -1, 0), chest=(0, 0, 0), head=(-8, 4, 0)),
     X(0, handL=(-0.3, 1.1, -0.9), lrot=(0, -100, 0))),
    (1.45, P(RELAXED, hand=(0.95, 0.38, -0.55), blade=(-0.35, 0.15, -1), edge=(0, -1, 0), chest=(0, 0, 0), head=(-8, 3, 0)),
     X(0, handL=(-0.3, 1.12, -0.9), lrot=(0, -100, 0))),
    (1.64, P(READY, drop=0.1, hand=(0.6, -0.2, -1.1), blade=(0, 0.45, -0.9), chest=(-4, 2, 0), head=(2, -2, 0)),
     X(0, handL=(-0.6, -0.5, -0.75), lrot=(0, -60, 0))),
    (2.0, READY, X(1.0)),
])

# 8. Karasu: the left arm held out as a perch; a crow lands, settles, takes off.
PERCH = X(0, handL=(-1.78, 0.85, -0.45), lrot=(0, 0, 95))
INTROS['Crow'] = dict(hold=0.12, fade=0.35, props=[], note='a crow lands on the outstretched arm, then takes off', keys=[
    (0.12, P(RELAXED, **SWORD_LOW), FREE),
    (0.55, P(RELAXED, **SWORD_LOW, chest=(8, 0, 0), head=(30, -6, 0)), PERCH),
    (0.86, P(RELAXED, **SWORD_LOW, chest=(8, 0, 0), head=(30, -4, 0)), X(0, handL=(-1.78, 0.66, -0.45), lrot=(0, 0, 95))),
    (0.98, P(RELAXED, **SWORD_LOW, chest=(8, 0, 0), head=(28, -4, 0)), X(0, handL=(-1.78, 0.8, -0.45), lrot=(0, 0, 95))),
    (1.32, P(RELAXED, **SWORD_LOW, chest=(4, 0, 0), head=(0, -2, 0)), PERCH),
    (1.42, P(RELAXED, **SWORD_LOW, chest=(4, 0, 0), head=(0, -2, 0)), X(0, handL=(-1.7, 1.05, -0.45), lrot=(0, 0, 95))),
    (1.62, P(READY, drop=0.1, hand=(0.6, -0.35, -1.0), blade=(0, 0.45, -0.9), chest=(-4, 2, 0), head=(2, -4, 0)),
     X(0.2, handL=(-1.0, -0.35, -0.6))),
    (2.0, READY, X(1.0)),
])

# 9. Raiko: the blade thrust at the sky draws the lightning, then levelled at the foe, crackling.
INTROS['Raiko'] = dict(hold=0.12, fade=0.35, props=[], note='blade raised to the sky draws a lightning strike', keys=[
    (0.12, READY, X(1.0)),
    (0.34, P(READY, drop=0.36, hand=(0.6, -0.3, -0.5), blade=(0.1, 0.9, -0.2), edge=(0, 0, -1), chest=(0, 6, 0)),
     X(0, handL=(-1.1, -0.6, -0.4))),
    (0.58, P(READY, drop=-0.06, hand=(0.45, 1.85, -0.35), blade=(0, 1, 0.05), edge=(0, 0, -1), chest=(0, -10, 0), head=(0, -25, 0)),
     X(0, handL=(-1.15, -0.7, -0.2))),
    (0.7, P(READY, drop=0.0, hand=(0.45, 1.83, -0.35), blade=(0, 1, 0.05), edge=(0, 0, -1), chest=(0, -10, 0), head=(0, -24, 0)),
     X(0, handL=(-1.15, -0.7, -0.2))),
    (0.77, P(READY, drop=0.14, hand=(0.5, 1.68, -0.3), blade=(0.05, 1, 0.1), edge=(0, 0, -1), chest=(0, -6, 0), head=(0, -16, 0)),
     X(0, handL=(-1.2, -0.6, -0.3))),
    (1.04, P(READY, drop=0.26, hand=(0.35, 0.05, -1.3), blade=(0, 0.1, -1), edge=(0, -1, 0), chest=(0, 6, 0), head=(0, 0, 0)), X(1.0)),
    (1.12, P(READY, drop=0.3, hand=(0.35, -0.06, -1.3), blade=(0, 0.06, -1), edge=(0, -1, 0), chest=(0, 8, 0), head=(0, 1, 0)), X(1.0)),
    (1.5, P(READY, drop=0.27, hand=(0.35, 0.0, -1.3), blade=(0, 0.1, -1), edge=(0, -1, 0), chest=(0, 6, 0), head=(0, 0, 0)), X(1.0)),
    (1.96, READY, X(1.0)),
])

# 10. Shodo: the tip writes a brush stroke in the air (diagonal, hook, crossbar, drop).
INTROS['Shodo'] = dict(hold=0.12, fade=0.35, props=[], note='the blade tip writes a brush stroke in the air', keys=[
    (0.12, READY, X(1.0)),
    (0.36, P(READY, drop=0.12, hand=(-0.2, 0.9, -1.0), blade=(-0.35, 0.55, -0.75), edge=(0.6, -0.6, 0), chest=(12, -2, 0)), X(1.0)),
    (0.6, P(READY, drop=0.3, hand=(0.75, -0.35, -1.15), blade=(0.45, -0.3, -0.85), edge=(0.6, -0.6, 0), chest=(-14, 6, 0)), X(1.0)),
    (0.7, P(READY, drop=0.3, hand=(0.6, -0.22, -1.25), blade=(0.25, -0.12, -0.95), edge=(-0.5, 0.6, 0), chest=(-10, 6, 0)), X(1.0)),
    (0.92, P(READY, drop=0.2, hand=(-0.5, 0.45, -1.1), blade=(-0.6, 0.3, -0.75), edge=(0, 1, 0), chest=(18, 0, 0)), X(1.0)),
    (1.12, P(READY, drop=0.3, hand=(0.1, -0.4, -1.25), blade=(0, -0.35, -0.95), edge=(0, -1, 0), chest=(0, 8, 0)), X(1.0)),
    (1.42, P(READY, drop=0.3, hand=(0.1, -0.42, -1.25), blade=(0, -0.38, -0.94), edge=(0, -1, 0), chest=(0, 9, 0), head=(0, 6, 0)), X(1.0)),
    (1.96, READY, X(1.0)),
])

# 11. Tsukimi: the blade on the shoulder, eyes on the moon; a slow look down, then the guard.
SHOULDER = dict(hand=(0.78, 0.55, -0.45), blade=(-0.15, 0.4, 1), edge=(0, 1, 0.3))
INTROS['Tsukimi'] = dict(hold=0.12, fade=0.35, props=[], note='blade on the shoulder, gazing at the moon', keys=[
    (0.12, P(RELAXED, **SHOULDER, chest=(0, -6, 0), head=(15, -22, 0)), FREE),
    (0.62, P(RELAXED, **SHOULDER, chest=(0, -7, 0), head=(15, -26, 0)), FREE),
    (1.02, P(RELAXED, **SHOULDER, chest=(0, -2, 0), head=(0, 0, 0)), FREE),
    (1.3, P(RELAXED, hand=(0.86, 0.75, -0.35), blade=(0.1, 0.6, 0.8), edge=(0, 0.6, -0.8), chest=(-4, -4, 0), head=(0, -2, 0)), FREE),
    (1.54, P(READY, drop=0.2, hand=(0.4, -0.3, -1.25), blade=(0, 0.2, -1), edge=(0, -1, 0), chest=(0, 6, 0)), X(0.6)),
    (1.62, P(READY, drop=0.24, hand=(0.4, -0.4, -1.25), blade=(0, 0.15, -1), edge=(0, -1, 0), chest=(0, 8, 0)), X(1.0)),
    (2.0, READY, X(1.0)),
])

# 12. Ryu: the blade wheels overhead, faster and faster, and slams down into a low stance.
def spin(t, d, e):
    return (t, P(READY, drop=0.0, hand=(0.28, 1.62, -0.22), blade=d, edge=e, chest=(0, -4, 0), head=(0, -6, 0)),
            X(0, handL=(-1.3, 0.2, -0.4), lrot=(0, 0, 70)))
L_, B_, R_, F_ = (-1, 0.12, 0), (0, 0.12, 1), (1, 0.12, 0), (0, 0.12, -1)
INTROS['Ryu'] = dict(hold=0.12, fade=0.4, props=[], note='the blade wheels overhead and slams into a low stance', keys=[
    (0.12, READY, X(1.0)),
    (0.3, P(READY, drop=0.1, hand=(0.4, 1.5, -0.3), blade=L_, edge=(0, 0, 1), chest=(10, -2, 0)), X(0, handL=(-1.2, 0.0, -0.5), lrot=(0, 0, 60))),
    spin(0.43, B_, (1, 0, 0)), spin(0.54, R_, (0, 0, -1)), spin(0.63, F_, (-1, 0, 0)), spin(0.71, L_, (0, 0, 1)),
    spin(0.78, B_, (1, 0, 0)), spin(0.84, R_, (0, 0, -1)), spin(0.9, F_, (-1, 0, 0)), spin(0.95, L_, (0, 0, 1)),
    (1.12, P(READY, drop=0.78, hand=(0.95, -0.85, 0.32), blade=(0.55, -0.25, 0.8), edge=(-0.6, 0, 0.6),
             chest=(-25, 16, 0), head=(20, -10, 0), footR=(0.78, G0, -0.6), footL=(-0.78, G0, 0.72)), X(1.0)),
    (1.2, P(READY, drop=0.86, hand=(0.95, -0.92, 0.35), blade=(0.55, -0.3, 0.8), edge=(-0.6, 0, 0.6),
            chest=(-26, 19, 0), head=(20, -12, 0), footR=(0.78, G0, -0.6), footL=(-0.78, G0, 0.72)), X(1.0)),
    (1.6, P(READY, drop=0.8, hand=(0.95, -0.88, 0.33), blade=(0.55, -0.27, 0.8), edge=(-0.6, 0, 0.6),
            chest=(-25, 17, 0), head=(20, -11, 0), footR=(0.78, G0, -0.6), footL=(-0.78, G0, 0.72)), X(1.0)),
    (2.04, READY, X(1.0)),
])

# ---------------------------------------------------------------------------------------------
def clear_all():
    clear()
    for o in (CTRL_L, TARGET_L):
        o.animation_data_clear()

def author(name, spec, base):
    global BASE
    BASE = base
    for t, kw, extra in spec['keys']:
        if isinstance(kw, tuple) and kw[0] == 'SHEATH':
            place_sheathed(t, kw[1], kw[2], kw[3], **extra)
        else:
            key2(t, kw, **extra)

def quat_angle(a, b):
    d = abs(a.dot(b))
    return math.degrees(2 * math.acos(min(1.0, d)))

def sample(name, spec, base):
    t0 = spec['keys'][0][0]; t1 = spec['keys'][-1][0]
    times = set()
    t = t0
    while t < t1 - 1e-6:
        times.add(round(t, 4)); t += STEP
    for kt, _, _ in spec['keys']:
        times.add(round(kt, 4))
    times = sorted(times)
    frames = []
    for tt in times:
        js = joints_at(base + tt * FPS)
        q = {j: (p.copy(), R.to_quaternion()) for j, (p, R) in js.items()}
        frames.append((tt, q))
    must = {round(kt, 4) for kt, _, _ in spec['keys']}
    return reduce(frames, must)

def reduce(frames, must):
    """Greedy: extend each straight blend while every sample in between stays within TOL."""
    keep = [0]
    i = 0
    n = len(frames)
    while i < n - 1:
        j = i + 1
        while j + 1 < n:
            if frames[j][0] in must: break
            ok = True
            ta, qa = frames[i]; tb, qb = frames[j + 1]
            for k in range(i + 1, j + 1):
                tk, qk = frames[k]
                a = (tk - ta) / (tb - ta)
                for jn, (pk, rk) in qk.items():
                    pa, ra = qa[jn]; pb_, rb = qb[jn]
                    if ra.dot(rb) < 0: rb = -rb
                    r = ra.slerp(rb, a)
                    if quat_angle(r, rk) > TOL: ok = False; break
                    if jn == 'Root' and ((pa.lerp(pb_, a)) - pk).length > TOL_POS: ok = False; break
                if not ok: break
            if not ok: break
            j += 1
        keep.append(j)
        i = j
    return [frames[k] for k in keep]

JOINT_ORDER = ['Root', 'Waist', 'Neck', 'RightShoulder', 'RightElbow', 'RightWrist', 'LeftShoulder', 'LeftElbow',
               'LeftWrist', 'RightHip', 'RightKnee', 'RightAnkle', 'LeftHip', 'LeftKnee', 'LeftAnkle']

def fmt(x, nd=3):
    s = ('%.' + str(nd) + 'f') % x
    s = s.rstrip('0').rstrip('.') if '.' in s else s
    return '0' if s in ('-0', '') else s

def row(q):
    vals = []
    for j in JOINT_ORDER:
        p, r = q[j]
        if r.w < 0: r = -r
        if j == 'Root': vals += [p.x, p.y, p.z]
        vals += [r.x, r.y, r.z, r.w]
    return '{ false, {' + ','.join(fmt(v) for v in vals) + '} }'

def lua_quat(R):
    q = R.to_quaternion()
    return q

def main():
    build_prop_meshes()
    clear_all()
    names = [n for n in INTROS if not ONLY or n in ONLY]
    base = 1
    plan = []
    scene.timeline_markers.clear()
    for name in names:
        spec = INTROS[name]
        author(name, spec, base)
        scene.timeline_markers.new('Intro_' + name, frame=int(base))
        plan.append((name, base))
        base += int((spec['keys'][-1][0] + 0.6) * FPS)
    scene.frame_start, scene.frame_end = 1, base
    # sample + reduce
    sampled = {}
    for name, b in plan:
        sampled[name] = sample(name, INTROS[name], b)
        print('intro %-8s keys %2d  samples %3d  len %.2fs' % (name, len(INTROS[name]['keys']), len(sampled[name]), sampled[name][-1][0]))
    if not ONLY:
        write(sampled)
    if RENDER:
        render(plan)
    # keep the authored actions with the file, then save it as intros.blend
    for o in (rig, CTRL_L, TARGET_L, bpy.data.objects['CtrlHandR'], bpy.data.objects['CtrlFootR'], bpy.data.objects['CtrlFootL']):
        if o.animation_data and o.animation_data.action:
            o.animation_data.action.name = 'Intros|' + o.name
            o.animation_data.action.use_fake_user = True
    txt = bpy.data.texts.get('build_intros') or bpy.data.texts.new('build_intros')
    txt.from_string(open(os.path.abspath(__file__)).read())
    if not ONLY:
        bpy.ops.wm.save_as_mainfile(filepath=GAME + 'art/intros/intros.blend', compress=True)
        print('saved', GAME + 'art/intros/intros.blend')

def write(sampled):
    os.makedirs(OUT, exist_ok=True)
    head = '--!strict\n-- stylua: ignore start\n-- GENERATED by art/intros/build_intros.py (Blender, art/intros/intros.blend). Do not edit by hand.\n'
    # poses, split across modules
    lines = []
    for name, frames in sampled.items():
        for i, (t, q) in enumerate(frames):
            lines.append('\t["I.%s@%02d"] = %s,' % (name, i, row(q)))
    mods, cur, size = [], [], 0
    for ln in lines:
        if size + len(ln) > MAX_CHARS and cur:
            mods.append(cur); cur, size = [], 0
        cur.append(ln); size += len(ln) + 1
    if cur: mods.append(cur)
    for f in os.listdir(OUT):
        if f.startswith('Poses'): os.remove(OUT + f)
    for k, m in enumerate(mods, 1):
        open(OUT + 'Poses%d.luau' % k, 'w').write(head + '-- Intro poses: { joints, values } rows decoded by Shared/Baked/Decode.\nreturn {\n' + '\n'.join(m) + '\n} :: { [string]: { any } }\n-- stylua: ignore end\n')
    # clips
    L = []
    for name, frames in sampled.items():
        spec = INTROS[name]
        L.append('\tIntro_%s = {' % name)
        L.append('\t\thold = %s, fadeOut = %s, twoHanded = false, intro = true, length = %s,' % (fmt(spec['hold']), fmt(spec['fade']), fmt(frames[-1][0])))
        L.append('\t\tsegments = {')
        prev = 0.0
        for i, (t, q) in enumerate(frames):
            ease = 'inOut' if i == 0 else 'linear'
            L.append('\t\t\t{ pose = "I.%s@%02d", duration = %s, ease = "%s" },' % (name, i, fmt(t - prev, 4), ease))
            prev = t
        L.append('\t\t},')
        L.append('\t},')
    open(OUT + 'Clips.luau', 'w').write(head + '-- Intro clip timelines (authored timing; Animator.play(model, "Intro_<Ref>")).\nreturn {\n' + '\n'.join(L) + '\n} :: { [string]: any }\n-- stylua: ignore end\n')
    # props
    P_ = []
    for pname, p in PROPS.items():
        q = Matrix(p['rot']).to_quaternion()
        P_.append('\t%s = { part = "%s", joint = "%s", cf = { %s }, size = Vector3.new(%s) },' % (
            pname, p['part'], p['joint'],
            ', '.join(fmt(v, 4) for v in (p['pos'].x, p['pos'].y, p['pos'].z, q.x, q.y, q.z, q.w)),
            ', '.join(fmt(v) for v in p['size'])))
    uses = ', '.join('%s = { %s }' % (n, ', '.join('"%s"' % x for x in INTROS[n]['props'])) for n in sampled if INTROS[n]['props'])
    open(OUT + 'Props.luau', 'w').write(head + '-- Intro props: offsets (x, y, z, qx, qy, qz, qw) from the joint pivot of the part they ride on\n-- (part.CFrame * joint.C1 * offset), matching the stand-ins on the rig in intros.blend.\nreturn {\n' + '\n'.join(P_) + '\n\tUses = { ' + uses + ' },\n} :: { [string]: any }\n-- stylua: ignore end\n')
    print('wrote', len(mods), 'pose modules,', sum(len(f) for f in sampled.values()), 'poses')

def render(plan):
    os.makedirs(RENDER, exist_ok=True)
    scene.render.engine = 'BLENDER_WORKBENCH'
    scene.display.shading.color_type = 'OBJECT'
    scene.display.shading.light = 'STUDIO'
    scene.render.resolution_x = 360; scene.render.resolution_y = 420
    scene.render.film_transparent = False
    cam = bpy.data.objects.get('IntroCam')
    if not cam:
        cam = bpy.data.objects.new('IntroCam', bpy.data.cameras.new('IntroCam')); scene.collection.objects.link(cam)
    floor = bpy.data.objects.get('IntroFloor')
    if not floor:
        bpy.ops.mesh.primitive_plane_add(size=12, location=(0, 0, G0 - 0.16)); floor = bpy.context.active_object; floor.name = 'IntroFloor'
        floor.color = (0.35, 0.4, 0.35, 1)
    for o in bpy.data.objects:
        if o.type == 'MESH' and o.name.startswith('P_'): o.color = (0.85, 0.8, 0.72, 1)
    for n, c in (('Blade', (0.75, 0.82, 0.95, 1)), ('Tsuba', (0.2, 0.2, 0.2, 1)), ('Tsuka', (0.15, 0.1, 0.1, 1))):
        bpy.data.objects[n].color = c
    scene.camera = cam
    cam.data.lens = 40
    views = {'front': B(4.5, 0.6, -10.5), 'side': B(10.5, 0.4, -1.5)}
    for name, base in plan:
        spec = INTROS[name]
        for pn in PROPS:
            bpy.data.objects['Prop' + pn].hide_render = pn not in spec['props']
        t1 = spec['keys'][-1][0]
        ts = [spec['keys'][0][0] + (t1 - spec['keys'][0][0]) * i / 7 for i in range(8)]
        ts = sorted(set([round(t, 3) for t in ts] + [round(k[0], 3) for k in spec['keys']]))
        for view, loc in views.items():
            cam.location = loc
            d = Vector((0, 0, -0.6)) - loc
            cam.rotation_mode = 'QUATERNION'; cam.rotation_quaternion = d.to_track_quat('-Z', 'Y')
            for t in ts:
                f = base + t * FPS
                scene.frame_set(int(f), subframe=f - int(f))
                scene.render.filepath = os.path.join(RENDER, '%s_%s_%05.2f.png' % (name, view, t))
                bpy.ops.render.render(write_still=True)

main()
