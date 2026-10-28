#!/bin/bash
# iTerm2 の選択 → micro の選択 → クリップボードの順で文字を取得し、
#   - URL なら Mac のブラウザで開く
#   - ファイルやフォルダのパスなら「今そのタブで SSH 接続中のホスト」から ~/Downloads に落とす
#     (フォルダと大きいファイルは、大きさを見せて確認してから、進み具合の窓を出しながら落とす)
# 画面の折り返しで改行や字下げが混ざっていても、つなぎ目だけを「何も無い / 半角・全角スペース1つ」とみなして
# 候補を作り、改行で区切る場合も含めて選択全体の解釈が1つに決まったときだけまとめて落とす。
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
SCRIPT_DIR=$(dirname "$(perl -MCwd=abs_path -e 'print abs_path(shift)' "$0")")
. "$SCRIPT_DIR/messages.sh"
. "$SCRIPT_DIR/selection.sh"
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
  local message=$1 show
  shift
  show=$(msg btn_show_in_finder)
  answer=$(osascript - "$message" "$(msg btn_close)" "$show" <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    activate
    display dialog (item 1 of argv) buttons {item 2 of argv, item 3 of argv} default button (item 3 of argv) with title "iTerm2 download"
  end tell
  return button returned of result
end run
APPLESCRIPT
  )
  if [ "$answer" = "$show" ]; then open -R "$@"; fi
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
  echo "fail: ダウンロードを停止（理由はダイアログに表示）"
  local reason=$1
  if [ "${#saved_paths[@]}" -gt 0 ]; then
    reason="$reason

$(msg down_saved "${#saved_paths[@]}")"
  fi
  alert "$reason"
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
              set tmuxPane to variable named "tmuxWindowPane"
            end tell
            set sessionTTY to tty of s
            if sel is missing value then set sel to ""
            if selLen is missing value then set selLen to 0
            if cwd is missing value then set cwd to ""
            if tmuxPane is missing value then set tmuxPane to ""
            if sessionTTY is missing value then
              if jobPID is missing value then
                set sessionTTY to ""
              else
                set sessionTTY to "pid:" & (jobPID as text)
              end if
            end if
            return (sessionTTY as text) & US & (cwd as text) & US & (selLen as text) & US & (tmuxPane as text) & US & (sel as text) & US
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
rest=${rest#*"$US"}
tmux_pane=${rest%%"$US"*}
# 末尾の US は、選んだ文字の最後の改行が $( ) で消されないための止め
selection=${rest#*"$US"}
selection=${selection%"$US"}
selection_source=iterm2

[ -n "$session" ] || fail "$(msg no_session)"
if [ -z "$selection" ]; then
  [ "${selection_length:-0}" -eq 0 ] || fail "$(msg down_unreadable "$LOG")"
  read_fallback_selection
fi
[ -n "$selection" ] || fail "$(msg down_no_selection)"
echo "session: tty=[$session_tty] selection_source=[$selection_source] selectionLength=[$selection_length]"

# 実在する候補を長さごとに照合し、改行で区切る位置と折り返しを同時に決める。
transfer_work=$(mktemp -d "${TMPDIR:-/tmp}/iterm2-download.XXXXXX") || fail "$(msg down_unreadable "$LOG")"
response="$transfer_work/response"
state="$transfer_work/state.json"
query="$transfer_work/query.sh"
saved_paths=()
trap 'rm -rf "$transfer_work"' EXIT
plan=$(SEL="$selection" SELLEN="$selection_length" SELMAX="$SELECTION_LIMIT" CWD="$cwd" \
  osascript -l JavaScript "$SCRIPT_DIR/path-plan.js" init "$state" "$query" "") \
  || fail "$(msg down_unreadable "$LOG")"
ssh_ready=0
while :; do
  kind=${plan%%$'\n'*}
  body=${plan#*$'\n'}
  case "$kind" in
    url) open "$body" || fail "$(msg down_url_failed "$body")"; exit 0 ;;
    remote)
      if [ "$ssh_ready" -eq 0 ]; then
        [ -n "$session_tty" ] || fail "$(msg no_tty)"
        resolve_ssh_context
        [ -n "$cmd" ] || fail "$(msg local_session)"
        [ -n "$SERVER" ] || fail "$(msg no_ssh_dest)"
        ssh_ready=1
      fi
      ssh -o BatchMode=yes -o ClearAllForwardings=yes -o ConnectTimeout=10 "$SERVER" 'sh -s' <"$query" >"$response" \
        || fail "$(msg down_connect_failed "$SERVER" "$LOG")"
      plan=$(CONFIRM_BYTES="$CONFIRM_BYTES" osascript -l JavaScript "$SCRIPT_DIR/path-plan.js" advance "$state" "$query" "$response") \
        || fail "$(msg down_unreadable "$LOG")"
      ;;
    resolved) item_count=$body; break ;;
    too_long) fail "$(msg down_too_long "$body" "$SELECTION_LIMIT")" ;;
    truncated) selection_limit_dialog "$body" ;;
    no_cwd) fail "$(msg down_no_cwd)" ;;
    not_found) fail "$(msg down_not_found "$selection" "$SERVER")" ;;
    ambiguous) fail "$(msg down_ambiguous "$body")" ;;
    too_complex) fail "$(msg down_too_complex)" ;;
    *) fail "$(msg down_unreadable "$LOG")" ;;
  esac
