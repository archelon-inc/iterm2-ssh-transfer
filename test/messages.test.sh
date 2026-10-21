#!/bin/bash
# messages.sh の約束を確かめる。repo の根で test/messages.test.sh として動かす
#   - Mac の言語の先頭が日本語なら日本語、それ以外は英語で返す
#   - upload.sh・download.sh が使うキーは、日英の両方にある
#   - 日英で、同じ値を差し込む
#   - 値は、& や \ や {2} を含んでもそのまま入る
#   - 知らないキーは 1 を返す

cd "$(dirname "$0")/.." || exit 1
. ./messages.sh

failures=0
check() {
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    echo "NG   $1"
    echo "     want: [$3]"
    echo "     got:  [$2]"
    failures=$((failures + 1))
  fi
}

# 言語が日本語の文には日本語が入り、英語の文は ASCII だけ
lang_of() {
  msg_init "$1"
  if msg btn_close | LC_ALL=C grep -q '[^ -~]'; then echo ja; else echo en; fi
}
check '言語: 日本語だけ' "$(lang_of '(
    "ja-JP"
)')" ja
check '言語: 先頭が日本語' "$(lang_of '(
    "ja-JP",
    "en-US"
)')" ja
check '言語: 引用符の無い ja' "$(lang_of '(ja, en)')" ja
check '言語: 先頭が英語' "$(lang_of '(
    "en-JP",
    "ja-JP"
)')" en
check '言語: 日本語でも英語でもない' "$(lang_of '("fr-FR")')" en
check '言語: 取れなかった' "$(lang_of '')" en

# スクリプトが使うキー
keys=$(grep -ho 'msg [a-z_]*' upload.sh download.sh | sed 's/^msg //' | sort -u)
[ -n "$keys" ] || { echo "NG   スクリプトからキーを拾えない"; exit 1; }

# 1〜9 個目の値として <1>〜<9> を渡したとき、文に入った値の番号
used_values() {
  local out i
  out=$(msg "$1" '<1>' '<2>' '<3>' '<4>' '<5>' '<6>' '<7>' '<8>' '<9>')
  for i in 1 2 3 4 5 6 7 8 9; do
    case "$out" in *"<$i>"*) printf '%s ' "$i" ;; esac
  done
}

for key in $keys; do
  msg_init '("ja-JP")'
  ja=$(msg "$key"); ja_rc=$?
  ja_values=$(used_values "$key")
  msg_init '("en-US")'
  en=$(msg "$key"); en_rc=$?
  en_values=$(used_values "$key")
  check "$key: 日本語がある" "$ja_rc" 0
  check "$key: 英語がある" "$en_rc" 0
  check "$key: 英語は ASCII だけ" "$(printf '%s' "$en" | LC_ALL=C tr -d ' -~\n')" ''
  check "$key: 日英で同じ値を差し込む" "$ja_values" "$en_values"
done

msg_init '("en-US")'
check '値はそのまま入る' "$(msg down_not_found 'a&b\c{2}.txt' 'host')" '"a&b\c{2}.txt" is not on host. Select again'
msg nokey >/dev/null
check '知らないキーは 1 を返す' "$?" 1

echo
if [ "$failures" -eq 0 ]; then
  echo "all ok"
else
  echo "$failures failed"
  exit 1
fi
