#!/usr/bin/env python3
"""公開スクリプトから、選択したパスの照合と受信結果を確かめる。"""

import json
import os
from pathlib import Path
import shutil
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
        if len(args) > 3 and args[2] == "-e" and "DownloadProgress" in args[3]:
            raise SystemExit(1)  # 受信は継続し、試験中は進捗窓を開かない。
        os.execv("/usr/bin/osascript", ["/usr/bin/osascript", *args])
    script = sys.stdin.read()
    if "set targetID" in script:
        selection = os.environ["TRANSFER_TEST_SELECTION"]
        print("\x1f".join(["/dev/ttys999", os.environ["TRANSFER_TEST_REMOTE"], str(len(selection)), os.environ["TRANSFER_TEST_PANE"], selection, ""]))
    else:
        with open(os.environ["TRANSFER_TEST_DIALOGS"], "a") as log:
            log.write(json.dumps(args[1:], ensure_ascii=False) + "\n")
        if "落としますか" in args[1] and os.environ["TRANSFER_TEST_CANCEL_CONFIRM"] == "1":
            raise SystemExit(1)
        if "落としました" in args[1] and os.environ["TRANSFER_TEST_CLOSE_DONE"] == "1":
            print(args[-2])
            raise SystemExit(0)
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
    with open(os.environ["TRANSFER_TEST_OPENED"], "a") as log:
        log.write(json.dumps(args, ensure_ascii=False) + "\n")
