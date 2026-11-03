#!/usr/bin/env python3
"""Source-bound plane-plus-elevated-landmark calibration diagnostic.

NumPy is required. Pillow is required only when frame_image_path is supplied;
that optional path is read for its SHA256 and image-header dimensions, never as
a video or for automatic point selection. CLI: --input JSON --output NEWJSON,
or --self-test. See synthetic_document() for a complete generated input example.

This tool does not certify calibration, remove distortion, estimate speed, or
feed the legacy flight fitter. Its top-level camera and speed remain null.
"""
import argparse
import copy
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import stat
import sys
import tempfile
import unittest

import numpy as np


BASES = {'synthetic_exact', 'declared_assumption', 'measured_unverified'}
AXES = 'court_near_left_x_right_y_far_z_up_m'
POLICY = {
    'version': 'plane-elevated-general-intrinsics-diagnostic-v1',
    'method': 'normalized_ground_DLT_then_third_column_SVD_then_RQ',
    'minimum_ground_fit_points': 4, 'minimum_elevated_fit_points': 2,
    'maximum_landmarks': 512, 'rank_relative_tolerance': 1e-10,
    'maximum_normalized_design_condition': 1e10,
    'maximum_finite_camera_condition': 1e12,
    'minimum_absolute_elevated_height_m': 1e-9,
    'minimum_camera_depth_m': .01, 'minimum_camera_height_m': 1e-6,
    'maximum_input_bytes': 4 * 1024 * 1024,
    'maximum_optional_image_bytes': 64 * 1024 * 1024,
    'valid_pts_interval': 'half_open_start_inclusive_end_exclusive; exact rational time comparison',
    'uncertainty_propagated': False,
}


class Rejected(ValueError):
    def __init__(self, reason, diagnostics=None):
        super().__init__(reason)
        self.diagnostics = diagnostics or {}


def require(condition, reason):
    if not condition:
        raise Rejected(reason)


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def vector(value, count, name):
    require(isinstance(value, list) and len(value) == count and all(finite(x) for x in value), 'invalid_' + name)
    require(all(abs(x) <= 1e12 for x in value), 'input_magnitude_out_of_bounds_' + name)
    return np.array(value, dtype=float)


def text(value, name):
    require(isinstance(value, str) and bool(value.strip()) and len(value) <= 1024, 'invalid_' + name)
    return value


def digest_string(value, name):
    require(isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value), 'invalid_' + name)
    return value


def integer(value, name):
    require(isinstance(value, int) and not isinstance(value, bool) and -(2**63) <= value < 2**63, 'invalid_' + name)
    return value


def time_base(value):
    require(isinstance(value, str) and 0 < len(value) <= 64, 'invalid_time_base')
    try:
        result = Fraction(value)
    except (ValueError, ZeroDivisionError):
        raise Rejected('invalid_time_base')
    require(result > 0 and result.numerator <= 2**31-1 and result.denominator <= 2**31-1, 'invalid_time_base')
    return result


def bounded_json(value, depth=0):
    require(depth <= 16, 'input_nesting_too_deep')
    if isinstance(value, dict):
        require(len(value) <= 1024, 'too_many_object_fields')
        for child in value.values():
            bounded_json(child, depth+1)
    elif isinstance(value, list):
        require(len(value) <= 4096, 'input_array_too_large')
        for child in value:
            bounded_json(child, depth+1)
    elif isinstance(value, (int, float)) and not isinstance(value, bool):
        require(finite(value), 'nonfinite_input')


