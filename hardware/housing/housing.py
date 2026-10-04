"""ESP32 face housing v2 — 2-piece (front bezel + rear body), rear USB-C exit.
Outer shape reproduces 'Part Studio 2 - Part 1' (sphere R30.82, 2 mm wall, front cut z=14.43,
flat desk face). Units: mm. Front (display) faces +z; desk flat face is on +y; rear = -z.
Edit the PARAMETERS block and re-run:  python3 housing.py
"""
import numpy as np
import manifold3d as mf
from manifold3d import Manifold as M

# ---------------- PARAMETERS ----------------
SEG = 160                       # sphere/cylinder resolution
R0, WALL = 30.82, 2.0           # outer sphere radius, wall
Z_FRONT, Z_CAV = 14.43, 12.1    # front face, underside of front plate
N_FLAT = np.array([0, 0.967, -0.256]); N_FLAT /= np.linalg.norm(N_FLAT)
D_FLAT = 25.48                  # flat desk face offset along N_FLAT
DISP_C = (0.0, -4.9)            # display centre (x, y)
WIN_R = 16.9                    # front window radius (active area R16.2)
POCKET_R, POCKET_Z = 18.1, 13.9 # glass pocket radius, pocket top (depth = 1.8)
# split / joint
Z_SPLIT = 5.0                   # bezel | body split plane
LIP_H, LIP_T, CLR = 4.0, 1.2, 0.15   # lip height above split, lip thickness, radial clearance
SNAP = True; BUMP_R, BUMP_PROTRUDE = 0.8, 0.35; GROOVE_DEPTH = 0.6
# display clamp ribs (press on PCB back)
PCB_R, PCB_T = 19.0, 1.6        # display PCB radius, thickness  <-- measure
RIB_GAP = 0.2                   # gap between rib top and PCB back (add foam if loose)
RIB_OVERLAP, RIB_W = 1.5, 5.0
# USB-C / XIAO ESP32S3 — flush port, wires soldered directly (no headers/dupont)
# board stands vertical on the rear axis, USB-C receptacle face flush with a small flat land
USB_X, USB_Y = 0.0, 2.5         # receptacle centre (slightly toward desk so the board+wire stack is centred)
USB_W, USB_H = 8.94 + 0.7, 3.26 + 0.7   # receptacle opening (stadium), 0.35 clr/side for FDM hole shrink
USB_OVH = 1.3                   # receptacle overhang past board edge  <-- measure
REAR_CONE = False               # replace sphere below 45 deg latitude with a 45 deg cone -> support-free print
Z_LAND = -29.8                  # floor of the shallow overmold recess; USB face flush with it
RECESS_W, RECESS_H = 14.0, 8.5  # recess (cable overmold) size, max depth ~1 mm, fades out into the sphere
Z_BOARD_EDGE = Z_LAND + USB_OVH # board edge rests on pocket floor -> receptacle face flush
XIAO_W, XIAO_T = 17.8, 1.0      # board width, thickness  <-- measure
REC_TOP = 3.3                   # receptacle/buttons height above board top face
BOSS_TOP = -27.0
RAIL_TOP = -14.0
OUT = "."
# ---------------------------------------------

def big_halfspace_keep(normal, offset):
    """returns function trimming a manifold to keep dot(n,x) <= offset"""
    n = np.asarray(normal, float)
    return lambda m: m.trim_by_plane((-n).tolist(), -offset)

def S(t):
    """outer envelope offset inward by t"""
    s = M.sphere(R0 - t, SEG)
    return big_halfspace_keep(N_FLAT, D_FLAT - t)(s)

def zband(m, z0, z1):
    return m.trim_by_plane([0, 0, 1], z0).trim_by_plane([0, 0, -1], -z1)

def box(x0, x1, y0, y1, z0, z1):
    return M.cube([x1 - x0, y1 - y0, z1 - z0]).translate([x0, y0, z0])

def cyl(r, z0, z1, c=(0, 0)):
    return M.cylinder(z1 - z0, r, r, SEG).translate([c[0], c[1], z0])

cx, cy = DISP_C
# ---- base shell (original design) ----
outer = S(0)
if REAR_CONE:
    zt = -R0 / np.sqrt(2)                      # 45-deg tangent latitude
    r_bot = -zt - (zt + R0)                    # cone radius at z = -R0
    cone = M.cylinder(zt + R0, r_bot, -zt, SEG).translate([0, 0, -R0])
    outer = outer + big_halfspace_keep(N_FLAT, D_FLAT)(cone)
outer = zband(outer, -R0, Z_FRONT)
cavity = zband(S(WALL), -R0, Z_CAV)
window = cyl(WIN_R, Z_CAV - 1, Z_FRONT + 1, DISP_C)
pocket = M.hull(M.compose([cyl(POCKET_R, Z_CAV - 0.5, POCKET_Z, DISP_C),
                           box(-7, 7, 15.9, 16.0, Z_CAV - 0.5, POCKET_Z)]))
