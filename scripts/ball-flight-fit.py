#!/usr/bin/env python3
"""Independent calibrated-camera ballistic diagnostic (NumPy only).

World units: metres, seconds, z up. Camera: Xc=R@Xw+t, pinhole K;
pixels must already be undistorted in this exact K/image coordinate system.
Fits p(t)=p0+v0*t+[0,0,-g]*t²/2 directly to 2D observations.
This prototype never publishes a product speed: camera/model uncertainty and
collision/event review still need qualification. Candidate speed is diagnostic.
"""
import argparse
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import sys
import unittest

import numpy as np

G = np.array([0., 0., -9.80665])
POLICY = {'min_points': 8, 'min_span_seconds': .2, 'max_gap_seconds': .10,
          'max_scaled_jacobian_condition': 1e6, 'max_standardized_rms': 3.,
          'max_reprojection_rms_px': 5., 'minimum_camera_depth_m': .1,
          'minimum_height_m': -.05, 'max_local_sensitivity_relative_width': .2,
          'initial_depth_scales': [.25, .5, .75, .9, 1., 1.1, 1.25, 1.5, 2., 3.],
          'max_iterations': 60, 'model': 'fixed_gravity_no_drag_no_spin_collision_free'}


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def array(value, shape, name):
    require(isinstance(value, list), 'invalid_' + name)
    result = np.asarray(value, dtype=object)
    require(result.shape == shape and all(finite(v) for v in result.flat), 'invalid_' + name)
    return result.astype(float)


def camera_from(doc):
    require(isinstance(doc, dict), 'input_document_must_be_object')
    c = doc.get('camera')
    require(isinstance(c, dict), 'missing_camera_calibration')
    require(c.get('world_units') == 'metres' and c.get('world_up_axis') == 'z', 'unknown_metric_world_axes')
    require(c.get('pixel_model') == 'undistorted_pinhole', 'raw_or_unknown_distortion_not_supported')
    require(isinstance(c.get('calibration_basis'), str) and c['calibration_basis'], 'missing_calibration_basis')
    k, r, t = array(c.get('K'), (3, 3), 'K'), array(c.get('R'), (3, 3), 'R'), array(c.get('t'), (3,), 't')
    require(k[0, 0] > 0 and k[1, 1] > 0 and k[1, 0] == 0 and np.allclose(k[2], [0, 0, 1]), 'invalid_pinhole_intrinsics')
    require(np.allclose(r.T @ r, np.eye(3), atol=1e-6) and abs(np.linalg.det(r)-1) < 1e-6, 'invalid_camera_rotation')
    width, height = c.get('width'), c.get('height')
    require(isinstance(width, int) and not isinstance(width, bool) and isinstance(height, int) and not isinstance(height, bool) and width > 0 and height > 0, 'invalid_image_size')
    segment = doc.get('segment')
    require(isinstance(segment, dict), 'missing_segment_contract')
    require(segment.get('camera_static') is True, 'camera_motion_or_zoom_unresolved')
    require(segment.get('collision_free') is True, 'collision_boundaries_unresolved')
    source = doc.get('source')
    require(isinstance(source, dict), 'missing_source_binding')
    source_sha = source.get('sha256')
    require(isinstance(source_sha, str) and len(source_sha) == 64 and all(c in '0123456789abcdef' for c in source_sha), 'invalid_source_sha256')
    require(c.get('source_sha256') == source_sha, 'camera_source_binding_mismatch')
    return k, r, t, width, height