def file_hash(path):
    value = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def verify_optional_image(source):
    if 'frame_image_path' not in source:
        return {'provided': False, 'hash_and_dimensions_verified': False,
                'limit': 'Caller-supplied image digest is not authenticated without an explicit image path.'}
    value = text(source['frame_image_path'], 'frame_image_path')
    path = Path(value)
    require(path.is_absolute() and '://' not in value, 'frame_image_path_must_be_absolute_local')
    require(path.suffix.lower() in {'.jpg', '.jpeg', '.png', '.webp', '.tif', '.tiff', '.bmp'}, 'frame_image_path_must_be_image_not_video')
    before = path.stat()
    require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= POLICY['maximum_optional_image_bytes'], 'invalid_image_file')
    require(file_hash(path) == source['frame_image_sha256'], 'frame_image_sha256_mismatch')
    try:
        from PIL import Image
    except ImportError:
        raise Rejected('pillow_required_for_optional_image_header_check')
    # Only inspect stored dimensions. In particular, getexif() on some formats
    # can load pixels; orientation is the caller's explicit unrotated contract.
    try:
        with Image.open(path) as image:
            require(image.size == (source['width'], source['height']), 'frame_image_dimensions_mismatch')
    except Rejected:
        raise
    except Exception as error:
        raise Rejected('invalid_image_header: '+str(error))
    after = path.stat()
    require((before.st_size, before.st_mtime_ns, before.st_ino) ==
            (after.st_size, after.st_mtime_ns, after.st_ino), 'frame_image_changed_during_verification')
    return {'provided': True, 'path': str(path), 'bytes': after.st_size,
            'hash_and_dimensions_verified': True, 'image_pixels_decoded': False}


def validate(doc):
    require(isinstance(doc, dict), 'input_document_must_be_object')
    bounded_json(doc)
    require(type(doc.get('schema_version')) is int and doc['schema_version'] == 1, 'unsupported_schema_version')
    source, world, context = doc.get('source'), doc.get('world'), doc.get('camera_context')
    require(isinstance(source, dict), 'missing_source_binding')
    digest_string(source.get('sha256'), 'source_sha256')
    digest_string(source.get('frame_image_sha256'), 'frame_image_sha256')
    for name in ['width', 'height']:
        value = integer(source.get(name), name)
        require(1 <= value <= 16384, 'invalid_image_dimensions')
    require(source.get('coordinate_space') == 'decoded_top_left_unrotated', 'unknown_pixel_coordinate_space')
    text(source.get('frame_transform_id'), 'frame_transform_id')
    frame_pts = integer(source.get('frame_pts'), 'frame_pts')
    frame_time = frame_pts * time_base(source.get('frame_time_base'))
    require(isinstance(world, dict) and world.get('units') == 'metres' and
            world.get('up_axis') == 'z' and world.get('axes') == AXES, 'invalid_metric_world_axes_or_units')
    require(isinstance(context, dict), 'missing_camera_context')
    require(context.get('pixel_model') in {'undistorted_pinhole', 'raw_unknown'}, 'invalid_pixel_model')
    distortion = context.get('distortion_basis')
    require(isinstance(distortion, dict), 'missing_distortion_basis')
    text(distortion.get('description'), 'distortion_basis_description')
    if 'range_spec' in distortion:
        require(isinstance(distortion['range_spec'], dict) and bool(distortion['range_spec']), 'invalid_distortion_range_spec')
    static = context.get('static_camera')
    require(isinstance(static, dict) and isinstance(static.get('declared'), bool), 'missing_static_camera_declaration')
    text(static.get('basis'), 'static_camera_basis')
    interval = context.get('valid_pts_interval')
    require(isinstance(interval, dict), 'missing_valid_pts_interval')
    start, end = integer(interval.get('start_pts'), 'interval_start_pts'), integer(interval.get('end_pts'), 'interval_end_pts')
    base = time_base(interval.get('time_base'))
    require(start < end and start*base <= frame_time < end*base, 'frame_outside_declared_valid_interval')
    rows = doc.get('landmarks')
    require(isinstance(rows, list) and len(rows) <= POLICY['maximum_landmarks'], 'invalid_landmark_list')
    ids, landmarks = set(), []
    for row in rows:
        require(isinstance(row, dict), 'landmark_must_be_object')
        identifier = text(row.get('id'), 'landmark_id')
        require(identifier not in ids, 'duplicate_landmark_id')
        ids.add(identifier)
        require(row.get('role') in {'fit_ground', 'fit_elevated', 'check'}, 'invalid_landmark_role')
        xy, xyz = vector(row.get('xy_px'), 2, 'landmark_pixel'), vector(row.get('xyz_m'), 3, 'landmark_xyz')
        require(0 <= xy[0] < source['width'] and 0 <= xy[1] < source['height'], 'landmark_outside_image')
        require(row.get('pixel_basis') in BASES and row.get('xyz_basis') in BASES, 'invalid_landmark_basis')
        radius = row.get('pixel_radius_px')
        require(finite(radius) and 0 <= radius <= 1e12, 'invalid_pixel_radius_px')
        xyz_radius = vector(row.get('xyz_radius_m'), 3, 'xyz_radius_m')
        require(np.all(xyz_radius >= 0), 'negative_xyz_radius_m')
        if row['role'] == 'fit_ground':
            require(xyz[2] == 0, 'ground_fit_point_must_have_zero_height')
        elif row['role'] == 'fit_elevated':
            require(abs(xyz[2]) > POLICY['minimum_absolute_elevated_height_m'], 'elevated_fit_point_has_zero_or_tiny_height')
        landmarks.append({key: copy.deepcopy(row[key]) for key in
                          ['id', 'role', 'xy_px', 'xyz_m', 'pixel_basis', 'xyz_basis', 'pixel_radius_px', 'xyz_radius_m']})
    ground = [x for x in landmarks if x['role'] == 'fit_ground']
    elevated = [x for x in landmarks if x['role'] == 'fit_elevated']
    require(len(ground) >= POLICY['minimum_ground_fit_points'], 'at_least_four_ground_fit_points_required')
    require(len(elevated) >= POLICY['minimum_elevated_fit_points'], 'at_least_two_elevated_fit_points_required')
    verification = verify_optional_image(source)
    return source, world, context, landmarks, ground, elevated, verification


