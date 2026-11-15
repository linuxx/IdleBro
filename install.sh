#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
if [[ $EUID -ne 0 ]]; then
    echo 'Run this installer as root.' >&2
    exit 1
fi
if [[ -e /etc/init.d/idlebro || -e /opt/idlebro/IdleBro ]]; then
    echo 'Existing installation found; use: sudo bash upgrade.sh' >&2
    exit 1
fi
command -v g++ >/dev/null
command -v systemctl >/dev/null
build_dir=$(mktemp -d)
trap 'rm -rf -- "$build_dir"' EXIT
g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -pthread IdleBro.cpp -o "$build_dir/IdleBro"
"$build_dir/IdleBro" --config idlebro.conf --check-config
# Validate an existing configuration before touching the installed service.
if [[ -f /etc/idlebro/idlebro.conf ]]; then
    "$build_dir/IdleBro" --config /etc/idlebro/idlebro.conf --check-config
fi
install -d -m 755 /opt/idlebro /etc/idlebro
install -m 755 "$build_dir/IdleBro" /opt/idlebro/IdleBro.new
mv -f /opt/idlebro/IdleBro.new /opt/idlebro/IdleBro
if [[ ! -f /etc/idlebro/idlebro.conf ]]; then
    install -m 644 idlebro.conf /etc/idlebro/idlebro.conf
fi
install -m 644 idlebro.service /etc/systemd/system/idlebro.service
systemctl daemon-reload
systemctl enable idlebro.service
echo 'Installed. Start with: systemctl start idlebro'