def observations(doc, width, height):
    records = doc.get('observations')
    require(isinstance(records, list) and records, 'missing_observations')
    times, xy, sigma = [], [], []
    previous = None
    for row in records:
        require(isinstance(row, dict), 'observation_must_be_object')
        require(row.get('source_sha256') == doc['source']['sha256'], 'observation_source_binding_mismatch')
        pts = row.get('source_pts')
        require(isinstance(pts, int) and not isinstance(pts, bool), 'integer_source_pts_required')
        try:
            require(isinstance(row.get('source_time_base'), str), 'rational_time_base_string_required')
            tb = Fraction(row['source_time_base'])
        except (ValueError, ZeroDivisionError):
            raise ValueError('invalid_time_base')
        require(tb > 0, 'invalid_time_base')
        time = pts * tb
        require(previous is None or time > previous, 'nonmonotonic_or_duplicate_pts')
        previous = time
        require(row.get('gap_before') is not True, 'source_discontinuity')
        status = row.get('status')
        require(status in {'visible', 'unknown', 'occluded', 'out_of_frame'}, 'invalid_visibility_status')
        require(row.get('target_identity') in {'confirmed', 'uncertain'}, 'target_identity_required')
        require(isinstance(row.get('is_interpolated'), bool), 'interpolation_provenance_required')
        if status != 'visible':
            require(row.get('x') is None and row.get('y') is None, 'unknown_point_must_be_null')
            continue
        if row['target_identity'] != 'confirmed' or row['is_interpolated']:
            continue
        require(all(finite(row.get(key)) for key in ('x', 'y', 'sigma_px')), 'invalid_observation_or_uncertainty')
        require(0 <= row['x'] < width and 0 <= row['y'] < height and row['sigma_px'] > 0, 'point_outside_image_or_zero_uncertainty')
        times.append(time); xy.append([row['x'], row['y']]); sigma.append(row['sigma_px'])
    require(len(times) >= POLICY['min_points'], 'insufficient_visible_points')
    relative = np.array([float(time-times[0]) for time in times])
    require(relative[-1] >= POLICY['min_span_seconds'], 'insufficient_time_span')
    require(np.diff(relative).max() <= POLICY['max_gap_seconds'], 'visible_gap_too_long_for_one_flight')
    return relative, np.asarray(xy), np.asarray(sigma), str(times[0])


def trajectory(theta, ts, span):
    return theta[:3] + (ts/span)[:, None]*theta[3:] + .5*ts[:, None]**2*G


def project(theta, ts, span, k, r, t):
    world = trajectory(theta, ts, span)
    cam = world @ r.T + t
    depth = cam[:, 2]
    # Do not silently project through a camera plane during optimization.
    require(np.isfinite(cam).all() and np.all(depth > POLICY['minimum_camera_depth_m']), 'behind_or_near_camera')
    homogeneous = cam @ k.T
    require(np.isfinite(homogeneous).all(), 'nonfinite_camera_projection')
    uv = homogeneous[:, :2]/homogeneous[:, 2, None]
    require(np.isfinite(uv).all(), 'nonfinite_camera_projection')
    return uv, depth, world


def linear_initial(ts, xy, sigma, k, r, t):
    span = ts[-1]
    rays = np.column_stack([xy, np.ones(len(xy))]) @ np.linalg.inv(k).T
    rays /= np.linalg.norm(rays, axis=1)[:, None]
    aa, bb = [], []
    for tau, ray, uncertainty in zip(ts, rays, sigma):
        projector = np.eye(3)-np.outer(ray, ray)
        a = projector @ r
        aa.append(np.column_stack([a, a*(tau/span)])/uncertainty)
        bb.append(-projector @ (t + r @ (.5*G*tau*tau))/uncertainty)
    solution, _, rank, _ = np.linalg.lstsq(np.concatenate(aa), np.concatenate(bb), rcond=None)
    require(rank == 6, 'rank_deficient_bearing_initialization')
    return solution


def residual(theta, ts, xy, sigma, k, r, t):
    return ((project(theta, ts, ts[-1], k, r, t)[0]-xy)/sigma[:, None]).reshape(-1)


def jacobian(theta, args):
    columns = []
    for axis in range(6):
        step = 1e-5*max(1., abs(theta[axis]))
        offset = np.zeros(6); offset[axis] = step
        columns.append((residual(theta+offset, *args)-residual(theta-offset, *args))/(2*step))
    return np.column_stack(columns)


