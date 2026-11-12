# Shared by the tic-check hooks (prepended to each script by its
# package wrapper, after `table=` is set to the JSON array of
# {name, pattern, ignore, rule} rendered from ticChecks and
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
# tic_push_back_above KIND prints the probability at or above which a
# dimension with pushBack set is a finding for text of KIND:
# judge.writePushBackAbove for a write (prose, code, or message), since
# a write stays in the repository after the turn, and
# judge.pushBackAbove for a reply or a progress message.
#
# tic_findings TEXT [VERDICT [KIND]] prints one block per finding, or
# nothing when TEXT is clean.  A finding is either a regex entry that
# matched or a dimension the judge is confident about:
#   - A regex entry prints its name, the occurrence count, the rule,
#     and up to three matching lines.  Code fences and backtick spans
#     are removed before matching: quoted paths, commands, and output
#     are not the model's prose.  An entry's ignore pattern, when it
#     is set, removes more text before that entry is matched.  Patterns
#     are GNU grep EREs, matched case-insensitively.
#   - A dimension with pushBack set that the judge put at or above
#     tic_push_back_above KIND (KIND defaults to reply) prints its
#     name, the probability, its rule, and its `true` criterion.

tic_push_back_above() {
  case $1 in
    prose | code | message) jq -r '.writePushBackAbove' "$judge" 2>/dev/null ;;
    *) jq -r '.pushBackAbove' "$judge" 2>/dev/null ;;
  esac
}

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
  local text=$1 verdict=${2:-} kind=${3:-reply} prose matched name pattern ignore rule hits count lines at
  # The backticks are literal markdown fence and span markers.
  # shellcheck disable=SC2016
  prose=$(sed -e '/^[[:space:]]*```/,/^[[:space:]]*```/d' -e 's/`[^`]*`//g' <<<"$text")
  while IFS= read -r name && IFS= read -r pattern && IFS= read -r ignore && IFS= read -r rule; do
    # An entry's ignore pattern removes text (quotations, compound
    # nouns) from the prose this entry alone is matched against.  The
    # sed delimiter is the control character \001, which no pattern
    # contains.
    matched=$prose
    if [ -n "$ignore" ]; then
      matched=$(sed -E -e $'s\001'"$ignore"$'\001\001gI' <<<"$prose" 2>/dev/null) || matched=$prose
    fi
    hits=$(grep -n -i -E -- "$pattern" <<<"$matched" 2>/dev/null) || continue
    count=$(grep -o -i -E -- "$pattern" <<<"$matched" | wc -l)
    # The lines that matched, so the model can find them without
    # re-reading the whole text; each cut to keep the reason short.
    lines=$(head -n 3 <<<"$hits" | cut -c1-160 | sed 's/^\([0-9]*\):/    line \1: /')
    printf '\n- %s (%s): %s\n%s' "$name" "$count" "$rule" "$lines"
  done < <(jq -r '.[] | .name, .pattern, (.ignore // ""), .rule' "$table" 2>/dev/null)
  [ -n "$verdict" ] || return 0
  at=$(tic_push_back_above "$kind") || return 0
  jq -j --slurpfile c "$judge" --argjson at "$at" '
    $c[0] as $c
    | .answers | to_entries[]
    | $c.dimensions[.key] as $d
    | select($d != null and $d.pushBack and .value >= $at)
    | "\n- \(.key) (judge \((.value * 100 | round) / 100)): \($d.rule)\n    the judge read the text as: \($d.criteria.true)"
  ' <<<"$verdict" 2>/dev/null || true
}
