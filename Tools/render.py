# Renders a clay head and a mask shaped from it, plus 2D landmark positions for the dimension overlays.
# Run: Blender -b --disable-autoexec human_base_meshes_bundle.blend --python render.py -- OUT_DIR [samples]
import bpy, bmesh, json, math, sys, os
from mathutils import Vector, Matrix
from mathutils.bvhtree import BVHTree
from bpy_extras.object_utils import world_to_camera_view

args = sys.argv[sys.argv.index('--') + 1:]
OUT = args[0]
SAMPLES = int(args[1]) if len(args) > 1 else 128
os.makedirs(OUT, exist_ok=True)
PAD, THICK = 0.004, 0.0025
W, HPX = 540, 690
ORTHO_FRONT, ORTHO_SIDE = 0.30, 0.37

scn = bpy.context.scene
H = bpy.data.objects['GEO-head_sculpting_realistic']
SL = bpy.data.objects['GEO-head_sculpting_realistic.sclera.L']
SR = bpy.data.objects['GEO-head_sculpting_realistic.sclera.R']

# Isolate the head in its own collection.
rc = bpy.data.collections.new('RenderSet')
scn.collection.children.link(rc)
for o in (H, SL, SR):
    rc.objects.link(o)
    o.hide_render = False
    o.hide_viewport = False
for lc in bpy.context.view_layer.layer_collection.children:
    if lc.collection is not rc:
        lc.exclude = True
for o in scn.collection.objects:
    o.hide_render = True

dg = bpy.context.evaluated_depsgraph_get()
dg.update()
hm = bpy.data.meshes.new_from_object(H.evaluated_get(dg))
MW = H.matrix_world
HV = [MW @ v.co for v in hm.vertices]
bvh = BVHTree.FromPolygons(HV, [tuple(p.vertices) for p in hm.polygons])

eL = SL.matrix_world.translation.copy()
eR = SR.matrix_world.translation.copy()
X0, EY, EZ = (eL.x + eR.x) / 2, eL.y, eL.z


def hit(tree, origin, direction):
    loc, _, _, _ = tree.ray_cast(Vector(origin), Vector(direction).normalized(), 2.0)
    return loc


def front_profile(tree, x, z0, z1, step=0.0005):
    out = []
    z = z0
    while z >= z1:
        p = hit(tree, (x, EY - 0.5, z), (0, 1, 0))
        if p:
            out.append(p)
        z -= step
    return out


prof = front_profile(bvh, X0, EZ + 0.08, EZ - 0.17)
in_z = lambda pts, a, b: [p for p in pts if a <= p.z <= b]
pron = min(in_z(prof, EZ - 0.08, EZ - 0.01), key=lambda p: p.y)
sell = max(in_z(prof, EZ - 0.012, EZ + 0.025), key=lambda p: p.y)
pog = min(in_z(prof, pron.z - 0.10, pron.z - 0.045), key=lambda p: p.y)
# Menton: lowest point under the chin, found with rays cast upward just behind the chin front.
mens = []
y = pog.y
while y <= pog.y + 0.022:
    p = hit(bvh, (X0, y, EZ - 0.4), (0, 0, 1))
    if p and p.z < pog.z:
        mens.append(p)
    y += 0.0005
ment = min(mens, key=lambda p: p.z)


def zygion(side):
    best = None
    z = EZ - 0.005
    while z >= EZ - 0.04:
        y = EY - 0.01
        while y <= EY + 0.045:
            p = hit(bvh, (X0 + side * 0.3, y, z), (-side, 0, 0))
            if p and (best is None or abs(p.x - X0) > abs(best.x - X0)):
                best = p
            y += 0.002
        z -= 0.001
    return best


zL, zR = zygion(1), zygion(-1)
cheek_z = pron.z + 0.005
chk = [hit(bvh, (X0 + s * 0.035, EY - 0.5, cheek_z), (0, 1, 0)) for s in (1, -1)]
cheek_y = (chk[0].y + chk[1].y) / 2

face = {
    'A': (eL - eR).length, 'B': (zL - zR).length, 'C': (sell - ment).length,
    'D': (sell - pron).length, 'E': cheek_y - pron.y,
}
print('FACE mm', {k: round(v * 1000, 1) for k, v in face.items()})