def normalizer(points):
    center = points.mean(axis=0)
    rms = float(np.sqrt(np.mean(np.sum((points-center)**2, axis=1))))
    require(math.isfinite(rms) and rms > 1e-12, 'collapsed_landmark_configuration')
    scale = math.sqrt(points.shape[1])/rms
    matrix = np.eye(points.shape[1]+1)
    matrix[:-1, :-1] *= scale
    matrix[:-1, -1] = -scale*center
    return matrix


def normalized_ground_homography(xy, uv):
    tx, tu = normalizer(xy), normalizer(uv)
    x = np.column_stack([xy, np.ones(len(xy))]) @ tx.T
    u = np.column_stack([uv, np.ones(len(uv))]) @ tu.T
    rows = []
    for (a, b, _), (p, q, _) in zip(x, u):
        rows.extend([[-a, -b, -1, 0, 0, 0, p*a, p*b, p],
                     [0, 0, 0, -a, -b, -1, q*a, q*b, q]])
    _, singular, vt = np.linalg.svd(rows, full_matrices=True)
    tolerance = singular[0]*POLICY['rank_relative_tolerance']
    rank = int(np.count_nonzero(singular > tolerance))
    # Four points give an 8x9 matrix with eight returned singular values. The
    # eighth essential singular value is index7, including that minimal case.
    condition = float(singular[0]/singular[7]) if rank >= 8 else None
    info = {'normalized_singular_values': singular.tolist(), 'numerical_rank': rank,
            'essential_condition_excluding_projective_null': condition,
            'world_xy_normalization': tx.tolist(), 'pixel_normalization': tu.tolist()}
    if rank < 8:
        raise Rejected('ground_DLT_rank_below_eight', {'ground_DLT': info})
    if condition > POLICY['maximum_normalized_design_condition']:
        raise Rejected('ill_conditioned_normalized_ground_DLT', {'ground_DLT': info})
    hn = vt[-1].reshape(3, 3) @ tx
    hn /= np.linalg.norm(hn)
    return hn, tu, info


def third_column(hn, tu, xyz, uv):
    normalized_uv = np.column_stack([uv, np.ones(len(uv))]) @ tu.T
    matrix, rhs = [], []
    for point, (u, v, _) in zip(xyz, normalized_uv):
        base = hn @ np.array([point[0], point[1], 1.])
        height = point[2]
        matrix.extend([height*np.array([1., 0., -u]), height*np.array([0., 1., -v])])
        rhs.extend([u*base[2]-base[0], v*base[2]-base[1]])
    q, _, rank, singular = np.linalg.lstsq(matrix, rhs, rcond=POLICY['rank_relative_tolerance'])
    condition = float(singular[0]/singular[-1]) if rank == 3 else None
    info = {'rank': int(rank), 'normalized_image_design_singular_values': singular.tolist(),
            'condition': condition, 'height_unit': 'metres',
            'limit': 'Image normalization does not remove height uncertainty or guarantee physical speed precision.'}
    if rank != 3:
        raise Rejected('elevated_column_rank_below_three_same_or_degenerate_image_rays', {'elevated_column': info})
    if condition > POLICY['maximum_normalized_design_condition']:
        raise Rejected('ill_conditioned_normalized_elevated_design', {'elevated_column': info})
    projection = np.linalg.solve(tu, np.column_stack([hn[:, 0], hn[:, 1], q, hn[:, 2]]))
    return projection, info


