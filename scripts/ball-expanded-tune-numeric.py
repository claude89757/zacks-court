#!/usr/bin/env python3
"""Scoped numerical bridge around the frozen expanded diagnostic runner.

Only comparison, proposal and evaluation metadata hooks change. The original
forward, optimizer, loss, schedule, candidate construction and tracker execute
unchanged. --self-test uses synthetic dictionaries only, with zero forwards.
"""
import argparse
import copy
import importlib.util
import json
import math
from pathlib import Path
import re
import sys
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve()
ORIGINAL = HERE.with_name('ball-expanded-tune.py')
ORIGINAL_SHA256 = 'a95b046428dfd1cf38273030a35fb7782691537a5cb3d4a60e49ef2be1a8c383'
REVISION = 'bounded-scalar-log-propagation-v1'
spec = importlib.util.spec_from_file_location('expanded_frozen_numeric_bridge', ORIGINAL)
original = importlib.util.module_from_spec(spec)
spec.loader.exec_module(original)
causal, tune, native, require = original.causal, original.tune, original.native, original.require
original_proposal, original_evaluate = original.proposal, original.evaluate
original_bank_alignment, original_selection_alignment = causal.bank_alignment, causal.selection_alignment
STRUCTURE = ('identifier', 'box', 'originalXY', 'equivalentXY', 'pixelArea')
POLICY = {
    'revision': REVISION,
    'supersedes': 'intent.pre_fit_gates legacy scalar atol1e-5 clause only; all other frozen gates remain mandatory',
    'scope': 'engineering reproducibility bridge; no physical, speed or accuracy qualification',
    'original_runner_sha256': ORIGINAL_SHA256,
    'raw_gate_unchanged': 'first22 raw batches maxabs<=1e-5; strict>.3 maskflips0',
    'structure_gate': 'all2640 ordered bank structures/IDs/bboxes/XY/areas/counts and complete association decisions exact',
    'scalar_diagnostics': 'retain every legacy difference/max/pass and every paired peak/mean/cost difference; no uniform1e-5 claim',
    'domain_gate': 'both sides finite; every candidate peak/mean in[0,1], Float32(peak)>Float32(.3); costs in[0,2.5]; none selection costs exactly2.5',
    'native_peak_reconstruction': 'native JSON selected peak -> Float32 -> Double before log',
    'selected_cost_gate': 'deltaC=CT-CN; expected=log(pN/pT); abs(deltaC-expected)<=tau; abs(deltaC)<=abs(pN-pT)/min(pN,pT)+tau',
    'tau': '64*sys.float_info.epsilon*max(1,abs(CT),abs(CN),abs(log(pT)),abs(log(pN)))',
    'unchanged': 'model forward/loss/schedule/tracker/threshold/candidate selection/training and legacy metric gates',
}


def scalar(value):
    return type(value) in (int, float) and math.isfinite(value)


def candidate_domain(candidate, location):
    errors = []
    for key in ('peak', 'mean'):
        value = candidate.get(key)
        if not scalar(value) or not 0 <= value <= 1:
            errors.append(location + '.' + key + '.finite_probability')
    if scalar(candidate.get('peak')) and 0 <= candidate['peak'] <= 1 and \
            float(original.np.float32(candidate['peak'])) <= float(original.np.float32(.3)):
        errors.append(location + '.peak.strict_threshold')
    return errors


def exact_structure(actual, reference, prefix):
    return [prefix + '.' + key for key in STRUCTURE if actual.get(key) != reference.get(key)]


def bank_alignment(actual, reference):
    legacy = original_bank_alignment(actual, reference)
    # Filter precisely the two documented scalar keys, never other differences.
    structural = [key for key in legacy['differences']
                  if re.fullmatch(r'candidate\d+\.(peak|mean)', key) is None]
    domains, differences = [], []
    for side, bank in (('torch', actual), ('native', reference)):
        for index, candidate in enumerate(bank['candidates']):
            domains.extend(candidate_domain(candidate, f'{side}.candidate{index}'))
    for index, (a, b) in enumerate(zip(actual['candidates'], reference['candidates'])):
        structural.extend(exact_structure(a, b, f'candidate{index}'))
        differences.append({'candidate_index': index, 'torch_identifier': a['identifier'],
            'native_identifier': b['identifier'], **{key: {
                'torch': a[key], 'native_json': b[key], 'torch_minus_native_json': a[key]-b[key],
                'absolute_difference': abs(a[key]-b[key]), 'legacy_atol1e5_passed': abs(a[key]-b[key]) <= 1e-5}
                for key in ('peak', 'mean')}})
    reasons = sorted(set(structural + domains))
    return {**legacy, 'passed': not reasons, 'differences': reasons, 'legacy': legacy,
            'domain_failures': domains, 'scalar_diagnostics': differences}


