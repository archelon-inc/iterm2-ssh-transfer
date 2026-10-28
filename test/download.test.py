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
        print("\x1f".join(["/dev/ttys999", os.environ["TRANSFER_TEST_REMOTE"], str(len(selection)), os.environ["TRANSFER_TEST_PANE"], selection, ""]))
    else:
        with open(os.environ["TRANSFER_TEST_DIALOGS"], "a") as log:
            log.write(json.dumps(args[1:], ensure_ascii=False) + "\n")
        print(args[-1])
elif name == "defaults":
    print('(ja)')
elif name == "ps":
    print(os.environ["TRANSFER_TEST_SSH_COMMAND"])
elif name == "ssh":
    if args[-2:] != ["fixture", "sh -s"]:
        raise SystemExit("試験で許していない接続先です")
    raise SystemExit(subprocess.call(["/bin/sh", "-s"]))
elif name == "open":
    pass
elif name in ("board", "pbpaste"):
    with open(os.environ["TRANSFER_TEST_EVENTS"], "a") as log:
        log.write(name + "\n")
    if name == "board":
        if args != ["selection", "--socket", "/tmp/fixture.sock", "--pane", "%2"]:
            raise SystemExit("試験で許していない板の取得先です")
        if os.environ["TRANSFER_TEST_MICRO_ERROR"] == "1":
            raise SystemExit(1)
        print(json.dumps({"selection": os.environ["TRANSFER_TEST_MICRO"], "cwd": os.environ["TRANSFER_TEST_REMOTE"]}, ensure_ascii=False))
    else:
        sys.stdout.write(os.environ["TRANSFER_TEST_CLIPBOARD"])
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
        self.events = self.root / "events.log"
        binaries = self.root / "bin"
        binaries.mkdir()
        mock = binaries / "mock-command.py"
        mock.write_text(MOCK)
        mock.chmod(0o755)
        for name in ["osascript", "defaults", "ps", "ssh", "open", "board", "pbpaste"]:
            (binaries / name).symlink_to(mock)
        self.environment = {
            **os.environ,
            "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
            "ITERM_SESSION_ID": "fixture",
            "TRANSFER_TEST_REMOTE": str(self.remote),
            "TRANSFER_TEST_DIALOGS": str(self.dialogs),
            "TRANSFER_TEST_EVENTS": str(self.events),
            "TRANSFER_TEST_PANE": "",
            "TRANSFER_TEST_MICRO": "",
            "TRANSFER_TEST_MICRO_ERROR": "0",
            "TRANSFER_TEST_CLIPBOARD": "",
            "TRANSFER_TEST_SSH_COMMAND": "ssh fixture env -u TMUX tmux -CC -S /tmp/fixture.sock attach-session",
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

    def test_iterm_selection_precedes_micro_and_clipboard(self):
        source = self.file("iTerm2.xlsx")
        self.environment.update(TRANSFER_TEST_PANE="2", TRANSFER_TEST_MICRO=str(self.file("micro.xlsx")),
                                TRANSFER_TEST_CLIPBOARD=str(self.file("clipboard.xlsx")))
        self.assert_downloaded(source, str(source))
        self.assertFalse(self.events.exists())

    def test_micro_selection_precedes_clipboard(self):
        source = self.file("micro.xlsx")
        self.environment.update(TRANSFER_TEST_PANE="2", TRANSFER_TEST_MICRO=str(source),
                                TRANSFER_TEST_CLIPBOARD=str(self.file("clipboard.xlsx")))
        self.assert_downloaded(source, "")
        self.assertEqual(self.events.read_text().splitlines(), ["board"])

    def test_empty_micro_selection_uses_clipboard(self):
        source = self.file("clipboard.xlsx")
        self.environment.update(TRANSFER_TEST_PANE="2", TRANSFER_TEST_CLIPBOARD=str(source))
        self.assert_downloaded(source, "")
        self.assertEqual(self.events.read_text().splitlines(), ["board", "pbpaste"])

    def test_no_tmux_pane_uses_clipboard(self):
        source = self.file("clipboard.xlsx")
        self.environment["TRANSFER_TEST_CLIPBOARD"] = str(source)
        self.assert_downloaded(source, "")
        self.assertEqual(self.events.read_text().splitlines(), ["pbpaste"])

    def test_missing_iterm_path_does_not_use_other_sources(self):
        self.environment.update(TRANSFER_TEST_PANE="2", TRANSFER_TEST_MICRO=str(self.file("micro.xlsx")),
                                TRANSFER_TEST_CLIPBOARD=str(self.file("clipboard.xlsx")))
        result = self.download(self.selected("存在しない.xlsx"))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.events.exists())
        self.assertEqual(list(DOWNLOADS.glob(self.prefix + "*")), [])

    def test_missing_micro_path_does_not_use_clipboard(self):
        self.environment.update(TRANSFER_TEST_PANE="2", TRANSFER_TEST_MICRO=self.selected("存在しない.xlsx"),
                                TRANSFER_TEST_CLIPBOARD=str(self.file("clipboard.xlsx")))
        result = self.download("")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events.read_text().splitlines(), ["board"])
        self.assertEqual(list(DOWNLOADS.glob(self.prefix + "*")), [])

    def test_micro_error_does_not_use_clipboard(self):
        self.environment.update(TRANSFER_TEST_PANE="2", TRANSFER_TEST_MICRO_ERROR="1",
                                TRANSFER_TEST_CLIPBOARD=str(self.file("clipboard.xlsx")))
        result = self.download("")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events.read_text().splitlines(), ["board"])
        self.assertEqual(list(DOWNLOADS.glob(self.prefix + "*")), [])

    def test_empty_sources_do_not_download(self):
        self.environment["TRANSFER_TEST_PANE"] = "2"
        result = self.download("")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events.read_text().splitlines(), ["board", "pbpaste"])
        self.assertIn("文字が選ばれていません", self.dialogs.read_text())
        self.assertEqual(list(DOWNLOADS.glob(self.prefix + "*")), [])

    def test_quoted_tmux_command_reads_same_micro_selection(self):
        source = self.file("micro.xlsx")
        self.environment.update(
            TRANSFER_TEST_PANE="2", TRANSFER_TEST_MICRO=str(source),
            TRANSFER_TEST_SSH_COMMAND='ssh -tt -o ClearAllForwardings=yes -- fixture \'env -u TMUX /usr/bin/tmux -CC -S "/tmp/fixture.sock" attach-session\'',
        )
        self.assert_downloaded(source, "")

    def test_clipboard_length_limit_does_not_download(self):
        self.environment["TRANSFER_TEST_CLIPBOARD"] = "a" * 4097
        result = self.download("")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("4097", self.dialogs.read_text())
        self.assertEqual(list(DOWNLOADS.glob(self.prefix + "*")), [])

    def test_missing_clipboard_text_is_not_written_to_debug_log(self):
        text = self.prefix + "clipboard-text"
        self.environment["TRANSFER_TEST_CLIPBOARD"] = text
        log = Path("/tmp/iterm2-download.log")
        offset = log.stat().st_size if log.exists() else 0
        result = self.download("")
        self.assertNotEqual(result.returncode, 0)
        with log.open("rb") as handle:
            handle.seek(offset)
            self.assertNotIn(text.encode(), handle.read())


if __name__ == "__main__":
    unittest.main()
