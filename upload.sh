#!/bin/bash
# クリップボードの画像、または Finder でコピーしたファイルやフォルダ (複数可) を
# 「今そのタブで SSH 接続中のホスト」の ~/tmp に送り、
# リモートのフルパスを stdout に出す (Coprocess として動くとターミナルに入力される)。
# フォルダと大きいものは、大きさを見せて確認してから、進み具合の窓を出しながら送る。
#
# キーバインド: このファイル (Action: Run Coprocess、引数なし)
# デバッグログ: /tmp/iterm2-upload.log

# エラー出力は調査用にログへ (失敗時はここを見る)
LOG=/tmp/iterm2-upload.log
# 合わせてこれより大きいものは、送る前に確認する
CONFIRM_BYTES=$((10 * 1024 * 1024))
exec 2>>"$LOG"
echo "=== $(date '+%F %T') pid=$$ ===" >>"$LOG"

log() {
  printf '%s\n' "$*" >>"$LOG"
}

# 失敗時はターミナルに # コメントとして理由を入力しつつ終了
fail() {
  echo -n "# upload: $1"
  exit 1
}

# 起動元セッションの tty を取る。Coprocess に渡される ITERM_SESSION_ID でセッションを特定するので、
# 複数ウィンドウやペインがあってもよい。tmux 統合のセッションは tty を持たないので、代わりに foreground job の PID を返す
session_tty=$(osascript - "${ITERM_SESSION_ID##*:}" <<'APPLESCRIPT'
on run argv
  set targetID to item 1 of argv
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if (unique ID of s as text) is targetID then
            set sessionTTY to tty of s
            if sessionTTY is not missing value then return sessionTTY as text
            tell s to set sessionPID to variable named "jobPid"
            if sessionPID is not missing value then return "pid:" & (sessionPID as text)
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return ""
end run
APPLESCRIPT
)
log "session lookup: id=[${ITERM_SESSION_ID:-}] tty=[$session_tty]"
case "$session_tty" in
  pid:*)
    session_tty=$(ps -p "${session_tty#pid:}" -o tty= | xargs)
    case "$session_tty" in tty*) session_tty="/dev/$session_tty" ;; *) session_tty="" ;; esac
    ;;
esac
[ -n "$session_tty" ] || fail "セッションの tty が分かりません"

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

# 接続先を決められなければ、誤送信を避けるため送らない
cmd=$(ps -t "${session_tty#/dev/}" -o command= | grep -E '^([^ ]*/)?ssh( |$)' | grep -v -- ' -W ' | head -1)
log "tty lookup: tty=[$session_tty] ssh=[$cmd]"
[ -n "$cmd" ] || fail "ローカルセッションです (SSH 先へは送りません)"
SERVER=$(parse_ssh_dest "$cmd")
[ -n "$SERVER" ] || fail "SSH の接続先を判定できませんでした"

# クリップボードが Finder でコピーしたファイル (複数可) かどうかを先に判定する。
# AppleScript の `the clipboard as furl` は先頭 1 件しか取れないため、
# JXA で NSPasteboard の pasteboardItems を直接読んで全件拾う。
finder_files=$(osascript -l JavaScript 2>>"$LOG" <<'JXA'
ObjC.import("AppKit");
var pb = $.NSPasteboard.generalPasteboard;
var items = pb.pasteboardItems;
var result = [];
for (var i = 0; i < items.count; i++) {
  var item = items.objectAtIndex(i);
  try {
    var urlStr = item.stringForType("public.file-url");
    var path = $.NSURL.URLWithString(urlStr).filePathURL.path.js;
    if (path) result.push(path);
  } catch (e) {}
}
result.join("\n");
JXA
)

finder_paths=()
while IFS= read -r line; do
  [ -n "$line" ] && { [ -f "$line" ] || [ -d "$line" ]; } && finder_paths+=("$line")
done <<< "$finder_files"

