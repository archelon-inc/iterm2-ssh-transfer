#!/bin/bash
# iTerm2 で選んでいる文字を見て、
#   - URL なら Mac のブラウザで開く
#   - ファイルやフォルダのパスなら「今そのタブで SSH 接続中のホスト」から ~/Downloads に落とす
#     (フォルダと大きいファイルは、大きさを見せて確認してから、進み具合の窓を出しながら落とす)
# 画面の折り返しで改行や字下げが混ざっていても、つなぎ目だけを「何も無い / スペース1つ」とみなして
# 候補を作り、リモートに実在するファイルやフォルダがちょうど1つに決まったときだけ落とす。
# 相対パスは、iTerm2 が覚えているそのセッションの今いるディレクトリ (path 変数) から解決する。
#
# キーバインド: このファイル (Action: Run Coprocess、引数なし)
# 結果は iTerm2 の前に出るダイアログで知らせる。Coprocess の stdout はターミナルへの入力になるため、何も出さない。
# デバッグログ: /tmp/iterm2-download.log

LOG=/tmp/iterm2-download.log
# これより大きいファイルは、落とす前に確認する
CONFIRM_BYTES=$((10 * 1024 * 1024))
# これより長く選んだ文字は、パスとみなさない
SELECTION_LIMIT=4096
# 出力はすべてログへ。ただし元の stdout は fd 3 に残して開いたままにする。
# Coprocess の stdout が閉じると、iTerm2 は Coprocess が終わったとみなして止めてしまうため
exec 3>&1 >>"$LOG" 2>&1
echo "=== $(date '+%F %T') pid=$$ ==="
# 画面に出す文 (日本語と英語)。リンクから呼ばれても見つかるよう、実体の場所から読む
. "$(dirname "$(perl -MCwd=abs_path -e 'print abs_path(shift)' "$0")")/messages.sh"
msg_init "$(defaults read -g AppleLanguages 2>/dev/null)"

# 失敗を知らせるダイアログ
alert() {
  osascript - "$1" "$(msg btn_close)" <<'APPLESCRIPT' >/dev/null
on run argv
  tell application "System Events"
    activate
    display dialog (item 1 of argv) buttons {item 2 of argv} default button (item 2 of argv) with icon caution with title "iTerm2 download"
  end tell
end run
APPLESCRIPT
}

# 落とし終えたことを知らせ、「Finder で開く」なら Finder でそのファイルを選んだ状態で開く
done_dialog() {
  local show
  show=$(msg btn_show_in_finder)
  answer=$(osascript - "$1" "$(msg btn_close)" "$show" <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    activate
    display dialog (item 1 of argv) buttons {item 2 of argv, item 3 of argv} default button (item 3 of argv) with title "iTerm2 download"
  end tell
  return button returned of result
end run
APPLESCRIPT
  )
  [ "$answer" = "$show" ] && open -R "$2"
}

# 選んだ文字が上限で切れていたことを知らせ、「設定を開く」なら iTerm2 の設定の上限の行を出す。
# 設定画面で変えた値は、動いている iTerm2 にすぐ効く (defaults write は起動し直すまで効かない)
selection_limit_dialog() {
  echo "fail: selection truncated at $1"
  local open_settings
  open_settings=$(msg btn_open_settings)
  answer=$(osascript - "$(msg down_truncated "$1")" "$(msg btn_close)" "$open_settings" <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    activate
    display dialog (item 1 of argv) buttons {item 2 of argv, item 3 of argv} default button (item 3 of argv) with icon caution with title "iTerm2 download"
  end tell
  return button returned of result
end run
APPLESCRIPT
  )
  [ "$answer" = "$open_settings" ] || exit 1
  # 設定画面のタブや部品の名前は表示言語で変わるので、位置で選ぶ。「詳細」はツールバーの最後のボタン
  osascript <<'APPLESCRIPT' >/dev/null
tell application "iTerm2" to activate
tell application "System Events" to tell process "iTerm2"
  keystroke "," using command down
  repeat 20 times
    if exists toolbar 1 of front window then exit repeat
    delay 0.1
  end repeat
  click last button of toolbar 1 of front window
  delay 0.3
  set value of text field 1 of group 1 of front window to "Python API"
end tell
APPLESCRIPT
  exit 1
}

fail() {
  echo "fail: $1"
  alert "$1"
  exit 1
}

