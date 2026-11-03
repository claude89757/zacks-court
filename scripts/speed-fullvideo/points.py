"""Keep only hits that belong to a point, then re-match against the S家 rows (tuned on test.MOV).

usage: points.py shots-final.json OUT.json

A point opens with a serve (strokes.py v2 rule). Later hits join it while the hitter side alternates and
each hit comes 0.5-3.0 s after the last kept one. A same-side hit 1.6-5.0 s after the last kept one is kept
too (the other player's hit in between was missed); a quicker same-side hit is skipped.
A new serve from the side that served opens a new point (second serve or the next point). A hit without
a hitter side joins as the expected side when its timing fits. Everything else (fed balls, pre-serve ball
bounces, warm-up hits) is dropped. Two serves from the same side less than 3 s apart keep the later one
(a toss or a pre-serve bounce looked like a serve).
"""
import sys, json
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from shots import match

MIN_GAP, MAX_GAP = 0.5, 3.0
SKIP_GAP = (1.6, 5.0)  # same side again: one missed hit in between


def side_of(s):
    return s.get("stroke_detail", {}).get("side") or s.get("hitter_side")


def points(shots):
    order = sorted(range(len(shots)), key=lambda i: shots[i]["t_hit"])
    keep, cur = [], None  # cur = dict(server, last_t, last_side, idx)
    for i in order:
        s = shots[i]; t = s["t_hit"]; side = side_of(s)
        if cur is not None and t - cur["last_t"] > SKIP_GAP[1]:
            cur = None
        if s.get("stroke") == "发球" and side is not None:
            if cur is not None and len(cur["idx"]) == 1 and cur["server"] == side and t - cur["last_t"] < MAX_GAP:
                keep.remove(cur["idx"][0])  # the earlier "serve" was a toss or a ball bounce
            cur = dict(server=side, last_t=t, last_side=side, idx=[i]); keep.append(i)
            continue
        if cur is None:
            continue
        gap = t - cur["last_t"]
        if gap < MIN_GAP:
            continue
        want = "far" if cur["last_side"] == "near" else "near"
        if (side is None or side == want) and gap <= MAX_GAP:
            cur.update(last_t=t, last_side=want); cur["idx"].append(i); keep.append(i)
        elif side == cur["last_side"] and SKIP_GAP[0] <= gap <= SKIP_GAP[1]:
            cur.update(last_t=t); cur["idx"].append(i); keep.append(i)
    return sorted(keep, key=lambda i: shots[i]["t_hit"])


if __name__ == "__main__":
    d = json.load(open(sys.argv[1]))
    kept = [d["shots"][i] for i in points(d["shots"])]
    m = match(kept, d["teacher"])
    json.dump(dict(shots=kept, teacher=d["teacher"], match={str(k): v for k, v in m.items()}),
              open(sys.argv[2], "w"), indent=1, ensure_ascii=False, default=float)
    print("hits", len(d["shots"]), "kept", len(kept), "matched rows", len(m), "extra kept", len(kept) - len(m))
