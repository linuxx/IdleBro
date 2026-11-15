#!/bin/bash
# Shared transaction and logging helpers for install.sh and upgrade.sh.
set -Eeuo pipefail
umask 022
stage= backup=
pending_files=()
changed=false
new_service=false
committed=false
was_active=false
paths=()
log() { printf '[IdleBro %(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
run() {
    printf '[IdleBro] +'; printf ' %q' "$@"; printf '\n'
    "$@"
}
require() {
    local tool
    for tool in "$@"; do command -v "$tool" >/dev/null || fail "Missing dependency: $tool"; done
}
links() {
    local path
    for path in /etc/rc?.d/*idlebro /etc/systemd/system/*.wants/idlebro.service /etc/systemd/system/*.requires/idlebro.service; do
        [[ -e $path || -L $path ]] && printf '%s\n' "$path"
    done
    return 0
}
restore() {
    local path temp restore_failed=false
    log "ROLLBACK: restoring previous installation from $backup" >&2
    if $new_service; then
        run systemctl stop idlebro.service || restore_failed=true
    fi
    # Restore original boot links exactly, including disabled/custom runlevel states.
    while IFS= read -r path; do rm -f -- "$path" || restore_failed=true; done < <(links)
    for path in "${paths[@]}"; do
        if [[ -e $backup$path || -L $backup$path ]]; then
            mkdir -p -- "$(dirname -- "$path")" || restore_failed=true
            temp=$(mktemp "$(dirname -- "$path")/.idlebro-restore.XXXXXXXX") || { restore_failed=true; continue; }
            if cp -a --no-dereference --remove-destination -- "$backup$path" "$temp"; then
                if ! mv -Tf -- "$temp" "$path"; then
                    rm -f -- "$temp"
                    restore_failed=true
                fi
            else
                rm -f -- "$temp"
                restore_failed=true
            fi
        else
            rm -f -- "$path" || restore_failed=true
        fi
    done
    run systemctl daemon-reload || restore_failed=true
    if $was_active && ! $restore_failed; then
        local already_running=false exe target
        for exe in /proc/[0-9]*/exe; do
            target=$(readlink "$exe" 2>/dev/null || true)
            if [[ $target == /opt/idlebro/IdleBro || $target == '/opt/idlebro/IdleBro (deleted)' ]]; then already_running=true; fi
        done
        if $already_running; then
            log 'ROLLBACK: previous executable is still running; avoiding a duplicate start.'
        else
            run systemctl start idlebro.service || restore_failed=true
        fi
    fi
    if $restore_failed; then
        log "ERROR: rollback incomplete. Backup retained at $backup; inspect systemctl status idlebro and journalctl -u idlebro." >&2
    else
        log 'ROLLBACK: previous files and boot links restored.' >&2
    fi
}
finish() {
    local status=$? file
    trap - EXIT ERR INT TERM HUP
    set +e
    if ((status != 0)); then
        log "FAILED (exit $status)." >&2
        if $changed && ! $committed; then
            if $new_service; then
                log 'Collecting service diagnostics before rollback.' >&2
                systemctl status --no-pager --full idlebro.service >&2
                if command -v journalctl >/dev/null; then
                    journalctl -u idlebro.service -n 25 --no-pager >&2
                fi
            fi
            restore
        fi
    fi
    for file in "${pending_files[@]}"; do rm -f -- "$file"; done
    [[ -z $stage ]] || rm -rf -- "$stage"
    # Backups are intentionally retained, including after rollback.
    exit "$status"
}
trap finish EXIT
trap 'log "ERROR at line $LINENO: $BASH_COMMAND (exit $?)" >&2' ERR
trap 'log "Interrupted by SIGINT" >&2; exit 130' INT
trap 'log "Interrupted by SIGTERM" >&2; exit 143' TERM
trap 'log "Interrupted by SIGHUP" >&2; exit 129' HUP
preflight() {
    [[ $EUID == 0 ]] || fail 'Run as root with sudo bash, or use upgrade.sh --check.'
    require g++ systemctl systemd-analyze flock install mktemp cp mv readlink python3 mkdir rm sleep dirname
    [[ -d /run/systemd/system ]] || fail 'A running systemd host is required.'
    exec 9>/run/idlebro-deploy.lock
    flock -n 9 || fail 'Another IdleBro install or upgrade is running.'
    log 'Acquired exclusive deployment lock.'
    log 'Checking systemd manager connectivity.'
    run systemctl show-environment >/dev/null
    local path
    for path in /opt /opt/idlebro /etc/idlebro /etc/systemd/system /etc/init.d; do
        [[ ! -L $path ]] || fail "Refusing a symlinked installation directory: $path"
    done
    for path in IdleBro.cpp idlebro.conf idlebro.service; do
        [[ -f $path ]] || fail "Missing repository file: $path; download the complete repository."
    done
    stage=$(mktemp -d)
    log "Staging directory: $stage"
}
build() {
    log 'Building optimized C++17 executable; installed service remains untouched.'
    run g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -pthread IdleBro.cpp -o "$stage/IdleBro"
    run "$stage/IdleBro" --config idlebro.conf --check-config
    if command -v systemd-analyze >/dev/null; then
        log 'Checking service unit syntax against the staged executable.'
        python3 - "$stage" <<'VERIFY_UNIT'
import pathlib, sys
stage = pathlib.Path(sys.argv[1])
text = pathlib.Path('idlebro.service').read_text()
(stage / 'idlebro.service').write_text(text.replace('/opt/idlebro/IdleBro', str(stage / 'IdleBro')))
VERIFY_UNIT
        run systemd-analyze verify "$stage/idlebro.service"
    fi
    log 'Build completed.'
}
snapshot() {
    local path
    paths=(/opt/idlebro/IdleBro /etc/idlebro/idlebro.conf /etc/systemd/system/idlebro.service /etc/init.d/idlebro)
    while IFS= read -r path; do paths+=("$path"); done < <(links)
    # Config and executable symlinks could refer to files outside this transaction.
    for path in /opt/idlebro/IdleBro /etc/idlebro/idlebro.conf; do
        [[ ! -L $path ]] || fail "Refusing symlink: $path"
    done
    for path in "${paths[@]}"; do
        [[ ! -d $path ]] || fail "Expected a file, found directory: $path"
    done
    if [[ ! -d /var/backups ]]; then run install -d -m 755 /var/backups; fi
    backup=$(mktemp -d /var/backups/idlebro-deploy-XXXXXXXX)
    log "Saving rollback backup: $backup"
    for path in "${paths[@]}"; do
        if [[ -e $path || -L $path ]]; then run cp -a --parents -- "$path" "$backup"; fi
    done
    printf '%s\n' "${paths[@]}" > "$backup/paths.txt"
    printf 'was_active=%s\n' "$was_active" > "$backup/state.txt"
    log 'Backup completed before any service changes.'
}
atomic_install() {
    local source=$1 destination=$2 mode=$3 temp
    temp=$(mktemp "$(dirname -- "$destination")/.idlebro-deploy.XXXXXXXX")
    # Track temporary files for EXIT cleanup, including a failed copy/rename.
    pending_files+=("$temp")
    run install -m "$mode" -- "$source" "$temp"
    run mv -Tf -- "$temp" "$destination"
}
apply_files() {
    local directory
    for directory in /opt/idlebro /etc/idlebro; do
        if [[ ! -d $directory ]]; then run install -d -m 755 "$directory"; fi
    done
    atomic_install "$stage/IdleBro" /opt/idlebro/IdleBro 755
    atomic_install "$stage/idlebro.conf" /etc/idlebro/idlebro.conf 644
    atomic_install idlebro.service /etc/systemd/system/idlebro.service 644
    new_service=true
    run systemctl daemon-reload
    run systemctl enable idlebro.service
}
