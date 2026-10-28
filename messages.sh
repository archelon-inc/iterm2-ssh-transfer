# upload.sh・download.sh が画面に出す文。Mac の言語の先頭が日本語なら日本語、それ以外は英語で返す。
#   msg_init "$(defaults read -g AppleLanguages)"   言語を決める
#   msg <キー> [値…]                                文を stdout に出す。文の中の {1} {2} … は 1 つ目、2 つ目 … の値になる
# 知らないキーには、キーをそのまま出して 1 を返す

# $1: defaults read -g AppleLanguages の出力。("ja-JP", "en-US") のような並び
msg_init() {
  local first
  first=$(printf '%s' "$1" | tr -d '()" \t\n' | cut -d, -f1)
  case "$first" in
    ja | ja-* | ja_*) MSG_LANG=ja ;;
    *) MSG_LANG=en ;;
  esac
}

msg() {
  local key=$1 s n out=""
  shift
  case "$MSG_LANG:$key" in
    ja:btn_close) s='閉じる' ;;
    en:btn_close) s='Close' ;;
    ja:btn_cancel) s='キャンセル' ;;
    en:btn_cancel) s='Cancel' ;;
    ja:btn_stop) s='中断' ;;
    en:btn_stop) s='Stop' ;;
    ja:btn_send) s='送る' ;;
    en:btn_send) s='Send' ;;
    ja:btn_create) s='作る' ;;
    en:btn_create) s='Create' ;;
    ja:btn_download) s='落とす' ;;
    en:btn_download) s='Download' ;;
    ja:btn_show_in_finder) s='Finder で開く' ;;
    en:btn_show_in_finder) s='Show in Finder' ;;
    ja:btn_open_settings) s='設定を開く' ;;
    en:btn_open_settings) s='Open Settings' ;;

    ja:no_session_id) s='起動元のセッションが分かりません (ITERM_SESSION_ID なし)' ;;
    en:no_session_id) s='Cannot tell which session started this (ITERM_SESSION_ID is not set)' ;;
    ja:no_session) s='起動元のセッションが見つかりません' ;;
    en:no_session) s='Cannot find the session that started this' ;;
    ja:no_tty) s='セッションの tty が分かりません' ;;
    en:no_tty) s='Cannot find the tty of the session' ;;
    ja:local_session) s='このタブは SSH でつないでいません' ;;
    en:local_session) s='This tab is not connected over SSH' ;;
    ja:no_ssh_dest) s='SSH の接続先を判定できませんでした' ;;
    en:no_ssh_dest) s='Cannot tell the SSH destination' ;;
    ja:size_files) s='{1}・ファイル {2} 個' ;;
    en:size_files) s='{1}, {2} files' ;;

    ja:up_items) s='{1} 個' ;;
    en:up_items) s='{1} items' ;;
    ja:up_confirm) s='{1} は {2}です。{3} の ~/tmp に送りますか？' ;;
    en:up_confirm) s='{1} ({2}). Send to ~/tmp on {3}?' ;;
    ja:up_no_tmp) s='{1} に送り先の ~/tmp がありません。作りますか？' ;;
    en:up_no_tmp) s='~/tmp, where files are sent, does not exist on {1}. Create it?' ;;
    ja:up_progress) s='{1} を {2} に送っています' ;;
    en:up_progress) s='Sending {1} to {2}' ;;
    ja:up_failed_item) s='{1} を {2} に送れませんでした (詳細: {3})' ;;
    en:up_failed_item) s='Failed to send {1} to {2} (details: {3})' ;;
    ja:up_failed) s='{1} に送れませんでした (詳細: {2})' ;;
    en:up_failed) s='Failed to send to {1} (details: {2})' ;;
    ja:up_nothing) s='クリップボードにファイルも画像もありません (詳細: {1})' ;;
    en:up_nothing) s='The clipboard has neither files nor an image (details: {1})' ;;

    ja:down_no_selection) s='文字が選ばれていません' ;;
    en:down_no_selection) s='Nothing is selected' ;;
    ja:down_too_long) s='選んだ文字が長すぎます ({1} 文字。{2} 文字まで)' ;;
    en:down_too_long) s='The selection is too long ({1} characters; up to {2})' ;;
    ja:down_truncated)
      s=$'選んだ文字のうち、iTerm2 から届いたのは最初の {1} 文字だけでした。\n\niTerm2 の設定の「詳細」(Advanced) にある「Python API に渡す選択範囲の最大バイト数」(Maximum number of bytes of selection to provide to Python API) を大きくしてから、選び直してください。' ;;
    en:down_truncated)
      s=$'iTerm2 passed only the first {1} characters of the selection.\n\nIncrease "Maximum number of bytes of selection to provide to Python API" in iTerm2 Settings > Advanced, then select again.' ;;
    ja:down_no_cwd) s='相対パスですが、今いるディレクトリが分かりません' ;;
    en:down_no_cwd) s='The path is relative, but the current directory is unknown' ;;
    ja:down_unreadable) s='選んだ文字を読めませんでした (詳細: {1})' ;;
    en:down_unreadable) s='Cannot read the selection (details: {1})' ;;
    ja:down_url_failed) s='URL を開けませんでした: {1}' ;;
    en:down_url_failed) s='Cannot open the URL: {1}' ;;
    ja:down_connect_failed) s='{1} に接続できませんでした (詳細: {2})' ;;
    en:down_connect_failed) s='Cannot connect to {1} (details: {2})' ;;
    ja:down_not_found) s='「{1}」は {2} にありません。選び直してください' ;;
    en:down_not_found) s='"{1}" is not on {2}. Select again' ;;
    ja:down_ambiguous) s='選択したパスの区切り方・折り返しの解釈が {1} 通り以上あり、決められません。選び直してください' ;;
    en:down_ambiguous) s='The selection has at least {1} interpretations of path boundaries or wrapping. Select again' ;;
    ja:down_too_complex) s='折り返しの候補が多すぎます。選択範囲を分けて、もう一度実行してください' ;;
    en:down_too_complex) s='There are too many possible line wraps. Split the selection and try again' ;;
    ja:down_items) s='{1} 件' ;;
    en:down_items) s='{1} items' ;;
    ja:down_saved) s='{1} 件は ~/Downloads に保存済みです' ;;
    en:down_saved) s='{1} items have already been saved to ~/Downloads' ;;
    ja:down_cancelled) s='ダウンロードを中断しました' ;;
    en:down_cancelled) s='Download stopped' ;;
    ja:down_confirm) s='{1} は {2}です。~/Downloads に落としますか？' ;;
    en:down_confirm) s='{1} ({2}). Download to ~/Downloads?' ;;
    ja:down_progress) s='{1} を落としています' ;;
    en:down_progress) s='Downloading {1}' ;;
    ja:down_failed) s='{1} を受け取れませんでした (詳細: {2})' ;;
    en:down_failed) s='Failed to download {1} (details: {2})' ;;
    ja:down_done) s='{1} を ~/Downloads に落としました' ;;
    en:down_done) s='Downloaded {1} to ~/Downloads' ;;

    *) printf '%s' "$key"; return 1 ;;
  esac
  # 文を左から一度だけ読んで {1}〜{9} を値にする。値の中の & や \ や {2} は、そのまま入る
  while case "$s" in *"{"*) true ;; *) false ;; esac; do
    out+=${s%%"{"*}
    s=${s#*"{"}
    case "$s" in
      [1-9]}*)
        n=${s%%\}*}
        out+=${!n}
        s=${s#?\}}
        ;;
      *) out+="{" ;;
    esac
  done
  printf '%s' "$out$s"
}
