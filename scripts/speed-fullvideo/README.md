# Full-video speed prototype (development only)

Offline Python prototype that turns the native TrackNetV3 full-video candidates into per-shot
speeds and compares them with S家 App rows. It is research code, not the App path; results on
`double-test-003` are development numbers (that video was used for training and inspected while
designing). Protocol, outputs and results live in the private evidence folder
`.local/speed-training/takeover-speed-20261029/` (not in Git).

Python: the numpy/OpenCV venv under `.local/speed-training/tracknet-smoke-20261028/venv`.

```sh
export COURT_SPEED_VIDEO=/abs/video.MOV COURT_SPEED_WORK=/abs/work
python extract.py RUN_DIR/report.json $COURT_SPEED_WORK            # per-frame candidates -> frames.npz
python median.py 44848 $COURT_SPEED_WORK/median.png                 # static-camera background
python lines.py $COURT_SPEED_WORK/median.png $COURT_SPEED_WORK/lines.json   # ROUGH endpoints are per court
python camera.py $COURT_SPEED_WORK/lines.json $COURT_SPEED_WORK/camera.json 0.10
# or, with no hand-given endpoints: automatic court calibration from a 20 s window (refuses with a reason
# when the near baseline and near service line are not both visible). Writes a camera only when found.
python court_auto.py $COURT_SPEED_VIDEO 90 $COURT_SPEED_WORK/auto.json 20 $COURT_SPEED_WORK/auto-overlay.jpg
python make_tracks.py $COURT_SPEED_WORK/frames.npz $COURT_SPEED_WORK/tracks.pkl
COURT_SPEED_CAMERA=$COURT_SPEED_WORK/camera.json python junctions.py $COURT_SPEED_WORK/tracks.pkl $COURT_SPEED_WORK/junctions.pkl
swift people.swift $COURT_SPEED_VIDEO FRAMES.txt $COURT_SPEED_WORK/people.json   # frames = junction and piece-start frames
COURT_SPEED_SOURCE_SHA256=<video sha> python shots.py $COURT_SPEED_WORK/junctions.pkl \
  $COURT_SPEED_WORK/people.json $COURT_SPEED_WORK/camera.json SHOTS.jsonl $COURT_SPEED_WORK
python report.py $COURT_SPEED_WORK/shots.json table.md metrics.json
python perturb.py $COURT_SPEED_WORK/lines.json CAM_DIR              # +-2 px line shifts -> 10 cameras
```

Stages: camera from painted court lines (pinhole, principal point at the center, no distortion) →
2D tracks → smooth pieces and junctions → bounce test (both sides fit a flight anchored at the
junction's ground point) → hit = non-bounce junction near a Vision person box → per-shot 3D flight
(gravity + drag, bounce anchor and hitter-depth prior) → S家 endpoint speed
`|(P_net - P_hit)/T + (0, 0, gT/2)|` → one-to-one match within 0.6 s of the S家 App anchor.

## Singles run with stroke types (test.MOV, development tuning)

A video whose camera moved is split into segments, each with its own camera. Per segment:
`make_tracks.py FRAMES.npz TRACKS.pkl T0 T1` (seconds), `junctions.py`, then person detection on the
far half that the camera sees:

```sh
python people_frames.py FRAMES.txt SEG/junctions.pkl               # junction and piece-start frames
python far_crops.py SEG/camera.json SEG/crops.json                 # [x, y, w, h] crops of the far half
swift people.swift $COURT_SPEED_VIDEO FRAMES.txt SEG/people.json SEG/crops.json
python shots.py SEG/junctions.pkl PEOPLE.json SEG/camera.json SHOTS.jsonl OUT/SEG
python merge.py OUT/shots-merged.json OUT/A/shots.json OUT/B/shots.json
COURT_STROKES_V2=1 python strokes.py OUT/shots-merged.json A/junctions.pkl,B/junctions.pkl \
  A/camera.json,B/camera.json OUT/shots-final.json
COURT_SPEED_REQUIRE_BOUNCE=1 python report.py OUT/shots-final.json table.md metrics.json
```

`PEOPLE.json` is the per-segment person files merged into one map (frame keys do not overlap).

`shots.py` version flags (all off by default; v1 is the frozen run):

| Flag | Effect |
| --- | --- |
| `COURT_SPEED_V2=1` | hitter-depth prior searched back up to 0.4 s from the first observation; drop points > 15 px |
| `COURT_SPEED_REACH_ALL=1` | with V2, the backward search applies to every hit kind, not only chain starts |
| `COURT_SPEED_V3=1` (`COURT_SPEED_V3_TRIM=0`) | refit with the bounce anchor alone when the anchored fit misses (no trimming) |
| `COURT_SPEED_V4=1` | hitter on the side opposite the bounce |
| `COURT_SPEED_V5=1` | hitter side from the nearest person box (1.5 box heights), else the ball's image direction |
| `COURT_EVENTS_V2=1` | junctions.py: link across gaps up to 24 frames, store a second-chance bounce test and a one-flight continuity fit; shots.py: demote junctions turning less than `COURT_EVENTS_TURN_MIN` degrees (default 50; 0 turns it off) |
| `COURT_EVENTS_REVERSAL_HITS=1` | with events v2, a non-bounce junction turning >= 120 degrees is a hit even without a person box |
| `COURT_EVENTS_SECOND_BOUNCE=1` | honour second-chance bounces (not adopted) |

`strokes.py` with `COURT_STROKES_V2=1` calls a serve when the hitter stands at their baseline
(-1.0 m inside to 0.8 m behind) with the contact pixel >= 0.2 box heights above the box top, or after a
toss. `points.py` is an experiment that keeps only hits inside points; it was not adopted.
`pose.swift` returns Apple Vision body joints at given frames for later stroke-side work.
The current best run (v13) uses V2 + REACH_ALL + V3 (no trim) + V4 + V5, junctions built with
`COURT_EVENTS_V2=1`, shots with `COURT_EVENTS_V2=1 COURT_EVENTS_REVERSAL_HITS=1 COURT_EVENTS_TURN_MIN=0`,
and strokes v2.

## Automatic court calibration and the Swift chain

- `court_auto.py` (+ `court_frames.py` for the key-frame median, `court_evaluate.py` to compare against
  reference cameras on cached medians): white top-hat, Hough lines, 2×2 line search against the ITF model,
  closed-form camera, then `lines.py` refine and `camera.py` LM. Output `{"found", "quality", "reason",
  "camera", ...}`; on refusal the camera is stored as `rejected_camera`. Results and limits are in
  `docs/model-replacement-design.md` §2.1.
- Swift port: `IndependentCourtCalibrator` in `Sources/CourtCore/IndependentAnalysis/Court/`.
  `court-analyze court-calibrate MEDIAN.png [MORE.png ...] OUT.json [--trace TRACE.json]` runs it on a median
  (or on several frames, median first); `--trace` writes every stage in the layout of a Python dump for parity
  checks. On the 46 cached medians every stage matches `court_auto.py` (docs/verification.md, 2026-10-29).
- The Swift port of the shot rules is `court-analyze independent-shots`; `--person-frames` lists the frames
  `people.swift` needs, and `--live` replays the bounded-lag chain.