def optimize(initial, args):
    theta, damping = initial.copy(), 1e-3
    error = residual(theta, *args)
    termination = 'iteration_limit'
    for iteration in range(POLICY['max_iterations']):
        j = jacobian(theta, args)
        gradient = j.T @ error
        require(np.isfinite(j).all() and np.isfinite(error @ error), 'nonfinite_objective_or_jacobian')
        if np.linalg.norm(gradient, ord=np.inf) < 1e-6:
            termination = 'converged_gradient'; break
        h = j.T @ j
        delta = np.linalg.solve(h + damping*np.diag(np.maximum(np.diag(h), 1e-8)), -gradient)
        proposal = theta + delta
        try:
            updated = residual(proposal, *args)
        except ValueError:
            damping *= 10
            continue
        if updated @ updated < error @ error:
            theta, error = proposal, updated
            damping = max(1e-9, damping/3)
            if np.linalg.norm(delta) < 1e-8:
                termination = 'converged_step'
                break
        else:
            damping *= 10
        if damping > 1e12:
            termination = 'damping_limit'
            break
    j = jacobian(theta, args)
    info = {'termination': termination, 'iterations': iteration+1,
            'gradient_inf_norm': float(np.linalg.norm(j.T @ error, ord=np.inf)),
            'converged': termination.startswith('converged')}
    return theta, error, j, info


def diagnose(doc):
    result = {'schema_version': 1, 'status': 'rejected', 'speed_kmh': None,
              'production': False, 'physical_accuracy_validated': False, 'reasons': [],
              'policy': POLICY, 'speed_definition': 'norm(v0) at first visible observation; not automatically racket-contact speed',
              'limits': ['No drag or spin model; one independently segmented collision-free flight only.',
                         'Low 2D reprojection residual alone does not establish 3D scale or speed.',
                         'Local noise sensitivity omits calibration, event-time and model uncertainty.',
                         'Ten depth-scaled seeds sample one initialization family; agreement does not prove a unique 3D solution.',
                         'Camera fields are caller-supplied evidence, not independently certified calibration.']}
    try:
        k, r, t, width, height = camera_from(doc)
        ts, xy, sigma, first_time = observations(doc, width, height)
        args = (ts, xy, sigma, k, r, t)
        initial = linear_initial(*args)
        center = -r.T @ t
        solutions, initial_failures = [], []
        for scale in POLICY['initial_depth_scales']:
            seed = np.r_[center + scale*(initial[:3]-center), scale*initial[3:]]
            try:
                theta, error, j, optimization = optimize(seed, args)
                uv, depth, world = project(theta, ts, ts[-1], k, r, t)
                require(np.isfinite(theta).all() and np.isfinite(error @ error) and np.isfinite(j).all(), 'nonfinite_fit')
                if world[:, 2].min() < POLICY['minimum_height_m']:
                    initial_failures.append({'scale': scale, 'reason': 'below_court_plane'}); continue
                solutions.append((float(error @ error), theta, j, uv, depth, world, optimization))
            except (ValueError, np.linalg.LinAlgError) as ex:
                initial_failures.append({'scale': scale, 'reason': str(ex)})
        require(solutions, 'no_physically_feasible_fit')
        solutions.sort(key=lambda item: item[0])
        objective, theta, j, uv, depth, world, optimization = solutions[0]
        _, singular, vt = np.linalg.svd(j, full_matrices=False)
        condition = float(singular[0]/singular[-1]) if singular[-1] > 0 else float('inf')
        require(math.isfinite(condition), 'singular_projection_jacobian')
        velocity = theta[3:]/ts[-1]
        speed = float(np.linalg.norm(velocity)*3.6)
        gradient = np.r_[np.zeros(3), velocity/np.linalg.norm(velocity)/ts[-1]*3.6] if speed > 0 else np.zeros(6)
        covariance = (vt.T*(1/np.square(singular))) @ vt * max(1., objective/max(1, len(xy)*2-6))
        noise_radius = float(1.96*np.sqrt(max(0., gradient@covariance@gradient)))
        near = [s for s in solutions if s[0] <= objective+1.]
        near_speeds = [float(np.linalg.norm(s[1][3:]/ts[-1])*3.6) for s in near]
        standardized_rms = math.sqrt(objective/len(xy))
        rms = float(np.sqrt(np.square(uv-xy).sum(axis=1).mean()))
        require(all(math.isfinite(v) for v in (speed, noise_radius, standardized_rms, rms)), 'nonfinite_fit_diagnostics')
        if not optimization['converged']: result['reasons'].append('optimizer_not_converged')
        if condition > POLICY['max_scaled_jacobian_condition']: result['reasons'].append('ill_conditioned_3d_fit')
        if standardized_rms > POLICY['max_standardized_rms'] or rms > POLICY['max_reprojection_rms_px']: result['reasons'].append('reprojection_mismatch')
        if speed <= 0 or 2*noise_radius/max(speed, 1e-12) > POLICY['max_local_sensitivity_relative_width']: result['reasons'].append('excessive_local_noise_sensitivity')
        if max(near_speeds)-min(near_speeds) > .2*max(speed, 1e-12): result['reasons'].append('multiple_similarly_fitting_speeds')
        result['fit'] = {'position_at_first_observation_m': theta[:3].tolist(), 'velocity_at_first_observation_mps': velocity.tolist(),
                         'candidate_speed_kmh': speed, 'span_seconds': float(ts[-1]), 'visible_points': len(xy),
                         'first_observation_time_rational': first_time, 'reprojection_rms_px': rms,
                         'standardized_rms': standardized_rms, 'scaled_jacobian_condition': condition,
                         'scaled_jacobian_singular_values': singular.tolist(), 'minimum_camera_depth_m': float(depth.min()),
                         'minimum_height_m': float(world[:, 2].min()), 'local_noise_sensitivity_radius_kmh': noise_radius,
                         'local_noise_sensitivity_is_calibrated_confidence': False,
                         'near_optimum_seed_speeds_kmh': near_speeds, 'feasible_initializations': len(solutions),
                         'optimization': optimization,
                         'initialization_failures': initial_failures}
        if not result['reasons']:
            result['status'] = 'diagnostic_only'
        result['reasons'].append('calibration_event_and_model_uncertainty_not_qualified_for_product_speed')
    except (ValueError, KeyError, TypeError, np.linalg.LinAlgError, OverflowError) as ex:
        result['reasons'].append(str(ex))
    return result


