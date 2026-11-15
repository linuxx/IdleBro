#!/bin/sh
# Compatibility entry point. systemd owns process identity and lifecycle.
case "${1:-}" in
    start|stop|restart|status) exec systemctl "$1" idlebro.service ;;
    *) echo "Usage: $0 {start|stop|restart|status}" >&2; exit 1 ;;
esac
