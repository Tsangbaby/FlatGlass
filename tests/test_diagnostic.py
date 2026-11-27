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
BASE = 'f4a18ee0cd145880013e64f7e60a29a921ec4b85'  # Only the D2 candidate's base.
REPORT = 'FlatGlassDiagnostics-d2.plist'
PREFS = 'FlatGlassDiagnostics-d2-preferences.plist'
INSTALL = 'FlatGlassDiagnostics-d2-install.plist'


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
                'terminal_channel', 'terminal_flags', 'phase', 'documents_write_status',
                'preferences_write_status',
                'terminal_cache_write_failed',
            })
            self.assertEqual(v['format'], 2)
            self.assertEqual(v['phase'], 2)
            self.assertEqual(v['documents_write_status'], 0)
            self.assertEqual(v['preferences_write_status'], 2)
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
                self.assertEqual(subprocess.run(args, timeout=3).returncode, 6,
                                 'publication must honor the validated report inode lock')
                self.assertEqual(target.read_bytes(), raw)
            target.unlink()
            victim = work / 'unrelated'
            victim.write_bytes(b'untouched')
            target.symlink_to(victim)
            self.assertEqual(subprocess.run(args, timeout=3).returncode, 4)
            self.assertTrue(target.is_symlink())
            self.assertEqual(victim.read_bytes(), b'untouched')
            target.unlink()
            victim.chmod(0o600)
            target.hardlink_to(victim)
            self.assertEqual(subprocess.run(args, timeout=3).returncode, 5)
            self.assertEqual(victim.read_bytes(), b'untouched')
            target.unlink()
            target.write_bytes(b'not a report')
            target.chmod(0o644)
            self.assertEqual(subprocess.run(args, timeout=3).returncode, 5)
            self.assertEqual(target.read_bytes(), b'not a report')
            target.unlink()
            target.mkdir()
            self.assertEqual(subprocess.run(args, timeout=3).returncode, 4)
            target.rmdir()
            os.mkfifo(target, 0o600)
            self.assertEqual(subprocess.run(args, timeout=3).returncode, 4)
            fake_dir = work / 'fake-dir'
            fake_dir.symlink_to(work, target_is_directory=True)
            self.assertEqual(subprocess.run([str(exe), str(fake_dir)], timeout=3).returncode, 2)
            self.assertEqual(subprocess.run([str(exe), str(work / 'missing')], timeout=3).returncode, 2)
            self.assertEqual(subprocess.run([*args, '../unrelated'], timeout=3).returncode, 1)
            self.assertEqual(victim.read_bytes(), b'untouched')
            d1 = work / 'FlatGlassDiagnostics-d1.plist'
            d1.write_bytes(b'D1 evidence')
            self.assertEqual(subprocess.run([*args, d1.name], timeout=3).returncode, 1)
            subprocess.run([*args, PREFS], check=True, timeout=3)
            self.assertEqual((work / PREFS).read_bytes(), raw)
            self.assertEqual(d1.read_bytes(), b'D1 evidence')

            marker = work / INSTALL
            for phase, bootstrap, fallback in ((1, -1, -1), (2, 9, 0), (2, 0, -1), (2, 9, 17)):
                subprocess.run([*args, INSTALL, str(phase), str(bootstrap), str(fallback)], check=True, timeout=3)
                self.assertEqual(plistlib.loads(marker.read_bytes()), {
                    'format': 2, 'install_phase': phase, 'bootstrap_status': bootstrap, 'fallback_status': fallback,
                })
                self.assertEqual(marker.stat().st_mode & 0o777, 0o600)
            raw_marker = marker.read_bytes()
            self.assertEqual(subprocess.run([*args, INSTALL, '1', '0', '-1'], timeout=3).returncode, 1)
            self.assertEqual(marker.read_bytes(), raw_marker)
            marker.unlink()
            marker.symlink_to(d1)
            self.assertEqual(subprocess.run([*args, INSTALL, '1', '-1', '-1'], timeout=3).returncode, 4)
            self.assertEqual(d1.read_bytes(), b'D1 evidence')

    def test_candidate_leaves_d2_rendering_filters_and_launch_job_intact(self):
        protected = ('FlatGlassIconServices/FGRender.m', 'FlatGlassIconServices/FGWrap.m',
                     'FlatGlassIconServices/Tweak.x', 'FlatGlassIconServices/FGCompat.m',
                     'FlatGlassIconServices/FGDiagAgent.m',
                     'FlatGlassPrefs/Resources/Root.plist',
                     'FlatGlassIconServices/FlatGlassIconServices.plist',
                     'FlatGlassRefresh/FlatGlassRefresh.plist',
                     'templates/local.lumid.flatglass.plist.in',
                     'layout/DEBIAN/prerm', 'Makefile')
        for path in protected:
            with self.subTest(path=path):
                self.assertEqual((ROOT / path).read_bytes(), base_bytes(path))
        refresh = base_bytes('FlatGlassRefresh/Tweak.x').decode()
        refresh = refresh.replace('The agent publishes this once it has re-rendered; the delay below gives\n'
                                  '    // it room to finish writing the cache before we force a reload.',
                                  'The daemon publishes the mode. Allow the agent time to handle the\n'
                                  '    // cache before asking SpringBoard to reload; never write back stale state.')
        refresh = refresh.replace('            notify_set_state(RefreshStatusToken, state);\n', '')
        self.assertEqual(read('FlatGlassRefresh/Tweak.x'), refresh)
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
        self.assertIn(PREFS, read('Shared/FGDiagnostics.h'))
        self.assertNotIn('FlatGlassDiagnostics-d1.plist', read('Shared/FGDiagnostics.h'))

    @unittest.skipUnless(sys.platform == 'darwin', 'requires the macOS notify server')
    def test_native_transport_records_progress_and_exit_boundary(self):
        fixture = ROOT / 'tests/fg_diag_transport.m'
        self.assertTrue(fixture.is_file(), 'missing process-to-process transport fixture')
        with tempfile.TemporaryDirectory() as work:
            work = Path(work).resolve()
            exe = work / 'transport'
            documents = work / 'documents'
            preferences = work / 'preferences'
            preferences.mkdir()
            documents.write_bytes(b'not a directory')
            report = preferences / PREFS
            channel = 'local.lumid.flatglass.diag.host-test.' + work.name
            subprocess.run([
                'cc', '-fobjc-arc', '-fblocks', '-I', str(ROOT / 'Shared'),
                f'-DFGD_REPORT_DIRECTORY="{documents}"', f'-DFGD_PREFERENCES_DIRECTORY="{preferences}"',
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
                    self.assertEqual((startup['phase'], startup['documents_write_status'],
                                      startup['preferences_write_status']), (2, 2, 0))
                    self.assertEqual(documents.read_bytes(), b'not a directory')
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
                    self.assertEqual((final['documents_write_status'], final['preferences_write_status']), (2, 0))
                finally:
                    if collector.poll() is None:
                        collector.kill()

    def test_d2_writer_returns_closed_failure_stages_for_both_report_paths(self):
        header = read('Shared/FGDiagnostics.h')
        writer = read('flatglass/FGDiagReport.c')
        self.assertIn('int FGDWriteReport(const char *directory, const char *name, const FGDReport *report)', header)
        for result in ('FGD_WRITE_PARENT_OPEN', 'FGD_WRITE_PARENT_IDENTITY', 'FGD_WRITE_FILE_OPEN',
                       'FGD_WRITE_FILE_IDENTITY', 'FGD_WRITE_LOCK', 'FGD_WRITE_TRUNCATE',
                       'FGD_WRITE_CONTENT', 'FGD_WRITE_READBACK'):
            with self.subTest(result=result):
                self.assertIn(result, header)
                self.assertIn(result, writer)
        self.assertIn('FGD_PREFERENCES_NAME', header)
        self.assertIn('FGD_REPORT_NAME', header)

    def test_d2_install_marker_precedes_launchd_and_daemon_reports_first(self):
        postinst = read('layout/DEBIAN/postinst')
        daemon = read('flatglass/FGDiagDaemon.m')
        header = read('Shared/FGDiagnostics.h')
        self.assertIn('/usr/libexec/flatglassdiag', postinst, 'missing unprivileged install marker writer')
        self.assertIn(INSTALL, header)
        self.assertIn('/var/mobile/Documents', header)
        self.assertIn('/var/mobile/Library/Preferences', header)
        self.assertIn('FGD_WRITE_PARENT_OPEN', header)
        self.assertIn('FGDWriteReport(FGD_REPORT_DIRECTORY, FGD_REPORT_NAME', daemon)
        self.assertIn('FGDWriteReport(FGD_PREFERENCES_DIRECTORY, FGD_PREFERENCES_NAME', daemon)
        startup = daemon.split('dispatch_async(queue, ^{', 1)[1]
        self.assertLess(startup.index('writeSnapshot();'), startup.index('notify_register_dispatch(FGD_TERMINAL'))
        self.assertIn('preferences_write_status', read('flatglass/FGDiagReport.c'))
        self.assertIn('install_phase', read('flatglass/FGDiagReport.c'))
        helper = read('flatglass/FGDiagInstall.c')
        for guard in ('setgroups(', 'setgid(', 'setuid(', 'geteuid() !='):
            self.assertIn(guard, helper)
            self.assertLess(helper.index(guard), helper.index('FGDWriteInstallMarker('))
        self.assertIn('flatglassdiag_FILES = FGDiagInstall.c FGDiagReport.c', read('flatglass/Makefile'))

    def test_install_probe_failure_does_not_change_launch_order_or_exit_status(self):
        postinst = read('layout/DEBIAN/postinst')
        self.assertIn('/usr/libexec/flatglassdiag', postinst, 'missing independent install probe')
        mock = '''exec 3>&1
install_probe() { printf 'probe %s\\n' "$*" >&3; return "$PROBE"; }
launchctl() {
  printf 'launch %s\\n' "$*" >&3
  case "$1" in bootout) return 1;; bootstrap) return "$BOOT";; load) return "$LOAD";; esac
}
'''
        body = postinst.replace('/usr/libexec/flatglassdiag', 'install_probe')
        baseline = base_bytes('layout/DEBIAN/postinst').decode().replace('/usr/libexec/flatglassdiag', 'install_probe')
        for arch, probe, boot, load in (('iphoneos-arm64e', 0, 0, 31), ('iphoneos-arm64e', 5, 0, 31),
                                        ('iphoneos-arm64e', 5, 9, 0), ('iphoneos-arm64e', 5, 9, 31),
                                        ('iphoneos-arm64', 5, 9, 31), ('iphoneos-arm', 5, 0, 31)):
            with self.subTest(arch=arch, probe=probe, boot=boot, load=load):
                env = dict(os.environ, PROBE=str(probe), BOOT=str(boot), LOAD=str(load), DPKG_MAINTSCRIPT_ARCH=arch)
                old = subprocess.run(['/bin/sh', '-c', mock + baseline], env=env, capture_output=True, text=True, timeout=5)
                new = subprocess.run(['/bin/sh', '-c', mock + body], env=env, capture_output=True, text=True, timeout=5)
                expected = old.stdout.splitlines()
                if arch == 'iphoneos-arm64e':
                    expected = [expected[0], 'probe --prepare-mode-store', *expected[1:]]
                self.assertEqual(new.stdout.splitlines(), expected)
                self.assertEqual(new.returncode, old.returncode)

    def test_debian_identity_and_build_branch_distinguish_diagnostic_from_release(self):
        control = read('control')
        self.assertTrue(control.startswith('Package: local.lumid.flatglass\n'))
        version = next(s.split(': ', 1)[1] for s in control.splitlines() if s.startswith('Version: '))
        self.assertEqual(version, '1.8.4+diag.2.modefix.1')
        workflow = read('.github/workflows/build-flatglass-roothide.yml')
        self.assertIn('branches: [build/flatglass-1.8.4-roothide-d2-modefix1]', workflow)
        self.assertIn('Tsangbaby/FlatGlass:push:refs/heads/build/flatglass-1.8.4-roothide-d2-modefix1)', workflow)
        self.assertIn(BASE, workflow)
        self.assertIn('THEOS_PACKAGE_SCHEME=roothide', workflow)


if __name__ == '__main__':
    unittest.main()