def decompose_projection(projection, points):
    p = projection.copy()
    matrix = p[:, :3]
    condition = float(np.linalg.cond(matrix))
    require(math.isfinite(condition) and condition < POLICY['maximum_finite_camera_condition'], 'singular_finite_camera_matrix')
    if np.linalg.det(matrix) < 0:
        p = -p
        matrix = -matrix
    require(np.linalg.det(matrix) > 0, 'invalid_projection_handedness')
    reverse = np.fliplr(np.eye(3))
    qr_q, qr_r = np.linalg.qr(reverse @ matrix.T @ reverse)
    k, r = reverse @ qr_r.T @ reverse, reverse @ qr_q.T @ reverse
    signs = np.sign(np.diag(k))
    require(np.all(signs != 0), 'zero_intrinsic_diagonal')
    diagonal = np.diag(signs)
    k, r = k @ diagonal, diagonal @ r
    require(np.max(np.abs(r.T @ r-np.eye(3))) <= 1e-7 and abs(np.linalg.det(r)-1) <= 1e-7, 'invalid_right_handed_camera_rotation')
    scale = k[2, 2]
    require(math.isfinite(scale) and scale > 0, 'invalid_intrinsic_scale')
    k, p = k/scale, p/scale
    require(k[0, 0] > 0 and k[1, 1] > 0 and np.isfinite(k).all(), 'nonpositive_or_nonfinite_focal_length')
    t = np.linalg.solve(k, p[:, 3])
    center = -r.T @ t
    require(np.isfinite(t).all() and np.isfinite(center).all(), 'nonfinite_camera_pose')
    require(center[2] > POLICY['minimum_camera_height_m'], 'camera_not_above_declared_ground')
    reconstructed = k @ np.column_stack([r, t])
    reconstruction_error = float(np.linalg.norm(reconstructed-p)/np.linalg.norm(p))
    require(reconstruction_error <= 1e-8, 'RQ_projection_reconstruction_mismatch')
    depth = (points @ r.T+t)[:, 2]
    require(np.isfinite(depth).all() and np.all(depth > POLICY['minimum_camera_depth_m']), 'nonpositive_or_near_camera_landmark_depth')
    return k, r, t, center, p, {'finite_camera_matrix_condition': condition,
                               'minimum_landmark_depth_m': float(depth.min()),
                               'relative_RQ_reconstruction_error': reconstruction_error}


def reproject(projection, rows):
    if not rows:
        return {'count': 0, 'rms_px': None, 'maximum_error_px': None, 'points': []}
    xyz, observed = np.array([r['xyz_m'] for r in rows]), np.array([r['xy_px'] for r in rows])
    homogeneous = np.column_stack([xyz, np.ones(len(xyz))]) @ projection.T
    predicted = homogeneous[:, :2]/homogeneous[:, 2, None]
    require(np.isfinite(predicted).all(), 'nonfinite_landmark_reprojection')
    errors = np.linalg.norm(predicted-observed, axis=1)
    return {'count': len(rows), 'rms_px': float(np.sqrt(np.mean(errors**2))),
            'maximum_error_px': float(errors.max()),
            'points': [{'id': row['id'], 'role': row['role'], 'observed_xy_px': row['xy_px'],
                        'projected_xy_px': pred.tolist(), 'error_px': float(error),
                        'input_pixel_radius_px': row['pixel_radius_px']} for row, pred, error in zip(rows, predicted, errors)]}


