"""Plot ball candidates u(t), v(t) for a time span with cv2 (no matplotlib in the venv).
usage: plot.py OUT.png T0 T1 [anchors.json]"""
import sys, json
import numpy as np, cv2
import os
D = os.environ["COURT_SPEED_WORK"]  # work directory with frames.npz


def draw(out, t0, t1, extra=None, anchors=None, tracks=None):
    z = np.load(f"{D}/frames.npz"); C = z["cands"]
    t = C[:, 0] / 60.0
    sel = (t >= t0) & (t <= t1)
    Wd, Hp = 1800, 360
    img = np.full((Hp * 2 + 40, Wd, 3), 255, np.uint8)
    X = lambda tt: (40 + (tt - t0) / (t1 - t0) * (Wd - 60)).astype(int)
    Yu = lambda u: (10 + u / 1920 * (Hp - 20)).astype(int)
    Yv = lambda v: (Hp + 30 + (v - 450) / 550 * (Hp - 20)).astype(int)
    for s in np.arange(np.ceil(t0), t1, 1.0):
        cv2.line(img, (int(X(np.array(s))), 0), (int(X(np.array(s))), img.shape[0]), (225, 225, 225), 1)
        cv2.putText(img, f"{s:.0f}", (int(X(np.array(s))) + 2, Hp + 22), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (90, 90, 90), 1)
    for vv in (640, 680, 734, 870):
        y = int(Yv(np.array(vv))); cv2.line(img, (40, y), (Wd - 20, y), (200, 220, 255), 1)
        cv2.putText(img, str(vv), (2, y + 4), cv2.FONT_HERSHEY_SIMPLEX, 0.35, (90, 90, 90), 1)
    if anchors:
        for a in anchors:
            if t0 <= a["t"] <= t1:
                x = int(X(np.array(a["t"])))
                cv2.line(img, (x, 0), (x, img.shape[0]), (0, 160, 0), 1)
                cv2.putText(img, a.get("label", ""), (x + 2, 12), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (0, 130, 0), 1)
    for (fi, u, v, pk, mean, area, chosen) in C[sel]:
        col = (0, 0, 255) if chosen else (180, 120, 0)
        r = 2 if chosen else 1
        tt = np.array(fi / 60.0)
        cv2.circle(img, (int(X(tt)), int(Yu(np.array(u)))), r, col, -1)
        cv2.circle(img, (int(X(tt)), int(Yv(np.array(v)))), r, col, -1)
    if tracks:
        for tr in tracks:
            pts = np.array(tr["pts"])  # (frame, u, v)
            m = (pts[:, 0] / 60 >= t0) & (pts[:, 0] / 60 <= t1)
            if m.sum() < 2: continue
            col = tuple(int(c) for c in tr.get("color", (0, 0, 0)))
            pu = np.stack([X(pts[m, 0] / 60), Yu(pts[m, 1])], 1).astype(np.int32)
            pv = np.stack([X(pts[m, 0] / 60), Yv(pts[m, 2])], 1).astype(np.int32)
            cv2.polylines(img, [pu], False, col, 1); cv2.polylines(img, [pv], False, col, 1)
    if extra:
        for e in extra:
            x = int(X(np.array(e["t"])))
            cv2.drawMarker(img, (x, int(Yv(np.array(e["v"])))), e.get("color", (0, 0, 0)), cv2.MARKER_TRIANGLE_UP if e.get("kind") == "bounce" else cv2.MARKER_DIAMOND, 12, 2)
    cv2.putText(img, "u (px)", (Wd - 90, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 0), 1)
    cv2.putText(img, "v (px)", (Wd - 90, Hp + 50), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 0), 1)
    cv2.imwrite(out, img)


if __name__ == "__main__":
    anchors = None
    if len(sys.argv) > 4:
        T = json.load(open(sys.argv[4]))
        anchors = [dict(t=x["anchor"], label=("F" if x["hit"]["y"] > 11.9 else "N") + x["stroke"][:1]) for x in T]
    draw(sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), anchors=anchors)
