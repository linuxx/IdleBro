#!/bin/bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source ./deploy-common.sh
check_only=false
if [[ ${1:-} == --check && $# == 1 ]]; then check_only=true
elif [[ $# != 0 ]]; then fail 'Usage: sudo bash upgrade.sh [--check]'; fi
log 'Starting IdleBro upgrade preflight.'
if $check_only; then
    require g++ python3
    stage=$(mktemp -d)
else
    preflight
    [[ -x /opt/idlebro/IdleBro ]] || fail 'No installed executable; use sudo bash install.sh.'
fi
build
log 'Migrating configuration; preserving custom limits and removing legacy RANDOMNESS.'
python3 - /etc/idlebro/idlebro.conf idlebro.conf "$stage/idlebro.conf" <<'PY'
import pathlib, sys
old, defaults, output = map(pathlib.Path, sys.argv[1:])
values = {}
if old.exists():
    for raw in old.read_text().splitlines():
        line = raw.split('#', 1)[0].strip()
        if not line:
            continue
        key, sep, value = line.partition('=')
        if not sep:
            raise SystemExit('Invalid existing configuration: ' + raw)
        key, value = key.strip(), value.strip()
        if key in values:
            raise SystemExit('Duplicate configuration key: ' + key)
        values[key] = value
    legacy = 'RANDOMNESS' in values
    if legacy:
        int(values.pop('RANDOMNESS'))
    if legacy and int(values.get('CPU_LOWER_LIMIT', '5')) == 5 and int(values.get('CPU_UPPER_LIMIT', '10')) == 10:
        values['CPU_LOWER_LIMIT'], values['CPU_UPPER_LIMIT'] = '15', '25'
base = defaults.read_text()
known = {line.split('=', 1)[0] for line in base.splitlines() if '=' in line and not line.startswith('#')}
unknown = set(values) - known
if unknown:
    raise SystemExit('Unknown existing configuration keys: ' + ', '.join(sorted(unknown)))
lines = []
for line in base.splitlines():
    key = line.split('=', 1)[0]
    lines.append(key + '=' + values[key] if key in values else line)
output.write_text('\n'.join(lines) + '\n')
PY
run "$stage/IdleBro" --config "$stage/idlebro.conf" --check-config
if $check_only; then
    log 'SUCCESS: build and configuration migration checked; installed files unchanged.'
    cat "$stage/idlebro.conf"
    exit 0
fi
legacy=false
[[ ! -e /etc/init.d/idlebro ]] || legacy=true
if $legacy; then require update-rc.d; fi
# Snapshot actual processes; never trust legacy PID files.
pids=()
for exe in /proc/[0-9]*/exe; do
    target=$(readlink "$exe" 2>/dev/null || true)
    if [[ $target == /opt/idlebro/IdleBro || $target == '/opt/idlebro/IdleBro (deleted)' ]]; then
        pid=${exe#/proc/}; pid=${pid%/exe}
        pids+=("$pid")
    fi
done
if systemctl is-active --quiet idlebro.service || ((${#pids[@]} > 0)); then was_active=true; fi
log "Previous service active: $was_active; legacy SysV: $legacy; executable instances: ${#pids[@]}"
snapshot
changed=true
if ! $legacy; then
    log 'Stopping systemd service before replacing files.'
    run systemctl stop idlebro.service
fi
# Re-check executable identity before each signal. Do not execute the legacy stop
# script: its PID file could identify an unrelated process.
for pid in "${pids[@]}"; do
    target=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
    if [[ $target == /opt/idlebro/IdleBro || $target == '/opt/idlebro/IdleBro (deleted)' ]]; then
        log "Requesting clean termination of installed IdleBro process $pid."
        kill -TERM "$pid" || [[ ! -e /proc/$pid/exe ]]
    fi
done
for attempt in {1..100}; do
    alive=false
    for pid in "${pids[@]}"; do
        target=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
        if [[ $target == /opt/idlebro/IdleBro || $target == '/opt/idlebro/IdleBro (deleted)' ]]; then alive=true; fi
    done
    $alive || break
    sleep 0.1
done
if $alive; then fail 'Old executable did not stop within 10 seconds; refusing replacement.'; fi
log 'All identified old processes have stopped.'
if $legacy; then
    log 'Removing legacy startup registration and unsafe PID file.'
    run update-rc.d -f idlebro remove
    run rm -f /etc/init.d/idlebro /var/run/idlebro.pid
    run systemctl daemon-reload
    # The generated unit may retain active state; its ExecStop file is now gone.
    if ! run systemctl stop idlebro.service; then
        log 'Legacy unit stop reported an error after removal; checking inactive state.'
        if systemctl is-active --quiet idlebro.service; then fail 'Legacy unit remains active.'; fi
    fi
fi
apply_files
run systemctl reset-failed idlebro.service
run systemctl start idlebro.service
log 'Checking service health for five seconds.'
initial_pid=$(systemctl show -p MainPID --value idlebro.service)
[[ $initial_pid =~ ^[1-9][0-9]*$ ]] || fail 'Service has no main process.'
for attempt in {1..10}; do
    sleep 0.5
    run systemctl is-active --quiet idlebro.service
    current_pid=$(systemctl show -p MainPID --value idlebro.service)
    [[ $(readlink "/proc/$current_pid/exe") == /opt/idlebro/IdleBro ]] || fail 'Service main process is not the installed IdleBro executable.'
    [[ $current_pid == "$initial_pid" ]] || fail 'Service restarted during health checks.'
done
committed=true
log "SUCCESS: upgraded and running (PID $initial_pid). Backup: $backup"
log 'Inspect activity: journalctl -u idlebro -f'
