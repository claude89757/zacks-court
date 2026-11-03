#!/usr/bin/env python3
"""One frozen decoder-head experiment changing only negative loss reduction.

Existing causal helpers and previous models remain untouched. propose performs
no fitting; run requires explicit frozen-protocol and agent-label authorization.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import importlib.util
import math
from pathlib import Path
import sys
import tempfile
import time
import traceback
import unittest

sys.dont_write_bytecode = True
import numpy as np
import torch

HERE = Path(__file__).resolve()
NAME = "hardnegative_decoder_head"


def load(filename, name):
    spec = importlib.util.spec_from_file_location(name, HERE.with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


causal = load("ball-causal-tune.py", "hardnegative_frozen_causal")
view = load("ball-causal-tune-view.py", "hardnegative_previous_receipt")
tune, native = causal.tune, causal.native
require, write = causal.require, causal.write
FLAGS = causal.FLAGS


def checked_sha(path, expected):
    require(tune.sha(path) == native.valid_sha(expected), "Frozen source/artifact SHA differs: " + str(path))


def focal_terms(prediction, targets):
    """The unchanged old positive/full-negative primitives and mass divisions."""
    positive = -(1 - prediction).square() * targets * torch.log(prediction.clamp(1e-7, 1))
    q = -prediction.square() * (1 - targets) * torch.log((1 - prediction).clamp(1e-7, 1))
    positive_mass = targets.sum((-1, -2))
    negative_mass = (1 - targets).sum((-1, -2))
    return (positive.sum((-1, -2)) / positive_mass.clamp_min(1e-7),
            q.sum((-1, -2)) / negative_mass.clamp_min(1e-7), q)


def outside_three_sigma(geometry, height, width):
    require(isinstance(geometry, dict) and set(("center_xy", "sigma_xy")).issubset(geometry),
            "Confirmed-visible Gaussian geometry required")
    center, sigma = geometry["center_xy"], geometry["sigma_xy"]
    require(len(center) == len(sigma) == 2 and all(type(value) in (int, float) and math.isfinite(value) for value in center + sigma)
            and min(sigma) > 0, "Invalid Gaussian geometry")
    # Existing make_target builds the Gaussian in NumPy float64 before its
    # float32 cast. Exclusion uses that same declared continuous geometry.
    yy = torch.arange(height, dtype=torch.float64)[:, None]
    xx = torch.arange(width, dtype=torch.float64)[None, :]
    radius_squared = ((xx - center[0]) / sigma[0]).square() + ((yy - center[1]) / sigma[1]).square()
    return radius_squared > 9.0  # the 3-sigma boundary itself is excluded


def stable_top32(q, outside):
    require(q.ndim == 2 and outside.shape == q.shape and outside.dtype == torch.bool, "Invalid hard-negative geometry")
    raster = torch.nonzero(outside.reshape(-1), as_tuple=False).flatten()
    require(raster.numel() >= 32, "Fewer than32 eligible pixels; never pad or change K")
    values = q.reshape(-1)[raster]
    # nonzero returns ascending raster indices; stable descending sort retains
    # that order on exact loss ties. No epsilon or component ID tie surrogate.
    order = torch.argsort(values.detach(), descending=True, stable=True)[:32]
    selected = raster[order]
    return q.reshape(-1)[selected].mean(), selected


def hardnegative_loss(prediction, targets, frame_mask, geometry):
    require(prediction.shape == targets.shape and prediction.ndim == 4 and prediction.shape[0] == 1,
            "Loss expects one real temporal batch")
    require(frame_mask.shape == prediction.shape[:2] and len(geometry) == prediction.shape[1], "Loss mask/geometry differs")
    require(prediction.device.type == targets.device.type == frame_mask.device.type == "cpu", "CPU-only loss")
    require(prediction.dtype == targets.dtype and prediction.dtype in (torch.float32, torch.float64), "Loss dtype differs")
    require(torch.isfinite(prediction).all().item() and torch.isfinite(targets).all().item()
            and ((prediction >= 0) & (prediction <= 1)).all().item()
            and ((targets >= 0) & (targets <= 1)).all().item(), "Invalid prediction/target")
    require(((frame_mask == 0) | (frame_mask == 1)).all().item(), "Mask must be binary")
    count = frame_mask.sum()
    require(count.item() > 0, "All-unknown batch rejected")
    pos, neg_full, q = focal_terms(prediction, targets)
    hard, selections = [], []
    height, width = prediction.shape[-2:]
    for offset in range(prediction.shape[1]):
        if frame_mask[0, offset].item() == 0:
            hard.append(prediction.new_zeros(())); selections.append(None)
            continue
        require(targets[0, offset].sum().item() > 0, "Only confirmed-visible positive frames may mine negatives")
        outside = outside_three_sigma(geometry[offset], height, width)
        value, indices = stable_top32(q[0, offset], outside)
        hard.append(value)
        selections.append(indices.tolist())
    hard = torch.stack(hard)[None]
    per_frame = .5 * pos + .25 * neg_full + .25 * hard
    loss = (per_frame * frame_mask).sum() / count
    diagnostics = {"loss": loss.detach().item(), "positive_component": ((pos * frame_mask).sum() / count).detach().item(),
                   "full_negative_component": ((neg_full * frame_mask).sum() / count).detach().item(),
                   "top32_negative_component": ((hard * frame_mask).sum() / count).detach().item(),
                   "supervised_frames": int(count.item()), "mined_raster_indices": selections,
                   "mined_pixels": int(count.item()) * 32, "unknown_mining": False}
    return loss, diagnostics


def previous_artifacts(root, analysis_path):
    root = Path(root).resolve()
    completion, protocol, models = view.complete_run(root)
    analysis = native.load_json(analysis_path)
    require(analysis["source_completion_sha256"] == tune.sha(root / "completion.json"), "Failure analysis refers to another experiment")
    files = {str((root / name).resolve()): expected for name, expected in completion["files"].items()}
    files[str(root / "completion.json")] = tune.sha(root / "completion.json")
    files[str(Path(analysis_path).resolve())] = tune.sha(analysis_path)
    evaluations = {name: native.load_json(root / (name + "-evaluation.json")) for name in view.MODELS}
    require(evaluations["base"]["native_alignment"]["passed"] is True, "Previous baseline did not pass native gates")
    return completion, protocol, models, files, evaluations


def proposal(paths):
    checked_sha(paths["intent"], paths["intent_sha256"])
    intent = native.load_json(paths["intent"])
    completion, prior, models, prior_files, controls = previous_artifacts(paths["previous_run"], paths["failure_analysis"])
    require(intent["prior_run"]["path"] == paths["previous_run"], "Intent refers to another previous run")
    checked_sha(Path(paths["previous_run"]) / "completion.json", intent["prior_run"]["completion_sha256"])
    require(intent["prior_run"]["protocol_sha256"] == completion["protocol_sha256"], "Intent previous protocol differs")
    checked_sha(paths["failure_analysis"], intent["prior_run"]["failure_analysis_sha256"])
    checked_sha(paths["previous_audit"], intent["prior_run"]["independent_audit_sha256"])
    previous_audit = native.load_json(paths["previous_audit"])
    require(previous_audit["status"] == "passed" and previous_audit["completion_sha256"] == tune.sha(Path(paths["previous_run"]) / "completion.json")
            and previous_audit["protocol_sha256"] == completion["protocol_sha256"], "Previous independent audit identity/status differs")
    fixed = {"threshold": .3, "top_k_candidates": 20, "train_windows": list(causal.TRAIN_WINDOWS),
        "train_visible_unique": 134, "train_unknown": 10, "eligible_batches": 17, "steps": 72,
        "supervised_frame_occurrences": 568, "seed": 20261029, "optimizer": "Adam", "learning_rate": 1e-4,
        "device": "cpu", "dtype": "float32", "threads": 4, "interop_threads": 1, "feature_cache_mib": 4096, "new_fits": 1}
    for key, value in fixed.items(): require(intent["fixed"].get(key) == value, "Intent fixed recipe differs: " + key)
    require(intent["loss"]["k"] == 32, "Intent mining K differs")
    inputs = causal.Inputs(prior["paths"])
    require(inputs.files == prior["input_files"], "Previous native input receipt drift")
    require(inputs.eligible == prior["eligible_training_batches"] and len(inputs.eligible) == 17, "Previous eligible batches drift")
    require(prior["supervised_frame_occurrences_per_fit"] == 568 and prior["steps_per_fit"] == 72
            and prior["seed"] == 20261029 and prior["learning_rate"] == 1e-4 and prior["threads"] == 4
            and prior["interop_threads"] == 1 and prior["cache_mib"] == 4096 and prior["dtype"] == "float32"
            and prior["device"] == "cpu", "Previous experiment differs from required fixed recipe")
    expected_contract = next(row for row in prior["variants"] if row["mode"] == "decoder_head")
    require(causal.model_contract("decoder_head") == expected_contract, "Decoder trainable/BN contract differs")
    # Bind all older dependencies as well as the current adapter/receipt helper;
    # importing functions does not replace any old module function or forward.
    dependencies = dict(prior["dependencies"])
    for path in (HERE, HERE.with_name("ball-causal-tune.py"), HERE.with_name("ball-causal-tune-view.py")):
        dependencies[str(path)] = tune.sha(path)
    for path, expected in prior["dependencies"].items(): checked_sha(path, expected)
    files = {**inputs.files, **prior_files, paths["intent"]: paths["intent_sha256"],
             paths["previous_audit"]: tune.sha(paths["previous_audit"])}
    return {"schema_version": 1, **FLAGS, "experiment": "single_decoder_head_top32_negative_reduction_v1",
        "paths": paths, "frozen_intent": {"path": paths["intent"], "sha256": paths["intent_sha256"], "document": intent},
        "dependencies": dependencies, "files": files, "runtime": causal.versions(), "official_source": tune.source_check(),
        "previous_completion_sha256": tune.sha(Path(paths["previous_run"]) / "completion.json"),
        "previous_protocol_sha256": completion["protocol_sha256"], "previous_models": models,
        "frozen_controls": {name: {"model_state_sha256": value["model_state_sha256"], "metrics": value["metrics"]}
                            for name, value in controls.items()},
        "native_input_audits": inputs.audit_reports, "variant": expected_contract, "new_model_name": NAME,
        "seed": 20261029, "device": "cpu", "dtype": "float32", "threads": 4, "interop_threads": 1,
        "optimizer": "Adam", "learning_rate": 1e-4, "steps": 72, "cache_mib": 4096,
        "eligible_training_batches": inputs.eligible, "exact72_step_schedule": prior["exact72_step_schedule"],
        "supervised_frame_occurrences_per_fit": 568,
        "supervised_occurrences_per_unique_train_frame": prior["supervised_occurrences_per_unique_train_frame"],
        "initialization": "one independent official base, not old fitted decoder weights",
        "only_intervention": "negative reduction: .5*Lpos+.25*Lneg_full+.25*mean_top32(q)",
        "loss": {"positive": "unchanged -(1-p)^2*y*log(clamp(p,1e-7,1)) / sum(y)",
            "full_negative": "unchanged q=-p^2*(1-y)*log(clamp(1-p,1e-7,1)); sum(q)/sum(1-y), including exclusion ellipse",
            "mass_clamp_min": 1e-7, "weights": {"positive": .5, "full_negative": .25, "hard_negative": .25},
            "hard_k": 32, "exclusion": "strict ((x-cx)/sx)^2+((y-cy)/sy)^2>9 from existing make_target geometry, float64 grid",
            "ranking": "q descending, then raster-flat index ascending, stable exact ties; indices detached, selected q retains gradient",
            "supervision": "existing confirmed-visible train frames only; unknown/unlabelled loss-mask0, no mining and exact zero output gradient",
            "batch_reduction": "mean over supervised frames only; all-unknown batch rejected; no padding/fallback K"},
        "candidate_rule": prior["candidate_rule"], "causal_gate": prior["causal_gate"],
        "causal_gate_parameters": prior["causal_gate_parameters"], "background": prior["background"], "tensor": prior["tensor"],
        "success_rule_vs_official_base": prior["success_rule_each_fit_vs_own_torch_base"],
        "stopping_rule": {"single_fit_only": True, "continue_this_micro_tuning_direction_only_if":
            "new overall166 within10 strictly exceeds frozen head97, wrong_over20<=21, slow32 within10 remains32 and wrong0",
            "otherwise": "stop this small-sample micro-tuning direction; require new data or a different evidence-backed mechanism",
            "automatic_model_selection_or_promotion": False},
        "selection": "single final72-step checkpoint; no extra seed/steps/ROI/threshold or automatic winner",
        "limits": ["All4 windows/192 agent candidates are previously exposed development data;166visible are not human truth.",
            "Hard negatives are loss terms outside existing positive Gaussian, not newly certified absence or new labels.",
            "Background is past-only but8-frame detector still has up to7-frame lookahead.",
            "Historical base/head/decoder controls are frozen previous artifacts; none are refit or selected again.",
            "The prior failure analysis motivates this test but does not prove its causal explanation or predict success.",
            "No physical speed, camera/App integration, product promotion or independent final acceptance."]}


def train(inputs, protocol, protocol_sha, out):
    torch.manual_seed(protocol["seed"])
    model = tune.factory("decoder_head")
    require(causal.model_contract("decoder_head") == protocol["variant"], "Trainable parameter/BN contract drift")
    initial_sha = tune.state_sha(model)
    require(initial_sha == protocol["previous_models"]["base"]["model_state_sha256"], "Fresh official base differs from frozen control")
    trainable = {name for name, parameter in model.named_parameters() if parameter.requires_grad}
    affine, buffers = causal.bn_names(model)
    frozen_before = tune.state_sha(model, lambda name: name not in trainable)
    bn_before = tune.state_sha(model, lambda name: name in buffers)
    optimizer = torch.optim.Adam([parameter for parameter in model.parameters() if parameter.requires_grad], lr=1e-4)
    cache = tune.FeatureCache(4096)
    verified, fingerprints, history = set(), {}, []
    started = time.perf_counter()
    with (out / "steps.jsonl").open("x") as stream:
        for step, item in enumerate(protocol["exact72_step_schedule"]):
            require(step < 72 and item == inputs.eligible[step % 17], "Frozen72-step schedule differs")
            sample, start = item["sample_id"], item["start"]
            specification = causal.cache_spec(inputs, "decoder_head", frozen_before, sample, start)
            key = causal.digest(specification)
            fingerprints[key] = specification
            x = inputs.tensor(sample, start) if key not in cache.items or key not in verified else None
            features = cache.get(key, lambda: tune.frozen_features(model, x, "decoder_head"))
            if key not in verified:
                with torch.no_grad():
                    require(torch.equal(model(x), tune.suffix(model, features, "decoder_head")), "First real cached/full forward differs")
                verified.add(key)
            y, mask, geometry = inputs.targets(sample, start)
            for offset in range(8):
                label = inputs.labels.get((sample, start + offset))
                visible = label is not None and label["status"] == "visible" and label["target_identity"] == "confirmed"
                require(bool(mask[0, offset].item()) == visible, "Unknown/unlabelled/absence was given mining supervision")
            require(not model.training and all(not layer.training for layer in model.modules() if isinstance(layer, torch.nn.modules.batchnorm._BatchNorm)), "BN not in eval mode")
            optimizer.zero_grad(set_to_none=True)
            prediction = tune.suffix(model, features, "decoder_head")
            prediction.retain_grad()
            loss, diagnostics = hardnegative_loss(prediction, y, mask, geometry)
            require(torch.isfinite(loss).item(), "Nonfinite loss")
            loss.backward()
            require(all(torch.count_nonzero(prediction.grad[0, offset]).item() == 0 for offset in range(8) if mask[0, offset] == 0), "Unknown/unlabelled loss gradient nonzero")
            require(all(parameter.grad is None for name, parameter in model.named_parameters() if name not in trainable), "Frozen parameter received gradient")
            require(all(parameter.grad is not None and torch.isfinite(parameter.grad).all().item() for parameter in model.parameters() if parameter.requires_grad), "Missing/nonfinite trainable gradient")
            norm = math.sqrt(sum(float(parameter.grad.double().square().sum()) for parameter in model.parameters() if parameter.requires_grad))
            require(math.isfinite(norm) and norm > 0, "Invalid gradient norm")
            optimizer.step()
            require(all(torch.isfinite(parameter).all().item() for parameter in model.parameters() if parameter.requires_grad), "Nonfinite updated state")
            row = {"step": step, "sequence": item, "frame_mask": mask[0].tolist(), "cache_key": key,
                   "loss": diagnostics, "gradient_norm": norm, "unknown_loss_gradient_zero": True,
                   "label_point_predictions": tune.point_predictions(prediction, geometry)}
            history.append(row)
            stream.write(tune.canonical(row) + "\n"); stream.flush()
            print(f"HARDNEGATIVE_FIT step={step + 1}/72 loss={loss.item():.8f}", flush=True)
    require(len(history) == 72 and len(verified) == 17 and sum(row["sequence"]["supervised_frames"] for row in history) == 568,
            "Training schedule/supervision count incomplete")
    frozen_after = tune.state_sha(model, lambda name: name not in trainable)
    bn_after = tune.state_sha(model, lambda name: name in buffers)
    require(frozen_after == frozen_before and bn_after == bn_before, "Frozen state/BN running buffers changed")
    for item in inputs.eligible:
        sample, start = item["sample_id"], item["start"]
        x = inputs.tensor(sample, start)
        key = causal.digest(causal.cache_spec(inputs, "decoder_head", frozen_before, sample, start))
        features = cache.get(key, lambda: tune.frozen_features(model, x, "decoder_head"))
        with torch.no_grad():
            require(torch.equal(model(x), tune.suffix(model, features, "decoder_head")), "Final real cached/full forward differs")
    final_sha = tune.state_sha(model)
    checkpoint = {**FLAGS, "parent_sha256": tune.BASE_SHA, "protocol_sha256": protocol_sha, "model_name": NAME,
        "initial_model_state_sha256": initial_sha, "final_model_state_sha256": final_sha,
        "trainable_state": {name: value.detach().cpu().clone() for name, value in model.state_dict().items() if name in trainable}}
    path = out / (NAME + ".pt")
    torch.save(checkpoint, path); path.chmod(0o600)
    restored = torch.load(path, map_location="cpu", weights_only=True)
    require(restored["parent_sha256"] == tune.BASE_SHA and restored["protocol_sha256"] == protocol_sha and restored["model_name"] == NAME,
            "Checkpoint source/protocol differs")
    require(set(restored["trainable_state"]) == trainable, "Checkpoint trainable names differ")
    replay = tune.factory("decoder_head")
    state = replay.state_dict()
    for name, value in restored["trainable_state"].items():
        require(value.shape == state[name].shape and value.dtype == state[name].dtype and torch.isfinite(value).all().item(), "Checkpoint tensor invalid")
        state[name] = value
    replay.load_state_dict(state, strict=True)
    require(tune.state_sha(replay) == final_sha, "Safe delta reload differs from fitted full model")
    require(tune.state_sha(model, lambda name: name not in trainable) == frozen_before, "Final checks changed frozen state")
    report = {**FLAGS, "model": NAME, "mode": "decoder_head", "steps": 72, "seed": 20261029, "learning_rate": 1e-4,
        "supervised_frame_occurrences": 568, "history": history, "initial_model_state_sha256": initial_sha,
        "final_model_state_sha256": final_sha, "frozen_nontrainable_before": frozen_before,
        "frozen_nontrainable_after": frozen_after, "bn_running_buffers_before": bn_before, "bn_running_buffers_after": bn_after,
        "bn_affine_trainable": sorted(trainable & affine), "all17_first_split_forwards_exact": True,
        "all17_final_split_forwards_exact": True, "safe_reloaded_full_model_identical": True,
        "checkpoint": path.name, "checkpoint_sha256": tune.sha(path), "feature_cache": {
            "limit_mib": 4096, "resident_bytes": cache.bytes, "hits": cache.hits, "misses": cache.misses,
            "fingerprints": fingerprints}, "seconds": time.perf_counter() - started}
    write(out / "training.json", report)
    return replay, report


def controls_comparison(previous, current):
    result = {}
    scopes = ("all166_development", "train134_development", "slow32_development")
    for name, evaluation in previous.items():
        old, new = evaluation["metrics"]["causal"], current["metrics"]["causal"]
        scopes_report = {}
        for scope in scopes:
            a, b = old[scope], new[scope]
            require(a["visible_denominator"] == b["visible_denominator"], "Comparison denominators differ")
            scopes_report[scope] = {"frozen_control": a, "new_fit": b,
                "within10_delta": b["within_equivalent_px"]["10"] - a["within_equivalent_px"]["10"],
                "wrong_over20_delta": b["wrong_over20_on_visible"] - a["wrong_over20_on_visible"],
                "missing_delta": b["missing_on_visible"] - a["missing_on_visible"]}
        result[name] = {"model_state_sha256": evaluation["model_state_sha256"], "scopes": scopes_report,
                       "per_window": {sample: {"frozen_control": old["per_window"][sample], "new_fit": new["per_window"][sample]} for sample in native.WINDOWS},
                       "automatic_model_selection": False}
    return result


def stopping_decision(evaluation, controls):
    current = evaluation["metrics"]["causal"]
    overall, slow = current["all166_development"], current["slow32_development"]
    old_head = controls["head_only"]["metrics"]["causal"]["all166_development"]
    old_base = controls["base"]["metrics"]["causal"]
    checks = {"beats_head_within10": overall["within_equivalent_px"]["10"] > old_head["within_equivalent_px"]["10"],
              "wrong_over20_not_above21": overall["wrong_over20_on_visible"] <= 21,
              "slow32_preserved": slow["visible_denominator"] == 32 and slow["within_equivalent_px"]["10"] == 32
                                   and slow["wrong_over20_on_visible"] == 0}
    require(old_head["within_equivalent_px"]["10"] == 97 and old_base["all166_development"]["wrong_over20_on_visible"] == 21,
            "Frozen stopping-rule controls differ from head97/base21")
    passed = all(checks.values())
    return {"checks": checks, "continue_micro_tuning_direction_supported": passed,
            "stop_this_small_sample_micro_tuning_direction": not passed,
            "next_evidence_if_stopped": "new data or a different evidence-backed mechanism; no further seed/threshold/checkpoint trials",
            "automatic_model_selection_or_promotion": False}


def execute(args):
    require(args.execute_frozen_protocol and args.diagnostic_agent_labels, "run requires BOTH explicit execution/diagnostic-agent flags")
    protocol = native.load_json(args.protocol)
    require(protocol == proposal(protocol["paths"]), "Frozen protocol/inputs/helpers/runtime drift")
    protocol_sha = tune.sha(args.protocol)
    completion, prior, _, _, controls = previous_artifacts(protocol["paths"]["previous_run"], protocol["paths"]["failure_analysis"])
    inputs = causal.Inputs(prior["paths"])
    out = Path(args.output).resolve()
    require(not out.exists(), "Output exists; choose NEW directory")
    out.mkdir(parents=True); out.chmod(0o700)
    write(out / "protocol.json", protocol)
    write(out / "receipt.json", {**FLAGS, "protocol_sha256": protocol_sha, "runner_sha256": tune.sha(HERE),
        "previous_completion_sha256": protocol["previous_completion_sha256"], "files": protocol["files"],
        "runtime": causal.versions(), "created_at": datetime.now(timezone.utc).isoformat(), "training_started_at_receipt_creation": False})
    phase = "fit"
    try:
        torch.set_num_threads(4); torch.set_num_interop_threads(1)
        torch.use_deterministic_algorithms(True); torch.set_default_dtype(torch.float32)
        model, fitting = train(inputs, protocol, protocol_sha, out)
        phase = "evaluate"
        with (out / "predictions.jsonl").open("x") as stream:
            evaluation = causal.evaluate(model, NAME, inputs, out, stream)
        phase = "verify_frozen_sources"
        inputs.verify_unchanged()
        for path, expected in {**protocol["files"], **protocol["dependencies"]}.items(): checked_sha(path, expected)
        require(tune.source_check() == protocol["official_source"], "Official base/source changed")
        report = {**FLAGS, "model": NAME, "protocol_sha256": protocol_sha, "training": fitting,
            "evaluation": evaluation, "frozen_controls": protocol["frozen_controls"],
            "comparisons": controls_comparison(controls, evaluation),
            "development_success_vs_base": causal.success(controls["base"], evaluation),
            "stopping_decision": stopping_decision(evaluation, controls),
            "previous_controls_refit_or_reevaluated": False, "all_frozen_inputs_and_comparison_artifacts_unchanged": True,
            "single_new_fit": True, "automatic_model_selection": False, "limits": protocol["limits"]}
        write(out / "report.json", report)
        files = {path.name: tune.sha(path) for path in out.iterdir() if path.is_file()}
        write(out / "completion.json", {**FLAGS, "status": "complete", "protocol_sha256": protocol_sha,
            "runner_sha256": tune.sha(HERE), "files": files, "completed_fits": [NAME], "predicted_frames": 480,
            "previous_control_models": list(view.MODELS), "previous_completion_sha256": protocol["previous_completion_sha256"]})
        print(tune.canonical({"output": str(out), "new_fits": 1, "predicted_frames": 480,
              "development_rule_passed": report["development_success_vs_base"]["development_rule_passed"]}))
    except BaseException as error:
        write(out / "failure.json", {**FLAGS, "status": "failed", "phase": phase, "error": str(error),
            "protocol_sha256": protocol_sha, "traceback": traceback.format_exc(),
            "preserved_files": {path.name: tune.sha(path) for path in out.iterdir() if path.is_file()}})
        raise


class SelfTests(unittest.TestCase):
    def geometry(self):
        return {"center_xy": [4.5, 4.5], "sigma_xy": [.5, .5]}

    def batch(self, channels=1):
        geometry = self.geometry()
        yy, xx = np.ogrid[:10, :10]
        target = np.exp(-.5 * (((xx - 4.5) / .5) ** 2 + ((yy - 4.5) / .5) ** 2))
        y = torch.tensor(target, dtype=torch.float64)[None, None].repeat(1, channels, 1, 1)
        p = torch.linspace(.08, .83, 100, dtype=torch.float64).reshape(1, 1, 10, 10).repeat(1, channels, 1, 1).requires_grad_()
        return p, y, torch.ones((1, channels), dtype=torch.float64), [geometry] * channels

    def test_formula_matches_independent_scalar_reduction(self):
        p, y, mask, geometry = self.batch()
        loss, diagnostics = hardnegative_loss(p, y, mask, geometry)
        pp, yy = p.detach().numpy().ravel(), y.numpy().ravel()
        pos = -(1 - pp) ** 2 * yy * np.log(np.clip(pp, 1e-7, 1))
        q = -pp ** 2 * (1 - yy) * np.log(np.clip(1 - pp, 1e-7, 1))
        eligible = [i for i in range(100) if ((i % 10 - 4.5) / .5) ** 2 + ((i // 10 - 4.5) / .5) ** 2 > 9]
        selected = sorted(eligible, key=lambda i: (-q[i], i))[:32]
        expected = .5 * pos.sum() / yy.sum() + .25 * q.sum() / (1 - yy).sum() + .25 * q[selected].mean()
        self.assertAlmostEqual(loss.item(), expected, places=13)
        self.assertEqual(diagnostics["mined_raster_indices"][0], selected)

    def test_top32_exclusion_boundary_and_stable_raster_ties(self):
        geometry = {"center_xy": [5., 5.], "sigma_xy": [1., 1.]}
        outside = outside_three_sigma(geometry, 12, 12)
        self.assertFalse(outside[5, 8].item())  # exactly3sigma
        self.assertTrue(outside[5, 9].item())
        q = torch.ones((12, 12), dtype=torch.float64)
        q[~outside] = 1000
        value, selected = stable_top32(q, outside)
        self.assertEqual(selected.tolist(), torch.nonzero(outside.flatten()).flatten().tolist()[:32])
        self.assertEqual(value.item(), 1)

    def test_unknown_zero_gradient_no_mining_and_all_unknown_rejected(self):
        p, y, mask, geometry = self.batch(2)
        mask[0, 1] = 0; geometry[1] = None
        y[0, 1] = 0
        loss, diagnostics = hardnegative_loss(p, y, mask, geometry); loss.backward()
        self.assertEqual(torch.count_nonzero(p.grad[0, 1]).item(), 0)
        self.assertIsNone(diagnostics["mined_raster_indices"][1])
        self.assertGreater(torch.count_nonzero(p.grad[0, 0]).item(), 0)
        with self.assertRaises(ValueError): hardnegative_loss(p, y, torch.zeros_like(mask), geometry)

    def test_original_positive_and_full_negative_are_unchanged(self):
        for dtype in (torch.float32, torch.float64):
            p, y, mask, geometry = self.batch(2)
            p, y, mask = p.to(dtype), y.to(dtype), mask.to(dtype)
            mask[0, 1] = 0; geometry[1] = None
            _, old = tune.balanced_wbce(p, y, mask)
            _, new = hardnegative_loss(p, y, mask, geometry)
            self.assertEqual(old["positive_component"], new["positive_component"])
            self.assertEqual(old["negative_component"], new["full_negative_component"])

    def test_stopping_rule_does_not_accept_tie_with_old_head(self):
        def metric(within, wrong, n=166):
            return {"visible_denominator": n, "within_equivalent_px": {"10": within}, "wrong_over20_on_visible": wrong}
        controls = {"head_only": {"metrics": {"causal": {"all166_development": metric(97, 21)}}},
                    "base": {"metrics": {"causal": {"all166_development": metric(95, 21)}}}}
        def new_result(within, wrong=21, slow=32):
            return {"metrics": {"causal": {"all166_development": metric(within, wrong),
                                           "slow32_development": metric(slow, 0, 32)}}}
        self.assertFalse(stopping_decision(new_result(98), controls)["stop_this_small_sample_micro_tuning_direction"])
        self.assertTrue(stopping_decision(new_result(97, 18), controls)["stop_this_small_sample_micro_tuning_direction"])
        self.assertTrue(stopping_decision(new_result(98, 22), controls)["stop_this_small_sample_micro_tuning_direction"])
        self.assertTrue(stopping_decision(new_result(98, 20, 31), controls)["stop_this_small_sample_micro_tuning_direction"])

    def test_bad_input_geometry_and_source_digest_refused(self):
        p, y, mask, geometry = self.batch()
        with self.assertRaises(ValueError): hardnegative_loss(p, y, mask, [None])
        with self.assertRaises(ValueError): stable_top32(torch.ones((2, 2)), torch.ones((2, 2), dtype=torch.bool))
        with self.assertRaises(ValueError): hardnegative_loss(p * float("nan"), y, mask, geometry)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary, "source")
            path.write_bytes(b"frozen")
            checked_sha(path, tune.sha(path))
            with self.assertRaises(ValueError): checked_sha(path, "0" * 64)

    def test_finite_difference_gradient_small_example(self):
        p, y, mask, geometry = self.batch()
        loss, _ = hardnegative_loss(p, y, mask, geometry); loss.backward()
        require(torch.isfinite(p.grad).all().item(), "Test gradient nonfinite")
        for flat_index in (0, 44, 68, 99):
            epsilon = 1e-6
            plus, minus = p.detach().clone(), p.detach().clone()
            plus.flatten()[flat_index] += epsilon; minus.flatten()[flat_index] -= epsilon
            a, _ = hardnegative_loss(plus, y, mask, geometry)
            b, _ = hardnegative_loss(minus, y, mask, geometry)
            self.assertAlmostEqual(p.grad.flatten()[flat_index].item(), ((a - b) / (2 * epsilon)).item(), delta=1e-8)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    sub = parser.add_subparsers(dest="command")
    propose = sub.add_parser("propose")
    for name in ("previous-run", "failure-analysis", "intent", "intent-sha256", "output"):
        propose.add_argument("--" + name, required=True)
    propose.add_argument("--diagnostic-agent-labels", action="store_true")
    propose.add_argument("--previous-audit")
    run = sub.add_parser("run")
    run.add_argument("--protocol", required=True); run.add_argument("--output", required=True)
    run.add_argument("--execute-frozen-protocol", action="store_true")
    run.add_argument("--diagnostic-agent-labels", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        torch.set_num_threads(4)
        return 0 if unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SelfTests)).wasSuccessful() else 1
    require(args.command, "Choose propose/run or --self-test")
    if args.command == "propose":
        require(args.diagnostic_agent_labels, "propose requires --diagnostic-agent-labels")
        output = Path(args.output).resolve()
        require(not output.exists(), "Protocol exists; choose NEW file")
        paths = {key: str(Path(getattr(args, key)).resolve()) for key in ("previous_run", "failure_analysis", "intent")}
        paths["previous_audit"] = str(Path(args.previous_audit).resolve() if args.previous_audit else
                                     Path(paths["previous_run"]).parent / "independent-run-audit.json")
        paths["intent_sha256"] = native.valid_sha(args.intent_sha256)
        value = proposal(paths)
        output.parent.mkdir(parents=True, exist_ok=True); write(output, value)
        print(tune.canonical({"protocol": str(output), "sha256": tune.sha(output), "new_fits_planned": 1,
                              "optimizer_steps": 0, "supervised_batches": 17, "supervised_frame_occurrences": 568}))
    else:
        execute(args)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, KeyError, OSError) as error:
        print("ball-hardnegative-tune: " + str(error), file=sys.stderr)
        raise SystemExit(2)