def synthetic(span=.8, sigma=2., seed=20261029):
    center = np.array([0., -12., 5.])
    forward = np.array([0., 12., 1.])-center; forward /= np.linalg.norm(forward)
    right = np.cross(forward, [0, 0, 1]); right /= np.linalg.norm(right)
    up = np.cross(right, forward); r = np.vstack([right, -up, forward])
    k = np.array([[1300., 0., 960.], [0., 1300., 540.], [0., 0., 1.]])
    pts = np.arange(int(round(span*60))+1)
    ts = pts/60.; p0 = np.array([0., 0., 1.2]); v0 = np.array([4., 22., 3.])
    theta = np.r_[p0, v0*span]
    uv = project(theta, ts, span, k, r, -r@center)[0]
    uv += np.random.default_rng(seed).normal(0, sigma, uv.shape)
    source_sha = hashlib.sha256(b'synthetic-exact-camera-flight-generator-v1-not-a-video-file').hexdigest()
    return {'source': {'sha256': source_sha, 'kind': 'synthetic_generator_identity_not_video_sha'},
            'camera': {'K': k.tolist(), 'R': r.tolist(), 't': (-r@center).tolist(), 'width': 1920, 'height': 1080,
                       'source_sha256': source_sha,
                       'world_units': 'metres', 'world_up_axis': 'z', 'pixel_model': 'undistorted_pinhole',
                       'calibration_basis': 'synthetic exact pinhole camera, not a user-video calibration'},
            'segment': {'camera_static': True, 'collision_free': True},
            'observations': [{'source_pts': int(n), 'source_time_base': '1/60', 'status': 'visible',
                              'source_sha256': source_sha, 'target_identity': 'confirmed', 'is_interpolated': False,
                              'x': float(uv[i, 0]), 'y': float(uv[i, 1]), 'sigma_px': max(.1, sigma)} for i, n in enumerate(pts)]}, float(np.linalg.norm(v0)*3.6)