elif name in ("board", "pbpaste"):
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
        self.opened = self.root / "opened.jsonl"
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
            "TRANSFER_TEST_OPENED": str(self.opened),
            "TRANSFER_TEST_PANE": "",
            "TRANSFER_TEST_MICRO": "",
            "TRANSFER_TEST_MICRO_ERROR": "0",
            "TRANSFER_TEST_CLIPBOARD": "",
            "TRANSFER_TEST_CANCEL_CONFIRM": "0",
            "TRANSFER_TEST_CLOSE_DONE": "0",
            "TRANSFER_TEST_SSH_COMMAND": "ssh fixture env -u TMUX tmux -CC -S /tmp/fixture.sock attach-session",
        }

    def remove_downloads(self):
        for path in DOWNLOADS.glob(self.prefix + "*"):
            if path.is_dir():
                shutil.rmtree(path)
            else:
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
        self.assertIn("決められません", self.dialogs.read_text())
        self.assertEqual(list(DOWNLOADS.glob(self.prefix + "*")), [])

    def test_missing_candidates_are_not_downloaded(self):
        result = self.download(self.selected("存在しない\n  資料.xlsx"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ありません", self.dialogs.read_text())
        self.assertEqual(list(DOWNLOADS.glob(self.prefix + "*")), [])

    def assert_batch_downloaded(self, sources, selection):
        result = self.download(selection)
        self.assertEqual(result.returncode, 0, self.dialogs.read_text() if self.dialogs.exists() else result.stderr)
        for source in sources:
            self.assertEqual((DOWNLOADS / source.name).read_bytes(), source.read_bytes())
        dialogs = [json.loads(line) for line in self.dialogs.read_text().splitlines()]
        self.assertIn(str(len(sources)) + " 件", dialogs[-1][0])

    def test_three_absolute_paths(self):
        sources = [self.file(name) for name in ["排水.pdf", "クレーン GDI.pdf", "煙突（承認済）.pdf"]]
        self.assert_batch_downloaded(sources, "\r\n".join(map(str, sources)))

    def test_paths_and_wraps_with_different_spaces(self):
        sources = [self.file(name) for name in ["排水\u3000処理設備.pdf", "ごみクレーン GDI.pdf", "煙突GDI.pdf"]]
        selected = [self.selected(name) for name in ["排水\n  処理設備.pdf", "ごみクレーン\n GDI.pdf", "煙突\nGDI.pdf"]]
        self.assert_batch_downloaded(sources, "\n".join(selected))

    def test_absolute_wrapped_paths_without_cwd(self):
        sources = [self.file("排水\u3000処理設備.pdf"), self.file("煙突.pdf")]
        self.environment["TRANSFER_TEST_REMOTE"] = ""
        self.assert_batch_downloaded(sources, self.selected("排水\n処理設備.pdf") + "\n" + str(sources[1]))

    def test_many_directory_wraps(self):
        parent = self.remote.joinpath(*(["directory"] * 9))
        parent.mkdir(parents=True)
        source = parent / (self.prefix + "排水.pdf")
        source.write_bytes(b"deep path")
        self.assert_downloaded(source, str(source).replace("/directory", "/direc\ntory"))

    def test_relative_paths(self):
        sources = [self.file("排水.pdf"), self.file("クレーン.pdf")]
        self.assert_batch_downloaded(sources, "\n".join(source.name for source in sources))

    def test_quoted_paths_and_blank_lines(self):
        sources = [self.file("排水（承認済）.pdf"), self.file("クレーン.pdf")]
        self.assert_batch_downloaded(sources, "\n\n".join('"' + str(source) + '"' for source in sources) + "\n")

    def test_multiple_interpretations_of_boundaries_are_not_downloaded(self):
        sources = [self.file("排水.pdf"), self.file("煙突.pdf")]
        joined = self.remote / "".join(source.name for source in sources)
        joined.write_bytes(b"one combined path")
        result = self.download("\n".join(source.name for source in sources))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("決められません", self.dialogs.read_text())
        self.assertEqual(list(DOWNLOADS.glob(self.prefix + "*")), [])

    def test_missing_path_stops_entire_batch(self):
        source = self.file("排水.pdf")
        result = self.download(str(source) + "\n" + self.selected("存在しない.pdf"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ありません", self.dialogs.read_text())
        self.assertEqual(list(DOWNLOADS.glob(self.prefix + "*")), [])

    def test_only_complete_interpretation_is_used(self):
        unused = self.file("排水")
        sources = [self.file("排水処理設備.pdf"), self.file("煙突.pdf")]
        self.assert_batch_downloaded(sources, str(unused) + "\n処理設備.pdf\n" + str(sources[1]))
        self.assertFalse((DOWNLOADS / unused.name).exists())

    def test_same_basename_preserves_existing_file(self):
        sources = []
        for directory in ["first", "second"]:
            parent = self.remote / directory
            parent.mkdir()
            source = parent / (self.prefix + "同名.pdf")
            source.write_text(directory)
            sources.append(source)
        target = DOWNLOADS / sources[0].name
        target.write_bytes(b"existing")
        result = self.download("\n".join(map(str, sources)))
        self.assertEqual(result.returncode, 0)
        self.assertEqual(target.read_bytes(), b"existing")
        for i, source in enumerate(sources, 1):
            self.assertEqual(target.with_stem(target.stem + " (" + str(i) + ")").read_bytes(), source.read_bytes())

    def test_clipboard_batch(self):
        sources = [self.file("排水.pdf"), self.file("煙突.pdf")]
        self.environment["TRANSFER_TEST_CLIPBOARD"] = "\n".join(map(str, sources))
        self.assert_batch_downloaded(sources, "")

    def test_many_paths(self):
        sources = [self.file(str(i) + ".pdf") for i in range(20)]
        self.assert_batch_downloaded(sources, "\n".join(map(str, sources)))

    def test_shell_characters_are_literal(self):
        sources = [self.file("資料`x`'name$(false); &.pdf"), self.file("煙突.pdf")]
        self.assert_batch_downloaded(sources, "\n".join(map(str, sources)))

    def test_repeated_path_is_saved_once(self):
        source = self.file("排水.pdf")
        self.assert_downloaded(source, str(source) + "\n" + str(source))
        self.assertEqual(len(list(DOWNLOADS.glob(self.prefix + "*"))), 1)

    def test_file_and_directory(self):
        source = self.file("排水.pdf")
        folder = self.remote / (self.prefix + "図面")
        folder.mkdir()
        (folder / "図面.txt").write_text("図面の内容")
        result = self.download(str(source) + "\n" + str(folder))
        self.assertEqual(result.returncode, 0, self.dialogs.read_text())
        self.assertEqual((DOWNLOADS / source.name).read_bytes(), source.read_bytes())
        self.assertEqual((DOWNLOADS / folder.name / "図面.txt").read_text(), "図面の内容")

    def test_large_files_are_confirmed_as_a_batch(self):
        sources = [self.file("排水.pdf"), self.file("煙突.pdf")]
        for source in sources:
            source.write_bytes(b"x" * (11 * 1024 * 1024))
        self.assert_batch_downloaded(sources, "\n".join(map(str, sources)))
        dialogs = [json.loads(line) for line in self.dialogs.read_text().splitlines()]
        confirms = [dialog[0] for dialog in dialogs if "落としますか" in dialog[0]]
        self.assertEqual(len(confirms), 1)
        self.assertIn("2 件", confirms[0])

    def test_cancelled_batch_saves_nothing(self):
        source = self.file("排水.pdf")
        folder = self.remote / (self.prefix + "図面")
        folder.mkdir()
        self.environment["TRANSFER_TEST_CANCEL_CONFIRM"] = "1"
        result = self.download(str(source) + "\n" + str(folder))
        self.assertEqual(result.returncode, 0)
        self.assertEqual(list(DOWNLOADS.glob(self.prefix + "*")), [])

    def test_closing_completion_dialog_is_success(self):
        sources = [self.file("排水.pdf"), self.file("煙突.pdf")]
        self.environment["TRANSFER_TEST_CLOSE_DONE"] = "1"
        self.assert_batch_downloaded(sources, "\n".join(map(str, sources)))
        self.assertFalse(self.opened.exists())

    def test_excessive_wraps_do_not_guess_a_path(self):
        source = self.file("\u3000".join(["資料"] * 10) + ".pdf")
        result = self.download(self.selected("\n".join(["資料"] * 10) + ".pdf"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("候補が多すぎます", self.dialogs.read_text())
        self.assertFalse((DOWNLOADS / source.name).exists())

    def test_iterm_selection_precedes_micro_and_clipboard(self):
        source = self.file("iTerm2.xlsx")
        self.environment.update(TRANSFER_TEST_PANE="2", TRANSFER_TEST_MICRO=str(self.file("micro.xlsx")),
                                TRANSFER_TEST_CLIPBOARD=str(self.file("clipboard.xlsx")))
        self.assert_downloaded(source, str(source))
        self.assertEqual(len(list(DOWNLOADS.glob(self.prefix + "*"))), 1)

    def test_micro_selection_precedes_clipboard(self):
        source = self.file("micro.xlsx")
        self.environment.update(TRANSFER_TEST_PANE="2", TRANSFER_TEST_MICRO=str(source),
                                TRANSFER_TEST_CLIPBOARD=str(self.file("clipboard.xlsx")))
        self.assert_downloaded(source, "")
        self.assertEqual(len(list(DOWNLOADS.glob(self.prefix + "*"))), 1)

    def test_empty_micro_selection_uses_clipboard(self):
        source = self.file("clipboard.xlsx")
        self.environment.update(TRANSFER_TEST_PANE="2", TRANSFER_TEST_CLIPBOARD=str(source))
        self.assert_downloaded(source, "")

    def test_no_tmux_pane_uses_clipboard(self):
        source = self.file("clipboard.xlsx")
        self.environment["TRANSFER_TEST_CLIPBOARD"] = str(source)
        self.assert_downloaded(source, "")

    def test_missing_iterm_path_does_not_use_other_sources(self):
        self.environment.update(TRANSFER_TEST_PANE="2", TRANSFER_TEST_MICRO=str(self.file("micro.xlsx")),
                                TRANSFER_TEST_CLIPBOARD=str(self.file("clipboard.xlsx")))
        result = self.download(self.selected("存在しない.xlsx"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(DOWNLOADS.glob(self.prefix + "*")), [])

    def test_missing_micro_path_does_not_use_clipboard(self):
        self.environment.update(TRANSFER_TEST_PANE="2", TRANSFER_TEST_MICRO=self.selected("存在しない.xlsx"),
                                TRANSFER_TEST_CLIPBOARD=str(self.file("clipboard.xlsx")))
        result = self.download("")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(DOWNLOADS.glob(self.prefix + "*")), [])

    def test_micro_error_does_not_use_clipboard(self):
        self.environment.update(TRANSFER_TEST_PANE="2", TRANSFER_TEST_MICRO_ERROR="1",
                                TRANSFER_TEST_CLIPBOARD=str(self.file("clipboard.xlsx")))
        result = self.download("")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(DOWNLOADS.glob(self.prefix + "*")), [])

    def test_empty_sources_do_not_download(self):
        self.environment["TRANSFER_TEST_PANE"] = "2"
        result = self.download("")
        self.assertNotEqual(result.returncode, 0)
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

    def test_local_micro_selection_opens_its_url(self):
        url = "https://example.test/micro"
        self.environment.update(
            TRANSFER_TEST_PANE="2", TRANSFER_TEST_MICRO=url,
            TRANSFER_TEST_CLIPBOARD="https://example.test/clipboard",
            TRANSFER_TEST_SSH_COMMAND="tmux -CC -S /tmp/fixture.sock attach-session",
        )
        result = self.download("")
        self.assertEqual(result.returncode, 0)
        self.assertEqual([json.loads(line) for line in self.opened.read_text().splitlines()], [[url]])


if __name__ == "__main__":
    unittest.main()
