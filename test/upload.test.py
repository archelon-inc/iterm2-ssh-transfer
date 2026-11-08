#!/usr/bin/env python3
"""公開upload.shから、Macの会話を転送せずCtrl+Vで扱うことを確かめる。"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/env python3
import os
from pathlib import Path
import sys

name = Path(sys.argv[0]).name
if name == 'defaults':
    print('(ja)')
elif name == 'ps':
    print(os.environ['UPLOAD_TEST_SSH'])
elif name == 'osascript':
    script = sys.stdin.read()
    if 'set targetID' in script:
        print('/dev/ttys999')
    else:
        Path(os.environ['UPLOAD_TEST_CLIPBOARD_READ']).touch()
        raise SystemExit(1)
elif name == 'ssh':
    Path(os.environ['UPLOAD_TEST_TRANSFER']).touch()
    raise SystemExit('試験中にネットワークへ転送しません')
else:
    raise SystemExit('試験で許可していないコマンドです')
'''


class UploadTest(unittest.TestCase):
    def upload(self, command):
        with tempfile.TemporaryDirectory(prefix='iterm2-upload-test-') as directory:
            root = Path(directory)
            mock = root / 'mock.py'
            mock.write_text(MOCK)
            mock.chmod(0o755)
            for name in ['defaults', 'ps', 'osascript', 'ssh']:
                (root / name).symlink_to(mock)
            clipboard = root / 'clipboard-read'
            transfer = root / 'transfer'
            result = subprocess.run(
                ['/bin/bash', str(ROOT / 'upload.sh')],
                env={**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH'],
                     'ITERM_SESSION_ID': 'test-local-upload', 'UPLOAD_TEST_SSH': command,
                     'UPLOAD_TEST_CLIPBOARD_READ': str(clipboard), 'UPLOAD_TEST_TRANSFER': str(transfer)},
                capture_output=True, timeout=10,
            )
            return result, clipboard.exists(), transfer.exists()

    def test_mac_tabs_emit_ctrl_v_without_reading_or_sending_clipboard(self):
        for command in [
            '',
            'ssh -o BatchMode=yes arcom-seat-office-work -- --client=10 observe mac:office-work',
            '/usr/bin/ssh -o ControlMaster=no arcom-seat-arcom -- --client=999 observe mac:arcom',
        ]:
            with self.subTest(command=command):
                result, clipboard_read, transferred = self.upload(command)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b'\x16')
                self.assertFalse(clipboard_read)
                self.assertFalse(transferred)

    def test_remote_tabs_keep_the_upload_path(self):
        for command in [
            'ssh -tt rocket env -u TMUX tmux -CC attach-session',
            'ssh arcom-seat-office-work -- --client=10 observe rocket:secretary',
            'ssh mac:ordinary-host',
            'ssh example echo observe mac:office-work',
        ]:
            with self.subTest(command=command):
                result, clipboard_read, transferred = self.upload(command)
                self.assertNotEqual(result.stdout, b'\x16')
                self.assertTrue(clipboard_read)
                self.assertFalse(transferred)


if __name__ == '__main__':
    unittest.main()
