# Shared by the tic-check hooks (prepended to each script by its
# package wrapper, after `table=` is set to the JSON array of
# {name, pattern, rule} rendered from ticChecks and
# `judge=` to the judge config rendered from judge.*; the
# claude-response-judge program is on PATH).
#
# tic_verdict KIND TEXT [REPLACED [TRANSCRIPT]] asks the judge (a System One
# decision model, local or in the cloud, whichever answers first) how
# likely each of the judge.dimensions that target KIND is in TEXT, and
# prints its verdict:
#   {"endpoint": NAME, "model": MODEL, "answers": {DIMENSION: P, ...}}
# or nothing when no endpoint answered or none is configured, in
# which case every hook behaves as it did with the regex table alone.
# KIND is reply, prose, or code; REPLACED is the text an edit replaces;
# TRANSCRIPT is the session transcript, whose latest user messages the
# judge sends as context.
#
# tic_findings TEXT [VERDICT] prints one block per finding, or
# nothing when TEXT is clean.  A finding is either a regex entry that
# matched or a dimension the judge is confident about:
#   - A regex entry prints its name, the occurrence count, the rule,
#     and up to three matching lines.  Code fences and backtick spans
#     are removed before matching: quoted paths, commands, and output
#     are not the model's prose.  Patterns are GNU grep EREs, matched
#     case-insensitively.
#   - A dimension with pushBack set that the judge put at or above
#     judge.pushBackAbove prints its name, the probability, its rule,
#     and its `true` criterion.

tic_verdict() {
  local kind=$1 text=$2 replaced=${3:-} transcript=${4:-} file='' args=()
  if [ -n "$replaced" ] && file=$(mktemp 2>/dev/null); then
    printf '%s' "$replaced" > "$file" 2>/dev/null && args=(--replaced "$file")
  fi
  [ -z "$transcript" ] || args+=(--transcript "$transcript")
  claude-response-judge --config "$judge" --kind "$kind" "${args[@]}" <<<"$text" 2>/dev/null || true
  [ -z "$file" ] || rm -f "$file" 2>/dev/null || true
}

tic_findings() {
  local text=$1 verdict=${2:-} prose name pattern rule hits count lines
  # The backticks are literal markdown fence and span markers.
  # shellcheck disable=SC2016
  prose=$(sed -e '/^[[:space:]]*```/,/^[[:space:]]*```/d' -e 's/`[^`]*`//g' <<<"$text")
  while IFS= read -r name && IFS= read -r pattern && IFS= read -r rule; do
    hits=$(grep -n -i -E -- "$pattern" <<<"$prose" 2>/dev/null) || continue
    count=$(grep -o -i -E -- "$pattern" <<<"$prose" | wc -l)
    # The lines that matched, so the model can find them without
    # re-reading the whole text; each cut to keep the reason short.
    lines=$(head -n 3 <<<"$hits" | cut -c1-160 | sed 's/^\([0-9]*\):/    line \1: /')
    printf '\n- %s (%s): %s\n%s' "$name" "$count" "$rule" "$lines"
  done < <(jq -r '.[] | .name, .pattern, .rule' "$table" 2>/dev/null)
  [ -n "$verdict" ] || return 0
  jq -j --slurpfile c "$judge" '
    $c[0] as $c
    | .answers | to_entries[]
    | $c.dimensions[.key] as $d
    | select($d != null and $d.pushBack and .value >= $c.pushBackAbove)
    | "\n- \(.key) (judge \((.value * 100 | round) / 100)): \($d.rule)\n    the judge read the text as: \($d.criteria.true)"
  ' <<<"$verdict" 2>/dev/null || true
}
