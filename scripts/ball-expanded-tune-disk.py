#!/usr/bin/env python3
"""Target-only custom fine-tune wrapper around the frozen numerical runner.

Only training target encoding changes: official binary disk radius2.5 and
integer truncation, adapted to our explicit visible/unknown status. This is NOT
the author's complete training recipe: balanced_wbce and its per-class mass
normalization remain custom and unchanged. Annotation uncertainty is metadata,
not a Gaussian sigma, physical ball radius, or calibrated uncertainty.

CLI matches ball-expanded-tune-numeric.py: propose/run with the same flags.
--self-test extracts only the pinned official target function via AST and uses
synthetic arrays/tensors. It constructs no model and runs no model forward/fit.
New execution requires a separately frozen intent/protocol and explicit flags.
"""
import ast
import copy
import hashlib
import importlib.util
import math
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve()
PARENT = HERE.with_name('ball-expanded-tune-numeric.py')
PARENT_SHA256 = 'cf42fea5b2acc284ba9b3aa80e5e115c44bdceb97fe33857bb4d72fae7d7075c'
spec = importlib.util.spec_from_file_location('expanded_frozen_disk_numeric_bridge', PARENT)
numeric = importlib.util.module_from_spec(spec)
spec.loader.exec_module(numeric)
numeric.__doc__ = __doc__  # Reuse its CLI parser with this wrapper's accurate help.
original, tune, require = numeric.original, numeric.tune, numeric.require
np, torch = original.np, original.torch
parent_proposal = numeric.proposal
unchanged_loss = tune.balanced_wbce
unchanged_factory = tune.factory
unchanged_functions = {name: getattr(original, name) for name in
    ('train', 'full_model', 'model_contract', 'fixed_schedule', 'evaluate', 'execute', 'success')}
unchanged_tracker = {name: value for name, value in vars(original.causal.assoc).items()
                     if callable(value) and getattr(value, '__module__', None) == original.causal.assoc.__name__}
SOURCE = tune.OFFICIAL/'TrackNetV3'
DATASET = SOURCE/'dataset.py'
GENERAL = SOURCE/'utils/general.py'
SOURCE_FILES = {
    str(DATASET): 'c8cf51f8fd59e466f3a1916ba99b24ac8b487ff85f69362ee72758b6b1643f92',
    str(GENERAL): '7c7bdbac3d341302652292c0d62d848235ef774d4579f421797938eae230c3b4',
}
FUNCTION_SHA256 = '106ca912d1cf30b6f10fed6999bf934374d6bb924fd6537aa34d886be2ec656b'
POLICY_ID = 'binary_disk_radius2_5_v1'
RADIUS = 2.5
POLICY = {
    'policy_id': POLICY_ID,
    'scope': 'target-only custom fine-tune; not the complete official author training recipe',
    'source_commit': tune.PIN,
    'source_function': 'dataset.py::Shuttlecock_Trajectory_Dataset._get_heatmap',
    'source_function_sha256': FUNCTION_SHA256,
    'source_function_sha256_encoding': 'UTF-8 ast.get_source_segment without trailing newline',
    'source_dependency_sha256': SOURCE_FILES,
    'model_size_wh': [tune.W, tune.H],
    'radius_model_px': RADIUS,
    'values': [0., 1.],
    'center_scaling': 'unchanged full ROI: (x-x0)*512/(x1-x0), (y-y0)*288/(y1-y0)',
    'raster_center': 'int(scaled_x), int(scaled_y), truncation toward zero like official dataset callsites',
    'raster_rule': '(column-cx)^2+(row-cy)^2 <= 2.5^2; clip at image boundaries',
    'official_origin_sentinel_adaptation': 'official (0,0) means absent; our confirmed-visible origin uses clipped disk/mask1; unknown uses mask0',
    'unknown': 'unknown/unlabelled/unconfirmed/absent mask0; all-unknown group skip unchanged',
    'uncertainty': 'source_annotation_uncertainty_px metadata only, unused in target values or radius',
    'unchanged': 'labels, source family, input tensors, 647visible/73unknown/88groups, schedule1024, '
        'official base initialization, Adam, all parameters, BN eval/buffers, balanced_wbce including '
        'per-class mass normalization, numerical gates, threshold>.3, tracker and evaluation',
    'qualification': 'development agent labels only; no human/formal/physical/speed qualification or automatic promotion',
    'fit_ledger': {'previous_completed_expanded_fits': 1, 'previous_optimizer_steps': 1024,
        'previous_qualified_expanded_fits': 0, 'current_allowed_fits': 1, 'current_allowed_steps': 1024,
        'numerical_revision_previous_optimizer_steps_0': 'historical pre-first-fit engineering repair context only; not the current global fit ledger'},
}


