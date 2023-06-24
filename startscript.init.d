#!/bin/sh
### BEGIN INIT INFO
# Provides:          idlebro
# Required-Start:    $remote_fs $syslog
# Required-Stop:     $remote_fs $syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: IdleBro daemon
# Description:       Starts and stops the IdleBro daemon.
### END INIT INFO

# Change these variables to match your configuration
EXECUTABLE="/opt/idlebro/IdleBro"  # Path to your IdleBro executable
PIDFILE="/var/run/idlebro.pid"  # Path to the PID file created by IdleBro

start() {
    echo "Starting IdleBro..."
    nohup "$EXECUTABLE" >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
}

stop() {
    echo "Stopping IdleBro..."
    if [ -f "$PIDFILE" ]; then
        kill $(cat "$PIDFILE")
        rm "$PIDFILE"
    else
        echo "IdleBro is not running."
    fi
}

restart() {
    stop
    start
}

case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        restart
        ;;
    *)
        echo "Usage: /etc/init.d/idlebro {start|stop|restart}"
        exit 1
        ;;
esac

exit 0