# 前面に出る OK / キャンセルのダイアログ。キャンセルなら非 0 で返る
confirm() {
  osascript - "$1" <<'APPLESCRIPT' >/dev/null
on run argv
  tell application "System Events"
    activate
    display dialog (item 1 of argv) buttons {"キャンセル", "送る"} default button "送る" cancel button "キャンセル" with title "iTerm2 upload"
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

# stdin をそのまま stdout へ流しながら、流したバイト数に $1 を足した値を $count_file に書く
count_bytes() {
  perl -MTime::HiRes=time -e '
    my ($base, $file) = @ARGV;
    my ($n, $last, $buf) = (0, 0);
    my $put = sub {
      open my $fh, ">", "$file.new" or return;
      print $fh $base + $n; close $fh; rename "$file.new", $file;
    };
    while ((my $r = sysread STDIN, $buf, 1 << 16) > 0) {
      for (my $off = 0; $off < $r; ) {
        my $w = syswrite STDOUT, $buf, $r - $off, $off;
        defined $w or exit 1;
        $off += $w;
      }
      $n += $r;
      if (time - $last >= 0.2) { $put->(); $last = time; }
    }
    $put->();
  ' "$1" "$count_file"
}

# Mac の名前は濁点・半濁点が分かれた形 (NFD) のことがある。Linux では別の名前になるので、
# 送り先では合わさった形 (NFC) にする
nfc() {
  perl -MUnicode::Normalize -MEncode -e '
    my $u = eval { decode("UTF-8", $ARGV[0], Encode::FB_CROAK) };
    print defined $u ? encode("UTF-8", NFC($u)) : $ARGV[0];
  ' "$1"
}

# bsdtar の mtree の各行の名前とリンク先を NFC にし、中身は元の名前から読むよう contents= を足す
IFS= read -r -d '' nfc_mtree_pl <<'PERL'
use Unicode::Normalize; use Encode;
sub unvis { my $s = shift; $s =~ s/\\([0-7]{3})/chr oct $1/ge; $s }
sub vis { my $s = shift; $s =~ s/([^!-~]|[\\#=])/sprintf "\\%03o", ord $1/ge; $s }
sub nfc {
  my $b = unvis(shift);
  my $u = eval { decode("UTF-8", $b, Encode::FB_CROAK) };
  defined $u ? encode("UTF-8", NFC($u)) : $b;
}
while (<STDIN>) {
  if (/^[#\/]/ || !/\S/) { print; next }
  chomp;
  my ($name, @kw) = split / /;
  s/^link=(.*)/"link=" . vis(nfc($1))/e for @kw;
  push @kw, "contents=$name" if grep { $_ eq "type=file" } @kw;
  print join(" ", vis(nfc($name)), @kw), "\n";
}
PERL

# フォルダ ($1) を、中の名前をすべて NFC にした tar にして stdout に出す
tar_nfc() {
  (
    cd "$(dirname "$1")" || exit 1
    tar cf - --format=mtree "$(basename "$1")" | perl -e "$nfc_mtree_pl" \
      | COPYFILE_DISABLE=1 tar cf - --no-xattrs --no-mac-metadata --no-acls --no-fflags @-
  )
}

# 1 つ送り、リモートのホームを stdout に出す。フォルダは tar で固めて送り、~/tmp で展開する。
# 途中で切れたものは残さない。同じ名前が ~/tmp にあれば置き換える
send_one() {
  local f=$1 offset=$2 bytes=$3 q
  q=$(shq "$(nfc "$(basename "$f")")")
  if [ -d "$f" ]; then
    tar_nfc "$f" | count_bytes "$offset" \
      | ssh -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes "$SERVER" \
        "mkdir -p \"\$HOME/tmp\" && w=\$(mktemp -d \"\$HOME/tmp/.upload.XXXXXX\") || exit 1
         if tar xf - -C \"\$w\" && rm -rf \"\$HOME/tmp/\"$q && mv \"\$w/\"$q \"\$HOME/tmp/\"; then
           rmdir \"\$w\"; echo \"@@\$HOME\"
         else
           rm -rf \"\$w\"
         fi"
  else
    count_bytes "$offset" < "$f" \
      | ssh -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes "$SERVER" \
        "mkdir -p \"\$HOME/tmp\" && p=\"\$HOME/tmp/\"$q && cat > \"\$p.part\"
         if [ \"\$(wc -c < \"\$p.part\" | tr -d ' ')\" = $bytes ] && mv \"\$p.part\" \"\$p\"; then
           echo \"@@\$HOME\"
         else
           rm -f \"\$p.part\"
         fi"
  fi | sed -n 's/^@@//p' | tail -1
}

# 順に送り、送った先のパスを 1 行ずつ $sent に書く。失敗したら、その名前を $failed に書いて 1 を返す
send_all() {
  local i offset=0 home
  for i in "${!finder_paths[@]}"; do
    home=$(send_one "${finder_paths[$i]}" "$offset" "${sizes[$i]}")
    if [ -z "$home" ]; then
      basename "${finder_paths[$i]}" >"$failed"
      return 1
    fi
    printf '%s\n' "$home/tmp/$(nfc "$(basename "${finder_paths[$i]}")")" >>"$sent"
    offset=$((offset + sizes[i]))
  done
}

# 進み具合の窓 (JXA)。$count_file に書かれた送ったバイト数を見て進み具合を出し、中断を押すと窓ごと終わる
IFS= read -r -d '' progress_js <<'JXA'
// 引数: <送ったバイト数を書いたファイル> <全体のバイト数> <見出し>
ObjC.import("Cocoa");
function run(argv) {
  var path = argv[0], total = Number(argv[1]), label = argv[2];
  var app = $.NSApplication.sharedApplication;
  app.setActivationPolicy($.NSApplicationActivationPolicyAccessory);

  var win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
    $.NSMakeRect(0, 0, 440, 120), $.NSWindowStyleMaskTitled, $.NSBackingStoreBuffered, false);
  win.title = "iTerm2 upload";
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
    name: "UploadProgress",
    methods: {
      "tick:": {
        types: ["void", ["id"]],
        implementation: function () {
          var s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
          var got = s.isNil() ? 0 : Number(s.js) || 0;
          var pct = total > 0 ? Math.min(99, Math.floor(got * 100 / total)) : 0;
          bar.doubleValue = pct;
          status.stringValue = size(got) + " / " + size(total) + "（" + pct + "%）";
        }
      },
      "cancel:": {
        types: ["void", ["id"]],
        implementation: function () { app.terminate(null); }
      }
    }
  });
  var target = $.UploadProgress.alloc.init;

  var cancel = $.NSButton.buttonWithTitleTargetAction("中断", target, "cancel:");
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

# $1 と、その子孫のプロセスを止める
kill_tree() {
  local c
  for c in $(pgrep -P "$1"); do kill_tree "$c"; done
  kill "$1" 2>/dev/null
}

# send_all を裏で動かしながら、進み具合の窓を出す。
# 窓の中断で止めたら 2、送るのに失敗したら 1 を返す
send_with_progress() {
  local total=$1 label=$2
  send_all &
  local sender=$!
  osascript -l JavaScript -e "$progress_js" "$count_file" "$total" "$label" >/dev/null &
  local window=$!
  while kill -0 "$sender" 2>/dev/null; do
    if [ -n "$window" ] && ! kill -0 "$window" 2>/dev/null; then
      if wait "$window"; then
        # 中断が押された
        kill_tree "$sender"; wait "$sender"
        return 2
      fi
      # 窓だけが失敗した。送るのはそのまま続ける
      log "progress window failed"
      window=""
    fi
    sleep 0.3
  done
  wait "$sender"
  local status=$?
  [ -n "$window" ] && kill "$window" 2>/dev/null
  return $status
}

if [ "${#finder_paths[@]}" -gt 0 ]; then
  # Finder のファイルやフォルダ: 送った先のパスをスペース区切り 1 行にまとめて出す
  # (Coprocess で `vim ` などの後ろに続けて複数ファイルをまとめて開けるようにするため)
  # フォルダや大きいものは、大きさを見せて確認してから、進み具合の窓を出しながら送る。
  # フォルダは tar で固めて送るので、du の大きさで見積もる
  sizes=()
  total=0 dirs=0 files=0
  for f in "${finder_paths[@]}"; do
    if [ -d "$f" ]; then
      bytes=$(($(du -sk "$f" | cut -f1) * 1024))
      dirs=$((dirs + 1))
      files=$((files + $(find "$f" -type f | wc -l)))
    else
      bytes=$(stat -f %z "$f")
      files=$((files + 1))
    fi
    sizes+=("$bytes")
    total=$((total + bytes))
  done
  log "items: count=[${#finder_paths[@]}] dirs=[$dirs] files=[$files] total=[$total]"

  work=$(mktemp -d "${TMPDIR:-/tmp}/iterm2-upload.XXXXXX")
  trap 'rm -rf "$work"' EXIT
  count_file="$work/count" sent="$work/sent" failed="$work/failed"

  if [ "$dirs" -gt 0 ] || [ "$total" -gt "$CONFIRM_BYTES" ]; then
    if [ "${#finder_paths[@]}" -eq 1 ]; then
      what=$(basename "${finder_paths[0]}")
      [ "$dirs" -eq 1 ] && what="$what/"
    else
      what="${#finder_paths[@]} 個"
    fi
    detail=$(human_size "$total")
    [ "$dirs" -gt 0 ] && detail="${detail}・ファイル $files 個"
    confirm "${what} は ${detail}です。$SERVER の ~/tmp に送りますか？" \
      || { log "cancelled"; exit 0; }
    send_with_progress "$total" "${what} を $SERVER に送っています"
    status=$?
  else
    send_all
    status=$?
  fi
  [ "$status" -eq 2 ] && { log "cancelled"; exit 0; }
  [ "$status" -eq 0 ] \
    || fail "$SERVER への転送に失敗しました ($(cat "$failed" 2>/dev/null)) (詳細: /tmp/iterm2-upload.log)"

  # ファイル名に " $ ` などがあっても崩れないよう、" の中で特別な意味を持つ文字を \ でエスケープする
  out=""
  while IFS= read -r p; do
    out+="\"$(printf '%s' "$p" | sed 's/[\\"$`]/\\&/g')\" "
  done <"$sent"
  log "sent: $out"
  echo -n "${out% }"
  exit 0
fi

# 画像 (PNG) をクリップボードから一時ファイルへ書き出す
# マイクロ秒まで入れて、連続で呼ばれてしまっても衝突しないようにする
local_file="/tmp/img_$(date +%Y%m%d_%H%M%S_%N | cut -c1-22).png"

osascript >/dev/null <<EOF
try
  set theFile to (open for access POSIX file "$local_file" with write permission)
  write (the clipboard as «class PNGf») to theFile
  close access theFile
on error errMsg
  try
    close access POSIX file "$local_file"
  end try
  error "クリップボードに画像がありません: " & errMsg
end try
EOF

if [ $? -ne 0 ] || [ ! -s "$local_file" ]; then
  rm -f "$local_file"
  fail "クリップボードにファイルも画像もありません (詳細: /tmp/iterm2-upload.log)"
fi

# 1回の接続で リモートの ~/tmp 作成 + 転送 + ホームのパス取得 をまとめて行う。
# リモートの rc が出力するゴミ (iTerm2 の SetProfile など) を除くため @@ を目印にする
fname=$(basename "$local_file")
remote_home=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes "$SERVER" \
  "mkdir -p \"\$HOME/tmp\" && cat > \"\$HOME/tmp/$fname\" && echo \"@@\$HOME\"" \
  < "$local_file" | sed -n 's/^@@//p' | tail -1)

rm -f "$local_file"

if [ -z "$remote_home" ]; then
  fail "$SERVER への転送に失敗しました (詳細: /tmp/iterm2-upload.log)"
fi

# Coprocess 経由ならこれがターミナルに入力される
echo -n "$remote_home/tmp/$fname"
