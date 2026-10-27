"""Display labels remain exact aliases, never replacement producer evidence."""

from copy import deepcopy
from pathlib import Path

import pytest
import yaml

from tools.ci_producer_trust import PRODUCERS, _JOB_ALIASES, evidence_job_name
from tools import ci_preview_audit, ci_release_candidates

ROOT = Path(__file__).resolve().parents[1]


def workflow(name):
    return yaml.safe_load((ROOT / '.github/workflows' / name).read_text())


def test_equivalent_platform_stages_have_the_same_display_shape():
    platform = workflow('macos.yml')['jobs']
    linux = workflow('linux-platform-stages.yml')['jobs']
    assert platform['macos-checks']['name'] == 'macOS checks / ${{ matrix.stage }}'
    assert platform['linux-native']['name'] == 'Linux checks'
    for stage in ('native', 'core', 'desktop', 'service'):
        assert linux[stage + '-linux']['name'] == stage
        assert evidence_job_name({'name': 'Linux checks / ' + stage}) == 'linux-native / ' + stage + '-linux'
        assert evidence_job_name({'name': 'macOS checks / ' + stage}) == 'macos-checks (' + stage + ')'
    assert platform['linux-build']['name'] == 'Linux bundle / build'
    assert platform['linux-test']['name'] == 'Linux bundle / integration'
    assert platform['macos']['name'] == 'macOS bundle / build and smoke'
    assert platform['linux-test']['needs'] == 'linux-build'
    for required in ('platform-checks', 'acceptance-checks'):
        assert platform[required].get('name', required) == required


def test_packaging_contracts_are_named_separately_from_acceptance():
    platform = workflow('macos.yml')['jobs']
    assert platform['packaging']['name'] == 'Linux packaging'
    assert platform['dmg']['name'] == 'macOS packaging'
    assert workflow('package-contracts.yml')['jobs']['linux']['name'] == '${{ matrix.format }} contracts'
    assert workflow('dmg-contracts.yml')['jobs']['dmg']['name'] == 'dmg contracts'
    assert platform['acceptance-deb']['name'] == 'Linux acceptance / deb installer'
    assert platform['acceptance-audio']['name'] == 'Linux acceptance / virtual audio'


@pytest.mark.parametrize('prefix', ['', 'build / ', 'candidates / '])
def test_composed_callers_keep_logical_ids_and_raw_original_metadata(prefix):
    row = {'name': prefix + 'Linux bundle / build', 'id': 12, 'run_attempt': 2,
           'started_at': '2026-10-27T12:00:00Z', 'completed_at': '2026-10-27T12:01:00Z'}
    original = deepcopy(row)
    assert evidence_job_name(row) == prefix + 'linux-build'
    assert row == original
    assert evidence_job_name({'name': prefix + 'Linux packaging / deb contracts'}) == prefix + 'packaging / linux-deb'
    assert evidence_job_name({'name': prefix + 'macOS packaging / dmg contracts'}) == prefix + 'dmg / dmg'
    assert evidence_job_name({'name': prefix + 'Linux sanitizer checks / thread'}) == prefix + 'sanitizers / native-thread-sanitizer'


@pytest.mark.parametrize('name', [
    'Linux bundle/build', 'linux bundle / build', 'Linux bundle / build extra',
    'foreign / Linux bundle / build', 'Linux checks / core extra',
    'Linux packaging / zip contracts', 'macOS packaging / dmg contracts extra',
])
def test_near_misses_do_not_authorize_an_existing_producer(name):
    assert evidence_job_name({'name': name}) == name
    assert not PRODUCERS['shadow-handoff'].matches_job({'name': name})


def test_renamed_producer_still_needs_the_same_workflow_and_event():
    producer = PRODUCERS['shadow-handoff']
    assert producer.matches_job({'name': 'Linux bundle / build'})
    assert producer.matches_job({'name': 'build / Linux bundle / build'})
    assert producer.matches_run({'path': '.github/workflows/macos.yml', 'event': 'pull_request'})
    assert not producer.matches_run({'path': '.github/workflows/quality.yml', 'event': 'pull_request'})
    assert not producer.matches_run({'path': '.github/workflows/macos.yml', 'event': 'issue_comment'})


def completed(name, identity=1):
    return {'name': name, 'id': identity, 'run_id': 7, 'head_sha': 'a' * 40,
            'run_attempt': 1, 'status': 'completed', 'conclusion': 'success'}


def test_old_and_new_rows_for_one_logical_job_remain_ambiguous():
    old = completed('linux-build')
    current = completed('Linux bundle / build', 2)
    with pytest.raises(ValueError, match='Latest required job'):
        ci_release_candidates.latest([old, current], 'linux-build')
    current['conclusion'] = 'failure'
    with pytest.raises(ValueError, match='Latest required job'):
        ci_release_candidates.latest([old, current], 'linux-build')
    assert ci_release_candidates.latest([old], 'linux-build') is old


def test_preview_requires_every_renamed_child_and_rejects_collisions():
    inverse = {logical: display for display, logical in _JOB_ALIASES.items()}
    rows = [completed(inverse.get(name, name), index + 1)
            for index, name in enumerate(ci_preview_audit.NIGHTLY_REQUIRED)]
    run = {'id': 7, 'run_attempt': 1}
    assert ci_preview_audit.green_closure(rows, run, 'a' * 40)
    assert not ci_preview_audit.green_closure(rows[:-1], run, 'a' * 40)
    rows.append(completed('build / linux-build', 1000))
    assert not ci_preview_audit.green_closure(rows, run, 'a' * 40)


# Reuse the existing real archive/receipt fixture; no frozen historical source is
# rewritten. Only the current API display label differs from its historical ID.
from tests.test_integration_application import producer as producer, restore  # noqa: E402


def test_renamed_application_producer_preserves_bytes_and_original_receipt(tmp_path, producer):
    producer[5]['name'] = 'Linux bundle / build'
    original_job = deepcopy(producer[5])
    original, restored, qualification = restore(tmp_path, producer)
    assert (restored / 'application.tar.gz').read_bytes() == (original / 'application.tar.gz').read_bytes()
    assert qualification['producer_job'] == original_job['id']
    assert qualification['producer_attempt'] == original_job['run_attempt']
    assert qualification['artifact_digest'] == 'sha256:' + producer[2]
    assert producer[5] == original_job


@pytest.mark.parametrize('invalid', ['workflow', 'upload-window'])
def test_renamed_label_cannot_waive_actual_artifact_provenance(tmp_path, producer, invalid):
    producer[5]['name'] = 'Linux bundle / build'
    if invalid == 'workflow':
        producer[3]['path'] = '.github/workflows/quality.yml'
    else:
        producer[4]['created_at'] = '2025-01-01T00:03:00Z'
    with pytest.raises(ValueError):
        restore(tmp_path, producer)
    assert not (tmp_path / 'restored').exists()