# ---- Mask: shrink-wrap hull of the face, offset by padding, then a shell with eye holes.
C0 = Vector((X0, EY + 0.075, EZ - 0.02))


def ang(p):
    d = p - C0
    return math.atan2(d.x, -d.y), math.atan2(d.z, math.hypot(d.x, d.y))


forehead = hit(bvh, (X0, EY - 0.5, EZ + 0.068), (0, 1, 0))
b_top = ang(forehead)[1]
b_bot = ang(ment)[1] - math.radians(2)
a_max = abs(ang(zL)[0]) + math.radians(9)
bc, bh = (b_top + b_bot) / 2, (b_top - b_bot) / 2
NR, NT = 80, 256
dirs, raw = [], []


def direction(a, b):
    return Vector((math.sin(a) * math.cos(b), -math.cos(a) * math.cos(b), math.sin(b)))


for i in range(NR + 1):
    s = i / NR
    for j in range(NT if i else 1):
        t = 2 * math.pi * j / NT
        b = bc + s * bh * math.sin(t)
        a = s * a_max * math.cos(t) * (1 + 0.10 * math.sin(t))
        d = direction(a, b)
        p = hit(bvh, C0 + d * 0.25, -d)
        dirs.append(d)
        rr = (p - C0).length if p else None
        raw.append(rr if rr and rr < 0.16 else None)
for k in range(len(raw)):
    if raw[k] is None:
        raw[k] = raw[k - NT] if k >= NT else 0.1

idx = lambda i, j: 0 if i == 0 else 1 + (i - 1) * NT + (j % NT)
faces = [(0, idx(1, j), idx(1, j + 1)) for j in range(NT)]
for i in range(1, NR):
    for j in range(NT):
        faces.append((idx(i, j), idx(i + 1, j), idx(i + 1, j + 1), idx(i, j + 1)))
nbrs = [set() for _ in raw]
for f in faces:
    for a_ in f:
        nbrs[a_].update(f)
for k in range(len(nbrs)):
    nbrs[k].discard(k)
    nbrs[k] = list(nbrs[k])
r = raw[:]
for _ in range(60):  # Smooth from outside: bridges eye sockets, nostrils and lips like a rigid shell.
    r = [max(0.5 * r[k] + 0.5 * sum(r[n] for n in nbrs[k]) / len(nbrs[k]), raw[k]) for k in range(len(r))]

bm = bmesh.new()
bv = [bm.verts.new(C0 + dirs[k] * r[k]) for k in range(len(r))]
for f in faces:
    bm.faces.new([bv[k] for k in f])
bm.normal_update()
bm.faces.ensure_lookup_table()
f0 = bm.faces[len(faces) // 2]
if f0.normal.dot(f0.calc_center_median() - C0) < 0:
    bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
    bm.normal_update()
for v in bm.verts:
    v.co += v.normal * PAD
inner_me = bpy.data.meshes.new('mask_inner')
bm.to_mesh(inner_me)
IV = [v.co.copy() for v in bm.verts]
ibvh = BVHTree.FromBMesh(bm)
bm.free()

# Eye-hole cutter: two elliptical cylinders along Y.
cb = bmesh.new()
for e, tilt in ((eL, -7), (eR, 7)):
    m = (Matrix.Translation((e.x, EY - 0.02, e.z + 0.001)) @ Matrix.Rotation(math.radians(tilt), 4, 'Y')
         @ Matrix.Rotation(math.radians(90), 4, 'X') @ Matrix.Diagonal((0.0165, 0.0088, 0.14, 1)))
    bmesh.ops.create_cone(cb, cap_ends=True, cap_tris=False, segments=96, radius1=1, radius2=1, depth=1, matrix=m)
cut_me = bpy.data.meshes.new('cutter')
cb.to_mesh(cut_me)
cb.free()
cutter = bpy.data.objects.new('cutter', cut_me)
rc.objects.link(cutter)
cutter.hide_render = True

mask_raw = bpy.data.objects.new('mask_raw', inner_me)
rc.objects.link(mask_raw)
so = mask_raw.modifiers.new('solid', 'SOLIDIFY')
so.thickness, so.offset, so.use_even_offset, so.use_quality_normals = THICK, 1.0, False, False
ss = mask_raw.modifiers.new('subd', 'SUBSURF')
ss.levels = ss.render_levels = 1
bo = mask_raw.modifiers.new('eyes', 'BOOLEAN')
bo.operation, bo.object, bo.solver = 'DIFFERENCE', cutter, 'MANIFOLD'
dg = bpy.context.evaluated_depsgraph_get()
dg.update()
mask_me = bpy.data.meshes.new_from_object(mask_raw.evaluated_get(dg))
mask_raw.hide_render = True


def finish_shading(bm_, angle=40):
    for f in bm_.faces:
        f.smooth = True
    for e in bm_.edges:
        if e.is_manifold and e.calc_face_angle(0) > math.radians(angle):
            e.smooth = False


bm = bmesh.new()
bm.from_mesh(mask_me)
finish_shading(bm)
bm.to_mesh(mask_me)
bm.free()
mask = bpy.data.objects.new('mask', mask_me)
rc.objects.link(mask)

# Section: keep the x >= X0 half and cap the cut.
sec_me = mask_me.copy()
bm = bmesh.new()
bm.from_mesh(sec_me)
res = bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], plane_co=(X0, 0, 0),
                             plane_no=(1, 0, 0), clear_inner=True)