def selection_alignment(actual, reference):
    legacy = original_selection_alignment(actual, reference)
    reasons = [key for key in legacy['differences'] if key != 'incrementalCost']
    domains = []
    for side, selection in (('torch', actual), ('native', reference)):
        cost = selection.get('incrementalCost')
        if not scalar(cost) or not 0 <= cost <= 2.5:
            domains.append(side + '.incrementalCost.finite_range')
        if selection.get('candidate') is not None:
            domains.extend(candidate_domain(selection['candidate'], side + '.selected'))
        elif cost != 2.5:
            domains.append(side + '.none_cost_must_equal_2.5')
    a, b = actual.get('candidate'), reference.get('candidate')
    propagation = None
    if a is not None and b is not None:
        reasons.extend(exact_structure(a, b, 'selected_candidate'))
        if not domains:
            p_t, p_n = a['peak'], float(original.np.float32(b['peak']))
            c_t, c_n = actual['incrementalCost'], reference['incrementalCost']
            log_t, log_n = math.log(p_t), math.log(p_n)
            tau = 64 * sys.float_info.epsilon * max(1., abs(c_t), abs(c_n), abs(log_t), abs(log_n))
            delta = c_t-c_n
            expected = math.log(p_n/p_t)
            residual = delta-expected
            bound = abs(p_n-p_t)/min(p_n, p_t)+tau
            propagation = {'torch_peak': p_t, 'native_peak_json': b['peak'],
                'native_peak_float32_as_double': p_n, 'delta_cost': delta,
                'expected_log_ratio': expected, 'residual': residual, 'tau': tau,
                'mean_value_bound_including_tau': bound,
                'log_residual_passed': abs(residual) <= tau,
                'mean_value_bound_passed': abs(delta) <= bound}
            if not propagation['log_residual_passed']: reasons.append('cost_log_propagation_residual')
            if not propagation['mean_value_bound_passed']: reasons.append('cost_log_mean_value_bound')
    reasons = sorted(set(reasons + domains))
    return {**legacy, 'passed': not reasons, 'differences': reasons, 'legacy': legacy,
            'domain_failures': domains, 'scalar_diagnostics': {
                'torch_cost': actual['incrementalCost'], 'native_cost': reference['incrementalCost'],
                'torch_minus_native_cost': actual['incrementalCost']-reference['incrementalCost'],
                'absolute_difference': legacy['incremental_cost_difference'],
                'legacy_atol1e5_passed': legacy['incremental_cost_difference'] <= 1e-5},
            'log_propagation': propagation}


def proposal(index_path):
    require(tune.sha(ORIGINAL) == ORIGINAL_SHA256, 'Frozen original runner source drift')
    result = original_proposal(index_path)
    revision = result['intent'].get('numerical_gate_revision')
    require(isinstance(revision, dict) and revision.get('cost_propagation') and
            revision.get('model_selection_threshold_label_training_configuration_unchanged') is True and
            revision.get('previous_optimizer_steps') == 0 and revision.get('total_allowed_fits') == 1 and
            revision.get('total_allowed_fit_steps') == 1024,
            'Intent must explicitly freeze the reviewed numerical_gate_revision and unchanged fit budget')
    result['dependencies'][str(HERE)] = tune.sha(HERE)
    result['numerical_gate_policy'] = POLICY
    result['pre_fit_gate'] = ('native base all2640 exact bank/selection structural parity; finite/domain and '
        'Float32-native-peak log residual/MVT gates; peak/mean/cost differences fully diagnostic; '
        'first22 raw batches maxabs<=1e-5 and strict>.3 maskflips0 unchanged; legacy base/head old4 metrics exact')
    return result


def json_safe(value):
    """Keep failed nonfinite diagnostics writable without permitting the gate."""
    if isinstance(value, float) and not math.isfinite(value): return {'nonfinite': repr(value)}
    if isinstance(value, dict): return {key: json_safe(item) for key, item in value.items()}
    if isinstance(value, list): return [json_safe(item) for item in value]
    return value