def diagnose(doc):
    result = {'schema_version': 1, 'status': 'rejected', 'camera': None, 'camera_candidate': None,
              'production': False, 'calibration_qualified': False, 'speed_kmh': None,
              'reasons': [], 'conditional_reasons': [], 'policy': POLICY,
              'limits': ['Low reprojection error does not establish calibration, true height, distortion or physical speed accuracy.',
                         'Landmark provenance and camera-static intervals are caller declarations, not verified human identity or measurements.',
                         'This two-stage algebraic fit freezes a noisy ground H; no joint nonlinear refinement or uncertainty propagation is implemented.',
                         'The candidate is not a legacy camera_from input and is never automatically applied to a flight or App.']}
    try:
        source, world, context, rows, ground, elevated, verification = validate(doc)
        result['input_binding'] = {key: copy.deepcopy(source[key]) for key in
                                   ['sha256', 'frame_image_sha256', 'frame_pts', 'frame_time_base', 'width', 'height', 'coordinate_space', 'frame_transform_id']}
        result['image_verification'] = verification
        result['input_landmarks'] = rows
        ground_xyz, ground_uv = np.array([r['xyz_m'] for r in ground]), np.array([r['xy_px'] for r in ground])
        elevated_xyz, elevated_uv = np.array([r['xyz_m'] for r in elevated]), np.array([r['xy_px'] for r in elevated])
        hn, tu, ground_info = normalized_ground_homography(ground_xyz[:, :2], ground_uv)
        result['geometry_diagnostics'] = {'ground_DLT': ground_info}
        projection, column_info = third_column(hn, tu, elevated_xyz, elevated_uv)
        result['geometry_diagnostics']['elevated_column'] = column_info
        k, r, t, center, p, pose_info = decompose_projection(projection, np.array([row['xyz_m'] for row in rows]))
        result['geometry_diagnostics']['pose'] = pose_info
        checks = [row for row in rows if row['role'] == 'check']
        result['reprojection'] = {'fit_ground': reproject(p, ground), 'fit_elevated': reproject(p, elevated),
                                  'held_out_check': reproject(p, checks),
                                  'check_independence_verified': False,
                                  'check_role_semantics': 'Held out from this solve only; human or capture independence is not certified.'}
        conditional = ['conditional_algebraic_camera_only', 'uncertainty_not_propagated',
                       'static_interval_is_recorded_caller_declaration_only', 'human_and_physical_qualification_not_established']
        if context['pixel_model'] == 'raw_unknown':
            conditional.append('raw_unknown_distortion_not_removed_or_qualified')
            if 'range_spec' not in context['distortion_basis']:
                conditional.append('unknown_distortion_has_no_declared_range')
        if not checks:
            conditional.append('independent_check_landmarks_missing')
        elif not any(abs(row['xyz_m'][2]) > POLICY['minimum_absolute_elevated_height_m'] for row in checks):
            conditional.append('elevated_check_landmarks_missing')
        fit_xyz = {tuple(row['xyz_m']) for row in ground+elevated}
        if any(tuple(row['xyz_m']) in fit_xyz for row in checks):
            conditional.append('check_landmark_overlaps_fit_world_coordinate')
        if checks and any(point['error_px'] > point['input_pixel_radius_px']+1e-7 for point in result['reprojection']['held_out_check']['points']):
            conditional.append('check_reprojection_exceeds_declared_pixel_radius')
        if any(row['xyz_basis'] != 'synthetic_exact' and row['xyz_radius_m'][2] == 0 for row in elevated):
            conditional.append('elevated_height_uncertainty_has_no_nonzero_declared_range')
        if any(row['pixel_basis'] != 'synthetic_exact' or row['xyz_basis'] != 'synthetic_exact' for row in rows):
            conditional.append('landmark_measurements_or_assumptions_not_independently_verified')
        if not context['static_camera']['declared']:
            conditional.append('static_camera_not_declared')
        result['conditional_reasons'] = conditional
        result['camera_candidate'] = {'K': k.tolist(), 'R': r.tolist(), 't': t.tolist(),
            'width': source['width'], 'height': source['height'], 'world_units': world['units'],
            'world_up_axis': world['up_axis'], 'axes': world['axes'], 'pixel_model': context['pixel_model'],
            'distortion_basis': copy.deepcopy(context['distortion_basis']),
            'calibration_basis': 'conditional_plane_plus_elevated_landmarks_unqualified_v1',
            'source_sha256': source['sha256'], 'frame_image_sha256': source['frame_image_sha256'],
            'frame_pts': source['frame_pts'], 'frame_time_base': source['frame_time_base'],
            'frame_transform_id': source['frame_transform_id'], 'coordinate_space': source['coordinate_space'],
            'valid_pts_interval': copy.deepcopy(context['valid_pts_interval']),
            'static_camera': copy.deepcopy(context['static_camera'])}
        result['geometry_diagnostics']['camera_center_m'] = center.tolist()
        result['geometry_diagnostics']['projection_matrix'] = p.tolist()
        result['status'] = 'conditional_candidate'
    except (Rejected, ValueError, TypeError, KeyError, OSError, OverflowError, np.linalg.LinAlgError) as error:
        result['reasons'].append(str(error))
        if isinstance(error, Rejected) and error.diagnostics:
            result.setdefault('geometry_diagnostics', {}).update(error.diagnostics)
        result['camera_candidate'] = None
    return result


