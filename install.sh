#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Direct, reversible installer for the WhoisDS NRD OPNsense plugin.
# Intended for OPNsense 26.7.x / FreeBSD 15.x. Run as root from the
# extracted os-whoisds-nrd source directory.
set -eu
set -f

PLUGIN="WhoisDS NRD"
STATE_DIR="/var/db/whoisds-nrd-installer"
DATA_DIR="/var/db/whoisds-nrd"
MANIFEST="$STATE_DIR/manifest.tsv"
BACKUP_DIR="$STATE_DIR/backup"
PYTHON="/usr/local/bin/python3.13"
CONFIGD_SERVICE="/usr/sbin/service configd"
SERVICE="/usr/sbin/service whoisds_nrd"
DRY_RUN=0

usage() {
    echo "Usage: $0 [--dry-run]"
    echo "  --dry-run  Validate prerequisites and show planned changes without installing."
}

say() { echo "[whoisds-nrd] $*"; }
die() { echo "[whoisds-nrd] ERROR: $*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || die "run as root (SSH as root or use su)."
[ "$(uname -s)" = "FreeBSD" ] || die "this installer must run on the OPNsense/FreeBSD firewall."
[ -x "$PYTHON" ] || die "$PYTHON is missing. This installer does not install or upgrade system packages."
[ -x /usr/local/sbin/configctl ] || die "/usr/local/sbin/configctl not found; this does not look like a complete OPNsense installation."
[ -x /usr/sbin/service ] || die "/usr/sbin/service is missing."

"$PYTHON" -c 'import sys; print("Python", sys.version.split()[0]); sys.exit(0 if sys.version_info[:2] == (3,13) else 1)' \
    || die "Python 3.13 is required."

SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
required_files="uninstall.sh
src/etc/rc.d/whoisds_nrd
src/opnsense/scripts/whoisds_nrd/updater.py
src/opnsense/scripts/whoisds_nrd/status.py
src/opnsense/service/conf/actions.d/actions_whoisds_nrd.conf
src/opnsense/mvc/app/controllers/OPNsense/WhoisdsNrd/IndexController.php
src/opnsense/mvc/app/controllers/OPNsense/WhoisdsNrd/Api/ServiceController.php
src/opnsense/mvc/app/controllers/OPNsense/WhoisdsNrd/Api/SettingsController.php
src/opnsense/mvc/app/controllers/OPNsense/WhoisdsNrd/forms/general.xml
src/opnsense/mvc/app/models/OPNsense/WhoisdsNrd/WhoisdsNrd.php
src/opnsense/mvc/app/models/OPNsense/WhoisdsNrd/WhoisdsNrd.xml
src/opnsense/mvc/app/models/OPNsense/WhoisdsNrd/ACL/ACL.xml
src/opnsense/mvc/app/models/OPNsense/WhoisdsNrd/Menu/Menu.xml
src/opnsense/service/templates/OPNsense/WhoisdsNrd/+TARGETS
src/opnsense/service/templates/OPNsense/WhoisdsNrd/settings.conf
src/opnsense/mvc/app/views/OPNsense/WhoisdsNrd/index.volt"
for rel in $required_files; do
    [ -f "$SOURCE_DIR/$rel" ] || die "source file missing: $rel (run from the extracted plugin directory)."
done

if [ -e "$STATE_DIR" ] || [ -L "$STATE_DIR" ]; then
    die "$STATE_DIR already exists. Refusing to overwrite an existing install/backup state. Run the matching uninstall.sh first or inspect that directory manually."
fi
[ ! -L "$DATA_DIR" ] || die "$DATA_DIR is a symlink; refusing to use it."
if [ -e "$DATA_DIR" ] && [ ! -d "$DATA_DIR" ]; then
    die "$DATA_DIR exists but is not a directory; refusing to modify it."
fi
[ ! -L "$DATA_DIR/daily" ] || die "$DATA_DIR/daily is a symlink; refusing to use it."
[ ! -L "$DATA_DIR/nrd-15days.txt" ] || die "$DATA_DIR/nrd-15days.txt is a symlink; refusing to use it."

if [ "$DRY_RUN" -eq 1 ]; then
    say "Dry-run checks passed. No files were changed."
    say "Would install plugin files under /usr/local/etc and /usr/local/opnsense."
    say "Would save original copies of any conflicting target files in $BACKUP_DIR."
    say "Would install persistent rollback command at /usr/local/sbin/whoisds-nrd-uninstall."
    say "Would create /etc/rc.conf.d/whoisds_nrd with whoisds_nrd_enable=YES."
    say "Would create the local data directory if missing, restart configd, generate persistent settings from the OPNsense model, and start the loopback HTTP service."
    say "Would NOT download domains, edit /conf/config.xml, create Cron jobs, or change Unbound settings."
    exit 0
fi

umask 077
mkdir -p "$BACKUP_DIR"
: > "$MANIFEST"
if [ -d "$DATA_DIR" ]; then DATA_PREEXISTED=1; else DATA_PREEXISTED=0; fi
if [ -d "$DATA_DIR/daily" ]; then DAILY_PREEXISTED=1; else DAILY_PREEXISTED=0; fi
if [ -f "$DATA_DIR/nrd-15days.txt" ]; then OUTPUT_PREEXISTED=1; else OUTPUT_PREEXISTED=0; fi
printf '%s\n' "$DATA_PREEXISTED" > "$STATE_DIR/data_preexisted"
printf '%s\n' "$DAILY_PREEXISTED" > "$STATE_DIR/daily_preexisted"
printf '%s\n' "$OUTPUT_PREEXISTED" > "$STATE_DIR/output_preexisted"
INSTALL_ACTIVE=1
TEMP_FILE=""

rollback_install() {
    status=$?
    if [ "$status" -ne 0 ] && [ "$INSTALL_ACTIVE" -eq 1 ]; then
        trap - EXIT HUP INT TERM
        say "Installation failed; attempting automatic rollback."
        if [ -n "${TEMP_FILE:-}" ]; then rm -f "$TEMP_FILE"; fi
        "$SERVICE" stop >/dev/null 2>&1 || true
        if [ -f "$MANIFEST" ]; then
            awk '{ line[NR]=$0 } END { for (i=NR; i>0; i--) print line[i] }' "$MANIFEST" |
            while IFS="$(printf '\t')" read -r kind state target backup installed_hash; do
                case "$kind" in
                    FILE)
                        if [ "$state" = "backup" ] && [ -f "$backup" ]; then
                            mkdir -p "$(dirname "$target")"
                            cp -p "$backup" "$target" || true
                        elif [ "$state" = "created" ]; then
                            rm -f "$target" || true
                        fi
                        ;;
                    DIR) rmdir "$target" 2>/dev/null || true ;;
                esac
            done
        fi
        "$CONFIGD_SERVICE" restart >/dev/null 2>&1 || true
        if [ "${DATA_PREEXISTED:-1}" -eq 0 ]; then
            rm -rf "$DATA_DIR"
        else
            if [ "${OUTPUT_PREEXISTED:-1}" -eq 0 ] && [ -f "$DATA_DIR/nrd-15days.txt" ] && [ ! -s "$DATA_DIR/nrd-15days.txt" ]; then
                rm -f "$DATA_DIR/nrd-15days.txt"
            fi
            if [ "${DAILY_PREEXISTED:-1}" -eq 0 ]; then rmdir "$DATA_DIR/daily" 2>/dev/null || true; fi
        fi
        rm -rf "$STATE_DIR"
        say "Rollback attempt finished. Check service/configd status before proceeding."
    fi
}
trap rollback_install EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

