#!/bin/bash
# download.sh の選択元を解決する。本文は最初に取得できた選択元だけを使う。

SSH_CONTEXT_CHECKED=0
SERVER=""
cmd=""

parse_ssh_dest() {
  set -- $1
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -o|-p|-i|-l|-L|-R|-D|-J|-F|-c|-m|-e|-b|-E|-S|-W|-w|-B|-I|-P) shift 2 ;;
      -*) shift ;;
      *) echo "$1"; return 0 ;;
    esac
  done
  return 1
}

resolve_ssh_context() {
  if [ "$SSH_CONTEXT_CHECKED" -eq 1 ]; then [ -n "$SERVER" ]; return; fi
  SSH_CONTEXT_CHECKED=1
  case "$session_tty" in
    pid:*)
      session_tty=$(ps -p "${session_tty#pid:}" -o tty= | xargs)
      case "$session_tty" in tty*) session_tty="/dev/$session_tty" ;; *) session_tty="" ;; esac
      ;;
  esac
  [ -n "$session_tty" ] || return 1
  cmd=$(ps -t "${session_tty#/dev/}" -o command= | grep -E '^([^ ]*/)?ssh( |$)' | grep -v -- ' -W ' | head -1)
  [ -n "$cmd" ] || return 1
  SERVER=$(parse_ssh_dest "$cmd")
  echo "ssh context: tty=[$session_tty] host=[$SERVER]"
  [ -n "$SERVER" ]
}

read_micro_selection() {
  local micro_socket response payload parsed micro_cwd context_cmd
  [ -n "$tmux_pane" ] || return 0
  resolve_ssh_context
  context_cmd=$cmd
  if [ -z "$SERVER" ] && [ -n "$session_tty" ]; then
    context_cmd=$(ps -t "${session_tty#/dev/}" -o command= | grep -E '^([^ ]*/)?tmux( |$)' | head -1)
  fi
  [ -n "$context_cmd" ] || return 0
  # tmux -CC を起動した接続と同じ socket に限定し、別 server の同じ pane 番号を読まない。
  micro_socket=$(perl -MText::ParseWords=shellwords -e '
    sub find_socket {
      my ($line, $depth) = @_;
      return "" if $depth > 2;
      my @words = shellwords($line);
      for (my $i = 0; $i < @words; $i++) {
        next unless $words[$i] =~ m{(?:^|/)tmux$};
        for (my $j = $i + 1; $j + 1 < @words; $j++) {
          return $words[$j + 1] if $words[$j] eq "-S";
        }
      }
      for my $word (@words) {
        next unless $word =~ /\s/ && $word =~ /tmux/;
        my $found = find_socket($word, $depth + 1);
        return $found if length($found);
      }
      return "";
    }
    print find_socket($ARGV[0], 0);
  ' "$context_cmd")
  [ -n "$micro_socket" ] || return 0
  case "$tmux_pane" in %*) ;; *) tmux_pane="%$tmux_pane" ;; esac

  response=$({
    cat <<'REMOTE'
provider=$(command -v board 2>/dev/null)
if [ -z "$provider" ]; then
  for candidate in "$HOME/ai-playbook/shared/skills/board/scripts/board" "$HOME/git/ai-playbook/shared/skills/board/scripts/board"; do
    if [ -x "$candidate" ]; then provider=$candidate; break; fi
  done
fi
printf '@@MICRO\n'
REMOTE
    printf 'if [ -n "$provider" ]; then "$provider" selection --socket %s --pane %s; else printf '\''%%s\\n'\'' '\''{"selection":"","cwd":""}'\''; fi\n' \
      "$(shq "$micro_socket")" "$(shq "$tmux_pane")"
    printf '%s\n' 'status=$?; printf '\''\n@@MICRO_END\n'\''; exit "$status"'
  } | run_selection_query) \
    || fail "$(msg down_unreadable "$LOG")"
  payload=$(printf '%s\n' "$response" | sed -n '/^@@MICRO$/,/^@@MICRO_END$/{/^@@/d;p;}')
  parsed=$(MICRO_RESULT="$payload" osascript -l JavaScript -e '
ObjC.import("Foundation");
var data = JSON.parse($.NSProcessInfo.processInfo.environment.objectForKey("MICRO_RESULT").js);
if (typeof data.selection !== "string" || typeof data.cwd !== "string" ||
    (data.selection && data.cwd.charAt(0) !== "/")) throw Error("micro の応答を読めない");
data.cwd + "\u001f" + data.selection + "\u001f";
') || fail "$(msg down_unreadable "$LOG")"
  micro_cwd=${parsed%%"$US"*}
  selection=${parsed#*"$US"}
  selection=${selection%"$US"}
  if [ -n "$selection" ]; then
    cwd=$micro_cwd
    selection_source=micro
    selection_length=""
  fi
}

run_selection_query() {
  if [ -n "$SERVER" ]; then
    ssh -o BatchMode=yes -o ClearAllForwardings=yes -o ConnectTimeout=10 "$SERVER" 'sh -s'
  else
    sh -s
  fi
}

read_fallback_selection() {
  read_micro_selection
  [ -z "$selection" ] || return 0
  # 末尾の改行もパスの選択として保ち、クリップボード自体は変更しない。
  selection=$(pbpaste && printf '%s' "$US") || fail "$(msg down_unreadable "$LOG")"
  selection=${selection%"$US"}
  selection_source=clipboard
  selection_length=""
}