def synthetic_document():
    """Generated exact general-K case; no real frame, point or video is read."""
    k = np.array([[1400., 20., 935.], [0., 1360., 555.], [0., 0., 1.]])
    center, aim = np.array([5.485, -10., 3.2]), np.array([5.485, 11.885, .4])
    forward = aim-center; forward /= np.linalg.norm(forward)
    right = np.cross(forward, [0, 0, 1]); right /= np.linalg.norm(right)
    r = np.vstack([right, np.cross(forward, right), forward])
    t = -r @ center
    p = k @ np.column_stack([r, t])
    ground = [[0, 0, 0], [10.97, 0, 0], [0, 23.77, 0], [10.97, 23.77, 0],
              [1.37, 5.485, 0], [9.6, 5.485, 0], [1.37, 18.285, 0], [9.6, 18.285, 0]]
    elevated = [[-.914, 11.885, 1.07], [11.884, 11.885, 1.07]]
    checks = [[5.485, 0, 0], [2., 4., 2.], [8., 19., 1.5]]
    landmarks = []
    for role, points in [('fit_ground', ground), ('fit_elevated', elevated), ('check', checks)]:
        for index, point in enumerate(points):
            uvw = p @ np.r_[point, 1.]
            landmarks.append({'id': role+'-'+str(index), 'role': role, 'xy_px': (uvw[:2]/uvw[2]).tolist(),
                              'xyz_m': point, 'pixel_basis': 'synthetic_exact', 'xyz_basis': 'synthetic_exact',
                              'pixel_radius_px': 0., 'xyz_radius_m': [0., 0., 0.]})
    doc = {'schema_version': 1,
           'source': {'sha256': hashlib.sha256(b'synthetic-source-identity-not-video').hexdigest(),
                      'frame_image_sha256': hashlib.sha256(b'synthetic-frame-identity-not-real-image').hexdigest(),
                      'width': 1920, 'height': 1080, 'coordinate_space': 'decoded_top_left_unrotated',
                      'frame_transform_id': 'synthetic-exact-unrotated-v1', 'frame_pts': 0, 'frame_time_base': '1/60'},
           'world': {'units': 'metres', 'up_axis': 'z', 'axes': AXES},
           'camera_context': {'pixel_model': 'undistorted_pinhole', 'distortion_basis': {'description': 'Synthetic exact pinhole; no real lens'},
                              'static_camera': {'declared': True, 'basis': 'Synthetic exact fixed pose'},
                              'valid_pts_interval': {'start_pts': 0, 'end_pts': 60, 'time_base': '1/60'}},
           'landmarks': landmarks}
    return doc, {'K': k, 'R': r, 't': t, 'C': center}


