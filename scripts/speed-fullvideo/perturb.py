"""Camera sensitivity: shift every fitted court line by U(-2, 2) px along its normal, refit, save."""
import sys, json, copy
import numpy as np
sys.path.insert(0, __file__.rsplit("/", 1)[0])
import camera as C
lines = json.load(open(sys.argv[1])); outdir = sys.argv[2]
use = ["near_baseline", "left_singles", "right_singles", "left_doubles", "right_doubles", "near_service", "center_service", "far_service"]
rng = np.random.default_rng(7)
for k in range(10):
    L = copy.deepcopy(lines)
    for n in use:
        off = rng.uniform(-2, 2); nv = np.array(L[n]["normal"])
        L[n]["point"] = (np.array(L[n]["point"]) + off * nv).tolist()
        L[n]["ends"] = [(np.array(e) + off * nv).tolist() for e in L[n]["ends"]]
    C._MASKS.clear()
    x0 = C.init(L, 0.10); x, r, J = C.lm(lambda p: C.line_residuals(p, L, use, 0.10), x0)
    Cc = C.camera_center(x)
    json.dump(dict(f=x[0], rvec=x[1:4].tolist(), tvec=x[4:7].tolist(), principal=[960, 540], camera_center_m=Cc.tolist()), open(f"{outdir}/cam{k}.json", "w"))
    print(k, "f %.1f center %s" % (x[0], np.round(Cc, 2)), flush=True)