def evaluate(model, name, inputs, out, stream, native_gate=False):
    if not native_gate:
        return original_evaluate(model, name, inputs, out, stream, native_gate=False)
    rows, pending = [], None
    identities = [(sample, index) for sample in sorted(inputs.entries) for index in range(120)]
    prior_bank, prior_selection = causal.bank_alignment, causal.selection_alignment

    def compare_bank(actual, reference):
        nonlocal pending
        require(pending is None, 'Unpaired numeric bank/selection hook')
        sample, index = identities[len(rows)]
        frame = inputs.windows[sample]['frames'][index]
        pending = {'sample_id': sample, 'window_id': sample, 'frame_index': index,
            'source_sha256': inputs.windows[sample]['source_sha256'],
            'source_pts': frame['source_pts'], 'source_time_base': frame['source_time_base'],
            'bank': bank_alignment(actual, reference)}
        return pending['bank']

    def compare_selection(actual, reference):
        nonlocal pending
        require(pending is not None, 'Selection hook missing bank')
        checked = selection_alignment(actual, reference)
        pending['selection'] = checked
        pending['passed'] = pending['bank']['passed'] and checked['passed']
        rows.append(pending); pending = None
        return checked

    causal.bank_alignment, causal.selection_alignment = compare_bank, compare_selection
    try:
        report = original_evaluate(model, name, inputs, out, stream, native_gate=True)
        require(len(rows) == 2640 and pending is None, 'Incomplete numeric diagnostic frame ledger')
        return report
    finally:
        causal.bank_alignment, causal.selection_alignment = prior_bank, prior_selection
        original.write(Path(out)/'numeric-diagnostics.json', json_safe({**original.FLAGS,
            'policy': POLICY, 'model': name, 'wrapper_sha256': tune.sha(HERE),
            'original_runner_sha256': tune.sha(ORIGINAL), 'expected_frames': 2640,
            'frames_checked': len(rows), 'all_frames_complete': len(rows) == 2640 and pending is None,
            'passed': len(rows) == 2640 and pending is None and all(row['passed'] for row in rows),
            'frames': rows, 'incomplete_frame': pending}))


# execute resolves these globals dynamically, including its protocol equality
# check. All training/evaluation model computations remain in the frozen module.
original.proposal, original.evaluate = proposal, evaluate