def official_function_node():
    source = DATASET.read_text()
    tree = ast.parse(source)
    owner = next(node for node in tree.body if isinstance(node, ast.ClassDef) and
                 node.name == 'Shuttlecock_Trajectory_Dataset')
    node = next(node for node in owner.body if isinstance(node, ast.FunctionDef) and node.name == '_get_heatmap')
    require(hashlib.sha256(ast.get_source_segment(source, node).encode()).hexdigest() == FUNCTION_SHA256,
            'Pinned official target function drift')
    return node


def target_source_check():
    require(tune.sha(PARENT) == PARENT_SHA256, 'Frozen numerical runner source drift')
    require(subprocess.check_output(['git', '-C', str(SOURCE), 'rev-parse', 'HEAD'], text=True).strip() == tune.PIN,
            'Official target source commit changed')
    require(not subprocess.check_output(['git', '-C', str(SOURCE), 'status', '--porcelain'], text=True).strip(),
            'Official target source checkout modified')
    for path, expected in SOURCE_FILES.items():
        require(tune.sha(path) == expected, 'Official target dependency drift: '+path)
    official_function_node()
    return copy.deepcopy(POLICY)


def finite_number(value):
    return type(value) in (int, float) and math.isfinite(value)


def make_target(label, rect):
    zero = np.zeros((tune.H, tune.W), np.float32)
    if label is None or label.get('target_identity') != 'confirmed' or label.get('status') != 'visible':
        return zero, 0., None
    require(len(rect) == 4 and all(finite_number(v) for v in rect) and
            rect[2] > rect[0] and rect[3] > rect[1], 'Target ROI must be finite with positive area')
    require(all(finite_number(label.get(k)) for k in ('x', 'y')), 'Visible target coordinates must be finite')
    require(finite_number(label.get('uncertainty_px')) and label['uncertainty_px'] > 0,
            'Visible source annotation uncertainty must be finite and positive metadata')
    if not tune.inside(label, rect):
        return zero, 0., {'reason': 'visible_point_outside_fixed_training_ROI'}
    x = (label['x']-rect[0])*tune.W/(rect[2]-rect[0])
    y = (label['y']-rect[1])*tune.H/(rect[3]-rect[1])
    cx, cy = int(x), int(y)
    geometry = {'center_xy': [x, y], 'raster_center_xy': [cx, cy],
        'radius_model_px': RADIUS, 'target_policy_id': POLICY_ID,
        'source_annotation_uncertainty_px': label['uncertainty_px'],
        'visible_origin_disk': cx == cy == 0}
    yy, xx = np.ogrid[:tune.H, :tune.W]
    return (((xx-cx)**2+(yy-cy)**2) <= RADIUS**2).astype(np.float32), 1., geometry


def validate_target_revision(intent):
    revision = intent.get('target_revision')
    require(isinstance(revision, dict), 'Intent must freeze target_revision')
    for key, expected in {'policy_id': POLICY_ID, 'previous_completed_fits': 1,
                          'previous_qualified_fits': 0, 'previous_optimizer_steps': 1024,
                          'new_fit_steps': 1024}.items():
        require(type(revision.get(key)) is type(expected) and revision[key] == expected,
                'Intent target_revision differs: '+key)


def proposal(index_path):
    policy = target_source_check()
    # Check the new authorization before the parent can construct/audit a model.
    index = original.native.load_json(Path(index_path).resolve())
    intent_path = original.resolve(index['intent']['path'] if isinstance(index['intent'], dict) else index['intent'],
                                   Path(index_path).resolve().parent)
    validate_target_revision(original.native.load_json(intent_path))
    result = parent_proposal(index_path)
    validate_target_revision(result['intent'])
    result['dependencies'].update({str(PARENT): PARENT_SHA256, str(HERE): tune.sha(HERE), **SOURCE_FILES})
    result['target_policy'] = policy
    result['purpose'] = 'one target-only binary-disk custom diagnostic development fit from official base'
    result['loss'] = ('unchanged balanced_wbce including focal gamma2 and separate positive/negative mass normalization; '
                      'target only changed Gaussian->official binary disk; unknown/unlabelled output gradient0')
    result['limitations'] = [item for item in result['limitations'] if
                            item != 'Data volume, trainable layers and LR change together; this tests the whole proposal.']
    result['limitations'].extend([
        'Only target encoding changes: binary shape plus official integer rasterization, adapted visible-origin semantics; original label coordinates and training specification remain fixed.',
        'Official radius2.5 is an engineering target convention, not physical ball size or true annotation uncertainty.',
        'This retains custom balanced_wbce; it does not reproduce the complete official training recipe.',
        'The previous completed fit failed qualification; this separate1024 fit has no automatic extension or promotion.'])
    return result


