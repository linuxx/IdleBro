#!/bin/bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source ./deploy-common.sh
[[ $# == 0 ]] || fail 'Usage: sudo bash install.sh'
log 'Starting IdleBro installation.'
preflight
for path in /etc/init.d/idlebro /opt/idlebro/IdleBro /etc/systemd/system/idlebro.service; do
    [[ ! -e $path && ! -L $path ]] || fail "Existing installation found at $path; use sudo bash upgrade.sh."
done
build
if [[ -e /etc/idlebro/idlebro.conf ]]; then
    log 'Preserving and validating existing configuration.'
    run cp -- /etc/idlebro/idlebro.conf "$stage/idlebro.conf"
else
    run cp -- idlebro.conf "$stage/idlebro.conf"
fi
run "$stage/IdleBro" --config "$stage/idlebro.conf" --check-config
snapshot
changed=true
apply_files
committed=true
log "SUCCESS: installed and enabled for boot. Backup: $backup"
log 'Start now with: sudo systemctl start idlebro'