ensure_dir_chain() {
    path=$1
    old_ifs=$IFS
    IFS=/
    # These are fixed system paths without whitespace or glob characters.
    set -- $path
    IFS=$old_ifs
    current=""
    for part do
        [ -n "$part" ] || continue
        current="$current/$part"
        if [ -L "$current" ]; then die "refusing to install through symlink directory: $current"; fi
        if [ ! -d "$current" ]; then
            mkdir "$current"
            chown root:wheel "$current"
            chmod 755 "$current"
            printf 'DIR\t-\t%s\t-\t-\n' "$current" >> "$MANIFEST"
        fi
    done
}

install_file() {
    source=$1
    target=$2
    mode=$3
    ensure_dir_chain "$(dirname "$target")"
    [ ! -L "$target" ] || die "refusing to replace symlink: $target"
    if [ -e "$target" ]; then
        [ -f "$target" ] || die "target exists and is not a regular file: $target"
        backup="$BACKUP_DIR/file.$(find "$BACKUP_DIR" -type f | wc -l | tr -d ' ')"
        cp -p "$target" "$backup"
        state=backup
    else
        backup="-"
        state=created
    fi
    # Record the rollback instruction before replacing the target. If a later
    # copy/chmod/move fails, the EXIT trap can still restore the original.
    printf 'FILE\t%s\t%s\t%s\n' "$state" "$target" "$backup" >> "$MANIFEST"
    temp="$target.whoisds-nrd-tmp.$$"
    TEMP_FILE="$temp"
    cp "$source" "$temp"
    chown root:wheel "$temp"
    chmod "$mode" "$temp"
    mv -f "$temp" "$target"
    TEMP_FILE=""
    say "Installed $target"
}