# The parent's main resolves numeric.proposal; its frozen execute resolves
# original.proposal. Inputs.targets resolves original.tune.make_target, which is
# the same nested tune module exposed by numeric.tune. No training code is copied.
tune.make_target = make_target
numeric.proposal = original.proposal = proposal


class DiskTests(unittest.TestCase):
    @staticmethod
    def label(x=960., y=540., uncertainty=6.):
        return {'status': 'visible', 'target_identity': 'confirmed', 'x': x, 'y': y,
                'uncertainty_px': uncertainty}

    @classmethod
    def setUpClass(cls):
        target_source_check()
        node = official_function_node()
        code = ast.Module(body=[node], type_ignores=[])
        namespace = {'np': np}
        exec(compile(ast.fix_missing_locations(code), str(DATASET), 'exec'), namespace)
        cls.reference = staticmethod(namespace['_get_heatmap'])
        cls.owner = SimpleNamespace(WIDTH=512, HEIGHT=288, sigma=2.5, mag=1)

    def test_twenty_cases_exactly_match_pinned_official_function(self):
        points = [(3., 0.), (0., 3.), (1., 0.), (0., 1.), (1., 1.), (2., 2.), (2.5, 2.5),
                  (10.999, 20.001), (255.5, 143.5), (256., 144.), (300.25, 60.75),
                  (510., 286.), (511., 287.), (511.999, 287.999), (0., 287.9), (511.9, 0.),
                  (4.125, 279.875), (123.456, 234.567), (100.999999, 20.999999), (7.5, 8.5)]
        for x, y in points:
            with self.subTest(x=x, y=y):
                target, mask, geo = make_target(self.label(x, y), (0, 0, 512, 288))
                expected = self.reference(self.owner, int(x), int(y))[0].astype(np.float32)
                self.assertTrue(np.array_equal(target, expected))
                self.assertEqual(target.dtype, np.float32)
                self.assertTrue(set(np.unique(target)) <= {0., 1.})
                self.assertEqual(mask, 1.)
                self.assertEqual(geo['center_xy'], [x, y])
                self.assertEqual(geo['raster_center_xy'], [int(x), int(y)])

    def test_visible_origin_uses_clipped_disk_instead_of_official_absent_sentinel(self):
        self.assertEqual(self.reference(self.owner, 0, 0).sum(), 0.)
        for x, y in ((0., 0.), (.5, .5), (.999, .999)):
            target, mask, geo = make_target(self.label(x, y), (0, 0, 512, 288))
            self.assertEqual(target.sum(), 8.)
            self.assertEqual(target[0, 0], 1.)
            self.assertEqual(mask, 1.)
            self.assertTrue(geo['visible_origin_disk'])

    def test_scaling_boundary_radius_and_metadata(self):
        target, _, geo = make_target(self.label(1000., 600.), (100, 60, 2020, 1140))
        self.assertEqual(geo['center_xy'], [240., 144.])
        self.assertEqual(geo['radius_model_px'], 2.5)
        self.assertEqual(target.sum(), 21.)
        self.assertEqual(target[144, 242], 1.)
        self.assertEqual(target[146, 242], 0.)
        self.assertEqual(target[145, 242], 1.)
        self.assertNotIn('sigma_xy', geo)
        changed, _, altered = make_target(self.label(1000., 600., 123.), (100, 60, 2020, 1140))
        self.assertTrue(np.array_equal(target, changed))
        self.assertEqual(altered['source_annotation_uncertainty_px'], 123.)
        for x, y in ((-1., 0.), (512., 20.), (20., 288.)):
            a, mask, why = make_target(self.label(x, y), (0, 0, 512, 288))
            self.assertEqual((a.sum(), mask), (0., 0.))
            self.assertEqual(why['reason'], 'visible_point_outside_fixed_training_ROI')

    def test_unknown_absent_unconfirmed_and_nonfinite(self):
        labels = [None, {}, {'status': 'unknown', 'target_identity': 'confirmed', 'x': float('nan')},
                  {'status': 'absent', 'target_identity': 'confirmed'},
                  {'status': 'visible', 'target_identity': 'uncertain'}]
        for label in labels:
            a, mask, geo = make_target(label, (0, 0, 512, 288))
            self.assertEqual((a.sum(), mask, geo), (0., 0., None))
        for key in ('x', 'y', 'uncertainty_px'):
            for value in (float('nan'), float('inf'), -float('inf')):
                label = self.label(); label[key] = value
                with self.assertRaises(ValueError): make_target(label, (0, 0, 1920, 1080))
        for rect in ((0, 0, 0, 288), (0, 0, 512, float('nan'))):
            with self.assertRaises(ValueError): make_target(self.label(), rect)

    def test_actual_parent_targets_wiring_and_unchanged_functions(self):
        inputs = original.Inputs.__new__(original.Inputs)
        inputs.entries = {'s': {'split': 'old_train'}}
        inputs.windows = {'s': {'width': 512, 'height': 288}}
        inputs.labels = {('s', 0): self.label(100., 50.),
                         ('s', 1): {'status': 'unknown', 'target_identity': 'uncertain'}}
        y, mask, geometry = inputs.targets('s', 0)
        self.assertEqual(tuple(y.shape), (1, 8, 288, 512))
        self.assertTrue(torch.equal(y[0, 0], torch.from_numpy(make_target(inputs.labels[('s', 0)], (0, 0, 512, 288))[0])))
        self.assertEqual(mask.tolist(), [[1., 0., 0., 0., 0., 0., 0., 0.]])
        self.assertEqual(geometry[0]['target_policy_id'], POLICY_ID)
        self.assertIs(original.execute.__globals__['proposal'], proposal)
        self.assertIs(numeric.main.__globals__['proposal'], proposal)
        self.assertIs(original.Inputs.targets.__globals__['tune'].make_target, make_target)
        self.assertIs(original.train.__globals__['tune'].balanced_wbce, unchanged_loss)
        self.assertIs(tune.factory, unchanged_factory)
        for name, fn in unchanged_functions.items(): self.assertIs(getattr(original, name), fn)
        for name, fn in unchanged_tracker.items(): self.assertIs(getattr(original.causal.assoc, name), fn)
        with patch.object(numeric, 'proposal', return_value={'sentinel': True}) as mocked:
            self.assertEqual(numeric.main.__globals__['proposal']('no-index'), {'sentinel': True})
            mocked.assert_called_once_with('no-index')

    def test_tiny_synthetic_output_gradient_mask_and_all_unknown_rejection(self):
        p = torch.full((1, 3, 3, 4), .4, dtype=torch.float32, requires_grad=True)
        y = torch.zeros_like(p); y[0, 0, 1, 1] = 1
        mask = torch.tensor([[1., 0., 0.]])
        loss, diag = unchanged_loss(p, y, mask); loss.backward()
        self.assertEqual(torch.count_nonzero(p.grad[0, 1:]).item(), 0)
        self.assertGreater(torch.count_nonzero(p.grad[0, 0]).item(), 0)
        self.assertEqual(diag['supervised_frames'], 1)
        with self.assertRaises(ValueError): unchanged_loss(p, y, torch.zeros_like(mask))

    def test_minimal_explicit_revision_and_unchanged_training_spec(self):
        revision = {'policy_id': POLICY_ID, 'previous_completed_fits': 1,
                    'previous_qualified_fits': 0, 'previous_optimizer_steps': 1024, 'new_fit_steps': 1024}
        validate_target_revision({'target_revision': revision})
        for key in revision:
            invalid = dict(revision); del invalid[key]
            with self.assertRaises(ValueError): validate_target_revision({'target_revision': invalid})
        with patch.object(original.native, 'load_json', side_effect=[{'intent': 'intent.json'}, {}]), \
                patch.dict(proposal.__globals__, {'parent_proposal': lambda _: self.fail('Unauthorized parent proposal/model construction')}):
            with self.assertRaises(ValueError): proposal('/synthetic/index.json')
        # Mock only proposal I/O/model construction; verify the wrapper preserves
        # parent loss implementation, training spec, gates, schedule, and flags.
        fake = {'intent': {'target_revision': revision}, 'dependencies': {}, 'training': dict(original.FIXED_TRAINING),
                'loss': 'old Gaussian text', 'limitations': [], 'schedule': [{'step': 0}],
                'numerical_gate_policy': numeric.POLICY, **original.FLAGS}
        with patch.object(original.native, 'load_json', side_effect=[{'intent': 'intent.json'}, fake['intent']]), \
                patch.dict(proposal.__globals__, {'parent_proposal': lambda _: copy.deepcopy(fake)}):
            result = proposal('/synthetic/index.json')
        self.assertEqual(result['training'], fake['training'])
        self.assertEqual(result['schedule'], fake['schedule'])
        self.assertEqual(result['numerical_gate_policy'], fake['numerical_gate_policy'])
        self.assertEqual(result['target_policy']['policy_id'], POLICY_ID)
        for flag, expected in original.FLAGS.items(): self.assertEqual(result[flag], expected)


def main():
    if sys.argv[1:] == ['--self-test']:
        suite = unittest.TestSuite([unittest.defaultTestLoader.loadTestsFromTestCase(DiskTests),
                                   unittest.defaultTestLoader.loadTestsFromTestCase(numeric.NumericTests)])
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    return numeric.main()


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, KeyError, OSError) as error:
        print('ball-expanded-tune-disk: '+str(error), file=sys.stderr)
        raise SystemExit(2)
