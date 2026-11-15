"""Isolated checks: no root privileges or service installation required."""
import pathlib
import subprocess
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class IdleBroTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='idlebro-test-')
        cls.directory = pathlib.Path(cls.temp.name)
        cls.binary = cls.directory / 'IdleBro'
        subprocess.run(['g++', '-std=c++17', '-O2', '-Wall', '-Wextra',
                        '-Wpedantic', '-pthread', str(ROOT / 'IdleBro.cpp'),
                        '-o', str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def config(self, contents):
        path = self.directory / 'test.conf'
        path.write_text(contents)
        return path

    def check(self, path):
        return subprocess.run([str(self.binary), '--config', str(path),
                               '--check-config'], capture_output=True, text=True)

    def test_shipped_defaults(self):
        self.assertEqual(self.check(ROOT / 'idlebro.conf').returncode, 0)

    def test_invalid_configurations(self):
        for text in ['CPU_LOWER_LIMIT=26\nCPU_UPPER_LIMIT=25',
                     'CPU_UPPER_LIMIT=101', 'MEMORY_LOWER_LIMIT=-1',
                     'MEMORY_UPPER_LIMIT=4097', 'CPU_UPPER_LIMIT=abc',
                     'CPU_UPPER_LIMIT=20garbage', 'CPU_UPPER_LIMIT=9999999999999999',
                     'RANDOMNESS=10', 'UNKNOWN=1', 'no equals',
                     'RESUME_EXTERNAL_CPU=5', 'IDLE_SECONDS=0']:
            with self.subTest(text=text):
                self.assertNotEqual(self.check(self.config(text)).returncode, 0)

    def test_whitespace_comments_and_missing_file(self):
        self.assertEqual(self.check(self.config(' # comment\n CPU_LOWER_LIMIT = 15 # target\n')).returncode, 0)
        self.assertNotEqual(self.check(self.directory / 'missing').returncode, 0)

    def test_activity_hysteresis(self):
        source = self.directory / 'gate.cpp'
        source.write_text('#define main idlebro_main\n#include "' + str(ROOT / 'IdleBro.cpp') + '"\n#undef main\n' + r"""
#include <cassert>
int main() {
    Config c;
    auto now = Clock::now();
    ActivityGate gate(now);
    assert(gate.update(0, c, now + std::chrono::seconds(4)));
    assert(!gate.update(0, c, now + std::chrono::seconds(5)));
    assert(gate.update(10, c, now + std::chrono::seconds(6)));
    assert(gate.update(0, c, now + std::chrono::seconds(10)));
    assert(!gate.update(0, c, now + std::chrono::seconds(11)));
    assert(!gate.update(3, c, now + std::chrono::seconds(12)));
    assert(gate.update(5, c, now + std::chrono::seconds(13)));
    assert(gate.update(3, c, now + std::chrono::seconds(17)));
    assert(gate.update(0, c, now + std::chrono::seconds(21)));
    assert(!gate.update(0, c, now + std::chrono::seconds(22)));
}
""")
        binary = self.directory / 'gate'
        subprocess.run(['g++', '-std=c++17', '-pthread', str(source), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)

    def test_upgrade_config_migration(self):
        script = (ROOT / 'upgrade.sh').read_text()
        migration = script.split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
        old = self.directory / 'old.conf'
        output = self.directory / 'migrated.conf'
        for low, high, expected in [(5, 10, (15, 25)), (30, 40, (30, 40))]:
            old.write_text(f'CPU_LOWER_LIMIT={low}\nCPU_UPPER_LIMIT={high}\nRANDOMNESS=10\n')
            subprocess.run(['python3', '-', str(old), str(ROOT / 'idlebro.conf'), str(output)],
                           input=migration, text=True, check=True)
            self.assertEqual(self.check(output).returncode, 0)
            self.assertIn(f'CPU_LOWER_LIMIT={expected[0]}', output.read_text())
            self.assertIn(f'CPU_UPPER_LIMIT={expected[1]}', output.read_text())
            self.assertNotIn('RANDOMNESS', output.read_text())

    def test_resident_memory_and_clean_shutdown(self):
        # Allow activity on a shared test host; disable CPU work for this check.
        path = self.config('CPU_LOWER_LIMIT=0\nCPU_UPPER_LIMIT=0\n'
                           'MEMORY_LOWER_LIMIT=16\nMEMORY_UPPER_LIMIT=16\n'
                           'PAUSE_EXTERNAL_CPU=100\nRESUME_EXTERNAL_CPU=99\n'
                           'IDLE_SECONDS=1\n')
        process = subprocess.Popen([str(self.binary), '--config', str(path)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            time.sleep(2)
            self.assertIsNone(process.poll())
            meminfo = pathlib.Path('/proc/meminfo').read_text()
            available = int(next(line.split()[1] for line in meminfo.splitlines()
                                 if line.startswith('MemAvailable:')))
            if available < 600 * 1024:
                self.skipTest('Insufficient free memory for resident-memory check')
            rss = []
            for _ in range(5):
                status = pathlib.Path(f'/proc/{process.pid}/status').read_text()
                rss.append(int(next(line.split()[1] for line in status.splitlines()
                                    if line.startswith('VmRSS:'))))
                time.sleep(.15)
            self.assertGreater(min(rss), 16 * 1024)
            process.terminate()
            _, errors = process.communicate(timeout=3)
            self.assertEqual(process.returncode, 0, errors)
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate()


if __name__ == '__main__':
    unittest.main()
