#!/usr/bin/env python3
"""Convert a trained court-net.pt to a Core ML package (FP16 weights and compute, float32 output).

usage: export.py court-net.pt OUT.mlpackage
"""
import os, sys
import numpy as np, torch, coremltools as ct

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from train import CourtNet, IN_W, IN_H, NK  # noqa: E402


def main():
    src, out = sys.argv[1], sys.argv[2]
    net = CourtNet(); net.load_state_dict(torch.load(src, map_location="cpu")); net.eval()
    example = torch.rand(1, 3, IN_H, IN_W)
    traced = torch.jit.trace(net, example)
    model = ct.convert(traced, inputs=[ct.TensorType(name="image", shape=example.shape, dtype=np.float32)],
                       outputs=[ct.TensorType(name="heatmaps", dtype=np.float32)],
                       compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.iOS17,
                       convert_to="mlprogram")
    model.short_description = "Court keypoints (14 heatmaps); trained on automatic labels from the geometric court calibrator"
    model.license = "MIT (Zacks Court)"
    model.save(out)
    with torch.no_grad():
        ref = net(example).numpy()
    got = model.predict({"image": example.numpy()})["heatmaps"]
    print("max |coreml - torch| =", float(np.abs(got - ref).max()), "shape", got.shape)


if __name__ == "__main__":
    main()