cut_edges = [g for g in res['geom_cut'] if isinstance(g, bmesh.types.BMEdge)]
capf = bmesh.ops.holes_fill(bm, edges=cut_edges, sides=0)['faces']
capf = bmesh.ops.triangulate(bm, faces=capf, ngon_method='EAR_CLIP')['faces']
for f in capf:
    f.material_index, f.smooth = 1, False
for e in cut_edges:
    if e.is_valid:
        e.smooth = False
bm.to_mesh(sec_me)
bm.free()
section = bpy.data.objects.new('section', sec_me)
rc.objects.link(section)

# Inner-surface landmarks on the mask.
iprof = front_profile(ibvh, X0, EZ + 0.08, EZ - 0.17)
i_nose = min(iprof, key=lambda p: p.y)
i_sell = hit(ibvh, (X0, EY - 0.5, sell.z), (0, 1, 0))
i_chin = min([v for v in IV if abs(v.x - X0) < 0.0015], key=lambda v: v.z)
band = [v for v in IV if abs(v.z - zL.z) < 0.0015]
i_bL, i_bR = max(band, key=lambda v: v.x), min(band, key=lambda v: v.x)
ichk = [hit(ibvh, (X0 + s * 0.035, EY - 0.5, cheek_z), (0, 1, 0)) for s in (1, -1)]
i_cheek_y = (ichk[0].y + ichk[1].y) / 2
maskm = {
    'A': (eL - eR).length, 'B': (i_bL - i_bR).length, 'C': (i_sell - i_chin).length,
    'D': (i_sell - i_nose).length, 'E': i_cheek_y - i_nose.y,
}
print('MASK INNER mm', {k: round(v * 1000, 1) for k, v in maskm.items()})

# ---- Materials, lights, render.
def material(name, rgb, rough):
    m = bpy.data.materials.new(name)
    try:
        m.use_nodes = True
    except Exception:
        pass
    b = m.node_tree.nodes.get('Principled BSDF')
    b.inputs['Base Color'].default_value = (*rgb, 1)
    b.inputs['Roughness'].default_value = rough
    return m


clay = material('clay', (0.36, 0.35, 0.34), 0.6)
pla = material('pla', (0.55, 0.56, 0.58), 0.5)
cap = material('cap', (0.16, 0.17, 0.19), 0.7)
for o in (H, SL, SR):
    for sl in o.material_slots:
        sl.link = 'OBJECT'
        sl.material = clay
    if not o.material_slots:
        o.data.materials.append(clay)
mask_me.materials.append(pla)
sec_me.materials.append(pla)
sec_me.materials.append(cap)
hs = H.modifiers.new('smooth', 'SUBSURF')
hs.levels = hs.render_levels = 1

world = bpy.data.worlds.new('w')
scn.world = world
try:
    world.use_nodes = True
except Exception:
    pass
bg = world.node_tree.nodes.get('Background')
bg.inputs['Color'].default_value = (1, 1, 1, 1)
bg.inputs['Strength'].default_value = 0.15

