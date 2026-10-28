#!/usr/bin/env python3
"""公開スクリプトから、選択したパスの照合と受信結果を確かめる。"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[1]
DOWNLOADS = Path.home() / "Downloads"
MOCK = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys

name, args = Path(sys.argv[0]).name, sys.argv[1:]
if name == "osascript":
    if args[:2] == ["-l", "JavaScript"]:
        os.execv("/usr/bin/osascript", ["/usr/bin/osascript", *args])
    script = sys.stdin.read()
    if "set targetID" in script:
        selection = os.environ["TRANSFER_TEST_SELECTION"]
        print("\x1f".join(["/dev/ttys999", os.environ["TRANSFER_TEST_REMOTE"], str(len(selection)), selection, ""]))
    else:
        with open(os.environ["TRANSFER_TEST_DIALOGS"], "a") as log:
            log.write(json.dumps(args[1:], ensure_ascii=False) + "\n")
        print(args[-1])
elif name == "defaults":
    print('(ja)')
elif name == "ps":
    print("ssh fixture")
elif name == "ssh":
    if args[-2:] != ["fixture", "sh -s"]:
        raise SystemExit("試験で許していない接続先です")
    raise SystemExit(subprocess.call(["/bin/sh", "-s"]))
elif name == "open":
    pass
else:
    raise SystemExit("試験で許していないコマンドです")
'''


@unittest.skipUnless(sys.platform == "darwin", "macOS の JXA を使う試験です")
class DownloadTest(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="iterm2-download-test-")
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.remote = self.root / "remote"
        self.remote.mkdir()
        self.prefix = "iterm2-test-" + uuid.uuid4().hex + "-"
        self.addCleanup(self.remove_downloads)
        self.dialogs = self.root / "dialogs.jsonl"
        binaries = self.root / "bin"
        binaries.mkdir()
        mock = binaries / "mock-command.py"
        mock.write_text(MOCK)
        mock.chmod(0o755)
        for name in ["osascript", "defaults", "ps", "ssh", "open"]:
            (binaries / name).symlink_to(mock)
        self.environment = {
            **os.environ,
            "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
            "ITERM_SESSION_ID": "fixture",
            "TRANSFER_TEST_REMOTE": str(self.remote),
            "TRANSFER_TEST_DIALOGS": str(self.dialogs),
        }

    def remove_downloads(self):
        for path in DOWNLOADS.glob(self.prefix + "*"):
            path.unlink()

    def file(self, name):
        path = self.remote / (self.prefix + name)
        path.write_bytes(("受信する内容: " + name).encode())
        return path

    def download(self, selection):
        return subprocess.run(
            ["/bin/bash", str(ROOT / "download.sh")],
            env={**self.environment, "TRANSFER_TEST_SELECTION": selection},
            capture_output=True, text=True, timeout=20,
        )

    def selected(self, name):
        return str(self.remote / (self.prefix + name))

    def assert_downloaded(self, source, selection):
        result = self.download(selection)
        target = DOWNLOADS / source.name
        self.assertEqual(result.returncode, 0, self.dialogs.read_text() if self.dialogs.exists() else result.stderr)
        self.assertEqual(target.read_bytes(), source.read_bytes())
        dialogs = [json.loads(line) for line in self.dialogs.read_text().splitlines()]
        self.assertIn(source.name, dialogs[-1][0])

    def test_fullwidth_space_lost_at_wrap(self):
        source = self.file("計画全社DR\u3000審議資料標準フォーム.xlsx")
        self.assert_downloaded(source, self.selected("計画全社DR\n  審議資料標準フォーム.xlsx"))

    def test_existing_wrap_choices(self):
        for separator in ["", " "]:
            with self.subTest(separator=separator):
                source = self.file("計画全社DR" + separator + "審議.xlsx")
                self.assert_downloaded(source, self.selected("計画全社DR\n  審議.xlsx"))
                source.unlink()

    def test_multiple_wraps_with_different_spaces(self):
        source = self.file("計画全社DR\u3000審議 資料.xlsx")
        self.assert_downloaded(source, self.selected("計画全社DR\n  審議\n  資料.xlsx"))

    def test_fullwidth_space_next_to_wrap(self):
        source = self.file("計画全社DR\u3000審議.xlsx")
        self.assert_downloaded(source, self.selected("計画全社DR\u3000\r\n\u3000審議.xlsx"))

    def test_spaces_away_from_wrap_are_preserved(self):
        source = self.file("計画\u3000全社DR\u3000審議.xlsx")
        self.file("計画全社DR\u3000審議.xlsx")
        self.assert_downloaded(source, self.selected("計画\u3000全社DR\n  審議.xlsx"))

    def test_multiple_existing_candidates_are_not_downloaded(self):
        for separator in ["", " ", "\u3000"]:
            self.file("計画全社DR" + separator + "審議.xlsx")
        result = self.download(self.selected("計画全社DR\n  審議.xlsx"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("3 個あり", self.dialogs.read_text())
        self.assertEqual(list(DOWNLOADS.glob(self.prefix + "*")), [])

    def test_missing_candidates_are_not_downloaded(self):
        result = self.download(self.selected("存在しない\n  資料.xlsx"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ありません", self.dialogs.read_text())
        self.assertEqual(list(DOWNLOADS.glob(self.prefix + "*")), [])


if __name__ == "__main__":
    unittest.main()
