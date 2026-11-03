#!/usr/bin/env python3
"""Strict offline acceptance accounting; never runs a model or opens video images.

report --reference reference.json [--predictions predictions.json]
       [--matching matching.json] [--evidence-index approved-index.json
       --evidence-index-sha256 EXPECTED] --output NEW_DIRECTORY
audit --workspace REPO --downloads DIRECTORY --output NEW_DIRECTORY
--self-test

Input schema v1 (all PTS are original integer ticks):
reference: {schema_version, availability:'available'|'unavailable', frozen_at,
 reference_definition:{teacher_product,app_version,inference_version,units:'km/h',
 speed_meaning,time_basis:'original_decoded_pts',snapshot_sha256s:[]},
 sources:[{source_id,source_sha256,source_family,session_id,condition_id,
 split:'final'|'supplement'|'train'|'dev'|'reserved',metadata:{width,height,
 time_base,nominal_frame_rate,average_frame_rate},lineage_sha256s:[]}],
 scoring_ranges:[{source_id,start_pts,end_pts,time_base}],
 shots:[{reference_id,source_id,event_pts,time_base,speed_kmh:null|positive,
 preapproved:boolean,approved_at,reviewer_kind:'independent_human'|other,
 human_review_receipt_id,origin_reviewer_kind:'independent_human'|other,tags:[],exclusion_reason:null|string}],
 development_exposure:[{source_sha256,source_family,session_id,lineage_sha256s:[]}],
 evidence:{definition,native_capture,session_conditions,split_isolation,...receipt IDs}}
predictions: {schema_version,units:'km/h',generated_at,model_sha256,protocol_sha256,
 frozen_at,rejection_policy:{frozen_at,features:[]},scoring_ranges:[],
 events:[{prediction_id,source_id,event_pts,time_base,decision:'accepted'|'rejected',
 speed_kmh:null|nonnegative,rejection_reason:null|string}],evidence:{...receipt IDs}}
matching: {schema_version,reference_sha256,predictions_sha256,
 policy:{frozen_at,speed_blinded:true,max_match_seconds:positive finite,features:[source_pts,visual_contact,...]},
 claims:[{prediction_id,reference_id:null|string,
 verdict:'correct'|'wrong'|'ambiguous'|'extra'|'duplicate'}],evidence_receipt_id}

A trusted evidence index is a separately, externally approved binding root:
{schema_version:1,role:'externally_approved_evidence_bindings',
 approvals:[{receipt_id,path,sha256,scope:{reference_sha256,...},
 approval_record:{path,sha256}}]}. The CLI expected hash must be explicit.
Each receipt: {receipt_id,kind,reviewer_kind,scope:{reference_sha256,...},
 artifacts:[{role,path,sha256}],facts:{...}}. Kind-specific structured artifacts
are checked below. Binding/attestation never proves human identity, truthful
physical geometry, legal authorization, or actual capture conditions by itself.
This script cannot generate or approve a trusted index. Agent/self-reported/UI
labels can never become independent human reference merely by editing a name.
"""
import argparse
import copy
import csv
import datetime as dt
from fractions import Fraction
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

V=1
ALLOWED_MATCH_FEATURES={'source_sha256','source_pts','time_base','visual_contact','ball_identity','event_order'}
CATEGORIES={'serve','high_speed_rally','far_small_ball','occlusion'}
KINDS={
 'definition':('reference_definition',{'teacher_export','definition_review'}),
 'human':('independent_human_reference_review',{'human_review_record','identity_verification','contact_pts_evidence'}),
 'native_capture':('native_capture_and_pts',{'original_capture_record','decoded_pts'}),
 'session_conditions':('independent_sessions_and_conditions',{'session_condition_log'}),
 'split_isolation':('source_session_isolation',{'development_registry','frozen_final_registry'}),
 'matching':('independent_matching_review',{'matching_review','frozen_matching_policy'}),
 'range':('complete_prediction_range',{'raw_event_log','frozen_scoring_ranges'}),
 'freeze':('frozen_model_and_policy',{'final_model','frozen_run_protocol'}),
 'integrated_runtime':('integrated_speed_chain',{'integrated_run_log'}),
 'coreml_parity':('python_coreml_parity',{'parity_results'}),
 'device_checks':('real_build_and_device_checks',{'build_results','device_results'}),
 'runtime_independence':('runtime_dependency_independence',{'dependency_audit'}),
 'license':('license_and_provenance',{'license_inventory','license_texts'}),
 'final_blindness':('final_not_used_for_development',{'final_access_log','development_decision_log'}),
}


class AcceptanceError(ValueError):pass


def load(path):
 def bad(value):raise AcceptanceError('Non-finite JSON value: '+value)
 def pairs(items):
  d={}
  for k,v in items:
   if k in d:raise AcceptanceError('Duplicate JSON key: '+k)
   d[k]=v
  return d
 value=json.loads(path.read_text(),parse_constant=bad,object_pairs_hook=pairs)
 def walk(x):
  if isinstance(x,float) and not math.isfinite(x):raise AcceptanceError('Non-finite JSON number')
  if isinstance(x,dict):
   for v in x.values():walk(v)
  elif isinstance(x,list):
   for v in x:walk(v)
 walk(value);return value


def canonical(value):return json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(',',':'),allow_nan=False)

def digest(value):return hashlib.sha256(canonical(value).encode()).hexdigest()