# 前面に出る OK / キャンセルのダイアログ。キャンセルなら非 0 で返る
confirm() {
  osascript - "$1" "$(msg btn_cancel)" "$(msg btn_download)" <<'APPLESCRIPT' >/dev/null
on run argv
  tell application "System Events"
    activate
    display dialog (item 1 of argv) buttons {item 2 of argv, item 3 of argv} default button (item 3 of argv) cancel button (item 2 of argv) with title "iTerm2 download"
  end tell
end run
APPLESCRIPT
}

human_size() {
  awk -v b="$1" 'BEGIN {
    split("B KB MB GB TB", u, " "); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i]
  }'
}

shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

[ -n "${ITERM_SESSION_ID:-}" ] || fail "$(msg no_session_id)"

# 起動元セッションの tty・今いるディレクトリ・選んでいる文字を 1 回で取る。
# 選んでいる文字は改行を含みうるので、区切りには US (0x1f) を使う。
# tmux 統合のセッションは tty を持たないので、代わりに foreground job の PID を返す。
US=$'\x1f'
session=$(osascript - "${ITERM_SESSION_ID##*:}" <<'APPLESCRIPT'
on run argv
  set targetID to item 1 of argv
  set US to character id 31
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if (unique ID of s as text) is targetID then
            tell s
              set sel to variable named "selection"
              set selLen to variable named "selectionLength"
              set cwd to variable named "path"
              set jobPID to variable named "jobPid"
            end tell
            set sessionTTY to tty of s
            if sel is missing value then set sel to ""
            if selLen is missing value then set selLen to 0
            if cwd is missing value then set cwd to ""
            if sessionTTY is missing value then
              if jobPID is missing value then
                set sessionTTY to ""
              else
                set sessionTTY to "pid:" & (jobPID as text)
              end if
            end if
            return (sessionTTY as text) & US & (cwd as text) & US & (selLen as text) & US & (sel as text) & US
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return ""
end run
APPLESCRIPT
)
session_tty=${session%%"$US"*}
rest=${session#*"$US"}
cwd=${rest%%"$US"*}
rest=${rest#*"$US"}
selection_length=${rest%%"$US"*}
# 末尾の US は、選んだ文字の最後の改行が $( ) で消されないための止め
selection=${rest#*"$US"}
selection=${selection%"$US"}
echo "session: tty=[$session_tty] cwd=[$cwd] selectionLength=[$selection_length] selection=[$selection]"

[ -n "$session" ] || fail "$(msg no_session)"
[ -n "$selection" ] || fail "$(msg down_no_selection)"

# 選んだ文字から、URL か、リモートで実行する探索スクリプトを作る (1 行目が種類)
# macOS の /bin/bash (3.2) は $( ) の中のヒアドキュメントにある引用符を読み違えるので、
# JXA のソースは先に変数へ読み込んでから渡す
IFS= read -r -d '' plan_js <<'JXA'
ObjC.import("Foundation");
function env(k) {
  var v = $.NSProcessInfo.processInfo.environment.objectForKey(k);
  return v.isNil() ? "" : v.js;
}
var sel = env("SEL"), cwd = env("CWD"), selLen = Number(env("SELLEN")), selMax = Number(env("SELMAX"));

// 折り返しのつなぎ目: 改行と、その前後の空白・枠線の文字
var edge = "[ \\t\\u2502\\u2503\\u2551]*";
var junction = new RegExp(edge + "\\r?\\n" + edge, "g");

// 前後の空白・枠線・引用符・括弧と、文末の句読点を外す
function trimEnds(s) {
  var prev;
  do {
    prev = s;
    s = s.replace(/^[\s│┃║`'"「『<\[]+/, "").replace(/[\s│┃║`'"」』>\],;:!?。、，．]+$/, "");
    if (/\)$/.test(s) && s.split("(").length < s.split(")").length) s = s.slice(0, -1);
    if (/\.$/.test(s)) s = s.slice(0, -1);
  } while (s !== prev);
  return s;
}

var text = trimEnds(sel);
var result;
// iTerm2 は選んだ文字を上限の数までしか渡さない
if (selLen > selMax) {
  result = "too_long\n" + selLen;
} else if (selLen > sel.length) {
  result = "truncated\n" + sel.length;
} else if (/^https?:\/\//.test(text)) {
  // URL は空白を含まないので、つなぎ目も残りの空白も全部消す
  result = "url\n" + text.replace(junction, "").replace(/\s+/g, "");
} else {
  var parts = text.split(junction);
  var k = parts.length - 1;

  // 各つなぎ目を「何も無い」か「スペース1つ」にした組み合わせ。つなぎ目が多すぎるときは「何も無い」だけ
  var masks = [];
  for (var m = 0; m < (k <= 8 ? 1 << k : 1); m++) masks.push(m);
  var bits = function (m) { var c = 0; for (; m; m >>= 1) c += m & 1; return c; };
  masks.sort(function (a, b) { return bits(a) - bits(b); });
  var bases = masks.map(function (m) {
    var s = parts[0];
    for (var i = 1; i <= k; i++) s += ((m >> (i - 1)) & 1 ? " " : "") + parts[i];
    return s;
  });
  bases = bases.filter(function (b, i) { return b && bases.indexOf(b) === i; });

  var shq = function (s) { return "'" + s.replace(/'/g, "'\\''") + "'"; };
  // パスの先頭をリモートのシェルの語にする。~ は $HOME に、相対パスは今いるディレクトリから
  var head = function (p) {
    if (p === "~") return '"$HOME"';
    if (p.indexOf("~/") === 0) return '"$HOME"' + shq(p.slice(1));
    if (p.charAt(0) === "/") return shq(p);
    if (!cwd) return null;
    return shq(cwd.replace(/\/$/, "") + "/" + p);
  };

  var exact = bases.map(head);
  if (exact.indexOf(null) >= 0) {
    result = "no_cwd\n";
  } else {
    result = "remote\n" + bases[0] + "\n" + [
      "n=0; hit=",
      "for c in " + exact.join(" ") + "; do",
      '  [ -f "$c" ] || [ -d "$c" ] || continue; n=$((n+1)); hit=$c; printf \'@@CAND %s\\n\' "$c"',
      "done"
    ].join("\n");
  }
}
result;
JXA
plan=$(SEL="$selection" SELLEN="$selection_length" SELMAX="$SELECTION_LIMIT" CWD="$cwd" osascript -l JavaScript -e "$plan_js")
kind=${plan%%$'\n'*}
body=${plan#*$'\n'}
if [ "$kind" = remote ]; then
  # remote の 2 行目は、見つからないときに見せる名前
  wanted=${body%%$'\n'*}
  body=${body#*$'\n'}
fi
echo "plan: kind=[$kind]"
echo "$body"

case "$kind" in
  url)
    open "$body" || fail "$(msg down_url_failed "$body")"
    exit 0
    ;;
  remote) ;;
  too_long) fail "$(msg down_too_long "$body" "$SELECTION_LIMIT")" ;;
  truncated) selection_limit_dialog "$body" ;;
  no_cwd) fail "$(msg down_no_cwd)" ;;
  *) fail "$(msg down_unreadable "$LOG")" ;;
esac

# ps の ssh コマンド行から接続先 (エイリアス or user@host) を取り出す
parse_ssh_dest() {
  set -- $1
  shift  # "ssh" を捨てる
  while [ $# -gt 0 ]; do
    case "$1" in
      -o|-p|-i|-l|-L|-R|-D|-J|-F|-c|-m|-e|-b|-E|-S|-W|-w|-B|-I|-P) shift 2 ;;
      -*) shift ;;
      *) echo "$1"; return 0 ;;
    esac
  done
  return 1
}

