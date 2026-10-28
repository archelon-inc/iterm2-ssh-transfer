# iterm2-ssh-transfer

[English](README.md)

iTerm2 で SSH 先に入っているタブから、キー 1 つで Mac とのあいだのファイルをやり取りするスクリプトです。scp のコマンドを打つ必要はありません。

| スクリプト | キーの例 | すること |
|---|---|---|
| `upload.sh` | ⌘⇧V | クリップボードの画像、または Finder でコピーしたファイルやフォルダを、SSH 先の `~/tmp` に送る。送った先のパスがターミナルに入力される |
| `download.sh` | ⌘⇧D | 画面で選んだパスのファイルやフォルダを、SSH 先から Mac の `~/Downloads` に落とす。選んだのが URL なら Mac のブラウザで開く |

- 送り先・落とし元は、そのタブで今動いている `ssh` の接続先です。tmux 統合 (`tmux -CC`) のタブでも使えます。
- ダウンロードは iTerm2 の選択、同じ pane の板（micro）の選択、Mac のクリップボードの順で、最初に空でない文字列を使います。そのパスが見つからない場合は、次の選択元へ進まずエラーにします。板の選択には、その板が動く host の `board selection --socket SOCKET --pane PANE` が必要です。
- SSH 先に `~/tmp` が無ければ、作ってよいかを聞いてから作ります。
- フォルダや 10 MB を超えるものは、大きさを見せて確認してから、中断できる進み具合の窓を出しながら送ります。
- Mac のファイル名の濁点・半濁点 (NFD) は、送るときに NFC に直します。
- 選んだパスが画面の折り返しをまたいでいても、つなぎ目を空文字・半角スペース・全角スペースで照合し、SSH 先に実在するものが 1 つに決まれば落とします。
- 複数のパスもまとめて選択できます。改行が折り返しかパスの区切りかを実在パスで照合し、選択全体の解釈が 1 つに決まれば一括保存します。見つからないパスや複数の解釈がある場合は、保存を始めずに知らせます。候補が多すぎるときは選択範囲を分けてください。
- 同名ファイルは連番を付け、同じパスの重複は一度だけ保存します。
- 画面の文は、Mac の言語の先頭が日本語なら日本語、それ以外なら英語で出ます。

## 必要なもの

- macOS と iTerm2
- パスワードを聞かれずに入れる SSH の接続 (鍵や ssh-agent)。スクリプトは `BatchMode=yes` で別の接続を張ります
- SSH 先に `sh`・`tar`・`base64`・`mktemp`・`du`・`find`

## 入れ方

1. clone します。

   ```sh
   git clone https://github.com/archelon-inc/iterm2-ssh-transfer.git ~/iterm2-ssh-transfer
   ```

2. iTerm2 の Settings > Keys > Key Bindings で「+」を押し、スクリプトごとにキーを割り当てます。

   - Keyboard Shortcut: 好きなキー (例: ⌘⇧V、⌘⇧D)
   - Action: Run Coprocess
   - その下の欄 (Enter command to run): スクリプトのフルパス (例: `/Users/you/iterm2-ssh-transfer/upload.sh`)。引数は付けません

3. iTerm2 の Settings > Advanced の「Maximum number of bytes of selection to provide to Python API」(日本語表示では「Python API に渡す選択範囲の最大バイト数」) を大きくします。初期値の 100 のままだと、長いパスが途中で切れて `download.sh` に届きます。切れていたときは `download.sh` がダイアログで知らせ、「設定を開く」でこの欄を出します (iTerm2 にアクセシビリティの許可が要ります)。

## 失敗したとき

`upload.sh` は理由をターミナルに `# upload: …` と入力し、`download.sh` はダイアログで知らせます。詳しいことは次のログにあります。

- `/tmp/iterm2-upload.log`
- `/tmp/iterm2-download.log`

## 画面の文を直すとき

画面に出る文は、日本語と英語の両方を `messages.sh` にまとめてあります。直したら、次のテストで日英がそろっているかを確かめられます。

```sh
test/messages.test.sh
```

## ライセンス

[zlib](LICENSE)

直した版を配るときは、zlib ライセンスの 2 条のとおり、直したことが分かるようにしてください。LICENSE に、あなたの Copyright の行を足す形をおすすめします。