def sha(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
 return h.hexdigest()


def write(path,value):
 with path.open('x',encoding='utf-8') as f:f.write(json.dumps(value,ensure_ascii=False,indent=2,allow_nan=False)+'\n')
 path.chmod(0o600)


def text(value,name):
 if not isinstance(value,str) or not value.strip():raise AcceptanceError(name+': nonempty text required')
 return value


def number(value,name,nullable=False):
 if value is None and nullable:return None
 if isinstance(value,bool) or not isinstance(value,(int,float)):
  raise AcceptanceError(name+': finite number required')
 try:valid=math.isfinite(value)
 except OverflowError:valid=False
 if not valid:raise AcceptanceError(name+': non-finite number')
 return value


def timestamp(value):
 try:r=dt.datetime.fromisoformat(value.replace('Z','+00:00'))
 except (ValueError,AttributeError) as e:raise AcceptanceError('Timezone-aware ISO timestamp required') from e
 if r.tzinfo is None:raise AcceptanceError('Timestamp has no timezone')
 return r


def rows_by_id(rows,key):
 if not isinstance(rows,list):raise AcceptanceError(key+': list required')
 out={}
 for row in rows:
  if not isinstance(row,dict):raise AcceptanceError(key+': object records required')
  ident=text(row.get(key),key)
  if ident in out:raise AcceptanceError('Duplicate '+key+': '+ident)
  out[ident]=row
 return out


def event_time(row):
 pts=row.get('event_pts')
 if not isinstance(pts,int) or isinstance(pts,bool):raise AcceptanceError('event_pts must be integer')
 try:base=Fraction(row['time_base'])
 except (ValueError,TypeError,KeyError,ZeroDivisionError) as e:raise AcceptanceError('Invalid original time_base') from e
 if base<=0:raise AcceptanceError('time_base must be positive')
 return pts*base


def validate_reference(ref):
 if ref.get('schema_version')!=V or ref.get('availability') not in {'available','unavailable'}:raise AcceptanceError('Invalid reference availability/schema')
 sources=rows_by_id(ref.get('sources',[]),'source_id');shots=rows_by_id(ref.get('shots',[]),'reference_id')
 definition=ref.get('reference_definition',{})
 if definition.get('units') not in (None,'km/h'):raise AcceptanceError('Reference units must be km/h')
 for source in sources.values():
  if not re.fullmatch('[a-f0-9]{64}',source.get('source_sha256','')):raise AcceptanceError('Source SHA256 must be64 lowercase hex characters')
  if source.get('split') not in {'final','supplement','train','dev','reserved'}:raise AcceptanceError('Unknown source split')
 seen=set()
 for r in shots.values():
  if r['source_id'] not in sources:raise AcceptanceError('Unknown reference source')
  t=event_time(r);key=(r['source_id'],t)
  if key in seen:raise AcceptanceError('Duplicate reference event identity')
  seen.add(key)
  value=number(r.get('speed_kmh'),'reference speed',nullable=True)
  if value is not None and value<=0:raise AcceptanceError('Reference speed must be strictly positive; invalid references cannot be silently dropped')
  if not isinstance(r.get('preapproved'),bool):raise AcceptanceError('Reference preapproval must be explicit boolean')
  if r['preapproved'] and r.get('exclusion_reason'):raise AcceptanceError('Approved reference cannot carry exclusion reason')
  if not r['preapproved'] and not r.get('exclusion_reason'):raise AcceptanceError('Excluded reference requires frozen reason')
  if r.get('approved_at') and ref.get('frozen_at') and timestamp(r['approved_at'])>timestamp(ref['frozen_at']):raise AcceptanceError('Reference review occurred after reference freeze')
 return sources,shots


def validate_predictions(pred,sources):
 if pred.get('schema_version')!=V or pred.get('units')!='km/h':raise AcceptanceError('Prediction schema/units must be v1 and km/h')
 events=rows_by_id(pred.get('events',[]),'prediction_id')
 for p in events.values():
  if p.get('source_id') not in sources:raise AcceptanceError('Unknown prediction source')
  event_time(p)
  value=number(p.get('speed_kmh'),'prediction speed',nullable=True)
  if value is not None and value<0:raise AcceptanceError('Negative prediction speed is invalid, not an exclusion rule')
  if p.get('decision') not in {'accepted','rejected'}:raise AcceptanceError('Prediction must explicitly be accepted/rejected')
  if p['decision']=='rejected' and not p.get('rejection_reason'):raise AcceptanceError('Rejected event requires frozen-policy reason')
 return events


def validate_matching(matching,refs,preds,ref_sha,pred_sha):
 if matching.get('schema_version')!=V or matching.get('reference_sha256')!=ref_sha or matching.get('predictions_sha256')!=pred_sha:raise AcceptanceError('Matching file binding mismatch')
 policy=matching.get('policy',{});features=policy.get('features',[])
 if not features or set(features)-ALLOWED_MATCH_FEATURES:raise AcceptanceError('Matching cannot use speed, error, or unapproved features')
 if policy.get('speed_blinded') is not True:raise AcceptanceError('Matching must be speed-blinded')
 max_match_seconds=number(policy.get('max_match_seconds'),'frozen max_match_seconds')
 if max_match_seconds<=0:raise AcceptanceError('Frozen max_match_seconds must be strictly positive')
 max_delta=Fraction(str(max_match_seconds))
 claims={};correct_refs=set()
 for claim in matching.get('claims',[]):
  p=claim.get('prediction_id');r=claim.get('reference_id');verdict=claim.get('verdict')
  if p not in preds or p in claims:raise AcceptanceError('Unknown/duplicate claimed prediction')
  if r is not None and r not in refs:raise AcceptanceError('Unknown claimed reference')
  if verdict not in {'correct','wrong','ambiguous','extra','duplicate'}:raise AcceptanceError('Unknown matching verdict')
  if verdict=='correct':
   if r is None or r in correct_refs:raise AcceptanceError('Correct matches must be one-to-one; do not pick by speed error')
   if refs[r]['source_id']!=preds[p]['source_id']:raise AcceptanceError('Correct match crosses source identity')
   if abs(event_time(refs[r])-event_time(preds[p]))>max_delta:raise AcceptanceError('Correct claim exceeds frozen original-PTS matching tolerance; time proximity alone still does not prove identity')
   correct_refs.add(r)
  claims[p]=claim
 return claims


def percentile(values,q):
 if not values:return None
 a=sorted(values);pos=(len(a)-1)*q;lo=math.floor(pos);hi=math.ceil(pos)
 return a[lo]+(a[hi]-a[lo])*(pos-lo)


def calculate(refs,preds,claims):
 """Pure accounting; caller separately establishes formal evidence eligibility."""
 accepted={k:p for k,p in preds.items() if p['decision']=='accepted'}
 correct={c['reference_id']:pid for pid,c in claims.items() if c['verdict']=='correct' and pid in accepted}
 accepted_correct=[pid for pid,c in claims.items() if pid in accepted and c['verdict']=='correct' and c['reference_id'] in refs]
 covered=0;abs_errors=[];apes=[];detail=[]
 for rid,r in refs.items():
  pid=correct.get(rid);p=preds.get(pid) if pid else None;vref=r.get('speed_kmh');vp=p.get('speed_kmh') if p else None
  absolute=ape=None;within=None
  if p is not None and vref is not None and vp is not None:
   # Explicit prediction zero remains a numeric estimate: 100% error.
   exact_error=abs(Fraction(str(vp))-Fraction(str(vref)));exact_ape=exact_error/Fraction(str(vref))
   try:absolute=float(exact_error);ape=float(exact_ape)
   except OverflowError as error:raise AcceptanceError('Finite speeds create unrepresentable error; do not silently omit output') from error
   within=exact_ape<=Fraction(1,5);covered+=1;abs_errors.append(absolute);apes.append(ape)
  detail.append({'reference_id':rid,'source_id':r['source_id'],'reference_speed_kmh':vref,
                 'prediction_id':pid,'prediction_speed_kmh':vp,'absolute_error_kmh':absolute,'ape':ape,
                 'within_hard_20_percent':within,'covered':ape is not None,
                 'unknown_speed':p is not None and vp is None})
 negatives={'wrong':0,'ambiguous':0,'extra':0,'duplicate':0,'unmatched_accepted':0}
 for pid,p in accepted.items():
  c=claims.get(pid)
  if c is None:negatives['unmatched_accepted']+=1
  elif c['verdict']!='correct':negatives[c['verdict']]+=1
 return {'reference_denominator':len(refs),'accepted_event_denominator':len(accepted),
         'correct_identity_accepted':len(accepted_correct),'covered_references':covered,
         'coverage':covered/len(refs) if refs else None,
         'matching_precision':len(accepted_correct)/len(accepted) if accepted else None,
         'missed_reference_events':sum(rid not in correct for rid in refs),
         'correct_match_but_unknown_speed':sum(d['unknown_speed'] for d in detail),
         'rejected_events':sum(p['decision']=='rejected' for p in preds.values()),
         'matching_failures':negatives,'scored_output_count':len(apes),'mae_kmh':sum(abs_errors)/len(abs_errors) if abs_errors else None,
         'mape':sum(apes)/len(apes) if apes else None,'median_ape':percentile(apes,.5),'p90_ape':percentile(apes,.9),
         'p95_ape':percentile(apes,.95),'max_ape':max(apes) if apes else None,
         'hard_20_percent_violations':sum(d['within_hard_20_percent'] is False for d in detail)},detail


def resolve_binding(spec,base):
 path=Path(text(spec.get('path'),'artifact path')).expanduser()
 if not path.is_absolute():path=base/path
 path=path.resolve();expected=spec.get('sha256')
 if not isinstance(expected,str) or not re.fullmatch('[a-f0-9]{64}',expected):raise AcceptanceError('Artifact requires exact SHA256')
 if not path.is_file() or sha(path)!=expected:raise AcceptanceError('Missing/changed evidence artifact: '+str(path))
 return path


class Evidence:
 def __init__(self,path,expected,ref_sha):
  self.ref_sha=ref_sha;self.items={};self.loaded={};self.errors=[];self.present=False
  if path is None:return
  if not expected:raise AcceptanceError('Trusted evidence index requires explicit expected SHA256')
  resolve_binding({'path':str(path),'sha256':expected},Path.cwd());index=load(path)
  if index.get('schema_version')!=V or index.get('role')!='externally_approved_evidence_bindings':raise AcceptanceError('Invalid evidence index role/schema')
  self.items=rows_by_id(index.get('approvals',[]),'receipt_id');self.base=path.parent;self.present=True
 def check(self,ident,kind,source_shas=None):
  missing=[]
  if not self.present:return None,['No externally approved, explicitly hash-pinned evidence index']
  item=self.items.get(ident)
  if item is None:return None,['Receipt is not in the externally approved evidence index: '+str(ident)]
  try:
   path=resolve_binding(item,self.base);approval_path=resolve_binding(item['approval_record'],self.base)
   approval=load(approval_path)
   if approval.get('receipt_sha256')!=item['sha256'] or approval.get('reference_sha256')!=self.ref_sha or approval.get('reviewer_kind')!='independent_human':raise AcceptanceError('External approval record lacks exact receipt/reference and independent-human attribution')
   r=load(path);expected_kind,roles=KINDS[kind]
   if r.get('receipt_id')!=ident or r.get('kind')!=expected_kind:raise AcceptanceError('Receipt ID/kind mismatch')
   for scope in (item.get('scope',{}),r.get('scope',{})):
    if scope.get('reference_sha256')!=self.ref_sha:raise AcceptanceError('Receipt not bound to this frozen reference')
    if source_shas and not set(source_shas)<=set(scope.get('source_sha256s',[])):raise AcceptanceError('Receipt source scope incomplete')
   if kind in {'human','matching','session_conditions','final_blindness'} and r.get('reviewer_kind')!='independent_human':raise AcceptanceError('Agent/self-reported/UI reviewer cannot establish independent human review')
   artifacts={}
   for spec in r.get('artifacts',[]):
    role=text(spec.get('role'),'artifact role')
    if role in artifacts:raise AcceptanceError('Duplicate evidence artifact role')
    artifacts[role]=resolve_binding(spec,path.parent)
   if not roles<=artifacts.keys():raise AcceptanceError('Missing substantive evidence artifacts: '+','.join(sorted(roles-artifacts.keys())))
   r['_artifacts']=artifacts;self.loaded[ident]={'kind':expected_kind,'path':str(path),'sha256':sha(path),'artifact_roles':sorted(artifacts)}
   return r,[]
  except (OSError,ValueError,KeyError,TypeError) as e:return None,[str(e)]


def gate(ident,status,requirement,measurement=None,missing=None,scope=None,evidence=None):
 return {'id':ident,'status':status,'requirement':requirement,'measurement':measurement,
         'missing_evidence':missing or [],'scope':scope or 'primary1080p60 final cohort only','evidence':evidence or []}


def known(value):return isinstance(value,str) and value.strip().lower() not in {'','unknown','none','unrecorded'}

def source_is_supplement(source):
 meta=source.get('metadata',{})
 if (meta.get('width'),meta.get('height'))!=(1920,1080):return True
 try:return Fraction(meta['nominal_frame_rate'])<45
 except (KeyError,ValueError,ZeroDivisionError):return False


def check_leakage(ref,sources):
 final=[s for s in sources.values() if s.get('split')=='final'];exposure=ref.get('development_exposure',[]);issues=[]
 for s in final:
  lineage=set(s.get('lineage_sha256s',[]))|{s.get('source_sha256')}
  for e in exposure:
   other=set(e.get('lineage_sha256s',[]))|{e.get('source_sha256')}
   if lineage&other or (known(s.get('source_family')) and s.get('source_family')==e.get('source_family')) or (known(s.get('session_id')) and s.get('session_id')==e.get('session_id')):
    issues.append({'source_id':s['source_id'],'reason':'source/family/session/derivative overlaps development','development_entry':e})
 return issues


def parse_artifact_json(receipt,role):return load(receipt['_artifacts'][role])


def evidence_conditions(receipt,kind,ref,pred,matching,sources,refs,preds):
 """Validate concrete, kind-specific contents after externally approved binding."""
 if kind=='definition':
  facts=receipt.get('facts',{});definition=ref['reference_definition']
  if any(definition.get(k) in (None,'','unknown') for k in ['teacher_product','app_version','units','speed_meaning','time_basis']):return ['Reference version/meaning/time basis remains unknown']
  export_sha=sha(receipt['_artifacts']['teacher_export'])
  if export_sha not in definition.get('snapshot_sha256s',[]):return ['Teacher export does not match frozen snapshot list']
  reviewed=parse_artifact_json(receipt,'definition_review')
  if reviewed.get('reference_definition')!=definition:return ['Version/units/time/speed-meaning review differs from frozen reference definition']
 elif kind=='human':
  review=parse_artifact_json(receipt,'human_review_record')
  if review.get('reviewer_kind')!='independent_human' or review.get('reference_sha256')!=receipt['scope']['reference_sha256']:return ['Human review record lacks independent identity/reference binding']
  if not set(refs)<=set(review.get('approved_reference_ids',[])):return ['Human review record does not cover approved reference IDs']
  identity_doc=parse_artifact_json(receipt,'identity_verification')
  if not review.get('reviewer_id') or review['reviewer_id'] not in identity_doc.get('independently_verified_reviewer_ids',[]):return ['Human reviewer identity is not substantiated by the bound verification record']
  cues=parse_artifact_json(receipt,'contact_pts_evidence');by_id={x['reference_id']:x for x in cues.get('events',[])}
  for rid,row in refs.items():
   cue=by_id.get(rid)
   if not cue or cue.get('source_sha256')!=sources[row['source_id']]['source_sha256']:return ['No source-bound visual/contact PTS evidence for reference']
   base=Fraction(cue['time_base']);lo=cue['contact_start_pts'];hi=cue['contact_end_pts']
   if not isinstance(lo,int) or not isinstance(hi,int) or hi<lo or not lo*base<=event_time(row)<=hi*base:return ['Reference event is outside independently reviewed contact PTS interval']
   cue_frames=cue.get('frames',[])
   if len(cue_frames)<2 or len({f['source_pts'] for f in cue_frames})<2:return ['Contact evidence requires distinct actual decoded frame bindings']
   for f in cue_frames:resolve_binding(f,receipt['_artifacts']['contact_pts_evidence'].parent)

 elif kind=='native_capture':
  capture=parse_artifact_json(receipt,'original_capture_record');pts=parse_artifact_json(receipt,'decoded_pts')
  entries={x['source_sha256']:x for x in capture.get('sources',[])};timelines={x['source_sha256']:x for x in pts.get('sources',[])}
  for s in sources.values():
   if s.get('split')!='final' or source_is_supplement(s):continue
   row=entries.get(s['source_sha256']);timeline=timelines.get(s['source_sha256'])
   if not row or not timeline:return ['Missing original capture/decoded PTS evidence for final source']
   source_file=row.get('source_file')
   if not source_file or source_file.get('sha256')!=s['source_sha256']:return ['Native capture record does not bind the actual original source file']
   resolve_binding(source_file,receipt['_artifacts']['original_capture_record'].parent)
   if row.get('resolution')!=[1920,1080] or row.get('native_capture_fps')!=60 or row.get('resampled') is not False:return ['Source is not proven original native1080p60 (resampling does not qualify)']
   ticks=timeline.get('pts',[])
   if len(ticks)<120 or any(not isinstance(x,int) or isinstance(x,bool) for x in ticks):return ['Insufficient actual integer PTS evidence']
   base=Fraction(timeline['time_base']);deltas=[(b-a)*base for a,b in zip(ticks,ticks[1:])]
   if any(d<=0 for d in deltas) or not Fraction(1,62)<=percentile(deltas,.5)<=Fraction(1,58):return ['Actual PTS evidence does not support native~60fps']
 elif kind=='session_conditions':
  log=parse_artifact_json(receipt,'session_condition_log');mapping={x['source_sha256']:x for x in log.get('sources',[])}
  for s in sources.values():
   if s.get('split')!='final' or source_is_supplement(s):continue
   item=mapping.get(s['source_sha256'])
   if not item or not known(s.get('session_id')) or not known(s.get('condition_id')) or item.get('session_id')!=s['session_id'] or item.get('condition_id')!=s['condition_id']:return ['Session/condition log does not substantiate source mapping']
  if log.get('session_independence_reviewed') is not True:return ['Session independence has not been explicitly externally reviewed']
 elif kind=='split_isolation':
  if any(not known(s.get('source_family')) or not known(s.get('session_id')) for s in sources.values() if s.get('split')=='final'):return ['Unknown source-family/session relationships cannot establish final isolation']
  registry=parse_artifact_json(receipt,'development_registry');frozen=parse_artifact_json(receipt,'frozen_final_registry')
  if registry.get('complete_exposure_registry') is not True or registry.get('entries')!=ref.get('development_exposure',[]):return ['Complete development exposure registry is not bound/consistent']
  if set(frozen.get('final_source_sha256s',[]))!={s['source_sha256'] for s in sources.values() if s.get('split')=='final'}:return ['Frozen final source registry mismatch']
 elif kind=='matching':
  policy=parse_artifact_json(receipt,'frozen_matching_policy');review=parse_artifact_json(receipt,'matching_review')
  if policy!=matching['policy'] or review.get('claims')!=matching.get('claims'):return ['Substantive matching/policy artifacts differ from scored input']
  if review.get('predictions_sha256')!=matching['predictions_sha256']:return ['Matching review does not bind predictions']
 elif kind=='range':
  raw=parse_artifact_json(receipt,'raw_event_log');ranges=parse_artifact_json(receipt,'frozen_scoring_ranges')
  if ranges.get('ranges')!=ref.get('scoring_ranges') or pred.get('scoring_ranges')!=ref.get('scoring_ranges'):return ['Prediction/reference/frozen scoring ranges differ']
  if raw.get('schema_version')!=V or raw.get('complete_run_log') is not True or raw.get('model_sha256')!=pred.get('model_sha256') or raw.get('protocol_sha256')!=pred.get('protocol_sha256'):return ['No structurally recognized, model-bound complete raw prediction run log']
  rows=rows_by_id(raw.get('events',[]),'prediction_id');in_range={}
  for pid,p in rows.items():
   t=event_time(p)
   for span in ref.get('scoring_ranges',[]):
    if p['source_id']==span['source_id'] and span['start_pts']*Fraction(span['time_base'])<=t<span['end_pts']*Fraction(span['time_base']):in_range[pid]=p
  if in_range!=preds:return ['Predictions omit/change accepted or rejected events from the complete frozen scoring ranges']
 elif kind=='freeze':
  protocol=parse_artifact_json(receipt,'frozen_run_protocol')
  if sha(receipt['_artifacts']['final_model'])!=pred.get('model_sha256') or protocol.get('protocol_sha256')!=pred.get('protocol_sha256'):return ['Final model/protocol artifact binding mismatch']
  if protocol.get('rejection_policy')!=pred.get('rejection_policy'):return ['Rejection/confidence/calibration policy differs from frozen protocol']
  forbidden=re.compile(r'ref|teacher|error|ape|target.speed',re.I)
  if any(forbidden.search(str(x)) for x in pred.get('rejection_policy',{}).get('features',[])):return ['Rejection policy uses reference/error-related features']
 elif kind=='final_blindness':
  access=parse_artifact_json(receipt,'final_access_log');decisions=parse_artifact_json(receipt,'development_decision_log')
  if access.get('used_to_guide_changes') is not False or decisions.get('final_influenced_architecture_threshold_calibration_or_weights') is not False:return ['Final set influenced changes; it must become development data']
  if access.get('source_sha256s')!=sorted(s['source_sha256'] for s in sources.values() if s.get('split')=='final'):return ['Final access source registry incomplete']
 elif kind=='integrated_runtime':
  log=parse_artifact_json(receipt,'integrated_run_log');required={'video_to_ball','ball_to_event','event_to_3d_geometry','geometry_to_speed','coreml_runtime','mac_and_iphone'}
  if not required<=set(log.get('stages_executed',[])) or log.get('synthetic') is not False or log.get('code_only') is not False:return ['No substantive real integrated end-to-end run evidence']
  if log.get('model_sha256')!=pred.get('model_sha256') or log.get('protocol_sha256')!=pred.get('protocol_sha256') or set(log.get('event_ids',[]))!=set(preds or {}):return ['Integrated run is not bound to final model/protocol and every scored event']
 elif kind=='coreml_parity':
  parity=parse_artifact_json(receipt,'parity_results');pairs=parity.get('pairs',[])
  if not pairs or parity.get('model_sha256')!=pred.get('model_sha256') or parity.get('synthetic') is not False:return ['No actual real-input final-model Python/CoreML paired outputs']
  tolerance=number(parity.get('frozen_absolute_tolerance'),'parity tolerance')
  if tolerance<0 or any(abs(number(x['python'],'python output')-number(x['coreml'],'CoreML output'))>tolerance for x in pairs):return ['Python/CoreML parity exceeds frozen tolerance']
 elif kind=='device_checks':
  builds=parse_artifact_json(receipt,'build_results');devices=parse_artifact_json(receipt,'device_results')
  if builds.get('model_sha256')!=pred.get('model_sha256') or devices.get('model_sha256')!=pred.get('model_sha256'):return ['Build/device records are not bound to final model']
  if any(builds.get(platform,{}).get('actual_build_passed') is not True for platform in ['mac','iphone']):return ['Missing actual Mac/iPhone full model builds']
  if devices.get('physical_iphone_executed') is not True or devices.get('nonblocking_1080p60_capture') is not True:return ['Missing real-device nonblocking1080p60 checks']
 elif kind=='runtime_independence':
  audit=parse_artifact_json(receipt,'dependency_audit')
  if audit.get('runtime_reference_private_models',audit.get('runtime_swing_private_models'))!=[] or audit.get('runtime_teacher_answers_or_test_video_memory')!=[] or audit.get('uses_ground_homography_for_airborne_speed') is not False:return ['Runtime is not independent or uses forbidden airborne geometry']
  if audit.get('dependency_inventory_complete') is not True or audit.get('model_sha256')!=pred.get('model_sha256'):return ['Runtime dependency audit incomplete/unbound']
 elif kind=='license':
  inv=parse_artifact_json(receipt,'license_inventory')
  if not inv.get('dependencies') or inv.get('all_runtime_dependencies_reviewed') is not True or inv.get('model_sha256')!=pred.get('model_sha256'):return ['Runtime weight/code licensing evidence incomplete or not bound to final model']
 return []


def report(reference_path,prediction_path,matching_path,index_path,index_sha,output):
 if output.exists():raise AcceptanceError('Output exists; choose a new directory')
 ref=load(reference_path);ref_sha=sha(reference_path);sources,all_refs=validate_reference(ref)
 evidence=Evidence(index_path,index_sha,ref_sha);pred=load(prediction_path) if prediction_path else None
 preds=validate_predictions(pred,sources) if pred else None
 matching=load(matching_path) if matching_path else None
 if matching and not pred:raise AcceptanceError('Matching requires real predictions')
 claims=validate_matching(matching,all_refs,preds,ref_sha,sha(prediction_path)) if matching else None
 if pred and matching and timestamp(matching['policy']['frozen_at'])>timestamp(pred['generated_at']):raise AcceptanceError('Matching policy frozen after predictions; cannot establish speed-blind predefinition')
 if pred and ref.get('frozen_at') and timestamp(ref['frozen_at'])>timestamp(pred['generated_at']):raise AcceptanceError('Reference frozen after prediction generation')
 if pred and (timestamp(pred['frozen_at'])>timestamp(pred['generated_at']) or timestamp(pred['rejection_policy']['frozen_at'])>timestamp(pred['generated_at'])):raise AcceptanceError('Model/rejection policy frozen after predictions')
 gates=[];checks={};all_source_shas=sorted(s['source_sha256'] for s in sources.values() if s.get('split')=='final' and not source_is_supplement(s))
 evidence_ids={**ref.get('evidence',{}),**(pred.get('evidence',{}) if pred else {})}
 def receipt_check(kind,ident=None):
  r,missing=evidence.check(ident or evidence_ids.get(kind),kind,all_source_shas)
  if r:
   try:missing=evidence_conditions(r,kind,ref,pred,matching,sources,all_refs,preds)
   except (ValueError,KeyError,TypeError,OSError) as error:missing=[str(error)]
  checks[kind]=(r,missing)
  return not missing
 human_refs={};human_missing=[];supplemental_refs={};supplemental_missing=[]
 primary_preapproved={rid:row for rid,row in all_refs.items() if row['preapproved'] and sources[row['source_id']].get('split')=='final' and not source_is_supplement(sources[row['source_id']])}
 for rid,row in all_refs.items():
  source=sources[row['source_id']]
  if not row['preapproved'] or row.get('speed_kmh') is None or source.get('split') not in {'final','supplement'}:continue
  supplemental=source_is_supplement(source) or source.get('split')=='supplement'
  bucket_missing=supplemental_missing if supplemental else human_missing
  if row.get('reviewer_kind')!='independent_human' or row.get('origin_reviewer_kind')!='independent_human':
   bucket_missing.append(rid+': agent/self-report/UI or missing human origin is not independent human review');continue
  receipt,missing=evidence.check(row.get('human_review_receipt_id'),'human',[source['source_sha256']])
  if receipt:
   try:missing=evidence_conditions(receipt,'human',ref,pred,matching,sources,{rid:row},preds)
   except (ValueError,KeyError,TypeError,OSError) as error:missing=[str(error)]
  if missing:bucket_missing.extend(rid+': '+m for m in missing)
  elif supplemental:supplemental_refs[rid]=row
  else:human_refs[rid]=row
 available=ref.get('availability')=='available' and bool(all_refs)
 n=len(human_refs)
 reference_cohort_complete=available and bool(primary_preapproved) and len(human_refs)==len(primary_preapproved)
 if any(r.get('speed_kmh') is None for r in primary_preapproved.values()):human_missing.append('Preapproved primary reference has unknown speed; cannot shrink denominator')
 count_status=('pass' if n>=100 else 'fail') if reference_cohort_complete else 'incomplete'
 gates.append(gate('at_least_100_independent_human_references',count_status,'At least100 preapproved independent-human reviewed primary references',{'verified_count':n,'candidate_rows':len(all_refs),'minimum':100},human_missing or ([] if n>=100 else ['No complete100-shot independently reviewed primary cohort'])))
 for kind in ['definition','native_capture','session_conditions','split_isolation','final_blindness','freeze','integrated_runtime','coreml_parity','device_checks','runtime_independence','license']:
  if kind in {'freeze','integrated_runtime','coreml_parity','device_checks','runtime_independence','license'} and not pred:
   ok=False;checks[kind]=(None,['No final speed-model prediction run/artifact exists'])
  else:ok=receipt_check(kind)
  gates.append(gate(kind,'pass' if ok else 'incomplete',KINDS[kind][0],missing=checks[kind][1],evidence=[evidence_ids[kind]] if ok else []))
 leakage=check_leakage(ref,sources)
 if leakage:
  next(g for g in gates if g['id']=='split_isolation').update(status='fail',measurement={'leakage':leakage})
 session_ok=not checks.get('session_conditions',(None,['missing']))[1]
 primary_sources={r['source_id'] for r in human_refs.values()}
 session_count=len({sources[k].get('session_id') for k in primary_sources if known(sources[k].get('session_id'))})
 condition_count=len({sources[k].get('condition_id') for k in primary_sources if known(sources[k].get('condition_id'))})
 for ident,count,minimum in [('independent_sessions',session_count,3),('capture_conditions',condition_count,2)]:
  gates.append(gate(ident,('pass' if count>=minimum else 'fail') if session_ok and n else 'incomplete',f'At least{minimum} independently substantiated '+ident,{'verified_count':count if session_ok else None,'declared_primary_count':count,'minimum':minimum},[] if session_ok else checks['session_conditions'][1]))
 tags=set(t for r in human_refs.values() for t in r.get('tags',[]));missing_tags=sorted(CATEGORIES-tags)
 gates.append(gate('required_play_conditions',('pass' if not missing_tags else 'fail') if reference_cohort_complete else 'incomplete','Serve/high-speed rally/far small ball/occlusion represented by independently reviewed primary references',{'missing_categories':missing_tags},['No independently reviewed category coverage'] if missing_tags else []))
 metrics=None;supplemental_metrics=None;details=[];matching_ok=range_ok=False
 if preds is not None and claims is not None:
  primary_preds={pid:p for pid,p in preds.items() if sources[p['source_id']].get('split')=='final' and not source_is_supplement(sources[p['source_id']])}
  primary_claims={pid:c for pid,c in claims.items() if pid in primary_preds}
  if human_refs:
   metrics,details=calculate(human_refs,primary_preds,primary_claims)
   for row in details:row['cohort']='primary'
  supplemental_preds={pid:p for pid,p in preds.items() if sources[p['source_id']].get('split')=='supplement' or (sources[p['source_id']].get('split')=='final' and source_is_supplement(sources[p['source_id']]))}
  if supplemental_refs:
   supplemental_metrics,supplemental_details=calculate(supplemental_refs,supplemental_preds,{pid:c for pid,c in claims.items() if pid in supplemental_preds})
   for row in supplemental_details:row['cohort']='supplemental'
   details.extend(supplemental_details)
  matching_ok=receipt_check('matching',matching.get('evidence_receipt_id'))
  range_ok=receipt_check('range')
 for kind,ok in [('matching',matching_ok),('range',range_ok)]:
  gates.append(gate(kind,'pass' if ok else 'incomplete',KINDS[kind][0],missing=checks.get(kind,(None,['No real complete prediction/matching evidence']))[1]))
 for ident,field,target,direction in [('coverage_90','coverage',.9,'min'),('matching_precision_95','matching_precision',.95,'min'),('every_valid_output_ape_20','max_ape',.2,'max')]:
  value=metrics.get(field) if metrics else None;ready=bool(reference_cohort_complete and matching_ok and range_ok and value is not None)
  ok=value is not None and (value>=target if direction=='min' else value<=target)
  if ident=='every_valid_output_ape_20' and metrics is not None:ok=metrics['hard_20_percent_violations']==0
  gates.append(gate(ident,('pass' if ok else 'fail') if ready else 'incomplete',f'{field} {">=" if direction=="min" else "<="}{target}',{'value':value,'threshold':target,'formal_evidence_ready':ready},[] if ready else ['Independent human references, speed-blind matching and complete prediction scope are required']))
 optimization={'mape_at_most_10_percent':None if not metrics or metrics['mape'] is None else metrics['mape']<=.1,
               'p95_at_most_15_percent':None if not metrics or metrics['p95_ape'] is None else metrics['p95_ape']<=.15,
               'not_a_substitute_for_each_output_hard_gate':True}
 status='fail' if any(g['status']=='fail' for g in gates) else 'incomplete' if any(g['status']=='incomplete' for g in gates) else 'pass'
 result={'schema_version':V,'generator_sha256':sha(Path(__file__)),'overall_status':status,'evaluation_kind':'agreement_with_frozen_reference_snapshot_not_radar_truth',
         'reference_sha256':ref_sha,'predictions_sha256':sha(prediction_path) if prediction_path else None,
         'matching_sha256':sha(matching_path) if matching_path else None,'metrics':metrics,
         'supplemental_evaluation':{'scope':'30fps/nonprimary rows; never count toward primary100 shots/3 sessions/2 conditions',
           'independent_human_reference_count':len(supplemental_refs),'metrics':supplemental_metrics,'missing_evidence':supplemental_missing},
         'prediction_event_counts':None if preds is None else {'accepted':sum(p['decision']=='accepted' for p in preds.values()),'rejected':sum(p['decision']=='rejected' for p in preds.values())},'gates':gates,'optimization_targets':optimization,
         'independent_human_verified_reference_count':n,'reference_cohort_complete':reference_cohort_complete,'primary_preapproved_count':len(primary_preapproved),'supplemental_rows_excluded_from_primary':sum(source_is_supplement(sources[r['source_id']]) for r in all_refs.values()),
         'loaded_evidence_bindings':evidence.loaded,'trust_boundary':'Pinned index/receipts establish binding and external attestations, not human authenticity or physical truth by themselves. No index is generated/approved by this reporter.',
         'no_teacher_features_used_as_model_input':True,'model_execution_performed':False,
         'unknown_policy':'Missing speed and error remain null; numeric predicted0 remains100%APE when reference>0.',
         'metric_denominators':'coverage: all preapproved independently human-reviewed primary references. Precision: all accepted events in complete frozen scoring ranges, including extras/duplicates/wrong/ambiguous. Rejected events separately retained.',
         'missing_predictions_is_not_zero_percent_test_failure':pred is None}
 output.mkdir(parents=True,mode=0o700);write(output/'report.json',result)
 with (output/'per-shot.jsonl').open('x') as f:
  for d in details:f.write(canonical(d)+'\n')
 (output/'per-shot.jsonl').chmod(0o600)
 fields=['cohort','reference_id','source_id','reference_speed_kmh','prediction_id','prediction_speed_kmh','absolute_error_kmh','ape','within_hard_20_percent','covered','unknown_speed']
 with (output/'per-shot.csv').open('x',newline='') as f:
  writer=csv.DictWriter(f,fieldnames=fields);writer.writeheader();writer.writerows(details)
 (output/'per-shot.csv').chmod(0o600)
 with (output/'event-accounting.jsonl').open('x') as f:
  for pid,p in (preds or {}).items():f.write(canonical({'prediction_id':pid,'source_id':p['source_id'],'event_pts':p['event_pts'],'time_base':p['time_base'],'decision':p['decision'],'speed_kmh':p.get('speed_kmh'),'rejection_reason':p.get('rejection_reason'),'matching_claim':claims.get(pid) if claims else None})+'\n')
 (output/'event-accounting.jsonl').chmod(0o600)
 return result


def audit(workspace,downloads,output):
 if output.exists():raise AcceptanceError('Audit output exists; choose a new directory')
 workspace,downloads=workspace.resolve(),downloads.resolve();root=workspace/'.local/speed-training'
 prior_path=root/'source-audit-20261028-v1.0.1.json';prior=load(prior_path)
 known={Path(s['path']).resolve():s for s in prior['sources']}
 tune_path=root/'ball-tune-20261029/data/manifest.json';tune=load(tune_path)
 developed={s['source_sha256'] for s in tune['sources']}
 dataset_path=root/'dataset-combined-v1-20261028/manifest.json';dataset=load(dataset_path)
 developed|={s['source_sha256'] for s in dataset['sources']}
 sources=[]
 matcher=re.compile(r'tennis|swing|court|double|single|test|网球|击球',re.I)
 for path in sorted(downloads.rglob('*')):
  if not path.is_file() or path.suffix.lower() not in {'.mov','.mp4','.m4v','.mkv','.avi'} or not matcher.search(str(path.relative_to(downloads))):continue
  before=(path.stat().st_size,path.stat().st_mtime_ns);actual=sha(path)
  command=['ffprobe','-v','error','-select_streams','v:0','-show_streams','-show_format','-of','json',str(path)]
  payload=json.loads(subprocess.run(command,check=True,capture_output=True,text=True,timeout=60).stdout)
  stream=payload['streams'][0]
  if before!=(path.stat().st_size,path.stat().st_mtime_ns) or sha(path)!=actual:raise AcceptanceError('Source changed during metadata/hash audit')
  old=known.get(path.resolve());duplicate=path.name=='single-test.MOV'
  if actual in developed or duplicate:role='development'
  elif path.name=='double-test-001.mp4':role='reserved_supplemental_30fps_freshness_unconfirmed'
  else:role='unclassified_origin'
  near60=Fraction(stream['avg_frame_rate'])>45
  family='test-source-family-20261007' if path.name in {'test.MOV','single-test.MOV'} else path.stem+'-source-family'
  source={'source_id':path.stem.replace('.','-')+'-'+actual[:8],'path':str(path),'source_sha256':actual,'bytes':before[0],
   'role':role,'source_family':family,'session_id':None,'condition_id':None,'known_audit_sha_matches':old['file_sha256']==actual if old else None,
   'not_in_prior_source_audit':old is None,'source_audit_binding_sha256':sha(prior_path) if old else None,
   'metadata':{'width':stream['width'],'height':stream['height'],'duration_seconds':stream.get('duration'),
               'nominal_frame_rate':stream['r_frame_rate'],'average_frame_rate':stream['avg_frame_rate'],
               'time_base':stream['time_base'],'codec_name':stream['codec_name'],
               'rotation_degrees':next((x['rotation'] for x in stream.get('side_data_list',[]) if 'rotation'in x),stream.get('tags',{}).get('rotate'))},
   'primary_1080p60_metadata_candidate':(stream['width'],stream['height'])==(1920,1080) and near60,
   'native60_capture_verified':False,'actual_final_pts_evidence_verified':False,'final_eligible':False,
   'capture_device':'unknown','capture_height':'unknown','capture_zoom':'unknown','frames_opened_by_audit':0,
   'limits':['Container average fps alone neither proves native capture nor automatically fails a near60 source.']}
  if duplicate:source['derivative_evidence']='Prior video-packet audit proves all18125 packets equal prefix of test.MOV; same family, never independent split.'
  if path.name=='double-test-001.mp4':source['historical_usage_evidence']={'path':str(workspace/'.local/historical-usage-notes.md'),
   'finding':'Prior project history records full CPU analysis; no frames opened by this audit. Current reserve status is not proof of historical blindness.'}
  sources.append(source)
 exports=[];module_path=workspace/'scripts/speed-dataset.py'
 spec=importlib.util.spec_from_file_location('acceptance_xlsx_reader',module_path);reader=importlib.util.module_from_spec(spec);spec.loader.exec_module(reader)
 export_paths=sorted(root.glob('*.xlsx'))
 old_exports=workspace/'.local/s-reference-exports'
 if old_exports.exists():export_paths+=sorted(old_exports.glob('*.xlsx'))
 binding={s['export_sha256']:s for s in dataset['sources']}
 for path in export_paths:
  if not path.is_file():continue
  actual=sha(path);rows,_=reader.read_shots_xlsx(path)
  speeds=[reader.finite_number(r.get('Speed (KM/H)'),'speed',optional=True) for _,r in rows]
  exports.append({'path':str(path),'sha256':actual,'shots_rows':len(rows),'speed_present':sum(v is not None for v in speeds),
                  'technical_snapshot_digest':digest(rows),'confirmed_source_sha256':binding.get(actual,{}).get('source_sha256'),
                  'reference_role':'unreviewed_teacher_snapshot_only','independent_human_valid_shots':0,'Player_identity_emitted':False})
 labels=[]
 for path in sorted(downloads.glob('*.json')):
  if not (path.name.startswith('ball-labels-') or path.name.startswith('tennis-ultimate-')):continue
  value=load(path);record={'path':str(path),'sha256':sha(path),'top_keys':list(value) if isinstance(value,dict) else None,
                          'formal_speed_acceptance_eligible':False}
  if isinstance(value,dict) and isinstance(value.get('labels'),list):
   rows=value['labels'];record.update(kind='image_point_labels_not_speed_references',label_count=len(rows),reviewer_kind=value.get('reviewer_kind'),
       agent_or_ui_count=sum(x.get('reviewer_kind') in {'agent','agent_candidate','ui_test'} for x in rows),
       human_self_reported_count=sum(x.get('reviewer_kind')=='human_self_reported' for x in rows),
       missing_evidence=['No independently verified per-hit speed reference/one-to-one source-event binding'])
  else:record.update(kind='historical_tennis_json_unbound',missing_evidence=['No frozen sourceSHA/PTS/snapshot and independent human review binding'])
  labels.append(record)
 inventory={'schema_version':V,'generator_sha256':sha(Path(__file__)),'scope':'Filesystem metadata, hashes, historical technical receipts only; no video frames or browser state opened.',
  'prior_source_audit':{'path':str(prior_path),'sha256':sha(prior_path)},'sources':sources,'teacher_exports':exports,'downloaded_label_candidates':labels,
  'current_dataset':{'path':str(dataset_path),'sha256':sha(dataset_path),'shots':223,'unreviewed_teacher_speed_rows':223,'independently_human_reviewed_speed_rows':0},
  'ball_development':{'manifest_path':str(tune_path),'sha256':sha(tune_path),'train_native_frames':360,'eval_native_frames':120,
                      'train_agent_visible_points':134,'eval_agent_visible_points':32,'independent_physical_hits_from_these_point_counts':0,
                      'current_outputs_are_ball_localization_not_speed':True},
  'current_speed_prediction_run_available':False,
  'scan_limits':['Only relevant filename videos, known XLSX locations and ball-labels/tennis-ultimate Downloads JSON inspected.',
                 'Browser localStorage/unsaved annotations were not inspected; no claim that no other files exist outside scanned scope.',
                 'Historical used source filenames are not evidence of capture-session or physical-condition independence.']}
 gaps={'schema_version':V,'verified_final_primary_sources':0,'verified_independent_human_speed_hits':0,'required_human_speed_hits':100,
       'verified_independent_sessions':0,'required_sessions':3,'verified_conditions':0,'required_conditions':2,
       'verified_final_speed_predictions':None,'coverage':None,'matching_precision':None,'hard_ape_max':None,
       'status':'incomplete','needed_user_information':['Local paths of unused original1080p60 videos, if any.',
          'Which files are from the same physical capture session, derivative, transcode or adjacent rallies.',
          'Capture sessions and camera/condition relationships; original capture/FPS evidence when available.',
          'Independent human event/teacher-speed audit later; do not promote Agent/UI point labels.'],
       'development_history_preserved':{'coarse_motion_teacher_difference_mae_kmh':23.78,'did_not_beat_constant_baseline':True,
          'ball_tune_train_agent_points':134,'ball_tune_eval_agent_points':32,'these_are_not_final_speed_acceptance_results':True}}
 output.mkdir(parents=True,mode=0o700);write(output/'inventory.json',inventory);write(output/'gaps.json',gaps)
 ref={'schema_version':V,'availability':'unavailable','reference_definition':{'teacher_product':'S家','app_version':None,'inference_version':None,
      'units':'km/h','speed_meaning':None,'time_basis':'original_decoded_pts','snapshot_sha256s':[x['sha256'] for x in exports]},
      'sources':[],'shots':[],'scoring_ranges':[],'development_exposure':[{'source_sha256':s['source_sha256'],'source_family':s['source_family'],
        'session_id':None,'lineage_sha256s':[]} for s in sources if s['role']=='development'],
      'evidence':{},'unavailability_reason':'No independently human-reviewed frozen final speed-reference cohort; no actual final speed prediction/matching run.',
      'not_a_synthetic_empty_evaluation':True,'audit_inventory_sha256':sha(output/'inventory.json')}
 write(output/'reference-status.json',ref)
 result=report(output/'reference-status.json',None,None,None,None,output/'current-report')
 return {'output':str(output.resolve()),'status':result['overall_status'],'related_videos':len(sources),'teacher_export_files':len(exports),
         'downloaded_label_candidates':len(labels),'verified_final_primary_sources':0,'verified_human_reference_hits':0,
         'metrics':result['metrics'],'formal_speed_test_executed':False}


class Tests(unittest.TestCase):
 def setUp(self):
  self.refs={'r1':{'source_id':'s','speed_kmh':100,'event_pts':10,'time_base':'1/600'},'r2':{'source_id':'s','speed_kmh':50,'event_pts':20,'time_base':'1/600'}}
  self.preds={'p1':{'source_id':'s','speed_kmh':120,'decision':'accepted','event_pts':10,'time_base':'1/600'},'p2':{'source_id':'s','speed_kmh':None,'decision':'accepted','event_pts':20,'time_base':'1/600'},
              'extra':{'source_id':'s','speed_kmh':80,'decision':'accepted'},'reject':{'source_id':'s','speed_kmh':None,'decision':'rejected'}}
  self.claims={'p1':{'reference_id':'r1','verdict':'correct'},'p2':{'reference_id':'r2','verdict':'correct'}}
 def test_unknown_not_zero_and_complete_denominators(self):
  m,d=calculate(self.refs,self.preds,self.claims)
  self.assertEqual(m['coverage'],.5);self.assertEqual(m['matching_precision'],2/3);self.assertEqual(m['scored_output_count'],1)
  self.assertAlmostEqual(m['max_ape'],.2);self.assertEqual(m['rejected_events'],1);self.assertIsNone(d[1]['ape'])
 def test_exact_decimal20_percent_boundary(self):
  refs={'r':{'source_id':'s','speed_kmh':92}};preds={'p':{'source_id':'s','speed_kmh':110.4,'decision':'accepted'}}
  m,d=calculate(refs,preds,{'p':{'reference_id':'r','verdict':'correct'}})
  self.assertEqual(m['hard_20_percent_violations'],0);self.assertIs(d[0]['within_hard_20_percent'],True)
  preds['p']['speed_kmh']=110.400001;m,_=calculate(refs,preds,{'p':{'reference_id':'r','verdict':'correct'}})
  self.assertEqual(m['hard_20_percent_violations'],1)
 def test_prediction_range_completeness_cannot_be_a_string(self):
  with tempfile.TemporaryDirectory() as tmp:
   base=Path(tmp);raw=base/'raw.json';ranges=base/'ranges.json'
   p1={'prediction_id':'p1','source_id':'s','event_pts':10,'time_base':'1/600','speed_kmh':100,'decision':'accepted'}
   p2={**p1,'prediction_id':'p2','event_pts':20}
   write(raw,{'schema_version':1,'complete_run_log':True,'model_sha256':'model','protocol_sha256':'protocol','events':[p1,p2]})
   spans=[{'source_id':'s','start_pts':0,'end_pts':100,'time_base':'1/600'}];write(ranges,{'ranges':spans})
   receipt={'_artifacts':{'raw_event_log':raw,'frozen_scoring_ranges':ranges}}
   missing=evidence_conditions(receipt,'range',{'scoring_ranges':spans},{'model_sha256':'model','protocol_sha256':'protocol','scoring_ranges':spans},None,{}, {}, {'p1':p1})
   self.assertTrue(missing)
 def test_explicit_predicted_zero_is100_percent_error(self):
  self.preds['p1']['speed_kmh']=0;m,_=calculate(self.refs,self.preds,self.claims)
  self.assertEqual(m['max_ape'],1);self.assertEqual(m['hard_20_percent_violations'],1)
 def test_each_output_hard_gate_not_mean(self):
  refs={str(i):{'source_id':'s','speed_kmh':100} for i in range(10)}
  preds={str(i):{'source_id':'s','speed_kmh':121 if i==9 else 100,'decision':'accepted'} for i in range(10)}
  claims={str(i):{'reference_id':str(i),'verdict':'correct'} for i in range(10)}
  m,_=calculate(refs,preds,claims);self.assertLess(m['mape'],.1);self.assertEqual(m['hard_20_percent_violations'],1)
 def test_duplicates_and_speed_pairing_rejected(self):
  with self.assertRaises(AcceptanceError):rows_by_id([{'id':'same'},{'id':'same'}],'id')
  matching={'schema_version':1,'reference_sha256':'a','predictions_sha256':'b','policy':{'features':['speed_kmh'],'speed_blinded':True,'max_match_seconds':1},'claims':[]}
  with self.assertRaises(AcceptanceError):validate_matching(matching,self.refs,self.preds,'a','b')
  matching['policy']['features']=['source_pts'];matching['claims']=[{'prediction_id':'p1','reference_id':'r1','verdict':'correct'},
    {'prediction_id':'p2','reference_id':'r1','verdict':'correct'}]
  with self.assertRaises(AcceptanceError):validate_matching(matching,self.refs,self.preds,'a','b')
 def test_correct_claim_must_meet_frozen_actual_pts_tolerance(self):
  matching={'schema_version':1,'reference_sha256':'a','predictions_sha256':'b',
            'policy':{'features':['source_pts','visual_contact'],'speed_blinded':True,'max_match_seconds':.2},
            'claims':[{'prediction_id':'p1','reference_id':'r1','verdict':'correct'}]}
  # Same-source, equal-speed or external correct claims cannot bypass time.
  self.preds['p1']['event_pts']=60000
  with self.assertRaisesRegex(AcceptanceError,'matching tolerance'):
   validate_matching(matching,self.refs,self.preds,'a','b')
  self.preds['p1']['event_pts']=130  # exactly0.2s from10 ticks at1/600
  self.assertIn('p1',validate_matching(matching,self.refs,self.preds,'a','b'))
  self.preds['p1']['event_pts']=131
  with self.assertRaises(AcceptanceError):validate_matching(matching,self.refs,self.preds,'a','b')
  for bad in (None,0,-1,float('nan')):
   matching['policy']['max_match_seconds']=bad
   with self.assertRaises(AcceptanceError):validate_matching(matching,self.refs,self.preds,'a','b')
 def test_source_family_session_and_transcode_leakage(self):
  source={'source_id':'s','split':'final','source_sha256':'a','source_family':'f','session_id':'session','lineage_sha256s':['parent']}
  for dev in [{'source_sha256':'a'},{'source_family':'f'},{'session_id':'session'},{'source_sha256':'parent'}]:
   self.assertTrue(check_leakage({'development_exposure':[dev]},{'s':source}))
 def test_unknown_session_is_not_assumed_same_or_independent(self):
  source={'source_id':'s','split':'final','source_sha256':'a','source_family':'unknown','session_id':'unknown'}
  self.assertEqual(check_leakage({'development_exposure':[{'source_sha256':'b','source_family':'unknown','session_id':'unknown'}]},{'s':source}),[])
  self.assertFalse(known('unknown'))
 def test_wrong_units_nonfinite_and_duplicate_json(self):
  with self.assertRaises(AcceptanceError):validate_reference({'schema_version':1,'availability':'available','sources':[],'shots':[],'reference_definition':{'units':'mph'}})
  with tempfile.TemporaryDirectory() as tmp:
   p=Path(tmp)/'bad.json'
   for value in ['{"x":NaN}','{"x":1e999}','{"x":1,"x":2}']:
    p.write_text(value)
    with self.assertRaises(AcceptanceError):load(p)
 def test_pinned_evidence_binding_not_string_or_name(self):
  e=Evidence(None,None,'a');r,missing=e.check('independent_human','human');self.assertIsNone(r);self.assertTrue(missing)
  with tempfile.TemporaryDirectory() as tmp:
   p=Path(tmp)/'index.json';write(p,{'schema_version':1,'role':'externally_approved_evidence_bindings','approvals':[]})
   with self.assertRaises(AcceptanceError):Evidence(p,None,'a')
   with self.assertRaises(AcceptanceError):Evidence(p,'0'*64,'a')
 def test_agent_reference_never_becomes_formal(self):
  with tempfile.TemporaryDirectory() as tmp:
   base=Path(tmp);p=base/'reference.json';write(p,{'schema_version':1,'availability':'available','frozen_at':'2026-10-01T00:00:00Z',
    'reference_definition':{'units':'km/h'},'sources':[{'source_id':'s','source_sha256':'a'*64,'split':'final','metadata':{'width':1920,'height':1080,'nominal_frame_rate':'60/1'}}],
    'shots':[{'reference_id':'r','source_id':'s','event_pts':10,'time_base':'1/600','speed_kmh':100,'preapproved':True,'approved_at':'2026-09-30T00:00:00Z','reviewer_kind':'agent'}]})
   result=report(p,None,None,None,None,base/'out');self.assertEqual(result['overall_status'],'incomplete');self.assertEqual(result['independent_human_verified_reference_count'],0);self.assertIsNone(result['metrics'])
 def test_no_predictions_is_not_zero_percent_failed_test(self):
  with tempfile.TemporaryDirectory() as tmp:
   base=Path(tmp);p=base/'reference.json';write(p,{'schema_version':1,'availability':'unavailable','reference_definition':{'units':'km/h'},'sources':[],'shots':[]})
   result=report(p,None,None,None,None,base/'out');self.assertEqual(result['overall_status'],'incomplete');self.assertIsNone(result['metrics'])
   self.assertTrue(all(g['status']=='incomplete' for g in result['gates']))
 def test_old_model_build_cannot_qualify_new_model(self):
  with tempfile.TemporaryDirectory() as tmp:
   base=Path(tmp);builds=base/'builds.json';devices=base/'devices.json'
   write(builds,{'model_sha256':'old','mac':{'actual_build_passed':True},'iphone':{'actual_build_passed':True}})
   write(devices,{'model_sha256':'old','physical_iphone_executed':True,'nonblocking_1080p60_capture':True})
   missing=evidence_conditions({'_artifacts':{'build_results':builds,'device_results':devices}},'device_checks',{}, {'model_sha256':'new'},None,{}, {}, {})
   self.assertTrue(missing)
 def test_30fps_supplement_and59_8_not_automatic_failure(self):
  self.assertTrue(source_is_supplement({'metadata':{'width':1920,'height':1080,'nominal_frame_rate':'30/1'}}))
  self.assertFalse(source_is_supplement({'metadata':{'width':1920,'height':1080,'nominal_frame_rate':'60000/1001','average_frame_rate':'59.8'}}))


def main():
 p=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter);p.add_argument('--self-test',action='store_true')
 sub=p.add_subparsers(dest='command');a=sub.add_parser('audit');a.add_argument('--workspace',type=Path,default=Path.cwd());a.add_argument('--downloads',type=Path,required=True);a.add_argument('--output',type=Path,required=True)
 r=sub.add_parser('report');r.add_argument('--reference',type=Path,required=True);r.add_argument('--predictions',type=Path);r.add_argument('--matching',type=Path);r.add_argument('--evidence-index',type=Path);r.add_argument('--evidence-index-sha256');r.add_argument('--output',type=Path,required=True)
 args=p.parse_args()
 if args.self_test:
  result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Tests));return 0 if result.wasSuccessful() else 1
 try:
  if args.command=='audit':result=audit(args.workspace,args.downloads,args.output)
  elif args.command=='report':
   report_result=report(args.reference,args.predictions,args.matching,args.evidence_index,args.evidence_index_sha256,args.output)
   result={'output':str(args.output.resolve()),'overall_status':report_result['overall_status'],'metrics':report_result['metrics'],'gates':{g['id']:g['status'] for g in report_result['gates']}}
  else:p.error('Choose audit/report or --self-test')
  print(json.dumps(result,ensure_ascii=False,indent=2,allow_nan=False));return 0
 except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError) as error:print('speed-acceptance: '+str(error),file=sys.stderr);return 2


if __name__=='__main__':sys.exit(main())
