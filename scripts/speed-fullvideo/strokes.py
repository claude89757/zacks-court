"""Rule-based stroke type for detected hits (frozen rules, right-handed default).

usage: strokes.py MERGED_shots.json JUNCTIONS.pkl[,JUNCTIONS.pkl...] CAMERA.json[,CAMERA.json...] OUT.json

Per hit, from the ball's contact pixel, the hitter's Vision box and the ball tracks:
- side: hitter feet ground y < 11.885 m -> near, else far.
- serve (never when another flight crossed the net in the 3 s before: a serve opens a point):
  (a) the hit follows a toss (the incoming piece lasts >= 0.25 s, moves mostly vertically,
  |du| <= 0.35 * v range, and turns from rising to falling inside the piece), whoever the nearest box
  is; or (b) no toss seen, hitter feet behind/near their baseline (near y <= 1.0 m, far y >= 22.77 m),
  fitted contact height >= 2.2 m and no hit from the other side in the 2.5 s before.
- volley (non-serve): hitter inside their service line (|y - 11.885| <= 6.4 m), a hit from the other
  side within 2.0 s before, and no bounce on the hitter's side in between.
- forehand/backhand (non-serve): right-handed. Near hitter (seen from behind): ball right of the box
  center = forehand. Far hitter (seen from the front): ball left of the box center = forehand.
  |offset| < 0.1 box width -> unknown.
No hitter box -> unknown ("—").

v2 serve rule (COURT_STROKES_V2=1, tuned on test.MOV after v1): the fed balls between points made the
"no rally before" test unreliable, and the fitted contact height is noisy. A serve is instead a hit whose
hitter stands at their own baseline (-1.0 m inside to 0.8 m behind it; rally players stood 1.3-2.5 m
behind on test.MOV) with the contact pixel at least 0.2 box heights above the box top, or a toss with the
hitter at the baseline. No rally test.
"""
import os, sys, json, pickle
import numpy as np
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from flight import Camera
from shots import is_toss

NET_Y = 11.885
BASELINE_Y = 23.77
V2 = os.environ.get("COURT_STROKES_V2") == "1"


def serve_v2(side, feet, box, uv, toss):
    behind = -feet[1] if side == "near" else feet[1] - BASELINE_Y
    if not -1.0 <= behind <= 0.8:
        return False
    above = (box[1] - uv[1]) / max(box[3] - box[1], 1)
    return above >= 0.2 or bool(toss)


def classify(shots, bounces, cams):
    out = []
    order = sorted(range(len(shots)), key=lambda i: shots[i]["t_hit"])
    sides = {}
    for i in order:
        s = shots[i]; box = s.get("hitter_box")
        cam = cams[s.get("segment", 0)]
        if box:
            feet = cam.on_plane_z(np.array([[(box[0] + box[2]) / 2, box[3]]]), 0.0)[0]
            sides[i] = ("near" if feet[1] < NET_Y else "far", feet)
        else:
            sides[i] = (None, None)
    for n, i in enumerate(order):
        s = shots[i]; side, feet = sides[i]; box = s.get("hitter_box"); uv = s.get("contact_uv")
        r = dict(index=i, t_hit=s["t_hit"], side=side)
        # a serve opens a point: no other flight that crossed the net in the 3 s before
        rally = any(j != i and "speed_kmh" in shots[j] and 0.3 <= s["t_hit"] - shots[j]["t_hit"] <= 3.0 for j in order[:n])
        r["rally_before"] = bool(rally)
        if V2:
            if side is None or uv is None:
                r.update(stroke=None, reason="no hitter found"); out.append(r); continue
            if serve_v2(side, feet, box, uv, is_toss(s.get("incoming"))):
                r.update(stroke="发球", feet=feet.tolist()); out.append(r); continue
        elif is_toss(s.get("incoming")) and not rally:
            # a toss only happens on a serve; the box near a toss can be the server's partner at the net
            if side is None:
                y = s.get("fit_hit", [None, None, None])[1] if s.get("fit_hit") else None
                if y is None and s.get("bounce_ground"):
                    y = 23.77 - s["bounce_ground"][1]
                r["side"] = None if y is None else ("near" if y < NET_Y else "far")
            r.update(stroke="发球", toss=True); out.append(r); continue
        if side is None or uv is None:
            r.update(stroke=None, reason="no hitter found"); out.append(r); continue
        prev = [sides[j][0] for j in order[:n] if s["t_hit"] - shots[j]["t_hit"] <= 2.5 and sides[j][0] not in (None, side)]
        prev_t = [shots[j]["t_hit"] for j in order[:n] if sides[j][0] not in (None, side) and s["t_hit"] - shots[j]["t_hit"] <= 2.0]
        at_baseline = feet[1] <= 1.0 if side == "near" else feet[1] >= 22.77
        toss = is_toss(s.get("incoming"))
        z_hit = s.get("fit_hit", [None, None, None])[2]
        serve = (not V2) and at_baseline and not rally and (toss or (z_hit is not None and z_hit >= 2.2 and not prev))
        r.update(at_baseline=bool(at_baseline), toss=bool(toss), z_hit=z_hit, feet=feet.tolist())
        if serve:
            r["stroke"] = "发球"; out.append(r); continue
        w = box[2] - box[0]; off = uv[0] - (box[0] + box[2]) / 2
        r["offset_px"] = off
        if abs(off) < 0.1 * w:
            r.update(stroke=None, reason="ball too close to the body centre"); out.append(r); continue
        fore = off > 0 if side == "near" else off < 0
        base = "正手" if fore else "反手"
        volley = False
        if abs(feet[1] - NET_Y) <= 6.4 and prev_t:
            t0 = max(prev_t)
            own = [b for b in bounces if t0 < b[0] < s["t_hit"] and ((b[1] < NET_Y) == (side == "near"))]
            volley = not own
        r["stroke"] = base + (" 截击" if volley else "")
        out.append(r)
    return out


if __name__ == "__main__":
    d = json.load(open(sys.argv[1]))
    bounces = []
    for p in sys.argv[2].split(","):
        J = pickle.load(open(p, "rb"))
        bounces += [(l["t"], l["ground"][1]) for l in J["links"] if l.get("bounce")]
    cams = [Camera(p) for p in sys.argv[3].split(",")]
    res = classify(d["shots"], bounces, cams)
    by = {r["index"]: r for r in res}
    for i, s in enumerate(d["shots"]):
        s["stroke"] = by[i].get("stroke"); s["stroke_detail"] = {k: v for k, v in by[i].items() if k not in ("index",)}
    json.dump(d, open(sys.argv[4], "w"), indent=1, ensure_ascii=False, default=float)
    print("hits", len(res), "with stroke", sum(1 for r in res if r.get("stroke")))