done

# 解釈が確定してから、全件のメタデータと小さいファイルを1接続で受け取る。
ssh -o BatchMode=yes -o ClearAllForwardings=yes -o ConnectTimeout=10 "$SERVER" 'sh -s' <"$query" >"$response" \
  || fail "$(msg down_connect_failed "$SERVER" "$LOG")"
total_bytes=0
needs_confirm=0
for ((item=0; item<item_count; item++)); do
  item_response="$transfer_work/item-$item"
  awk -v item="$item" '$0 == "@@ITEM " item { inside=1; next } $0 == "@@ITEMEND " item { inside=0; ended=1 } inside { print } END { if (!ended) exit 1 }' \
    "$response" >"$item_response" || fail "$(msg down_unreadable "$LOG")"
  hits=$(sed -n 's/^@@CAND //p' "$item_response")
  [ -n "$hits" ] || fail "$(msg down_unreadable "$LOG")"
  dir_info=$(sed -n 's/^@@DIR //p' "$item_response")
  file_bytes=$(sed -n 's/^@@FILE //p' "$item_response")
  if [ -n "$dir_info" ]; then
    [[ "$dir_info" =~ ^[0-9]+\ [0-9]+$ ]] || fail "$(msg down_unreadable "$LOG")"
    total_bytes=$((total_bytes + ${dir_info%% *} * 1024))
    needs_confirm=1
  else
    [[ "$file_bytes" =~ ^[0-9]+$ ]] || fail "$(msg down_unreadable "$LOG")"
    total_bytes=$((total_bytes + file_bytes))
    [ "$file_bytes" -le "$CONFIRM_BYTES" ] || needs_confirm=1
  fi
done
# 複数件の確認は、合計の大きさを一度だけ見せる。
if [ "$item_count" -gt 1 ] && [ "$needs_confirm" -eq 1 ]; then
  confirm "$(msg down_confirm "$(msg down_items "$item_count")" "$(human_size "$total_bytes")")" \
    || { echo "cancelled"; exit 0; }
fi

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
  printf '%s\n' "$1" | ssh -o BatchMode=yes -o ClearAllForwardings=yes -o ConnectTimeout=10 "$SERVER" 'sh -s' \
    | sed -n '/^@@BEGIN$/,/^@@END$/{/^@@/d;p;}' | base64 -D >"$2"
}

