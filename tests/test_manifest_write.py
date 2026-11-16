"""write_with_backup must never leave the manifest truncated (R12, P0.7)."""

import os
import stat
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import manifest  # noqa: E402,F401  -- manifest_write requires manifest imported first
import manifest_write  # noqa: E402

ORIGINAL = "repos:\n  - name: alpha\n    path: ~/src/alpha\n"


def half_dump(data, stream, **kwargs):
    """A crash or full disk partway through the dump."""
    stream.write("repos:\n  - na")
    raise OSError(28, "No space left on device")


class WriteWithBackupTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = os.path.join(self.tmp.name, "repos.local.yaml")
        with open(self.target, "w", encoding="utf-8") as handle:
            handle.write(ORIGINAL)

    def read(self, path):
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read()

    def test_failed_dump_leaves_original_unchanged(self):
        with mock.patch.object(manifest_write.yaml, "safe_dump", side_effect=half_dump):
            with self.assertRaises(OSError):
                manifest_write.write_with_backup(self.target, {"repos": []})
        self.assertEqual(self.read(self.target), ORIGINAL)

    def test_failed_dump_leaves_no_temp_file(self):
        with mock.patch.object(manifest_write.yaml, "safe_dump", side_effect=half_dump):
            with self.assertRaises(OSError):
                manifest_write.write_with_backup(self.target, {"repos": []})
        self.assertEqual(sorted(os.listdir(self.tmp.name)),
                         ["repos.local.yaml", "repos.local.yaml.bak"])

    def test_success_writes_new_data_and_backup(self):
        manifest_write.write_with_backup(self.target, {"repos": [{"name": "beta"}]})
        self.assertIn("name: beta", self.read(self.target))
        self.assertEqual(self.read(self.target + ".bak"), ORIGINAL)
        self.assertEqual(sorted(os.listdir(self.tmp.name)),
                         ["repos.local.yaml", "repos.local.yaml.bak"])

    def test_keeps_file_mode(self):
        os.chmod(self.target, 0o600)
        manifest_write.write_with_backup(self.target, {"repos": []})
        self.assertEqual(os.stat(self.target).st_mode & 0o777, 0o600)

    def test_first_backup_takes_manifest_mode_not_umask(self):
        os.chmod(self.target, 0o600)
        old_umask = os.umask(0o022)
        try:
            manifest_write.write_with_backup(self.target, {"repos": []})
        finally:
            os.umask(old_umask)
        self.assertEqual(os.stat(self.target + ".bak").st_mode & 0o777, 0o600)

    def test_fsyncs_parent_directory_after_replace(self):
        real_fsync = os.fsync
        synced = []

        def record(fd):
            info = os.fstat(fd)
            if stat.S_ISDIR(info.st_mode):
                synced.append((info.st_dev, info.st_ino))
            real_fsync(fd)

        with mock.patch.object(manifest_write.os, "fsync", side_effect=record):
            manifest_write.write_with_backup(self.target, {"repos": []})
        parent = os.stat(self.tmp.name)
        # once for the .bak rename, once for the manifest rename
        self.assertEqual(synced, [(parent.st_dev, parent.st_ino)] * 2)

    def test_writes_through_symlink_to_resolved_file(self):
        link = os.path.join(self.tmp.name, "alias.yaml")
        os.symlink(self.target, link)
        manifest_write.write_with_backup(link, {"repos": [{"name": "beta"}]})
        self.assertTrue(os.path.islink(link))
        self.assertIn("name: beta", self.read(self.target))
        self.assertEqual(self.read(self.target + ".bak"), ORIGINAL)


if __name__ == "__main__":
    unittest.main()
