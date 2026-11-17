"""Exercise the real Bash DNS functions with a fake macOS networksetup."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]

NETWORKSETUP = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p = Path(os.environ['MOCK_NETWORK'])
s = json.loads(p.read_text())
args = sys.argv[1:]
if args[0] == '-listallnetworkservices':
    print('An asterisk (*) denotes that a network service is disabled.')
    print('\\n'.join(s['services']))
elif args[1] not in s['dns']:
    sys.exit(1)
elif args[0] == '-getdnsservers':
    value = s['dns'][args[1]]
    print('\\n'.join(value) if value else "There aren't any DNS Servers set on " + args[1] + '.')
else:
    if s.get('fail') == args[1]: sys.exit(1)
    s['dns'][args[1]] = [] if args[2:] == ['Empty'] else args[2:]
    p.write_text(json.dumps(s))
'''


class DNS(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.network = self.root / 'network.json'
        self.env = dict(os.environ, MOCK_NETWORK=str(self.network),
                        PATH=str(self.root) + ':' + os.environ['PATH'])
        mock = self.root / 'networksetup'
        mock.write_text(NETWORKSETUP)
        mock.chmod(0o755)
        # Source function definitions only; all paths are confined to the fixture.
        source = (ROOT / 'mihomo-ctl').read_text().split('case "${1:-}" in')[0]
        self.library = self.root / 'functions.sh'
        self.library.write_text(source + '\nDNSSTATE="' + str(self.root / 'journal') + '"\n'
                               'PIDF="' + str(self.root / 'core.pid') + '"\n')
        self.write({'services': ['Wi-Fi', 'USB LAN', '*Disabled'],
                    'dns': {'Wi-Fi': [], 'USB LAN': ['9.9.9.9', '149.112.112.112'],
                            '*Disabled': ['8.8.8.8']}})

    def write(self, state):
        self.network.write_text(json.dumps(state))

    def state(self):
        return json.loads(self.network.read_text())

    def run_shell(self, commands, ok=True):
        result = subprocess.run(['bash', '-c', 'source "$1"; ' + commands,
                                 'dns-test', str(self.library)], env=self.env,
                                text=True, capture_output=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_restore_dhcp_and_multiple_manual_servers(self):
        original = self.state()
        self.run_shell('dns_apply')
        self.assertEqual(self.state()['dns']['Wi-Fi'], ['127.0.0.1'])
        self.assertEqual(self.state()['dns']['USB LAN'], ['127.0.0.1'])
        self.assertEqual(self.state()['dns']['*Disabled'], ['8.8.8.8'])
        # A separate helper process must recover the same persistent journal.
        self.run_shell('dns_restore')
        self.assertEqual(self.state(), original)

    def test_repeated_apply_does_not_save_loopback_as_original(self):
        original = self.state()
        self.run_shell('dns_apply; dns_apply; dns_apply; dns_restore')
        self.assertEqual(self.state(), original)

    def test_new_service_gets_saved_and_restored(self):
        self.run_shell('dns_apply')
        state = self.state()
        state['services'].append('New Ethernet')
        state['dns']['New Ethernet'] = ['1.0.0.1']
        self.write(state)
        self.run_shell('dns_apply')
        self.assertEqual(self.state()['dns']['New Ethernet'], ['127.0.0.1'])
        self.run_shell('dns_restore')
        self.assertEqual(self.state()['dns']['New Ethernet'], ['1.0.0.1'])

    def test_external_change_is_not_overwritten_by_restore(self):
        self.run_shell('dns_apply')
        state = self.state()
        state['dns']['Wi-Fi'] = ['8.8.4.4']
        self.write(state)
        self.run_shell('dns_restore')
        self.assertEqual(self.state()['dns']['Wi-Fi'], ['8.8.4.4'])

    def test_partial_apply_can_be_rolled_back(self):
        original = self.state()
        state = self.state()
        state['fail'] = 'USB LAN'
        self.write(state)
        self.assertNotEqual(self.run_shell('dns_apply', ok=False).returncode, 0)
        self.run_shell('dns_restore')
        state = self.state()
        del state['fail']
        self.assertEqual(state, original)

    def test_failed_restore_keeps_journal_for_retry(self):
        original = self.state()
        self.run_shell('dns_apply')
        state = self.state()
        state['fail'] = 'Wi-Fi'
        self.write(state)
        self.assertNotEqual(self.run_shell('dns_restore', ok=False).returncode, 0)
        self.assertTrue(list((self.root / 'journal').glob('*/service')))
        state = self.state()
        del state['fail']
        self.write(state)
        self.run_shell('dns_restore')
        self.assertEqual(self.state(), original)

    def test_readiness_requires_a_usable_dns_reply(self):
        (self.root / 'core.pid').write_text('123\n')
        lsof = self.root / 'lsof'
        lsof.write_text('#!/bin/bash\nexit "${MOCK_LSOF_STATUS:-0}"\n')
        lsof.chmod(0o755)
        mock = self.root / 'dig'
        mock.write_text('#!/bin/bash\nprintf "%s\\n" "${MOCK_REPLY:-}"\n')
        mock.chmod(0o755)
        for reply, expected in [('', False), ('status: SERVFAIL', False),
                                ('status: NOERROR', True), ('status: NXDOMAIN', True)]:
            self.env['MOCK_REPLY'] = reply
            result = self.run_shell('dns_ready', ok=False)
            self.assertEqual(result.returncode == 0, expected)
        self.env['MOCK_LSOF_STATUS'] = '1'
        self.assertNotEqual(self.run_shell('dns_ready', ok=False).returncode, 0)

    def test_watcher_restores_after_core_exit_and_retries_failure(self):
        original = self.state()
        self.run_shell('dns_apply')
        state = self.state()
        state['fail'] = 'Wi-Fi'
        self.write(state)
        alive = self.root / 'alive'
        alive.touch()
        watcher = self.root / 'watcher'
        source = (ROOT / 'mihomo-ctl').read_text()
        overrides = ('\nDNSSTATE="' + str(self.root / 'journal') + '"\n'
                     'LOCKD="' + str(self.root / 'lock') + '"\n'
                     'DNSPID="' + str(self.root / 'watch.pid') + '"\n'
                     'running() { test -f "' + str(alive) + '"; }\n'
                     'sleep() { command sleep 0.05; }\n')
        watcher.write_text(source.replace('case "${1:-}" in', overrides + 'case "${1:-}" in', 1))
        with open(self.root / 'watch.log', 'w') as log:
            process = subprocess.Popen(['bash', str(watcher), '__dns-watch'],
                                       env=self.env, stdout=log, stderr=log)
            try:
                alive.unlink()
                # Wait until the watcher restores the service that can succeed.
                deadline = time.monotonic() + 5
                while self.state()['dns']['USB LAN'] == ['127.0.0.1']:
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.02)
                self.assertIsNone(process.poll())  # failed Wi-Fi restore must retry
                state = self.state()
                del state['fail']
                self.write(state)
                self.assertEqual(process.wait(timeout=5), 0)
                self.assertEqual(self.state(), original)
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