case "$session_tty" in
  pid:*)
    session_tty=$(ps -p "${session_tty#pid:}" -o tty= | xargs)
    case "$session_tty" in tty*) session_tty="/dev/$session_tty" ;; *) session_tty="" ;; esac
    ;;
esac
[ -n "$session_tty" ] || fail "$(msg no_tty)"

cmd=$(ps -t "${session_tty#/dev/}" -o command= | grep -E '^([^ ]*/)?ssh( |$)' | grep -v -- ' -W ' | head -1)
echo "tty lookup: tty=[$session_tty] ssh=[$cmd]"
[ -n "$cmd" ] || fail "$(msg local_session)"
SERVER=$(parse_ssh_dest "$cmd")
[ -n "$SERVER" ] || fail "$(msg no_ssh_dest)"

# 探索を ssh 1 接続で行う。当たりがちょうど 1 つで、確認の要らない大きさのファイルなら、同じ接続で中身も受け取る。
# リモートの rc が出すゴミと混ざらないよう、結果は @@ で始まる行で、中身は @@BEGIN〜@@END の間に base64 で受け取る
response=$(mktemp "${TMPDIR:-/tmp}/iterm2-download.XXXXXX")
trap 'rm -f "$response"' EXIT
{
  printf '%s\n' "$body"
  cat <<REMOTE
[ "\$n" -eq 1 ] || exit 0
if [ -d "\$hit" ]; then
  printf '@@DIR %s %s\n' "\$(du -sk "\$hit" | cut -f1)" "\$(find "\$hit" -type f | wc -l | tr -d ' ')"
  exit 0
fi
bytes=\$(wc -c < "\$hit" | tr -d ' ')
printf '@@FILE %s\n' "\$bytes"
[ "\$bytes" -le $CONFIRM_BYTES ] || exit 0
printf '\n@@BEGIN\n'; base64 < "\$hit"; printf '\n@@END\n'
REMOTE
} | ssh -o BatchMode=yes -o ConnectTimeout=10 "$SERVER" 'sh -s' >"$response" \
  || fail "$(msg down_connect_failed "$SERVER" "$LOG")"

