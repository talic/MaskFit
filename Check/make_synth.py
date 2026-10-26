# Renders synthetic TrueDepth-style depth maps of the CC0 head (Blender Human Base Meshes) from
# several head angles, in ARKit conventions, for checking DepthFusion off-device.
# Run: Blender -b --disable-autoexec human_base_meshes_bundle.blend --python make_synth.py -- Check/
import bpy, json, math, os, sys
import numpy as np
from mathutils import Vector, Matrix
from mathutils.bvhtree import BVHTree

out = sys.argv[sys.argv.index('--') + 1]
H = bpy.data.objects['GEO-head_sculpting_realistic']
eL = bpy.data.objects['GEO-head_sculpting_realistic.sclera.L'].matrix_world.translation.copy()
eR = bpy.data.objects['GEO-head_sculpting_realistic.sclera.R'].matrix_world.translation.copy()
X0, EY, EZ = (eL.x + eR.x) / 2, eL.y, eL.z
OY, OZ = EY + 0.06, EZ - 0.02  # face-anchor origin, same as export_face.py

dg = bpy.context.evaluated_depsgraph_get()
me = bpy.data.meshes.new_from_object(H.evaluated_get(dg))
bvh = BVHTree.FromPolygons([H.matrix_world @ v.co for v in me.vertices], [tuple(p.vertices) for p in me.polygons])

to_world = lambda f: Vector((f.x + X0, -f.z + OY, f.y + OZ))   # face space -> world point
dir_world = lambda f: Vector((f.x, -f.z, f.y))                  # face space -> world direction

W, HGT, FX, CX, CY = 240, 180, 220.0, 120.0, 90.0
target = Vector((0, -0.01, 0.06))
poses = [(0, 0), (20, 0), (-20, 0), (35, 0), (-35, 0), (0, 15), (0, -15), (20, 10), (-20, 10), (20, -10), (-20, -10)]
frames, depth = [], []
for yaw, pitch in poses:
    a, b = math.radians(yaw), math.radians(pitch)
    c = target + 0.35 * Vector((math.sin(a) * math.cos(b), math.sin(b), math.cos(a) * math.cos(b)))
    z = (c - target).normalized()
    x = Vector((0, 1, 0)).cross(z).normalized()
    y = z.cross(x)
    R = Matrix((x, y, z)).transposed()  # columns are camera axes in face space
    img = np.zeros((HGT, W), dtype=np.float32)
    for v in range(HGT):
        for u in range(W):
            cam = Vector(((u + 0.5 - CX) / FX, -((v + 0.5 - CY) / FX), -1.0))
            hit, *_ = bvh.ray_cast(to_world(c), dir_world(R @ cam).normalized(), 2.0)
            if hit:
                f = Vector((hit.x - X0, hit.z - OZ, -(hit.y - OY)))
                img[v, u] = (f - c).dot(-z)
    M = [[*x, 0], [*y, 0], [*z, 0], [*c, 1]]  # column-major 4x4
    frames.append({'yaw': yaw, 'pitch': pitch, 'cameraToFace': [round(e, 7) for col in M for e in col]})
    depth.append(img)
np.concatenate([d.ravel() for d in depth]).astype('<f4').tofile(os.path.join(out, 'synth.bin'))
json.dump({'width': W, 'height': HGT, 'fx': FX, 'fy': FX, 'cx': CX, 'cy': CY, 'frames': frames},
          open(os.path.join(out, 'synth.json'), 'w'))
print('SYNTH', len(frames), 'frames')
