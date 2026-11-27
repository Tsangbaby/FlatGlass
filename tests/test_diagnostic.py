"""Behavior-neutral diagnostic contracts; the phone is still the delivery oracle."""
import fcntl
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest
from xml.parsers.expat import ExpatError

ROOT = Path(__file__).resolve().parents[1]
BASE = 'e815a7385b08c13fe0b4456c5baa16202af241fc'
REPORT = 'FlatGlassDiagnostics-d1.plist'


def read(path):
    return (ROOT / path).read_text()


def base_bytes(path):
    return subprocess.check_output(['git', 'show', f'{BASE}:{path}'], cwd=ROOT)


class FlatGlassDiagnostic(unittest.TestCase):
    def test_one_observation_chain_is_wired_into_the_existing_owners(self):
        daemon = read('flatglass/main.m')
        agent = read('FlatGlassIconServices/Tweak.x')
        cache = read('FlatGlassIconServices/FGCompat.m')
        self.assertIn('FGDRecordPublish(', daemon, 'missing publisher result observation')
        self.assertIn('FGDStartDaemon(', daemon)
        self.assertLess(agent.index('FGD_ENTERED'), agent.index('FGInstallHooks()'))
        self.assertEqual(agent.count('FGDReadFlag('), 2)
        self.assertIn('FGD_MODE_REGISTER_FAILED', agent)
        self.assertIn('FGD_MODE_REGISTER_OK', agent)
        self.assertIn('FGD_CACHE_WRITE_OK', cache)
        self.assertIn('FGDAgentTerminalWriteFailure(state, fromNotification);', cache)
        self.assertLess(cache.index('FGDAgentTerminalWriteFailure(state, fromNotification);'),
                        cache.index('_exit(0);'))
        self.assertIn('FGDiagDaemon.m FGDiagReport.c', read('flatglass/Makefile'))
        self.assertIn('FGDiagAgent.m', read('FlatGlassIconServices/Makefile'))

    def test_report_writer_produces_bounded_typed_plist_and_refuses_unsafe_nodes(self):
        writer = ROOT / 'flatglass/FGDiagReport.c'
        self.assertTrue(writer.is_file(), 'missing portable production report writer')
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            exe = work / 'probe'
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                            '-I', str(ROOT / 'Shared'), str(ROOT / 'tests/fg_diag_fixture.c'),
                            str(writer), '-o', str(exe)], check=True)
            target = work / REPORT
            args = [str(exe), str(work)]
            subprocess.run(args, check=True, timeout=3)
            raw = target.read_bytes()
            self.assertLessEqual(len(raw), 4096)
            v = plistlib.loads(raw)
            self.assertEqual(set(v), {
                'format', 'generation', 'sequence', 'watch_status', 'initial', 'change',
                'changes', 'agent_flags', 'agent_channel', 'startup_read', 'notification_read',
                'terminal_channel', 'terminal_flags',
                'terminal_cache_write_failed',
            })
            self.assertEqual(v['format'], 1)
            self.assertEqual(v['generation'], 12345)
            self.assertEqual(v['sequence'], 2)
            self.assertEqual(v['initial'], {'mode': 3, 'state': 4, 'register': 0, 'set': 0, 'cancel': 0, 'post': 0})
            self.assertEqual(v['change'], {'mode': 1, 'state': 2, 'register': 0, 'set': 0, 'cancel': 0, 'post': 7})
            self.assertEqual(v['startup_read'], 0)
            self.assertEqual(v['notification_read'], 2)
            self.assertNotEqual(v['terminal_flags'], 0)
            self.assertEqual(v['changes'], 1)
            self.assertIs(type(v['terminal_cache_write_failed']), bool)
            self.assertTrue(v['terminal_cache_write_failed'])
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            if sys.platform == 'darwin':
                subprocess.run(['/usr/bin/plutil', '-lint', str(target)], check=True, timeout=3)
            subprocess.run(args, check=True, timeout=3)
            self.assertEqual(target.read_bytes(), raw)
            with target.open('rb') as locked:
                fcntl.flock(locked, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assertEqual(subprocess.run(args, timeout=3).returncode, 4,
                                 'publication must honor the validated report inode lock')
                self.assertEqual(target.read_bytes(), raw)
            self.assertEqual(list(work.glob('.flatglass-diag-d1-*')), [])
            target.unlink()
            victim = work / 'unrelated'
            victim.write_bytes(b'untouched')
            target.symlink_to(victim)
            self.assertEqual(subprocess.run(args, timeout=3).returncode, 4)
            self.assertTrue(target.is_symlink())
            self.assertEqual(victim.read_bytes(), b'untouched')
            target.unlink()
            target.hardlink_to(victim)
            self.assertEqual(subprocess.run(args, timeout=3).returncode, 4)
            self.assertEqual(victim.read_bytes(), b'untouched')
            target.unlink()
            os.mkfifo(target, 0o600)
            self.assertEqual(subprocess.run(args, timeout=3).returncode, 4)
            fake_dir = work / 'fake-dir'
            fake_dir.symlink_to(work, target_is_directory=True)
            self.assertEqual(subprocess.run([str(exe), str(fake_dir)], timeout=3).returncode, 4)
            self.assertEqual(list(work.glob('.flatglass-diag-d1-*')), [])

    def test_diagnostics_do_not_replace_rendering_preferences_or_launch_paths(self):
        protected = ('FlatGlassIconServices/FGRender.m', 'FlatGlassIconServices/FGWrap.m',
                     'FlatGlassRefresh/Tweak.x', 'FlatGlassPrefs/FGSettingsListController.m',
                     'FlatGlassPrefs/Resources/Root.plist', 'Shared/FGCommon.h',
                     'FlatGlassIconServices/FlatGlassIconServices.plist',
                     'templates/local.lumid.flatglass.plist.in',
                     'layout/DEBIAN/postinst', 'layout/DEBIAN/prerm', 'Makefile')
        for path in protected:
            with self.subTest(path=path):
                self.assertEqual((ROOT / path).read_bytes(), base_bytes(path))
        baseline = base_bytes('flatglass/main.m').decode()
        live = read('flatglass/main.m')
        self.assertEqual(live.count('notify_register_check(FG_NOTIFY_MODE, &token)'),
                         baseline.count('notify_register_check(FG_NOTIFY_MODE, &token)'))
        self.assertIn('if (ok) postStatus = notify_post(FG_NOTIFY_MODE);', live)
        ordered = ['notify_set_state(token, normalized)', 'notify_cancel(token)', 'notify_post(FG_NOTIFY_MODE)']
        self.assertEqual([live.index(s) for s in ordered], sorted(live.index(s) for s in ordered))
        daemon_transport = read('flatglass/FGDiagDaemon.m')
        agent_transport = read('FlatGlassIconServices/FGDiagAgent.m')
        for text in (daemon_transport, agent_transport, read('Shared/FGDiagnostics.h')):
            self.assertNotIn('iconservices-mode', text)
            self.assertNotIn('settings-changed', text)
            self.assertNotIn('FG_NOTIFY_MODE', text)
            self.assertNotIn('FG_NOTIFY_SETTINGS', text)
        self.assertIn('DISPATCH_SOURCE_TYPE_DATA_OR', agent_transport)
        self.assertIn('DISPATCH_SOURCE_TYPE_DATA_OR', daemon_transport)
        self.assertIn('FGD_REPORT_WRITE_LIMIT', daemon_transport)
        self.assertIn(REPORT, read('Shared/FGDiagnostics.h'))

    @unittest.skipUnless(sys.platform == 'darwin', 'requires the macOS notify server')
    def test_native_transport_records_progress_and_exit_boundary(self):
        fixture = ROOT / 'tests/fg_diag_transport.m'
        self.assertTrue(fixture.is_file(), 'missing process-to-process transport fixture')
        with tempfile.TemporaryDirectory() as work:
            work = Path(work).resolve()
            exe = work / 'transport'
            report = work / REPORT
            channel = 'local.lumid.flatglass.diag.host-test.' + work.name
            subprocess.run([
                'cc', '-fobjc-arc', '-fblocks', '-I', str(ROOT / 'Shared'),
                f'-DFGD_REPORT_DIRECTORY="{work}"',
                f'-DFGD_PROGRESS="{channel}.progress"', f'-DFGD_TERMINAL="{channel}.terminal"',
                str(fixture), str(ROOT / 'flatglass/FGDiagDaemon.m'), str(ROOT / 'flatglass/FGDiagReport.c'),
                str(ROOT / 'FlatGlassIconServices/FGDiagAgent.m'), '-framework', 'Foundation', '-o', str(exe),
            ], timeout=35, check=True)

            def await_report(watchdog, condition):
                latest = None
                until = time.monotonic() + 8
                while time.monotonic() < until and watchdog.poll() is None:
                    try:
                        latest = plistlib.loads(report.read_bytes())
                    except (FileNotFoundError, plistlib.InvalidFileException, ValueError, ExpatError):
                        pass  # The bounded write can be in progress.
                    else:
                        if condition(latest):
                            return latest
                    time.sleep(0.05)
                self.fail(f'no matching report; child={watchdog.poll()} last={latest!r}')

            with subprocess.Popen([str(exe), 'collector']) as collector:
                try:
                    startup = await_report(collector, lambda r: r['changes'] == 1 and
                                           r['agent_channel'] != -1 and r['terminal_channel'] != -1)
                    self.assertEqual((startup['agent_channel'], startup['terminal_channel']), (0, 0))
                    self.assertEqual(startup['change']['state'], 4)
                    with subprocess.Popen([str(exe), 'progress']) as progress:
                        try:
                            published = await_report(progress, lambda r: r['startup_read'] == 0)
                            self.assertFalse(published['terminal_cache_write_failed'])
                        finally:
                            if progress.poll() is None:
                                progress.kill()
                    subprocess.run([str(exe), 'terminal'], timeout=3, check=True)
                    final = await_report(collector, lambda r: r['terminal_cache_write_failed'])
                    self.assertEqual(final['generation'], startup['generation'])
                    self.assertGreater(final['sequence'], published['sequence'])
                    self.assertNotEqual(final['terminal_flags'], 0)
                    self.assertEqual((final['startup_read'], final['notification_read']), (0, 4))
                finally:
                    if collector.poll() is None:
                        collector.kill()

    def test_debian_identity_and_build_branch_distinguish_diagnostic_from_release(self):
        control = read('control')
        self.assertTrue(control.startswith('Package: local.lumid.flatglass\n'))
        version = next(s.split(': ', 1)[1] for s in control.splitlines() if s.startswith('Version: '))
        self.assertEqual(version, '1.8.4+diag.1')
        workflow = read('.github/workflows/build-flatglass-roothide.yml')
        self.assertIn('branches: [build/flatglass-1.8.4-roothide-diag1]', workflow)
        self.assertIn('Tsangbaby/FlatGlass:push:refs/heads/build/flatglass-1.8.4-roothide-diag1)', workflow)
        self.assertIn('THEOS_PACKAGE_SCHEME=roothide', workflow)
        self.assertNotIn('build/flatglass-1.8.4-repaired-roothide', workflow)


if __name__ == '__main__':
    unittest.main()
