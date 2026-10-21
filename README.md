# iterm2-ssh-transfer

[日本語版はこちら](README.ja.md)

Scripts that move files between your Mac and the SSH host of an iTerm2 tab with a single key. No `scp` commands to type.

| Script | Example key | What it does |
|---|---|---|
| `upload.sh` | ⌘⇧V | Sends the image on the clipboard, or the files and folders copied in Finder, to `~/tmp` on the SSH host, then types the remote path into the terminal |
| `download.sh` | ⌘⇧D | Downloads the file or folder whose path you selected on screen from the SSH host to `~/Downloads` on your Mac. If you selected a URL, opens it in your Mac's browser |

- The SSH host is whatever the `ssh` running in that tab is connected to. Tabs using tmux integration (`tmux -CC`) work too.
- If `~/tmp` does not exist on the SSH host, you are asked before it is created.
- Folders and anything over 10 MB are confirmed first with their size, then sent with a progress window you can stop.
- File names in the decomposed form macOS sometimes uses (NFD) are converted to the composed form (NFC) when sent.
- A selected path that wraps across lines on screen still works, as long as it matches exactly one file or folder on the host.
- Messages appear in Japanese if Japanese is first in your Mac's preferred languages, and in English otherwise.

## Requirements

- macOS and iTerm2
- SSH access that does not ask for a password (keys or ssh-agent). The scripts open their own connection with `BatchMode=yes`
- `sh`, `tar`, `base64`, `mktemp`, `du`, and `find` on the SSH host

## Setup

1. Clone the repository.

   ```sh
   git clone https://github.com/archelon-inc/iterm2-ssh-transfer.git ~/iterm2-ssh-transfer
   ```

2. In iTerm2, open Settings > Keys > Key Bindings, press "+", and assign a key to each script.

   - Keyboard Shortcut: any key (e.g. ⌘⇧V, ⌘⇧D)
   - Action: Run Coprocess
   - The field below it (Enter command to run): the full path of the script (e.g. `/Users/you/iterm2-ssh-transfer/upload.sh`), with no arguments

3. In iTerm2 Settings > Advanced, increase "Maximum number of bytes of selection to provide to Python API". With the default of 100, long paths reach `download.sh` cut off. When that happens, `download.sh` tells you in a dialog, and "Open Settings" shows this field (iTerm2 needs Accessibility permission for this).

## When something fails

`upload.sh` types the reason into the terminal as `# upload: …`, and `download.sh` shows it in a dialog. Details are in these logs:

- `/tmp/iterm2-upload.log`
- `/tmp/iterm2-download.log`

## Changing the messages

All on-screen messages, in both Japanese and English, are in `messages.sh`. After editing it, this test checks that both languages still match:

```sh
test/messages.test.sh
```

## License

[zlib](LICENSE)

If you distribute a modified version, mark it as modified, as clause 2 of the zlib license requires. We recommend adding your own Copyright line to LICENSE.
