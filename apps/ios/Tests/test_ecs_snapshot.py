import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

# Import the Linux reader on Windows without installing POSIX packages.
try:
    import pwd
except ImportError:
    sys.modules['pwd'] = types.SimpleNamespace(getpwuid=lambda uid: types.SimpleNamespace(pw_name=str(uid)))

SCRIPT = Path(__file__).resolve().parents[1] / 'Hako' / 'Resources' / 'ecs-snapshot.py.txt'
# The .txt suffix makes this an unambiguous Xcode bundle resource. Compile in
# memory so tests do not leave bytecode files in the app's resource directory.
collector = types.ModuleType('ecs_snapshot')
exec(compile(SCRIPT.read_text(encoding='utf-8'), str(SCRIPT), 'exec'), collector.__dict__)


def stat(name='worker (job)', ticks=100, start=1000, rss=10, flags=0):
    fields = ['0'] * 30
    fields[0] = 'S'
    for index, value in {1: 1, 6: flags, 11: ticks, 12: 0, 17: 4, 19: start, 21: rss}.items():
        fields[index] = str(value)
    return '42 (' + name + ') ' + ' '.join(fields)


class SnapshotTests(unittest.TestCase):
    def test_stat_handles_parentheses_and_pid_reuse(self):
        parsed = collector.process_stat(stat())
        self.assertEqual(parsed['name'], 'worker (job)')
        self.assertEqual(parsed['ticks'], 100)
        self.assertIsNone(collector.process_stat('gone'))
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            (proc / '42').mkdir()
            (proc / '42' / 'status').write_text('Uid:\t1001\t1001\t1001\t1001\n')
            (proc / '42' / 'cgroup').write_text('0::/user.slice/user-1001.slice\n')
            (proc / '42' / 'loginuid').write_text('1001')
            (proc / 'uptime').write_text('200 100')
            with patch.object(collector, 'PROC', proc), patch.object(collector.os, 'sysconf', create=True, side_effect=lambda key: 100 if key == 'SC_CLK_TCK' else 4096):
                value = collector.processes({42: parsed}, {42: collector.process_stat(stat(ticks=150))}, 1)[0]
                self.assertEqual(value['cpu'], 50)
                self.assertEqual(value['memory'], 40960)
                self.assertEqual(value['category'], 'user')
                self.assertIsNone(value['read'])  # Missing permission is not zero.
                reused = collector.processes({42: parsed}, {42: collector.process_stat(stat(ticks=999, start=2000))}, 1)[0]
                self.assertIsNone(reused['cpu'])

    def test_classification_does_not_equate_root_with_system(self):
        job = collector.process_stat(stat(name='my-business'))
        self.assertEqual(collector.classify(job, 0, '', None)[0], 'unknown')
        self.assertEqual(collector.classify(job, 0, '', 1000)[0], 'user')
        kernel = collector.process_stat(stat(name='kworker', flags=0x200000))
        self.assertEqual(collector.classify(kernel, 0, '', None)[0], 'system')

    def test_rates_handle_reset_and_new_interface(self):
        first = {'eth0': dict(receive=100, send=200, receiveDrops=0, sendDrops=1)}
        after = {'eth0': dict(receive=300, send=50, receiveDrops=0, sendDrops=1),
                 'lo': dict(receive=10, send=10, receiveDrops=0, sendDrops=0)}
        values = collector.network(first, after, 2)
        self.assertEqual(values[0]['receiveRate'], 100)
        self.assertIsNone(values[0]['sendRate'])
        self.assertIsNone(values[1]['receiveRate'])

    def test_socket_ipv6_missing_owner_and_dedup(self):
        text = ('tcp LISTEN 0 128 [::]:443 [::]:* users:(("nginx",pid=1260,fd=8))\n'
                'udp UNCONN 0 0 127.0.0.53:53 0.0.0.0:*\n'
                'tcp ESTAB 0 0 10.0.1.2:443 10.0.2.3:50000\n')
        values = collector.parse_sockets(text + text)
        self.assertEqual(len(values), 3)
        self.assertEqual(values[0]['local'], '[::]:443')
        self.assertEqual(values[0]['pid'], 1260)
        self.assertIsNone(values[1]['pid'])

    def test_output_budget_retains_total_and_marks_partial(self):
        value = {'version': 1, 'time': 100, 'totalProcesses': 200,
                 'processes': [{'pid': n, 'name': '汉' * 100} for n in range(200)]}
        result = collector.bounded_output(value)
        decoded = json.loads(result)
        self.assertLessEqual(len(result.encode()), 20000)
        self.assertTrue(decoded['truncated'])
        self.assertEqual(decoded['totalProcesses'], 200)
        self.assertLess(len(decoded['processes']), 200)

    def test_command_fits_cloud_assistant_limit(self):
        import base64
        command = "python3 - overview 0 <<'HAKO_ECS_SNAPSHOT'\n" + SCRIPT.read_text(encoding='utf-8') + '\nHAKO_ECS_SNAPSHOT\n'
        self.assertLess(len(base64.b64encode(command.encode())), 24000)

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Requires live Linux /proc')
    def test_live_linux_snapshots(self):
        overview = json.loads(collector.collect('overview'))
        self.assertGreater(overview['memoryTotal'], 0)
        self.assertLessEqual(overview.get('memoryAvailable', 0), overview['memoryTotal'])
        network = json.loads(collector.collect('network'))
        self.assertTrue(network['interfaces'])
        self.assertTrue(network.get('sockets') is not None or network.get('socketError'))
        process = json.loads(collector.collect('process', os.getpid()))['processes'][0]
        self.assertEqual(process['pid'], os.getpid())
        self.assertGreater(process['memory'], 0)


if __name__ == '__main__':
    unittest.main()
