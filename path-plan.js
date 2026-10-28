// 選択全体を覆う実在パスの組み合わせを探す。SSH先にはPOSIX shだけを要求する。
ObjC.import("Foundation");

function env(key) {
  const value = $.NSProcessInfo.processInfo.environment.objectForKey(key);
  return value.isNil() ? "" : value.js;
}

function read(path) {
  const value = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  if (value.isNil()) throw Error("照合結果を読めません: " + path);
  return value.js;
}

function write(path, value) {
  if (!$(value).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)) {
    throw Error("照合結果を保存できません: " + path);
  }
}

function shq(value) { return "'" + value.replace(/'/g, "'\\''") + "'"; }

function trimStart(value) { return value.replace(/^[\s│┃║`'"「『<\[]+/, ""); }

function trimEnds(value) {
  let previous;
  do {
    previous = value;
    value = trimStart(value).replace(/[\s│┃║`'"」』>\],;:!?。、，．]+$/, "");
    if (/\)$/.test(value) && value.split("(").length < value.split(")").length) value = value.slice(0, -1);
    if (/\.$/.test(value)) value = value.slice(0, -1);
  } while (value !== previous);
  return value;
}

function head(path, cwd) {
  if (path === "~") return '"$HOME"';
  if (path.indexOf("~/") === 0) return '"$HOME"' + shq(path.slice(1));
  if (path.charAt(0) === "/") return shq(path);
  if (!cwd || !path) return null;
  return shq(cwd.replace(/\/$/, "") + "/" + path);
}

// 途中のパスの親が存在しなければ、後ろに文字を足しても実在パスにならない。
// 各長さの候補をまとめて照合し、不要な連結候補を次の照合へ持ち越さない。
function query(frontier, cwd) {
  const lines = [
    "probe() {",
    "  found=0; viable=0",
    '  if [ -f "$2" ] || [ -d "$2" ]; then found=1; fi',
    '  case "$3" in */*) parent=${3%/*}; [ -n "$parent" ] || parent=/ ;; *) parent=. ;; esac',
    '  if [ -d "$parent" ]; then viable=1; fi',
    "  printf '@@PROBE %s %s %s\\n' \"$1\" \"$found\" \"$viable\"",
    "}"
  ];
  frontier.forEach(function (item, index) {
    lines.push("probe " + index + " " + head(trimEnds(item.text), cwd) + " " + head(trimStart(item.text), cwd));
  });
  return lines.join("\n") + "\n";
}

function solutions(state) {
  const count = [], first = [], n = state.parts.length;
  count[n] = 1;
  first[n] = [];
  for (let start = n - 1; start >= 0; start--) {
    count[start] = 0;
    state.edges.forEach(function (edge) {
      if (edge.start !== start || !count[edge.end]) return;
      if (!count[start]) first[start] = [edge.path].concat(first[edge.end]);
      count[start] = Math.min(1000000, count[start] + count[edge.end]);
    });
  }
  return { count: count[0], paths: first[0] };
}

function downloadQuery(paths, cwd, confirmBytes) {
  const lines = ["set -e"];
  // すべてのパスを再確認してから、個々のメタデータと小さいファイルを返す。
  paths.forEach(function (path) {
    lines.push("p=" + head(path, cwd), '[ -f "$p" ] || [ -d "$p" ] || exit 1');
  });
  paths.forEach(function (path, index) {
    lines.push(
      "p=" + head(path, cwd),
      "printf '@@ITEM " + index + "\\n'",
      'printf \'@@CAND %s\\n\' "$p"',
      'if [ -d "$p" ]; then',
      '  printf \'@@DIR %s %s\\n\' "$(du -sk "$p" | cut -f1)" "$(find "$p" -type f | wc -l | tr -d \' \')"',
      "else",
      '  bytes=$(wc -c < "$p" | tr -d \' \')',
      '  printf \'@@FILE %s\\n\' "$bytes"',
      '  if [ "$bytes" -le ' + confirmBytes + " ]; then",
      '    printf \'\\n@@BEGIN\\n\'; base64 < "$p"; printf \'\\n@@END\\n\'',
      "  fi",
      "fi",
      "printf '@@ITEMEND " + index + "\\n'"
    );
  });
  return lines.join("\n") + "\n";
}

function run(args) {
  if (args.length !== 4 || ["init", "advance"].indexOf(args[0]) < 0) {
    throw Error("引数: init|advance STATE_FILE QUERY_FILE RESPONSE_FILE。init の RESPONSE_FILE は空文字にする");
  }
  const stage = args[0], statePath = args[1], queryPath = args[2], responsePath = args[3];
  let state;
  if (stage === "init") {
    const selection = env("SEL"), length = env("SELLEN") === "" ? selection.length : Number(env("SELLEN"));
    if (length > Number(env("SELMAX"))) return "too_long\n" + length;
    if (length > selection.length) return "truncated\n" + selection.length;
    const text = trimEnds(selection);
    const edge = "[ \\t\\u3000\\u2502\\u2503\\u2551]*";
    const junction = new RegExp(edge + "\\r?\\n" + edge, "g");
    if (/^https?:\/\//.test(text)) return "url\n" + text.replace(junction, "").replace(/\s+/g, "");
    const parts = text.split(junction).filter(function (part) { return part !== ""; });
    if (!parts.length) return "not_found";
    state = { parts: parts, cwd: env("CWD"), frontier: [], edges: [], examined: 0 };
    if (!head(trimEnds(parts[0]), state.cwd)) return "no_cwd";
    parts.forEach(function (part, index) {
      if (head(trimEnds(part), state.cwd)) state.frontier.push({ start: index, end: index + 1, text: part });
    });
  } else {
    state = JSON.parse(read(statePath));
    const flags = Object.create(null);
    read(responsePath).split("\n").forEach(function (line) {
      const match = /^@@PROBE (\d+) ([01]) ([01])$/.exec(line);
      if (!match) return;
      const id = Number(match[1]);
      if (id >= state.frontier.length || flags[id]) throw Error("照合結果が重複または範囲外です");
      flags[id] = { found: match[2] === "1", viable: match[3] === "1" };
    });
    const next = [], seen = Object.create(null);
    state.frontier.forEach(function (item, index) {
      if (!flags[index]) throw Error("照合結果が足りません");
      if (flags[index].found) {
        const path = trimEnds(item.text);
        if (!state.edges.some(function (edge) { return edge.start === item.start && edge.end === item.end && edge.path === path; })) {
          state.edges.push({ start: item.start, end: item.end, path: path });
        }
      }
      if (!flags[index].viable || item.end === state.parts.length) return;
      ["", " ", "\u3000"].forEach(function (separator) {
        const text = item.text + separator + state.parts[item.end];
        const key = JSON.stringify([item.start, text]);
        if (seen[key]) return;
        seen[key] = true;
        next.push({ start: item.start, end: item.end + 1, text: text });
      });
    });
    state.examined += state.frontier.length;
    state.frontier = next;
    const result = solutions(state);
    if (result.count > 1) return "ambiguous\n" + result.count;
    if (!next.length) {
      if (!result.count) return "not_found";
      // 同じパスを繰り返し選択したときは、一度だけ保存する。
      const paths = result.paths.filter(function (path, index, all) { return all.indexOf(path) === index; });
      write(queryPath, downloadQuery(paths, state.cwd, Number(env("CONFIRM_BYTES"))));
      return "resolved\n" + paths.length;
    }
  }
  // 候補を省略して一意と誤判定しない。複雑すぎる選択は、受信する前に停止する。
  if (state.examined + state.frontier.length > 20000) return "too_complex";
  write(statePath, JSON.stringify(state));
  write(queryPath, query(state.frontier, state.cwd));
  return "remote";
}
