# Exports the front of the CC0 head as a face mesh in ARKit face-anchor space, plus the
# A–E values measured by ray casting in render.py, for checking FaceMeasurer off-device.
# Run: Blender -b --disable-autoexec human_base_meshes_bundle.blend --python export_face.py -- OUT.json LANDMARKS.json
import bpy, json, sys

out_path, landmarks_path = sys.argv[sys.argv.index('--') + 1:][:2]
H = bpy.data.objects['GEO-head_sculpting_realistic']
eL = bpy.data.objects['GEO-head_sculpting_realistic.sclera.L'].matrix_world.translation.copy()
eR = bpy.data.objects['GEO-head_sculpting_realistic.sclera.R'].matrix_world.translation.copy()
X0, EY, EZ = (eL.x + eR.x) / 2, eL.y, eL.z
OY, OZ = EY + 0.06, EZ - 0.02  # face-anchor origin roughly mid-head

dg = bpy.context.evaluated_depsgraph_get()
me = bpy.data.meshes.new_from_object(H.evaluated_get(dg))
me.calc_loop_triangles()
W = [H.matrix_world @ v.co for v in me.vertices]


def ark(p):  # world (face looks down -Y) -> ARKit face space
    return [p.x - X0, p.z - OZ, -(p.y - OY)]


keep = [i for i, p in enumerate(W) if p.y < EY + 0.055 and EZ - 0.17 < p.z < EZ + 0.09 and abs(p.x - X0) < 0.085]
remap = {old: new for new, old in enumerate(keep)}
tris = []
for t in me.loop_triangles:
    if all(i in remap for i in t.vertices):
        tris += [remap[i] for i in t.vertices]
expected = json.load(open(landmarks_path))['face_mm']
json.dump({'vertices': [[round(c, 6) for c in ark(W[i])] for i in keep], 'triangles': tris,
           'leftEye': ark(eL), 'rightEye': ark(eR), 'expected': expected}, open(out_path, 'w'))
print('EXPORTED', len(keep), 'verts', len(tris) // 3, 'tris')