class Tests(unittest.TestCase):
    def test_exact_metric_recovery_and_unknown_product_speed(self):
        doc, true_speed = synthetic(sigma=0.)
        out = diagnose(doc)
        self.assertEqual(out['status'], 'diagnostic_only')
        self.assertAlmostEqual(out['fit']['candidate_speed_kmh'], true_speed, places=5)
        self.assertIsNone(out['speed_kmh'])

    def test_noisy_long_flight_and_null_unobserved(self):
        doc, truth = synthetic()
        for i in (10, 20): doc['observations'][i].update(status='unknown', x=None, y=None)
        out = diagnose(doc)
        self.assertIn('fit', out)
        self.assertLess(abs(out['fit']['candidate_speed_kmh']-truth), 5.)
        self.assertEqual(out['fit']['visible_points'], 47)

    def test_short_segment_does_not_publish_speed(self):
        doc, _ = synthetic(span=.1)
        out = diagnose(doc)
        self.assertEqual(out['status'], 'rejected')
        self.assertIsNone(out['speed_kmh'])

    def test_missing_camera_and_wrong_rotation(self):
        self.assertIn('missing_camera_calibration', diagnose({})['reasons'])
        doc, _ = synthetic(); doc['camera']['R'][0][0] = 3
        self.assertIn('invalid_camera_rotation', diagnose(doc)['reasons'])

    def test_duplicate_pts_and_discontinuity_rejected(self):
        doc, _ = synthetic(); doc['observations'][2]['source_pts'] = 1
        self.assertIn('nonmonotonic_or_duplicate_pts', diagnose(doc)['reasons'])
        doc, _ = synthetic(); doc['observations'][2]['gap_before'] = True
        self.assertIn('source_discontinuity', diagnose(doc)['reasons'])

    def test_unknown_is_not_a_zero_pixel_or_synthetic_fill(self):
        doc, _ = synthetic(); doc['observations'][3]['status'] = 'occluded'
        self.assertIn('unknown_point_must_be_null', diagnose(doc)['reasons'])

    def test_collision_and_raw_distortion_rejected(self):
        doc, _ = synthetic(); doc['segment']['collision_free'] = False
        self.assertIn('collision_boundaries_unresolved', diagnose(doc)['reasons'])
        doc, _ = synthetic(); doc['camera']['pixel_model'] = 'raw_distorted'
        self.assertIn('raw_or_unknown_distortion_not_supported', diagnose(doc)['reasons'])

    def test_uncertain_or_interpolated_points_never_supervise_fit(self):
        for field, value in [('target_identity', 'uncertain'), ('is_interpolated', True)]:
            doc, _ = synthetic()
            for row in doc['observations']: row[field] = value
            self.assertIn('insufficient_visible_points', diagnose(doc)['reasons'])
        doc, _ = synthetic(); del doc['observations'][0]['target_identity']
        self.assertIn('target_identity_required', diagnose(doc)['reasons'])

    def test_malformed_time_and_row_rejected_without_exception(self):
        doc, _ = synthetic(); doc['observations'][0]['source_time_base'] = '1/0'
        self.assertIn('invalid_time_base', diagnose(doc)['reasons'])
        doc, _ = synthetic(); doc['observations'][0] = 0
        self.assertIn('observation_must_be_object', diagnose(doc)['reasons'])
        self.assertIn('input_document_must_be_object', diagnose([])['reasons'])

    def test_intrinsics_types_and_source_binding(self):
        for field, value, reason in [('K', [['1300', 0, 960], [0, 1300, 540], [0, 0, 1]], 'invalid_K'),
                                     ('width', True, 'invalid_image_size'),
                                     ('source_sha256', 'b'*64, 'camera_source_binding_mismatch')]:
            doc, _ = synthetic(); doc['camera'][field] = value
            self.assertIn(reason, diagnose(doc)['reasons'])
        doc, _ = synthetic(); doc['observations'][0]['source_sha256'] = 'a'*64
        self.assertIn('observation_source_binding_mismatch', diagnose(doc)['reasons'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--input'); parser.add_argument('--output')
    args = parser.parse_args()
    if args.self_test:
        return 0 if unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Tests)).wasSuccessful() else 1
    parser.error('--input and --output are required') if not args.input or not args.output else None
    path = Path(args.input)
    report = diagnose(json.loads(path.read_text()))
    report['input_sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
    report['runner_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    with open(args.output, 'x') as handle:
        json.dump(report, handle, indent=2, allow_nan=False); handle.write('\n')
    print(json.dumps({'status': report['status'], 'speed_kmh': report['speed_kmh'], 'output': args.output}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
