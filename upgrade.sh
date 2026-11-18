#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# In-place upgrade for an existing direct WhoisDS NRD installation.
# Preserves /var/db/whoisds-nrd data and does not modify Unbound or Cron settings.
set -eu
set -f

PYTHON="/usr/local/bin/python3.13"
CONFIGCTL="/usr/local/sbin/configctl"
CONFIGD_SERVICE="/usr/sbin/service configd"
DATA_DIR="/var/db/whoisds-nrd"
INSTALL_STATE="/var/db/whoisds-nrd-installer"
INSTALL_MANIFEST="$INSTALL_STATE/manifest.tsv"
INSTALL_BACKUP="$INSTALL_STATE/backup"
BACKUP_ROOT="/var/db/whoisds-nrd-upgrade"
DRY_RUN=0

usage() {
    echo "Usage: $0 [--dry-run]"
    echo "  --dry-run  Validate source and show files that would be backed up/replaced."
}

say() { echo "[whoisds-nrd-upgrade] $*"; }
die() { echo "[whoisds-nrd-upgrade] ERROR: $*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || die "run as root."
[ "$(uname -s)" = "FreeBSD" ] || die "this upgrade script must run on OPNsense/FreeBSD."
[ -x "$PYTHON" ] || die "$PYTHON is missing."
[ -x "$CONFIGCTL" ] || die "$CONFIGCTL is missing."
[ -d "$DATA_DIR/daily" ] || die "existing NRD data directory not found; use install.sh for a fresh installation."
[ -f "$INSTALL_MANIFEST" ] || die "original installer manifest not found at $INSTALL_MANIFEST; cannot safely register new files for future uninstall."
[ -d "$INSTALL_BACKUP" ] || die "original installer backup directory is missing: $INSTALL_BACKUP"

SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
files="uninstall.sh
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
for rel in $files; do
    [ -f "$SOURCE_DIR/$rel" ] || die "source file missing: $rel"
done

if [ "$DRY_RUN" -eq 1 ]; then
    say "Preflight passed. No files or data were changed."
    for rel in $files; do
        case "$rel" in
            uninstall.sh) target="/usr/local/sbin/whoisds-nrd-uninstall" ;;
            src/opnsense/scripts/*) target="/usr/local/opnsense/scripts/${rel#src/opnsense/scripts/}" ;;
            src/opnsense/service/conf/*) target="/usr/local/opnsense/service/conf/${rel#src/opnsense/service/conf/}" ;;
            src/opnsense/service/templates/*) target="/usr/local/opnsense/service/templates/${rel#src/opnsense/service/templates/}" ;;
            src/opnsense/mvc/app/*) target="/usr/local/opnsense/mvc/app/${rel#src/opnsense/mvc/app/}" ;;
        esac
        say "Would back up/replace $target"
    done
    say "Would restart configd and regenerate settings.conf. Feed data, Unbound settings, and Cron jobs would be preserved."
    exit 0
fi

STAMP=$(date +%Y%m%d%H%M%S)
BACKUP_DIR="$BACKUP_ROOT/$STAMP"
[ ! -e "$BACKUP_DIR" ] || die "backup directory already exists: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR/files"
chmod 700 "$BACKUP_ROOT" "$BACKUP_DIR" "$BACKUP_DIR/files"
MANIFEST="$BACKUP_DIR/manifest.tsv"
DIRS_TO_REGISTER="$BACKUP_DIR/new_dirs.tsv"
FILES_TO_REGISTER="$BACKUP_DIR/new_files.tsv"
ORIGINAL_INSTALL_MANIFEST="$BACKUP_DIR/original-install-manifest.tsv"
cp -p "$INSTALL_MANIFEST" "$ORIGINAL_INSTALL_MANIFEST"
: > "$MANIFEST"
: > "$DIRS_TO_REGISTER"
: > "$FILES_TO_REGISTER"

rollback() {
    status=$?
    if [ "$status" -ne 0 ]; then
        trap - EXIT HUP INT TERM
        say "Upgrade failed; rolling back files from $BACKUP_DIR."
        awk '{ line[NR]=$0 } END { for (i=NR; i>0; i--) print line[i] }' "$MANIFEST" |
        while IFS="$(printf '\t')" read -r kind target backup; do
            case "$kind" in
                BACKUP)
                    mkdir -p "$(dirname "$target")"
                    cp -p "$backup" "$target" || true
                    ;;
                CREATED) rm -f "$target" || true ;;
                DIR) rmdir "$target" 2>/dev/null || true ;;
            esac
        done
        cp -p "$ORIGINAL_INSTALL_MANIFEST" "$INSTALL_MANIFEST" || true
        $CONFIGD_SERVICE restart >/dev/null 2>&1 || true
        say "Rollback attempted. Backup retained at $BACKUP_DIR."
    fi
}
trap rollback EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

track_dir_chain() {
    path=$1
    old_ifs=$IFS
    IFS=/
    set -- $path
    IFS=$old_ifs
    current=""
    for part do
        [ -n "$part" ] || continue
        current="$current/$part"
        if [ -L "$current" ]; then die "refusing to use symlink directory: $current"; fi
        if [ ! -d "$current" ]; then
            mkdir "$current"
            chown root:wheel "$current"
            chmod 755 "$current"
            # Track directories in both manifests: the original persistent
            # uninstaller needs them removed later, while this upgrade's own
            # rollback must remove them if a later step fails.
            printf 'DIR\t%s\n' "$current" >> "$MANIFEST"
            printf 'DIR\t-\t%s\t-\t-\n' "$current" >> "$DIRS_TO_REGISTER"
        fi
    done
}

install_one() {
    rel=$1
    source="$SOURCE_DIR/$rel"
    case "$rel" in
        uninstall.sh) target="/usr/local/sbin/whoisds-nrd-uninstall" ;;
        src/opnsense/scripts/*) target="/usr/local/opnsense/scripts/${rel#src/opnsense/scripts/}" ;;
        src/opnsense/service/conf/*) target="/usr/local/opnsense/service/conf/${rel#src/opnsense/service/conf/}" ;;
        src/opnsense/service/templates/*) target="/usr/local/opnsense/service/templates/${rel#src/opnsense/service/templates/}" ;;
        src/opnsense/mvc/app/*) target="/usr/local/opnsense/mvc/app/${rel#src/opnsense/mvc/app/}" ;;
        *) die "unsupported upgrade path: $rel" ;;
    esac
    dir=$(dirname "$target")
    track_dir_chain "$dir"
    [ ! -L "$target" ] || die "refusing to replace symlink: $target"
    target_existed=0
    if [ -e "$target" ]; then
        target_existed=1
        [ -f "$target" ] || die "target is not a regular file: $target"
        backup="$BACKUP_DIR/files/${target#/}"
        mkdir -p "$(dirname "$backup")"
        cp -p "$target" "$backup"
        printf 'BACKUP\t%s\t%s\n' "$target" "$backup" >> "$MANIFEST"
    else
        printf 'CREATED\t%s\t-\n' "$target" >> "$MANIFEST"
    fi
    temp="$target.whoisds-nrd-upgrade.$$"
    cp "$source" "$temp"
    chown root:wheel "$temp"
    chmod 755 "$temp"
    case "$target" in
        *.php|*.xml|*.volt|*/+TARGETS|*/settings.conf|*.conf) chmod 644 "$temp" ;;
    esac
    mv -f "$temp" "$target"

    # The original direct-install manifest must know about files introduced by
    # this upgrade so the persistent uninstaller can later remove/restore them.
    if ! awk -F '\t' -v wanted="$target" '$3 == wanted { found=1 } END { exit(found ? 0 : 1) }' "$INSTALL_MANIFEST"; then
        if [ "$target_existed" -eq 1 ]; then
            registered_backup="$INSTALL_BACKUP/upgrade_${STAMP}_$(wc -l < "$FILES_TO_REGISTER" | tr -d ' ')"
            cp -p "$BACKUP_DIR/files/${target#/}" "$registered_backup"
            printf 'FILE\tbackup\t%s\t%s\t-\n' "$target" "$registered_backup" >> "$FILES_TO_REGISTER"
        else
            printf 'FILE\tcreated\t%s\t-\t-\n' "$target" >> "$FILES_TO_REGISTER"
        fi
    fi
    say "Installed $target"
}

