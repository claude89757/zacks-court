# Independent model binaries

`tracknetv3-base-v1/TrackNetV3Base.mlpackage` is the byte-identical float32 Core ML conversion recorded by `assets/independent-models/tracknetv3-base-v1/manifest.json`. Its binary model and weights use Git LFS. Run `git lfs pull` after cloning.

The original MIT notice and immutable research catalog remain in `assets/independent-models/tracknetv3-base-v1/`. They identify the official TrackNetV3 checkpoint and conversion; they do not certify tennis speed accuracy. The catalog's README describes the original offline conversion preprocessing. The current prefix-background native experiment has its own recorded runtime policy in `docs/speed-model-training.md`.

`scripts/prepare-independent-app-models.sh` verifies and stages the model with its catalog, documentation and license. `COURT_MODEL_SET=independent` selects this resource set when building the Mac App or generating the iOS project. That mode (the default) excludes the S家 reference model resources, which are not in Git and which a developer supplies locally in `.local/s-models` for `COURT_MODEL_SET=both` or `sjia`. It remains an experimental resource set; successful packaging does not establish a complete speed estimator or device accuracy.