# Keep the uninstaller on persistent storage so rollback remains available
# after /tmp is cleared by a reboot. Install it first so it is removed last.
install_file "$SOURCE_DIR/uninstall.sh" \
    "/usr/local/sbin/whoisds-nrd-uninstall" 700

install_file "$SOURCE_DIR/src/etc/rc.d/whoisds_nrd" \
    "/usr/local/etc/rc.d/whoisds_nrd" 755
install_file "$SOURCE_DIR/src/opnsense/scripts/whoisds_nrd/updater.py" \
    "/usr/local/opnsense/scripts/whoisds_nrd/updater.py" 755
install_file "$SOURCE_DIR/src/opnsense/scripts/whoisds_nrd/status.py" \
    "/usr/local/opnsense/scripts/whoisds_nrd/status.py" 755
install_file "$SOURCE_DIR/src/opnsense/service/conf/actions.d/actions_whoisds_nrd.conf" \
    "/usr/local/opnsense/service/conf/actions.d/actions_whoisds_nrd.conf" 644
install_file "$SOURCE_DIR/src/opnsense/mvc/app/controllers/OPNsense/WhoisdsNrd/IndexController.php" \
    "/usr/local/opnsense/mvc/app/controllers/OPNsense/WhoisdsNrd/IndexController.php" 644
install_file "$SOURCE_DIR/src/opnsense/mvc/app/controllers/OPNsense/WhoisdsNrd/Api/ServiceController.php" \
    "/usr/local/opnsense/mvc/app/controllers/OPNsense/WhoisdsNrd/Api/ServiceController.php" 644
install_file "$SOURCE_DIR/src/opnsense/mvc/app/controllers/OPNsense/WhoisdsNrd/Api/SettingsController.php" \
    "/usr/local/opnsense/mvc/app/controllers/OPNsense/WhoisdsNrd/Api/SettingsController.php" 644
install_file "$SOURCE_DIR/src/opnsense/mvc/app/controllers/OPNsense/WhoisdsNrd/forms/general.xml" \
    "/usr/local/opnsense/mvc/app/controllers/OPNsense/WhoisdsNrd/forms/general.xml" 644
install_file "$SOURCE_DIR/src/opnsense/mvc/app/models/OPNsense/WhoisdsNrd/WhoisdsNrd.php" \
    "/usr/local/opnsense/mvc/app/models/OPNsense/WhoisdsNrd/WhoisdsNrd.php" 644
install_file "$SOURCE_DIR/src/opnsense/mvc/app/models/OPNsense/WhoisdsNrd/WhoisdsNrd.xml" \
    "/usr/local/opnsense/mvc/app/models/OPNsense/WhoisdsNrd/WhoisdsNrd.xml" 644
install_file "$SOURCE_DIR/src/opnsense/mvc/app/models/OPNsense/WhoisdsNrd/ACL/ACL.xml" \
    "/usr/local/opnsense/mvc/app/models/OPNsense/WhoisdsNrd/ACL/ACL.xml" 644