for rel in $files; do install_one "$rel"; done

# Append created directories before file entries: uninstall processes this
# manifest in reverse, removing files before their now-empty directories.
cat "$DIRS_TO_REGISTER" "$FILES_TO_REGISTER" >> "$INSTALL_MANIFEST"

PYTHONPYCACHEPREFIX="$BACKUP_DIR/pycache" "$PYTHON" -m py_compile \
    /usr/local/opnsense/scripts/whoisds_nrd/updater.py \
    /usr/local/opnsense/scripts/whoisds_nrd/status.py
rm -rf "$BACKUP_DIR/pycache"

say "Restarting configd to load the new action and MVC files."
$CONFIGD_SERVICE restart
say "Regenerating the settings file from the persistent OPNsense model."
"$CONFIGCTL" template reload OPNsense/WhoisdsNrd >/dev/null
say "Checking backend status."
"$CONFIGCTL" whoisds_nrd status >/dev/null

trap - EXIT HUP INT TERM
say "Upgrade completed. Existing feed and daily archives were not deleted or rewritten."
say "Unbound blocklist settings and user Cron entries were not changed."
say "File backups and rollback manifest: $BACKUP_DIR"
say "Open the WhoisDS NRD page, set your filters/retention, then click Save Settings & Rebuild Feed."