scn.render.engine = 'CYCLES'
scn.cycles.samples = SAMPLES
scn.cycles.use_denoising = True
try:
    prefs = bpy.context.preferences.addons['cycles'].preferences
    prefs.compute_device_type = 'METAL'
    prefs.get_devices()
    for d in prefs.devices:
        d.use = True
    scn.cycles.device = 'GPU'
except Exception as ex:
    print('GPU unavailable:', ex)
scn.render.resolution_x, scn.render.resolution_y, scn.render.resolution_percentage = W, HPX, 100
scn.render.film_transparent = True
scn.render.image_settings.file_format = 'PNG'
scn.render.image_settings.color_mode = 'RGBA'
scn.view_settings.view_transform = 'AgX'
for look in ('AgX - Medium High Contrast', 'Medium High Contrast'):
    try:
        scn.view_settings.look = look
        break
    except Exception:
        pass

lights = []


def rig(cam, target):
    for o in lights:
        bpy.data.objects.remove(o)
    lights.clear()
    for name, local, energy, size in (('key', (-0.55, 0.5, -0.35), 40, 0.7), ('fill', (0.8, 0.05, -0.55), 6, 1.0),
                                      ('rim', (0.35, 0.55, -1.85), 30, 0.45)):
        ld = bpy.data.lights.new(name, 'AREA')
        ld.energy, ld.size = energy, size
        lo = bpy.data.objects.new(name, ld)
        rc.objects.link(lo)
        lo.location = cam.matrix_world @ Vector(local)
        lo.rotation_euler = (target - lo.location).to_track_quat('-Z', 'Y').to_euler()
        lights.append(lo)


def camera(name, loc, rot, ortho):
    cd = bpy.data.cameras.new(name)
    cd.type, cd.ortho_scale, cd.sensor_fit = 'ORTHO', ortho, 'VERTICAL'
    co = bpy.data.objects.new(name, cd)
    rc.objects.link(co)
    co.location, co.rotation_euler = loc, rot
    return co


ZC = EZ - 0.006
YC = pron.y + 0.101
views = {
    'face_front': (camera('cf', (X0, EY - 1, ZC), (math.pi / 2, 0, 0), ORTHO_FRONT), [H, SL, SR]),
    'mask_front': (camera('cm', (X0, EY - 1, ZC), (math.pi / 2, 0, 0), ORTHO_FRONT), [mask]),
    'face_side': (camera('cs', (X0 - 1, YC, ZC), (math.pi / 2, 0, -math.pi / 2), ORTHO_SIDE), [H, SL, SR]),
    'mask_section': (camera('cs2', (X0 - 1, YC, ZC), (math.pi / 2, 0, -math.pi / 2), ORTHO_SIDE), [section]),
}
bpy.context.view_layer.update()
pts = {
    'face_front': {'eyeL': eL, 'eyeR': eR, 'zygL': zL, 'zygR': zR, 'sell': sell, 'ment': ment, 'pron': pron},
    'mask_front': {'eyeL': eL, 'eyeR': eR, 'zygL': i_bL, 'zygR': i_bR, 'sell': i_sell, 'ment': i_chin, 'pron': i_nose},
    'face_side': {'cheek': Vector((X0, cheek_y, pron.z)), 'pron': pron},
    'mask_section': {'cheek': Vector((X0, i_cheek_y, i_nose.z)), 'pron': i_nose},
}
allobj = [H, SL, SR, mask, section]
out = {'size': [W, HPX], 'face_mm': {k: round(v * 1000, 1) for k, v in face.items()},
       'mask_inner_mm': {k: round(v * 1000, 1) for k, v in maskm.items()}, 'views': {}}
only = args[2].split(',') if len(args) > 2 else list(views)
for name, (cam, show) in views.items():
    scn.camera = cam
    out['views'][name] = {}
    for k, p in pts[name].items():
        c = world_to_camera_view(scn, cam, p)
        out['views'][name][k] = [round(c.x * W, 1), round((1 - c.y) * HPX, 1)]
    if name not in only:
        continue
    for o in allobj:
        o.hide_render = o not in show
    rig(cam, Vector((X0, EY + 0.03, ZC)))
    bpy.context.view_layer.update()
    scn.render.filepath = os.path.join(OUT, name + '.png')
    bpy.ops.render.render(write_still=True)
with open(os.path.join(OUT, 'landmarks.json'), 'w') as fh:
    json.dump(out, fh, indent=1)
print('DONE', json.dumps(out))