class NumericTests(unittest.TestCase):
    def candidate(self, peak=.5):
        return {'identifier': 1, 'box': [0, 0, 1, 1], 'originalXY': [0, 0],
                'equivalentXY': [0., 0.], 'pixelArea': 1, 'peak': peak, 'mean': peak}

    def bank(self, candidate):
        return {'candidates': [candidate], 'totalComponents': 1, 'truncatedComponents': 0}

    def selection(self, peak=.5, penalty=0):
        return {'candidate': self.candidate(peak), 'incrementalCost': -math.log(peak)+penalty,
                'linkedToPast': False, 'resetReason': None, 'missingReason': None}

    def test_scalar_difference_diagnostic_only_with_full_legacy(self):
        result = bank_alignment(self.bank(self.candidate(.50002)), self.bank(self.candidate()))
        self.assertTrue(result['passed']); self.assertFalse(result['legacy']['passed'])
        self.assertGreater(result['max_peak_difference'], 1e-5)
        self.assertEqual(result['scalar_diagnostics'][0]['peak']['absolute_difference'], .50002-.5)

    def test_all_structure_and_order_differences_still_fail(self):
        base = self.bank(self.candidate())
        for key, value in (('identifier', 2), ('box', [1, 0, 1, 1]), ('originalXY', [1, 0]),
                           ('equivalentXY', [1e-12, 0]), ('pixelArea', 2)):
            actual = copy.deepcopy(base); actual['candidates'][0][key] = value
            self.assertFalse(bank_alignment(actual, base)['passed'], key)
        for key in ('totalComponents', 'truncatedComponents'):
            actual = copy.deepcopy(base); actual[key] += 1
            self.assertFalse(bank_alignment(actual, base)['passed'])
        actual = copy.deepcopy(base); actual['candidates'] = []
        self.assertFalse(bank_alignment(actual, base)['passed'])

    def test_peak_mean_domains_reject_both_sides(self):
        for field in ('peak', 'mean'):
            for invalid in (float('nan'), float('inf'), -float('inf'), -.1, 1.1):
                a, b = self.bank(self.candidate()), self.bank(self.candidate())
                a['candidates'][0][field] = invalid
                self.assertFalse(bank_alignment(a, b)['passed'])
                self.assertFalse(bank_alignment(b, a)['passed'])
        self.assertFalse(bank_alignment(self.bank(self.candidate(.3)), self.bank(self.candidate()))['passed'])
        boundary = float(original.np.float32(.3))
        self.assertFalse(bank_alignment(self.bank(self.candidate(boundary)), self.bank(self.candidate()))['passed'])

    def test_log_propagation_with_float32_native_json_reconstruction(self):
        # Native writer's decimal peak is rounded; its cost used the original
        # Float32 converted to Double. Reconstruct that value before comparing.
        p_n = float(original.np.float32(.5594499))
        reference = self.selection(p_n); reference['candidate']['peak'] = .55944990000000006
        actual = self.selection(float(original.np.float32(.55947)))
        result = selection_alignment(actual, reference)
        self.assertTrue(result['passed'], result)
        self.assertFalse(result['legacy']['passed'])
        self.assertTrue(result['log_propagation']['mean_value_bound_passed'])

    def test_analytic_error_still_rejects(self):
        actual, reference = self.selection(.50002), self.selection()
        actual['incrementalCost'] += 1e-10
        result = selection_alignment(actual, reference)
        self.assertFalse(result['passed'])
        self.assertIn('cost_log_propagation_residual', result['differences'])

    def test_selection_domains_and_decisions_still_reject(self):
        reference = self.selection()
        for invalid in (float('nan'), float('inf'), -float('inf'), -.1, 2.50001):
            actual = copy.deepcopy(reference); actual['incrementalCost'] = invalid
            self.assertFalse(selection_alignment(actual, reference)['passed'])
            self.assertFalse(selection_alignment(reference, actual)['passed'])
        for field, value in (('linkedToPast', True), ('resetReason', 'source_changed'),
                             ('missingReason', 'no_candidate')):
            actual = copy.deepcopy(reference); actual[field] = value
            self.assertFalse(selection_alignment(actual, reference)['passed'])
        actual = copy.deepcopy(reference); actual['candidate']['box'][0] = 1
        self.assertFalse(selection_alignment(actual, reference)['passed'])

    def test_none_requires_both_exact_2point5(self):
        reference = {'candidate': None, 'incrementalCost': 2.5, 'linkedToPast': False,
                     'resetReason': None, 'missingReason': 'no_candidate'}
        self.assertTrue(selection_alignment(reference, reference)['passed'])
        actual = copy.deepcopy(reference); actual['incrementalCost'] -= 1e-12
        self.assertFalse(selection_alignment(actual, reference)['passed'])
        self.assertFalse(selection_alignment(reference, actual)['passed'])
        self.assertFalse(selection_alignment(self.selection(), reference)['passed'])

    def test_raw_budget_unchanged_and_nonfinite_diagnostics_serializable(self):
        self.assertTrue(causal.native_numeric_budget(1e-5, 0))
        self.assertFalse(causal.native_numeric_budget(1.00001e-5, 0))
        self.assertFalse(causal.native_numeric_budget(0., 1))
        json.dumps(json_safe({'a': [float('nan'), float('inf')]}), allow_nan=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    subs = parser.add_subparsers(dest='command')
    propose = subs.add_parser('propose')
    propose.add_argument('--input-index', required=True); propose.add_argument('--output', required=True)
    propose.add_argument('--diagnostic-agent-labels', action='store_true')
    run = subs.add_parser('run')
    run.add_argument('--protocol', required=True); run.add_argument('--output', required=True)
    run.add_argument('--execute-frozen-protocol', action='store_true')
    run.add_argument('--diagnostic-agent-labels', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        tests = unittest.defaultTestLoader.loadTestsFromTestCase(NumericTests)
        return 0 if unittest.TextTestRunner(verbosity=2).run(tests).wasSuccessful() else 1
    require(args.command, 'Choose propose/run or --self-test')
    if args.command == 'propose':
        require(args.diagnostic_agent_labels, 'propose requires --diagnostic-agent-labels')
        output = Path(args.output).resolve()
        require(not output.exists(), 'Protocol output exists; choose NEW file')
        protocol = proposal(args.input_index)
        output.parent.mkdir(parents=True, exist_ok=True); original.write(output, protocol)
        print(tune.canonical({'protocol': str(output), 'sha256': tune.sha(output), 'model_forwards': 0,
            'optimizer_steps': 0, 'eligible_groups': 88, 'schedule_steps': original.STEPS}))
    else:
        original.execute(args)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, KeyError, OSError) as error:
        print('ball-expanded-tune-numeric: ' + str(error), file=sys.stderr)
        raise SystemExit(2)