hdr_slot = box(-9, 9, 18.7, 21.2, Z_CAV - 0.5, POCKET_Z)
shell = outer - cavity - window - pocket - hdr_slot

# ---- split ----
bezel = zband(shell, Z_SPLIT, Z_FRONT + 1)
body = zband(shell, -R0 - 1, Z_SPLIT)

# lip on body (slides inside bezel wall)
lip = zband(S(WALL + CLR) - S(WALL + CLR + LIP_T), Z_SPLIT - 0.01, Z_SPLIT + LIP_H)
lip_root = zband(S(WALL - 0.1) - S(WALL + CLR + LIP_T), Z_SPLIT - 3, Z_SPLIT)
# 45-deg stepped chamfer under the lip root (no flat overhang ledge)
chamfer = M.compose([zband(S(WALL - 0.1) - S(WALL + CLR + LIP_T - 0.45 * (k + 1)),
                           Z_SPLIT - 3 - 0.5 * (k + 1), Z_SPLIT - 3 - 0.5 * k) for k in range(3)])
body = body + lip + lip_root + chamfer

if SNAP:
    zb = Z_SPLIT + LIP_H / 2 + 0.3
    groove = zband(S(WALL - GROOVE_DEPTH) - S(WALL + 0.3), zb - 1.0, zb + 1.0)
    bezel = bezel - groove
    rlip = np.sqrt((R0 - WALL - CLR) ** 2 - zb ** 2)
    bumps = []
    for a in (45, 135, 225, 315):
        r = rlip + BUMP_PROTRUDE - BUMP_R
        bumps.append(M.sphere(BUMP_R, 32).translate([r * np.cos(np.radians(a)), r * np.sin(np.radians(a)), zb]))
    body = body + M.compose(bumps)

# display clamp ribs
rib_top = Z_CAV - PCB_T - RIB_GAP
ribs = []
for ang in (0, 180, 270):
    top = box(PCB_R - RIB_OVERLAP, 30, -RIB_W / 2, RIB_W / 2, Z_SPLIT, rib_top)
    foot = box(29.5, 30, -RIB_W / 2, RIB_W / 2, Z_SPLIT - 12, Z_SPLIT)   # 45-deg-ish gusset to the wall
    rib = M.hull(M.compose([top, foot])).rotate([0, 0, ang]).translate([cx, cy, 0])
    ribs.append(zband(rib, Z_SPLIT, rib_top) ^ S(WALL + CLR))
    ribs.append(zband(rib, -R0, Z_SPLIT) ^ S(WALL - 0.1))
ribs = M.compose(ribs)
body = body + ribs

# USB-C: flat land, stadium opening, board pocket, guide rails
yb_top = USB_Y - USB_H / 2 + 0.15            # XIAO top face (receptacle sits on it)
rr = RECESS_H / 2
land = M.hull(M.compose([cyl(rr, -R0 - 5, Z_LAND, (USB_X - RECESS_W / 2 + rr, USB_Y)),
                         cyl(rr, -R0 - 5, Z_LAND, (USB_X + RECESS_W / 2 - rr, USB_Y))]))
boss = box(-11.5, 11.5, yb_top - XIAO_T - 0.8, yb_top + REC_TOP + 1.5, -R0 - 1, BOSS_TOP) ^ S(0.6)
rails = M.compose([box(9.05, 11.5, yb_top - XIAO_T - 1.5, yb_top + 1.5, BOSS_TOP - 1, RAIL_TOP),
                   box(-11.5, -9.05, yb_top - XIAO_T - 1.5, yb_top + 1.5, BOSS_TOP - 1, RAIL_TOP)]) ^ S(WALL - 0.1)
body = body + boss + rails
r = USB_H / 2
stadium = M.hull(M.compose([cyl(r, -R0 - 5, Z_BOARD_EDGE + 0.5, (USB_X - USB_W / 2 + r, USB_Y)),
                            cyl(r, -R0 - 5, Z_BOARD_EDGE + 0.5, (USB_X + USB_W / 2 - r, USB_Y))]))
pocket_x = box(-XIAO_W / 2 - 0.2, XIAO_W / 2 + 0.2, yb_top - XIAO_T - 0.2, yb_top + REC_TOP + 0.2,
               Z_BOARD_EDGE, BOSS_TOP + 0.1)
body = body - land - stadium - pocket_x

def save(m, name):
    mesh = m.to_mesh()
    import trimesh
    t = trimesh.Trimesh(mesh.vert_properties[:, :3], mesh.tri_verts)
    t.export(f"{OUT}/{name}")
    return t

if __name__ == "__main__":
    tb = save(bezel, "esp32_face_bezel.stl")
    tr = save(body, "esp32_face_body.stl")
    for n, t, m in (("bezel", tb, bezel), ("body", tr, body)):
        print(n, "watertight", t.is_watertight, "genus", m.genus(), "extents", t.extents.round(2),
              "vol", round(t.volume, 1), "PLA g", round(t.volume * 1.24e-3, 1))
    print("interference bezel/body vol:", round((bezel ^ body).volume(), 3))
