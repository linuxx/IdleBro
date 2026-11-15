#!/bin/bash
# Upgrade a running legacy SysV or systemd installation. No downloads are performed.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
check_only=false
if [[ ${1:-} == --check && $# == 1 ]]; then
    check_only=true
elif [[ $# != 0 ]]; then
    echo 'Usage: bash upgrade.sh [--check]' >&2
    exit 1
fi
if ! $check_only && [[ $EUID -ne 0 ]]; then
    echo 'Run this upgrade as root, or use --check to validate the build.' >&2
    exit 1
fi
for tool in g++ python3 systemctl; do command -v "$tool" >/dev/null; done
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -pthread IdleBro.cpp -o "$stage/IdleBro"
# Remove the obsolete knob; upgrade original CPU defaults while retaining custom limits.
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
"$stage/IdleBro" --config "$stage/idlebro.conf" --check-config
if $check_only; then
    echo 'Build and configuration migration validated; no installed files changed.'
    cat "$stage/idlebro.conf"
    exit 0
fi
[[ -x /opt/idlebro/IdleBro ]] || { echo 'No installed IdleBro; use install.sh.' >&2; exit 1; }
# Back up every file that will be replaced before stopping the service.
install -d -m 755 /var/backups
backup=$(mktemp -d /var/backups/idlebro-upgrade-XXXXXXXX)
paths=(/opt/idlebro/IdleBro /etc/idlebro/idlebro.conf /etc/systemd/system/idlebro.service /etc/init.d/idlebro)
for path in "${paths[@]}"; do
    if [[ -e $path ]]; then cp -a --parents -- "$path" "$backup"; fi
done
legacy=false
[[ ! -e /etc/init.d/idlebro ]] || legacy=true
$legacy && command -v update-rc.d >/dev/null
changed=false
rollback() {
    status=$?
    trap - ERR
    set +e
    if $changed; then
        echo "Upgrade failed; restoring files from $backup" >&2
        systemctl stop idlebro.service || true
        if [[ ! -e $backup/etc/systemd/system/idlebro.service ]]; then
            systemctl disable idlebro.service || true
        fi
        for path in "${paths[@]}"; do
            if [[ -e $backup$path ]]; then
                cp -a -- "$backup$path" "$path"
            else
                rm -f -- "$path"
            fi
        done
        if $legacy; then update-rc.d idlebro defaults || true; fi
        systemctl daemon-reload || true
        systemctl start idlebro.service || echo 'Previous service could not be restarted; inspect the backup and journal.' >&2
    fi
    exit "$status"
}
trap rollback ERR
changed=true
# Never trust a legacy PID file: identify all actual installed executable instances.
# This also cleans up duplicate instances left by repeated old `service start` calls.
if ! $legacy; then systemctl stop idlebro.service; fi
pids=()
for exe in /proc/[0-9]*/exe; do
    target=$(readlink "$exe" 2>/dev/null || true)
    if [[ $target == /opt/idlebro/IdleBro || $target == '/opt/idlebro/IdleBro (deleted)' ]]; then
        pid=${exe#/proc/}; pid=${pid%/exe}
        pids+=("$pid")
        kill -TERM "$pid" 2>/dev/null || true
    fi
done
for attempt in {1..50}; do
    alive=false
    for pid in "${pids[@]}"; do
        target=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
        if [[ $target == /opt/idlebro/IdleBro || $target == '/opt/idlebro/IdleBro (deleted)' ]]; then alive=true; fi
    done
    $alive || break
    sleep 0.1
done
if $alive; then echo 'Old process did not stop; refusing to start a second instance.' >&2; false; fi
if $legacy; then
    # Clear generated SysV unit state only after removing its untrusted PID file.
    rm -f /var/run/idlebro.pid
    systemctl daemon-reload
    systemctl stop idlebro.service
    update-rc.d -f idlebro remove
    rm -f /etc/init.d/idlebro
fi
rm -f /var/run/idlebro.pid
install -m 755 "$stage/IdleBro" /opt/idlebro/IdleBro.new
mv -f /opt/idlebro/IdleBro.new /opt/idlebro/IdleBro
install -d -m 755 /etc/idlebro
install -m 644 "$stage/idlebro.conf" /etc/idlebro/idlebro.conf
install -m 644 idlebro.service /etc/systemd/system/idlebro.service
systemctl daemon-reload
systemctl enable idlebro.service
systemctl start idlebro.service
sleep 2
systemctl is-active --quiet idlebro.service
trap - ERR
echo "Upgrade complete; IdleBro is running. Previous files: $backup"
echo 'Inspect activity with: journalctl -u idlebro -f'