class Tests(unittest.TestCase):
    def reject(self, doc, reason):
        result = diagnose(doc)
        self.assertEqual(result['status'], 'rejected', result)
        self.assertIsNone(result['camera_candidate'])
        self.assertIn(reason, result['reasons'])
        self.assertIsNone(result['camera'])
        self.assertIsNone(result['speed_kmh'])

    def test_general_intrinsics_and_heldout_recovery(self):
        doc, truth = synthetic_document(); result = diagnose(doc)
        self.assertEqual(result['status'], 'conditional_candidate', result)
        for key in ['K', 'R', 't']:
            np.testing.assert_allclose(result['camera_candidate'][key], truth[key], atol=1e-7)
        self.assertLess(result['reprojection']['held_out_check']['rms_px'], 1e-7)
        self.assertIsNone(result['camera']); self.assertIsNone(result['speed_kmh'])
        self.assertFalse(result['calibration_qualified']); self.assertFalse(result['production'])

    def test_minimum_four_ground_points(self):
        doc, truth = synthetic_document()
        doc['landmarks'] = [x for x in doc['landmarks'] if x['role'] != 'fit_ground' or int(x['id'].split('-')[-1]) < 4]
        result = diagnose(doc)
        self.assertEqual(result['status'], 'conditional_candidate', result)
        np.testing.assert_allclose(result['camera_candidate']['K'], truth['K'], atol=1e-7)

    def test_one_elevated_rejected(self):
        doc, _ = synthetic_document(); doc['landmarks'] = [x for x in doc['landmarks'] if x['id'] != 'fit_elevated-1']
        self.reject(doc, 'at_least_two_elevated_fit_points_required')

    def test_same_image_ray_rejected(self):
        doc, _ = synthetic_document(); off = [x for x in doc['landmarks'] if x['role'] == 'fit_elevated']
        off[1]['xy_px'] = off[0]['xy_px'][:]
        self.reject(doc, 'elevated_column_rank_below_three_same_or_degenerate_image_rays')
        self.assertEqual(diagnose(doc)['geometry_diagnostics']['elevated_column']['rank'], 2)

    def test_zero_height_and_collinear_ground_rejected(self):
        doc, _ = synthetic_document(); next(x for x in doc['landmarks'] if x['role'] == 'fit_elevated')['xyz_m'][2] = 0
        self.reject(doc, 'elevated_fit_point_has_zero_or_tiny_height')
        doc, _ = synthetic_document()
        for index, row in enumerate(x for x in doc['landmarks'] if x['role'] == 'fit_ground'):
            row['xyz_m'] = [float(index), 0., 0.]
        self.reject(doc, 'ground_DLT_rank_below_eight')

    def test_duplicate_ids_nonfinite_units_and_binding(self):
        for mutate, reason in [
            (lambda d: d['landmarks'][1].update(id=d['landmarks'][0]['id']), 'duplicate_landmark_id'),
            (lambda d: d['landmarks'][0].update(xy_px=[float('nan'), 4]), 'nonfinite_input'),
            (lambda d: d['world'].update(units='feet'), 'invalid_metric_world_axes_or_units'),
            (lambda d: d['source'].update(sha256='bad'), 'invalid_source_sha256'),
            (lambda d: d['source'].update(frame_image_sha256='bad'), 'invalid_frame_image_sha256'),
            (lambda d: d['source'].update(coordinate_space='rotated'), 'unknown_pixel_coordinate_space'),
            (lambda d: d['source'].update(frame_time_base='1/0'), 'invalid_time_base'),
            (lambda d: d['source'].update(frame_pts=60), 'frame_outside_declared_valid_interval'),
            (lambda d: d['landmarks'][0].update(xyz_radius_m=[0, -1, 0]), 'negative_xyz_radius_m')]:
            with self.subTest(reason=reason):
                doc, _ = synthetic_document(); mutate(doc); self.reject(doc, reason)

    def test_unknown_raw_and_unverified_basis_are_never_upgraded(self):
        doc, _ = synthetic_document(); doc['camera_context']['pixel_model'] = 'raw_unknown'
        for row in doc['landmarks']: row['xyz_basis'] = 'measured_unverified'
        result = diagnose(doc)
        self.assertEqual(result['status'], 'conditional_candidate', result)
        self.assertEqual(result['camera_candidate']['pixel_model'], 'raw_unknown')
        self.assertIn('unknown_distortion_has_no_declared_range', result['conditional_reasons'])
        self.assertIn('elevated_height_uncertainty_has_no_nonzero_declared_range', result['conditional_reasons'])
        self.assertFalse(result['calibration_qualified']); self.assertIsNone(result['camera'])

    def test_wrong_heights_can_have_tiny_fit_residual_and_bad_checks(self):
        doc, truth = synthetic_document()
        for row in doc['landmarks']:
            if row['role'] == 'fit_elevated':
                row['xyz_m'][2] = .8; row['xyz_basis'] = 'declared_assumption'
        result = diagnose(doc)
        self.assertEqual(result['status'], 'conditional_candidate', result)
        self.assertLess(result['reprojection']['fit_elevated']['rms_px'], 1e-7)
        self.assertGreater(result['reprojection']['held_out_check']['rms_px'], 1.)
        self.assertGreater(float(np.linalg.norm(np.array(result['camera_candidate']['K'])-truth['K'])), 1.)
        self.assertIn('check_reprojection_exceeds_declared_pixel_radius', result['conditional_reasons'])
        self.assertIsNone(result['camera']); self.assertIsNone(result['speed_kmh'])

    def test_missing_checks_and_static_claim_remain_conditional(self):
        doc, _ = synthetic_document(); doc['landmarks'] = [x for x in doc['landmarks'] if x['role'] != 'check']
        doc['camera_context']['static_camera']['declared'] = False
        result = diagnose(doc)
        self.assertEqual(result['status'], 'conditional_candidate', result)
        self.assertIn('independent_check_landmarks_missing', result['conditional_reasons'])
        self.assertIn('static_camera_not_declared', result['conditional_reasons'])
        self.assertFalse(result['camera_candidate']['static_camera']['declared'])

    def test_nonpositive_depth_rejected(self):
        doc, truth = synthetic_document()
        point = truth['C']-truth['R'][2]*3
        p = truth['K'] @ np.column_stack([truth['R'], truth['t']]); uvw = p @ np.r_[point, 1.]
        doc['landmarks'].append({'id': 'behind-camera-check', 'role': 'check', 'xy_px': (uvw[:2]/uvw[2]).tolist(),
                                 'xyz_m': point.tolist(), 'pixel_basis': 'synthetic_exact', 'xyz_basis': 'synthetic_exact',
                                 'pixel_radius_px': 0., 'xyz_radius_m': [0., 0., 0.]})
        self.reject(doc, 'nonpositive_or_near_camera_landmark_depth')

    def test_optional_image_hash_and_dimensions(self):
        from PIL import Image
        with tempfile.TemporaryDirectory(prefix='camera-calibration-synthetic-') as directory:
            path = Path(directory)/'synthetic.png'; Image.new('RGB', (1920, 1080)).save(path)
            doc, _ = synthetic_document(); doc['source']['frame_image_path'] = str(path)
            self.reject(doc, 'frame_image_sha256_mismatch')
            doc['source']['frame_image_sha256'] = file_hash(path)
            result = diagnose(doc)
            self.assertEqual(result['status'], 'conditional_candidate', result)
            self.assertTrue(result['image_verification']['hash_and_dimensions_verified'])
            Image.new('RGB', (10, 10)).save(path); doc['source']['frame_image_sha256'] = file_hash(path)
            self.reject(doc, 'frame_image_dimensions_mismatch')


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate_JSON_key')
        result[key] = value
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input'); parser.add_argument('--output')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        return 0 if unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Tests)).wasSuccessful() else 1
    if not args.input or not args.output:
        parser.error('--input and --output are required')
    output = Path(args.output)
    if output.exists():
        print('Refusing to overwrite output: '+str(output), file=sys.stderr)
        return 2
    try:
        path = Path(args.input)
        require(path.stat().st_size <= POLICY['maximum_input_bytes'], 'input_document_too_large')
        data = path.read_bytes()
        document = json.loads(data, object_pairs_hook=unique_object,
                              parse_constant=lambda value: (_ for _ in ()).throw(Rejected('nonfinite_input')))
        result = diagnose(document)
        result['input_sha256'] = hashlib.sha256(data).hexdigest()
    except (Rejected, ValueError, OSError, UnicodeError) as error:
        result = {'schema_version': 1, 'status': 'rejected', 'camera': None, 'camera_candidate': None,
                  'production': False, 'calibration_qualified': False, 'speed_kmh': None,
                  'reasons': [str(error)], 'policy': POLICY}
    result['runner_sha256'] = file_hash(Path(__file__))
    try:
        with output.open('x') as handle:
            json.dump(result, handle, ensure_ascii=False, indent=2, allow_nan=False)
            handle.write('\n')
    except (OSError, ValueError) as error:
        print('Cannot save new diagnostic output: '+str(error), file=sys.stderr)
        return 2
    print(json.dumps({'status': result['status'], 'camera': None, 'calibration_qualified': False,
                      'speed_kmh': None, 'reasons': result['reasons'], 'output': str(output)}))
    return 0 if result['status'] == 'conditional_candidate' else 1


if __name__ == '__main__':
    sys.exit(main())
