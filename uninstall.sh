#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Reversible uninstaller for a direct install made by install.sh.
set -eu
set -f

STATE_DIR="/var/db/whoisds-nrd-installer"
DATA_DIR="/var/db/whoisds-nrd"
MANIFEST="$STATE_DIR/manifest.tsv"
PYTHON="/usr/local/bin/python3.13"
SERVICE="/usr/sbin/service whoisds_nrd"
CONFIGD_SERVICE="/usr/sbin/service configd"
DRY_RUN=0
ASSUME_YES=0
DATA_MODE=auto

usage() {
    cat <<USAGE
Usage: $0 [--dry-run] [--yes] [--keep-data|--purge-data]
  --dry-run    Show what would be removed/restored without changing anything.
  --yes        Skip the interactive REMOVE confirmation.
  --keep-data  Keep /var/db/whoisds-nrd regardless of whether it was created by the installer.
  --purge-data Delete /var/db/whoisds-nrd even if it existed before installation.
Default: remove plugin data only when the installer recorded that the data directory did not exist before installation.
USAGE
}

say() { echo "[whoisds-nrd] $*"; }
die() { echo "[whoisds-nrd] ERROR: $*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --yes) ASSUME_YES=1 ;;
        --keep-data) DATA_MODE=keep ;;
        --purge-data) DATA_MODE=purge ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || die "run as root."
[ "$(uname -s)" = "FreeBSD" ] || die "this uninstaller must run on the OPNsense/FreeBSD firewall."
[ -f "$MANIFEST" ] || die "installation manifest not found at $MANIFEST. This uninstaller only removes files recorded by install.sh."
[ ! -L "$STATE_DIR" ] || die "refusing to use symlink state directory."
[ ! -L "$DATA_DIR" ] || die "refusing to delete or modify symlink data directory: $DATA_DIR"

DATA_PREEXISTED=1
if [ -f "$STATE_DIR/data_preexisted" ]; then
    value=$(cat "$STATE_DIR/data_preexisted")
    case "$value" in 0) DATA_PREEXISTED=0 ;; 1) DATA_PREEXISTED=1 ;; *) die "invalid data_preexisted marker." ;; esac
fi
DAILY_PREEXISTED=1
if [ -f "$STATE_DIR/daily_preexisted" ]; then
    value=$(cat "$STATE_DIR/daily_preexisted")
    case "$value" in 0) DAILY_PREEXISTED=0 ;; 1) DAILY_PREEXISTED=1 ;; *) die "invalid daily_preexisted marker." ;; esac
fi
OUTPUT_PREEXISTED=1
if [ -f "$STATE_DIR/output_preexisted" ]; then
    value=$(cat "$STATE_DIR/output_preexisted")
    case "$value" in 0) OUTPUT_PREEXISTED=0 ;; 1) OUTPUT_PREEXISTED=1 ;; *) die "invalid output_preexisted marker." ;; esac
fi
if [ "$DATA_MODE" = keep ]; then PURGE_DATA=0
elif [ "$DATA_MODE" = purge ]; then PURGE_DATA=1
elif [ "$DATA_PREEXISTED" -eq 0 ]; then PURGE_DATA=1
else PURGE_DATA=0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    say "Dry run: would stop service whoisds_nrd."
    awk -F '\t' '$1 == "FILE" { print "Would restore/remove: " $3 } $1 == "DIR" { print "Would remove empty directory if possible: " $3 }' "$MANIFEST"
    if [ "$PURGE_DATA" -eq 1 ]; then say "Would remove plugin data directory: $DATA_DIR"; else say "Would preserve plugin data directory: $DATA_DIR"; fi
    say "Would invalidate only the local feed's Unbound URL cache and restart configd."
    say "Would NOT edit /conf/config.xml, user-created Cron jobs, or Unbound DNSBL source settings."
    exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    echo "This will remove the WhoisDS NRD plugin files and restore any files that existed before installation."
    if [ "$PURGE_DATA" -eq 1 ]; then
        echo "It will also DELETE $DATA_DIR and its stored domain archives/feed."
    else
        echo "It will PRESERVE $DATA_DIR and the stored domain archives/feed."
    fi
    echo "Before continuing, manually remove any WhoisDS NRD URL from Unbound DNSBL and any Cron job using 'whoisds_nrd update'."
    printf 'Type REMOVE to continue: '
    IFS= read -r answer
    [ "$answer" = "REMOVE" ] || die "uninstall cancelled."
