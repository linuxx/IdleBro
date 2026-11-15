# IdleBro

<img src="images/idlebro-dude.png" alt="IdleBro dude relaxing beside a server" width="360">

IdleBro generates variable background CPU and memory activity on Linux. It samples
system CPU usage every 250 ms, subtracts its own usage, and yields when other
processes become active. It does not guarantee any cloud provider's retention policy.

Defaults target **15–25% of total host CPU capacity**, changing every 5–15 seconds.
At 5% external CPU usage it pauses and releases its memory. It resumes after external
CPU usage stays at or below 2% for five seconds. All workers use the lowest nice
priority; the systemd service also uses Linux's idle CPU scheduling policy, so normal
work takes priority even between samples. A single busy core on a large host may be
below the aggregate pause threshold, but still takes scheduling priority.

Memory varies between 32–96 MiB. Allocations are touched and retained, limited to a
quarter of available memory above a 512 MiB reserve, and released under pressure.
Memory is not a percentage target. No disk or network traffic is generated.

## Install

Requires Linux with /proc, systemd, and g++ with C++17 support.

```sh
sudo bash install.sh
sudo systemctl start idlebro
systemctl status idlebro
journalctl -u idlebro
```

The installer compiles and validates before replacing the executable, preserves
existing configuration, and enables startup at boot. It does not start or restart
the service automatically.

## Upgrade an existing running installation

From the updated repository, run:

```sh
bash upgrade.sh --check
sudo bash upgrade.sh
```

The check command compiles and validates the migrated configuration without changing
installed files. The upgrade command requires Python 3 as well as the installation
requirements. It builds before stopping anything, saves previous files under
`/var/backups/idlebro-upgrade-*`, stops the installed executable's processes, removes
legacy SysV boot registration, installs the systemd service, and starts it. Duplicate
legacy processes are stopped using their actual executable paths, not a stale PID
file. Expect a brief interruption while it replaces the service.

Custom CPU and memory limits are preserved. For legacy configurations with
`RANDOMNESS`, the original 5–10% CPU defaults become 15–25%; `RANDOMNESS` is removed.
New activity thresholds use the defaults in idlebro.conf. Malformed or unknown
configuration values abort the upgrade before stopping the running version.

If a command fails after shutdown begins, the script attempts to restore the backed-up
files and restart the previous service. Keep the printed backup path until you have
checked `systemctl status idlebro` and `journalctl -u idlebro`. Rollback restores files
and attempts service recovery; inspect its errors if the previous service cannot start.

## Configuration

Edit /etc/idlebro/idlebro.conf, then run:

```sh
/opt/idlebro/IdleBro --check-config
sudo systemctl restart idlebro
```

See idlebro.conf for all keys. CPU values are percentages from 0–100, with ordered
lower/upper bounds. Memory bounds are MiB from 0–4096. Resume CPU must be lower than
pause CPU. IDLE_SECONDS must be 1–3600. Unknown keys and malformed values are errors.
Whitespace and # comments are supported. RANDOMNESS has been replaced by automatic
target changes. Set both memory bounds to zero to disable background memory usage.

For a foreground run without installation:

```sh
g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -pthread IdleBro.cpp -o /tmp/IdleBro
/tmp/IdleBro --config idlebro.conf
```

SIGINT and SIGTERM request a clean shutdown. systemd manages the single service
instance; the program runs in the foreground and does not create a PID file.

CPU accounting uses host /proc counters and targets host capacity. Container CPU
quotas and cpusets are not supported; run on a normal Linux host/VM. Other processes
can use memory without meaningful CPU use: the available-memory reserve provides
additional protection in that case.

## Validation

Run `python3 tests/test_idlebro.py` for build, configuration, resource, and shutdown
checks. Tests use temporary paths and never install a system service.

Licensed under the MIT License.

## Mascot

The README mascot is saved at `images/idlebro-dude.png`, generated using the built-in
image generation tool. Prompt: a relaxed, friendly bearded computer dude in sunglasses
and a hoodie beside a small server; polished hand-drawn digital illustration, bold
silhouette, clean outlines, restrained colors, plain light background, no text.