install_file "$SOURCE_DIR/src/opnsense/mvc/app/models/OPNsense/WhoisdsNrd/Menu/Menu.xml" \
    "/usr/local/opnsense/mvc/app/models/OPNsense/WhoisdsNrd/Menu/Menu.xml" 644
install_file "$SOURCE_DIR/src/opnsense/service/templates/OPNsense/WhoisdsNrd/+TARGETS" \
    "/usr/local/opnsense/service/templates/OPNsense/WhoisdsNrd/+TARGETS" 644
install_file "$SOURCE_DIR/src/opnsense/service/templates/OPNsense/WhoisdsNrd/settings.conf" \
    "/usr/local/opnsense/service/templates/OPNsense/WhoisdsNrd/settings.conf" 644
install_file "$SOURCE_DIR/src/opnsense/mvc/app/views/OPNsense/WhoisdsNrd/index.volt" \
    "/usr/local/opnsense/mvc/app/views/OPNsense/WhoisdsNrd/index.volt" 644

# Manage only this service's rc.conf fragment; preserve and restore any previous file.
RC_TMP="$STATE_DIR/whoisds_nrd.rc.conf"
printf '%s\n' 'whoisds_nrd_enable="YES"' > "$RC_TMP"
install_file "$RC_TMP" "/etc/rc.conf.d/whoisds_nrd" 644

# Create only missing data scaffolding. Do not change permissions or contents
# of a pre-existing data directory or daily archive directory.
if [ ! -d "$DATA_DIR" ]; then
    mkdir -m 700 "$DATA_DIR"
    chown root:wheel "$DATA_DIR"
fi
if [ -L "$DATA_DIR/daily" ]; then die "refusing to use symlink data directory: $DATA_DIR/daily"; fi
if [ ! -d "$DATA_DIR/daily" ]; then
    mkdir -m 700 "$DATA_DIR/daily"
    chown root:wheel "$DATA_DIR/daily"
fi
if [ ! -e "$DATA_DIR/nrd-15days.txt" ]; then
    : > "$DATA_DIR/nrd-15days.txt"
    chown root:wheel "$DATA_DIR/nrd-15days.txt"
    chmod 644 "$DATA_DIR/nrd-15days.txt"
fi

# Validate installed Python syntax without leaving __pycache__ in the plugin tree.
PYTHONPYCACHEPREFIX="$STATE_DIR/pycache" "$PYTHON" -m py_compile \
    /usr/local/opnsense/scripts/whoisds_nrd/updater.py \
    /usr/local/opnsense/scripts/whoisds_nrd/status.py
rm -rf "$STATE_DIR/pycache"

say "Reloading configd so the WhoisDS NRD actions and templates are registered."
$CONFIGD_SERVICE restart
say "Generating the initial persistent plugin settings file."
/usr/local/sbin/configctl template reload OPNsense/WhoisdsNrd >/dev/null \
    || die "could not generate /var/db/whoisds-nrd/settings.conf from the OPNsense model."
say "Starting the local HTTP endpoint."
$SERVICE start

healthy=0
i=0
while [ "$i" -lt 10 ]; do
    if "$PYTHON" -c 'import urllib.request; r=urllib.request.urlopen("http://127.0.0.1:18765/health", timeout=2); raise SystemExit(0 if r.read() == b"whoisds-nrd-ok\n" else 1)' >/dev/null 2>&1; then
        healthy=1
        break
    fi
    sleep 1
    i=$((i + 1))
done
[ "$healthy" -eq 1 ] || die "HTTP health check failed. The installer will roll back."

# Confirm configd can resolve the new status action.
/usr/local/sbin/configctl whoisds_nrd status >/dev/null \
    || die "configd could not execute the new WhoisDS NRD status action."

INSTALL_ACTIVE=0
trap - EXIT HUP INT TERM
say "Installation completed successfully."
say "The HTTP endpoint is listening on 127.0.0.1:18765 only."
say "No feed download, Unbound configuration change, or Cron job was performed."
say "Rollback state and pre-install file backups are stored in $STATE_DIR."
say "To uninstall/roll back, run: sh /usr/local/sbin/whoisds-nrd-uninstall"