fi

say "Stopping the local HTTP service."
if [ -x /usr/local/etc/rc.d/whoisds_nrd ]; then
    $SERVICE stop >/dev/null 2>&1 || true
fi
if [ -x "$PYTHON" ]; then
    if "$PYTHON" -c 'import urllib.request; r=urllib.request.urlopen("http://127.0.0.1:18765/health", timeout=2); raise SystemExit(0 if r.read() == b"whoisds-nrd-ok\n" else 1)' >/dev/null 2>&1; then
        die "the local HTTP service is still responding after stop; no plugin files have been removed."
    fi
fi
if [ -f /var/run/whoisds_nrd.pid ]; then
    service_pid=$(cat /var/run/whoisds_nrd.pid)
    case "$service_pid" in
        ''|*[!0-9]*) die "invalid /var/run/whoisds_nrd.pid; inspect it before uninstalling." ;;
    esac
    if kill -0 "$service_pid" 2>/dev/null; then
        die "WhoisDS NRD process $service_pid is still running; no plugin files have been removed."
    else
        rm -f /var/run/whoisds_nrd.pid
    fi
fi

# The Unbound cache filename is the MD5 digest of the exact local source URL.
if [ -x "$PYTHON" ] && [ -d /tmp/bl_cache ]; then
    digest=$("$PYTHON" -c 'import hashlib; print(hashlib.md5(b"http://127.0.0.1:18765/nrd-15days.txt").hexdigest())')
    rm -f "/tmp/bl_cache/$digest" "/tmp/bl_cache/$digest.tmp"
fi

# Restore original files or remove installer-created files, in reverse install order.
awk '{ line[NR]=$0 } END { for (i=NR; i>0; i--) print line[i] }' "$MANIFEST" |
while IFS="$(printf '\t')" read -r kind state target backup installed_hash; do
    case "$kind" in
        FILE)
            if [ "$state" = "backup" ]; then
                if [ -f "$backup" ]; then
                    mkdir -p "$(dirname "$target")"
                    cp -p "$backup" "$target"
                    say "Restored pre-existing file: $target"
                else
                    say "WARNING: backup missing; leaving current file alone: $target" >&2
                fi
            elif [ "$state" = "created" ]; then
                rm -f "$target"
                say "Removed installed file: $target"
            fi
            ;;
        DIR)
            rmdir "$target" 2>/dev/null || true
            ;;
    esac
done

if [ "$PURGE_DATA" -eq 1 ]; then
    case "$DATA_DIR" in
        /var/db/whoisds-nrd) rm -rf "$DATA_DIR" ;;
        *) die "internal data path check failed; not deleting $DATA_DIR" ;;
    esac
    say "Removed plugin data directory."
else
    if [ "$OUTPUT_PREEXISTED" -eq 0 ] && [ -f "$DATA_DIR/nrd-15days.txt" ] && [ ! -s "$DATA_DIR/nrd-15days.txt" ]; then
        rm -f "$DATA_DIR/nrd-15days.txt"
    fi
    if [ "$DAILY_PREEXISTED" -eq 0 ]; then rmdir "$DATA_DIR/daily" 2>/dev/null || true; fi
    say "Preserved pre-existing/user data at $DATA_DIR. Removed only empty scaffolding created by the installer."
fi

say "Reloading configd after removing the WhoisDS NRD action file."
$CONFIGD_SERVICE restart || die "configd restart failed. The files were removed/restored, but rollback backups remain in $STATE_DIR; resolve configd and rerun this uninstaller."

rm -rf "$STATE_DIR"
say "Uninstall/rollback completed."
say "Reminder: remove the custom WhoisDS URL from Unbound DNSBL and delete any user-created Cron job that invokes whoisds_nrd."