cancelled() {
  echo "cancelled"
  if [ "${#saved_paths[@]}" -gt 0 ]; then
    done_dialog "$(msg down_cancelled)

$(msg down_saved "${#saved_paths[@]}")" "${saved_paths[@]}"
  fi
  exit 0
}

# 全件の照合が済んだ後、順に保存する。同名は既存ファイルも選択内のファイルも上書きしない。
for ((item=0; item<item_count; item++)); do
  response="$transfer_work/item-$item"
  hits=$(sed -n 's/^@@CAND //p' "$response")
  dir_info=$(sed -n 's/^@@DIR //p' "$response")
  file_bytes=$(sed -n 's/^@@FILE //p' "$response")
  remote_path=$(shq "$hits")
  name=$(basename "$hits")
  stem=$name ext=""
  case "$name" in ?*.*) stem=${name%.*} ext=".${name##*.}" ;; esac
  dest="$HOME/Downloads/$name"
  i=1
  while [ -e "$dest" ]; do
    dest="$HOME/Downloads/$stem ($i)$ext"
    i=$((i + 1))
  done
  label=$name
  [ "$item_count" -eq 1 ] || label="($((item + 1))/$item_count) $name"

  if [ -n "$dir_info" ]; then
    dir_kb=${dir_info%% *}
    dir_files=${dir_info#* }
    if [ "$item_count" -eq 1 ]; then
      confirm "$(msg down_confirm "$name/" "$(msg size_files "$(human_size $((dir_kb * 1024)))" "$dir_files")")" \
        || { echo "cancelled"; exit 0; }
    fi
    work=$(mktemp -d "$HOME/Downloads/.download.XXXXXX")
    receive_with_progress "$work/stream.tar" $((dir_kb * 1024)) "$(msg down_progress "$label/")" fetch_to "p=$remote_path
cd \"\$(dirname \"\$p\")\" && printf '\\n@@BEGIN\\n' && tar cf - \"./\$(basename \"\$p\")\" | base64 && printf '\\n@@END\\n'" \
      "$work/stream.tar"
    status=$?
    if [ "$status" -eq 2 ]; then
      rm -rf "$work"
      cancelled
    fi
    [ "$status" -eq 0 ] && tar xf "$work/stream.tar" -C "$work" && rm "$work/stream.tar" \
      && [ -d "$work/$name" ] && mv "$work/$name" "$dest" && rmdir "$work" \
      || { rm -rf "$work"; fail "$(msg down_failed "$name/" "$LOG")"; }
  else
    partial="$transfer_work/file-$item.part"
    if [ "$file_bytes" -le "$CONFIRM_BYTES" ]; then
      sed -n '/^@@BEGIN$/,/^@@END$/{/^@@/d;p;}' "$response" | base64 -D >"$partial"
    else
      if [ "$item_count" -eq 1 ]; then
        confirm "$(msg down_confirm "$name" "$(human_size "$file_bytes")")" \
          || { echo "cancelled"; exit 0; }
      fi
      receive_with_progress "$partial" "$file_bytes" "$(msg down_progress "$label")" fetch_to "p=$remote_path
printf '\\n@@BEGIN\\n'; base64 < \"\$p\"; printf '\\n@@END\\n'" \
        "$partial"
      status=$?
      if [ "$status" -eq 2 ]; then
        rm -f "$partial"
        cancelled
      fi
      [ "$status" -eq 0 ] || { rm -f "$partial"; fail "$(msg down_failed "$name" "$LOG")"; }
    fi
    [ "$(wc -c <"$partial" | tr -d ' ')" = "$file_bytes" ] && mv "$partial" "$dest" \
      || { rm -f "$partial"; fail "$(msg down_failed "$name" "$LOG")"; }
  fi
  saved_paths+=("$dest")
  echo "saved: $dest"
done

if [ "$item_count" -eq 1 ]; then
  message=$(msg down_done "$(basename "${saved_paths[0]}")")
else
  message=$(msg down_done "$(msg down_items "$item_count")")
fi
done_dialog "$message" "${saved_paths[@]}"