hits=$(sed -n 's/^@@CAND //p' "$response")
count=$(printf '%s' "$hits" | grep -c .)
echo "hits: count=[$count]"
echo "$hits"
case "$count" in
  0) fail "$(msg down_not_found "$wanted" "$SERVER")" ;;
  1) ;;
  *) fail "$(msg down_ambiguous "$wanted" "$count")
$(printf '%s\n' "$hits" | while IFS= read -r h; do echo "- $(basename "$h")"; done)" ;;
esac

# ~/Downloads に同じ名前があれば「名前 (1).拡張子」のようにずらす
name=$(basename "$hits")
stem=$name ext=""
case "$name" in ?*.*) stem=${name%.*} ext=".${name##*.}" ;; esac
dest="$HOME/Downloads/$name"
i=1
while [ -e "$dest" ]; do
  dest="$HOME/Downloads/$stem ($i)$ext"
  i=$((i + 1))
done

# 進み具合の窓 (JXA)。受け取り中のファイルの大きさを見て進み具合を出し、中断を押すと窓ごと終わる
IFS= read -r -d '' progress_js <<'JXA'
// 受け取り中のファイルの大きさを見て、進み具合の窓を出す。中断を押すと窓ごと終わる
// 引数: <受け取り中のファイル> <全体のバイト数> <見出し> <中断ボタンの文字>
ObjC.import("Cocoa");
function run(argv) {
  var path = argv[0], total = Number(argv[1]), label = argv[2], stopLabel = argv[3];
  var app = $.NSApplication.sharedApplication;
  app.setActivationPolicy($.NSApplicationActivationPolicyAccessory);

  var win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
    $.NSMakeRect(0, 0, 440, 120), $.NSWindowStyleMaskTitled, $.NSBackingStoreBuffered, false);
  win.title = "iTerm2 download";
  win.level = $.NSFloatingWindowLevel;
  var view = win.contentView;

  var title = $.NSTextField.labelWithString(label);
  title.frame = $.NSMakeRect(20, 82, 400, 20);
  title.lineBreakMode = $.NSLineBreakByTruncatingMiddle;
  view.addSubview(title);

  var bar = $.NSProgressIndicator.alloc.initWithFrame($.NSMakeRect(20, 58, 400, 20));
  bar.indeterminate = false;
  bar.minValue = 0;
  bar.maxValue = 100;
  view.addSubview(bar);

  var status = $.NSTextField.labelWithString("");
  status.frame = $.NSMakeRect(20, 18, 300, 20);
  view.addSubview(status);

  var size = function (b) {
    var u = ["B", "KB", "MB", "GB", "TB"], i = 0;
    while (b >= 1024 && i < 4) { b /= 1024; i++; }
    return (i === 0 ? b.toFixed(0) : b.toFixed(1)) + " " + u[i];
  };

  ObjC.registerSubclass({
    name: "DownloadProgress",
    methods: {
      "tick:": {
        types: ["void", ["id"]],
        implementation: function () {
          var attrs = $.NSFileManager.defaultManager.attributesOfItemAtPathError(path, null);
          var got = attrs.isNil() ? 0 : Number(ObjC.unwrap(attrs.objectForKey($.NSFileSize)));
          var pct = total > 0 ? Math.min(99, Math.floor(got * 100 / total)) : 0;
          bar.doubleValue = pct;
          status.stringValue = size(got) + " / " + size(total) + " (" + pct + "%)";
        }
      },
      "cancel:": {
        types: ["void", ["id"]],
        implementation: function () { app.terminate(null); }
      }
    }
  });
  var target = $.DownloadProgress.alloc.init;

  var cancel = $.NSButton.buttonWithTitleTargetAction(stopLabel, target, "cancel:");
  cancel.frame = $.NSMakeRect(320, 12, 100, 32);
  view.addSubview(cancel);

  $.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(0.3, target, "tick:", $(), true);
  target.tick(null);
  win.center;
  win.makeKeyAndOrderFront(null);
  app.activateIgnoringOtherApps(true);
  app.run;
}
JXA

