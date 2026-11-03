"""Convert the traced MIT TrackNetV3 base model to an FP16 Core ML ML Program for the Neural Engine.

Same contract as the FP32 package in assets/independent-models/tracknetv3-base-v1 (input `frames`
float32 [1,27,288,512], output `heatmaps` float32 [1,8,288,512]); only the compute precision differs,
so results match FP32 within a tolerance, not bit for bit.

usage: convert-tracknet-fp16.py TRACED.pt LICENSE OUT.mlpackage
TRACED.pt is the torch.jit trace written by the FP32 conversion (coremltools 9.0, torch 2.7.0).
"""
import sys
import numpy as np
import coremltools as ct

traced, licence, out = sys.argv[1:4]
model = ct.convert(traced, source="pytorch", convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17,
                   inputs=[ct.TensorType(name="frames", shape=(1, 27, 288, 512), dtype=np.float32)],
                   outputs=[ct.TensorType(name="heatmaps", dtype=np.float32)],
                   compute_precision=ct.precision.FLOAT16, compute_units=ct.ComputeUnit.ALL)
model.author = "qaz812345; FP16 Core ML conversion by Zacks Court"
model.license = open(licence).read()
model.short_description = "MIT TrackNetV3 badminton base, FP16 compute, not a qualified tennis/speed model"
model.user_defined_metadata["production"] = "false"
model.save(out)
print("saved", out)
