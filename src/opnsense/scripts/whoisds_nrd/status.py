#!/usr/local/bin/python3.13
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fast, read-only WhoisDS NRD status endpoint helper.

The updater writes a compact status snapshot after feed changes. This script
never reads/parses domain archives or the aggregate feed; it only reads that
small JSON document, stats the published file, and probes the loopback service.
"""

import json
import sys
import urllib.request
from pathlib import Path

BASE = Path('/var/db/whoisds-nrd')
OUT = BASE / 'nrd-15days.txt'
RUN_STATE = BASE / 'run-state.json'
SETTINGS_FILE = BASE / 'settings.conf'
DEFAULT_RETENTION_DAYS = 3
HEALTH_URL = 'http://127.0.0.1:18765/health'


def read_run_state() -> dict:
    try:
        data = json.loads(RUN_STATE.read_text(encoding='utf-8'))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def main() -> int:
    if sys.version_info[:2] != (3, 13):
        print(json.dumps({
            'error': f"Python 3.13 required; running {sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
        }))
        return 1

    state = read_run_state()
    snapshot = state.get('status_snapshot')
    if not isinstance(snapshot, dict):
        snapshot = {}

    try:
        with urllib.request.urlopen(HEALTH_URL, timeout=1) as response:
            http = response.status == 200
    except Exception:
        http = False

    try:
        output_stat = OUT.stat()
        output_exists = OUT.is_file()
        output_bytes = output_stat.st_size if output_exists else 0
    except OSError:
        output_exists = False
        output_bytes = 0

    settings_error = None
    settings = {}
    try:
        for line in SETTINGS_FILE.read_text(encoding='utf-8').splitlines():
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                settings[key.strip()] = value.strip()
    except FileNotFoundError:
        pass
    try:
        retention_days = int(settings.get('RETENTION_DAYS', DEFAULT_RETENTION_DAYS))
        if not 1 <= retention_days <= 15:
            raise ValueError('retention must be between 1 and 15 days')
        excluded_tlds = sorted({value.strip().lower() for value in settings.get('EXCLUDED_TLDS', '').split(',') if value.strip()})
    except Exception as exc:
        retention_days = int(snapshot.get('retention_days', DEFAULT_RETENTION_DAYS))
        excluded_tlds = snapshot.get('excluded_tlds', [])
        settings_error = str(exc)

    result = {
        'service': 'running' if http else 'stopped',
        'http_endpoint': http,
        'output_exists': output_exists,
        'output_bytes': output_bytes,
        'stats_available': bool(snapshot.get('stats_available')),
        'unique_domains': int(snapshot.get('unique_domains', 0)),
        'raw_daily_entries': int(snapshot.get('raw_daily_entries', 0)),
        'retained_days': int(snapshot.get('retained_days', 0)),
        'retention_days': retention_days,
        'excluded_tlds': excluded_tlds,
        'excluded_tld_domains': int(snapshot.get('excluded_tld_domains', 0)),
        'published_entries': int(snapshot.get('published_entries', 0)),
        'wildcard_entries': int(snapshot.get('wildcard_entries', 0)),
        'days': snapshot.get('days', []),
        'anchor_date': snapshot.get('anchor_date'),
        'last_checked_utc': state.get('last_checked_utc'),
        'last_successful_update_utc': state.get('last_successful_update_utc'),
        'last_feed_rebuild_utc': state.get('last_feed_rebuild_utc'),
        'last_unbound_refresh_attempt_utc': state.get('last_unbound_refresh_attempt_utc'),
        'last_unbound_refresh_utc': state.get('last_unbound_refresh_utc'),
        'last_unbound_ingest_utc': state.get('last_unbound_ingest_utc'),
        'unbound_ingest_status': state.get('unbound_ingest_status', 'unknown'),
        'unbound_ingest_error': state.get('unbound_ingest_error'),
    }
    if settings_error:
        result['settings_error'] = settings_error
    print(json.dumps(result, separators=(',', ':')))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
