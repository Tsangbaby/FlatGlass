import errno
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RECORD = 'mode.v1'


class RootHideModeStore(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build.cleanup)
        cls.probe = Path(cls.build.name) / 'probe'
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2',
                        '-DFG_MODE_STORE_PREPARE=1', '-I', str(ROOT / 'Shared'),
                        str(ROOT / 'tests/fg_mode_fixture.c'), str(ROOT / 'Shared/FGModeStore.c'),
                        '-o', str(cls.probe)], check=True, timeout=30)

    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.parent = Path(scratch.name)
        self.directory = self.parent / 'store'
        self.directory.mkdir(mode=0o700)
        self.record = self.directory / RECORD

    def invoke(self, command, *args, at=None):
        return tuple(map(int, subprocess.check_output([self.probe, command, at or self.directory,
                                                       *map(str, args)], text=True, timeout=5).split()))

    def test_saved_selection_survives_writer_exit_and_fresh_reader(self):
        for mode, state in [(1, 2), (3, 4), (2, 3), (0, 1)]:
            with self.subTest(mode=mode):
                self.assertEqual(self.invoke('write', mode), (0,))
                self.assertEqual(self.invoke('read'), (0, mode, state, state))
                self.assertEqual(self.record.read_bytes(), f'F1:{mode}\n'.encode())
                self.assertEqual(stat.S_IMODE(self.record.stat().st_mode), 0o600)
                self.assertEqual(list(self.directory.iterdir()), [self.record])

    def test_read_failure_is_not_remove_highlights(self):
        self.assertEqual(self.invoke('read'), (errno.ENOENT, -42, 0, -1))
        self.invoke('write', 1)
        self.directory.chmod(0o755)
        self.assertEqual(self.invoke('read'), (errno.EPERM, -42, 0, -1))
        self.assertEqual(self.invoke('write', 3), (errno.EPERM,))
        self.assertEqual(self.record.read_bytes(), b'F1:1\n')

    def test_refuse_invalid_values_and_ignore_malformed_records(self):
        self.invoke('write', 1)
        self.assertEqual(self.invoke('write', 4), (errno.EINVAL,))
        self.assertEqual(self.invoke('read'), (0, 1, 2, 2))
        for bad in (b'', b'F1:1', b'F1:4\n', b'F2:1\n', b'F1:1\n\0', b'F1:1\r', b'A' * 10000):
            with self.subTest(bad=bad[:14]):
                self.record.write_bytes(bad)
                self.assertEqual(self.invoke('read'), (errno.EINVAL, -42, 0, -1))
        self.assertEqual(self.invoke('write', 2), (0,))
        self.assertEqual(self.invoke('read'), (0, 2, 3, 3))

    def test_no_file_or_directory_symlink_and_no_special_or_linked_record(self):
        victim = self.parent / 'victim'
        victim.write_bytes(b'untouched')
        victim.chmod(0o600)
        alias = self.parent / 'alias'
        alias.symlink_to(self.directory, target_is_directory=True)
        self.assertNotEqual(self.invoke('write', 1, at=alias), (0,))
        for make in [lambda: self.record.symlink_to(victim), lambda: self.record.hardlink_to(victim),
                     lambda: os.mkfifo(self.record, 0o600)]:
            make()
            self.assertNotEqual(self.invoke('read')[0], 0)
            self.assertEqual(self.invoke('write', 1), (errno.EPERM,))
            self.assertEqual(victim.read_bytes(), b'untouched')
            self.record.unlink()
        self.invoke('write', 1)
        self.record.chmod(0o644)
        self.assertEqual(self.invoke('read'), (errno.EPERM, -42, 0, -1))
        self.assertEqual(self.invoke('write', 3), (errno.EPERM,))

    def test_reader_never_observes_a_partial_replace(self):
        self.assertEqual(self.invoke('write', 1), (0,))
        with subprocess.Popen([self.probe, 'writer', self.directory]) as writer:
            try:
                subprocess.run([self.probe, 'reader', self.directory], check=True, timeout=12)
                self.assertEqual(writer.wait(timeout=12), 0)
            finally:
                if writer.poll() is None:
                    writer.kill()
        self.assertEqual(self.invoke('read'), (0, 3, 4, 4))

    @unittest.skipUnless(os.geteuid() == 0, 'installer directory ownership requires local root fixture')
    def test_preparation_is_idempotent_and_never_relabels_existing_nodes(self):
        target = self.parent / 'local.lumid.flatglass'
        target.mkdir(mode=0o700)
        self.assertEqual(self.invoke('prepare', at=self.parent), (errno.EPERM,))
        self.assertEqual(target.stat().st_uid, 0)
        target.rmdir()
        target.symlink_to(self.directory, target_is_directory=True)
        self.assertNotEqual(self.invoke('prepare', at=self.parent), (0,))
        self.assertTrue(target.is_symlink())
        target.unlink()
        self.assertEqual(self.invoke('prepare', at=self.parent), (0,))
        st = target.stat()
        self.assertEqual((stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid), (0o700, 501, 501))
        self.assertEqual(self.invoke('prepare', at=self.parent), (0,))
        self.assertEqual(target.stat().st_ino, st.st_ino)

    def test_only_committed_values_wake_serial_publisher_and_diagnostics_are_independent(self):
        daemon = (ROOT / 'flatglass/main.m').read_text()
        watch = daemon.split('static int FGWatchMode(void)', 1)[1].split('static int FGDisableMode', 1)[0]
        self.assertIn('DISPATCH_QUEUE_SERIAL', watch)
        self.assertLess(watch.index('notify_register_dispatch(FG_NOTIFY_SETTINGS'),
                        watch.index('FGPublishSavedMode(&modeToken, false)'))
        publish = daemon.split('static BOOL FGPublishSavedMode', 1)[1].split('static void FGRemoveThemeAt', 1)[0]
        self.assertNotIn('notify_cancel(', publish)
        self.assertLess(publish.index('if (state == FG_MODE_KEEP_STATE)'), publish.index('notify_set_state('))
        self.assertLess(publish.index('notify_set_state('), publish.index('notify_post(FG_NOTIFY_MODE)'))
        self.assertIn('FGModeStoreRead(jbroot(FG_MODE_DIRECTORY), mode)', daemon)
        prefs = (ROOT / 'FlatGlassPrefs/FGSettingsListController.m').read_text()
        self.assertIn('FGModeStoreRead(directory, &stored) != ENOENT', prefs)
        self.assertNotIn('notify_set_state(', prefs)
        write = prefs.split('- (void)writeMode:', 1)[1].split('- (void)viewDidLoad', 1)[0]
        self.assertLess(write.index('FGModeStoreWrite('), write.index('FGNotifySettingsChanged()'))
        self.assertIn('if (status != 0)', write)
        report = (ROOT / 'flatglass/FGDiagDaemon.m').read_text()
        self.assertIn('documents != FGD_WRITE_OK && preferences != FGD_WRITE_OK', report)
        self.assertIn('FGDWriteReport(jbroot(FG_MODE_DIRECTORY), FGD_REPORT_NAME', report)


if __name__ == '__main__':
    unittest.main()