# 受け取りの処理 (引数のコマンド) を裏で動かしながら、進み具合の窓を出す。
# 窓の中断で受け取りを止めたら 2、受け取りに失敗したら 1 を返す
receive_with_progress() {
  local file=$1 total=$2 label=$3
  shift 3
  ( set -o pipefail; "$@" ) &
  local receiver=$!
  osascript -l JavaScript -e "$progress_js" "$file" "$total" "$label" "$(msg btn_stop)" &
  local window=$!
  while kill -0 "$receiver" 2>/dev/null; do
    if [ -n "$window" ] && ! kill -0 "$window" 2>/dev/null; then
      if wait "$window"; then
        # 中断が押された
        pkill -P "$receiver"; kill "$receiver" 2>/dev/null; wait "$receiver"
        return 2
      fi
      # 窓だけが失敗した。受け取りはそのまま続ける
      echo "progress window failed"
      window=""
    fi
    sleep 0.3
  done
  wait "$receiver"
  local status=$?
  [ -n "$window" ] && kill "$window" 2>/dev/null
  return $status
}

# リモートで sh スクリプト ($1) を実行し、@@BEGIN〜@@END の base64 を戻してファイル ($2) に書く
fetch_to() {
  printf '%s\n' "$1" | ssh -o BatchMode=yes -o ConnectTimeout=10 "$SERVER" 'sh -s' \
    | sed -n '/^@@BEGIN$/,/^@@END$/{/^@@/d;p;}' | base64 -D >"$2"
}

dir_info=$(sed -n 's/^@@DIR //p' "$response")
file_bytes=$(sed -n 's/^@@FILE //p' "$response")
echo "info: dir=[$dir_info] file_bytes=[$file_bytes]"
remote_path=$(shq "$hits")

if [ -n "$dir_info" ]; then
  # フォルダ: 大きさとファイル数を見せて確認し、tar で固めて受け取って、~/Downloads に置く。
  # 進み具合を du の大きさと比べられるよう、圧縮はしない
  dir_kb=${dir_info%% *}
  dir_files=${dir_info#* }
  confirm "$(msg down_confirm "$name/" "$(msg size_files "$(human_size $((dir_kb * 1024)))" "$dir_files")")" \
    || { echo "cancelled"; exit 0; }
  work=$(mktemp -d "$HOME/Downloads/.download.XXXXXX")
  receive_with_progress "$work/stream.tar" $((dir_kb * 1024)) "$(msg down_progress "$name/")" fetch_to "p=$remote_path
cd \"\$(dirname \"\$p\")\" && printf '\\n@@BEGIN\\n' && tar cf - \"./\$(basename \"\$p\")\" | base64 && printf '\\n@@END\\n'" \
    "$work/stream.tar"
  status=$?
  [ "$status" -eq 2 ] && { rm -rf "$work"; echo "cancelled"; exit 0; }
  [ "$status" -eq 0 ] && tar xf "$work/stream.tar" -C "$work" && rm "$work/stream.tar" \
    && [ -d "$work/$name" ] && mv "$work/$name" "$dest" && rmdir "$work" \
    || { rm -rf "$work"; fail "$(msg down_failed "$name/" "$LOG")"; }
else
  partial="$dest.part"
  if [ "$file_bytes" -le "$CONFIRM_BYTES" ]; then
    sed -n '/^@@BEGIN$/,/^@@END$/{/^@@/d;p;}' "$response" | base64 -D >"$partial"
  else
    # 大きいファイル: 大きさを見せて確認してから、進み具合の窓を出しながら改めて受け取る
    confirm "$(msg down_confirm "$name" "$(human_size "$file_bytes")")" \
      || { echo "cancelled"; exit 0; }
    receive_with_progress "$partial" "$file_bytes" "$(msg down_progress "$name")" fetch_to "p=$remote_path
printf '\\n@@BEGIN\\n'; base64 < \"\$p\"; printf '\\n@@END\\n'" \
      "$partial"
    [ $? -eq 2 ] && { rm -f "$partial"; echo "cancelled"; exit 0; }
  fi
  [ "$(wc -c <"$partial" | tr -d ' ')" = "$file_bytes" ] && mv "$partial" "$dest" \
    || { rm -f "$partial"; fail "$(msg down_failed "$name" "$LOG")"; }
fi

echo "saved: $dest"
done_dialog "$(msg down_done "$(basename "$dest")")" "$dest"
