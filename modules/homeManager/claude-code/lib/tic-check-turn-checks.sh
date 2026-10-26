# Shared by the tic-check Stop hook and the write hooks (prepended by
# each package wrapper after `judge=` is set to the rendered judge
# config; the claude-response-judge package is on PATH).
#
# tic_turn_checks MESSAGE TRANSCRIPT VERDICT runs the checks that look at
# the final message of a turn beside the session, and prints one JSON
# object {"findings": TEXT, "report": {"load", "coinage", "references"}}.
# findings is blocks in tic_findings' format, for the check/clean/tic
# cycle; report holds what reached a report level but not a finding,
# for the context hook.
#   - load: claude-turn-load scores the final message from its prose
#     words, the information-density score in VERDICT, and the prompt
#     that opened the turn (judge.load).
#   - coinage: claude-coinage-check finds phrases the assistant coined
#     and has the judge score each one (judge.coinage).
#   - references: claude-reference-check finds references the user
#     cannot resolve (judge.references).
# A check that is disabled, has no transcript, or fails contributes
# nothing.
#
# tic_write_coinage TEXT TRANSCRIPT prints the same object for a durable
# write (a prose file, a commit message, a pull request text), from the
# coinage check alone, which then counts the write as a use.
#
# tic_write_ghosts TEXT REPLACED TRANSCRIPT prints {"findings": TEXT,
# "report": [SENTENCE, ...]} for a prose write: claude-ghost-check asks
# the judge about each sentence that may argue with ghosts (judge.ghosts),
# a sentence at the push-back level is a finding, and one at the report
# level goes in report.

tic_json_or_null() { # $1 = text; prints it when it is JSON, else null
  if [ -n "$1" ] && jq -e . >/dev/null 2>&1 <<<"$1"; then printf '%s' "$1"; else printf 'null'; fi
}

tic_check_enabled() { # $1 = config section
  jq -e --arg s "$1" '.[$s].enable' "$judge" >/dev/null 2>&1
}

tic_assemble_checks() { # $1 = load JSON, $2 = coinage JSON, $3 = references JSON
  jq -cn --slurpfile c "$judge" --argjson load "$1" --argjson coinage "$2" --argjson references "$3" '
    $c[0] as $c
    | def two: (. * 100 | round) / 100;
    ([($coinage.candidates // [])[] | select(.action == "block")]) as $coined
    | {
        findings: (
          (if $load != null and $load.score >= $c.load.pushBackAbove then
             ["\n- too-much-at-once (load \($load.score | two), \($load.words) words): \($c.load.rule)"]
           else [] end)
          + [$coined[]
             | "\n- coined-phrase \"\(.phrase)\" (judge \(.score | two)): \($c.coinage.rule)"
               + (if .real_name then "; the real name may be `\(.real_name)`" else "" end)
               + "\n    \(.sentence)"]
          + (if ($references.block // false) then
               ["\n- unresolvable-references (\($references.flags | length)): \($c.references.rule)"]
               + [$references.flags[] | "\n    \(.reference): \(.sentence)"]
             else [] end)
          | join("")
        ),
        report: {
          load: (if $load != null and $load.score >= $c.load.reportAbove and $load.score < $c.load.pushBackAbove
                 then $load else null end),
          coinage: [($coinage.candidates // [])[] | select(.action == "report")],
          references: (if ($references.block // false) then [] else ($references.flags // []) end)
        }
      }' 2>/dev/null
}

# Each hook that includes this file calls one of the next two.
# shellcheck disable=SC2329
tic_turn_checks() {
  local message=$1 transcript=$2 verdict=$3 load=null coinage=null references=null density=
  if [ -n "$verdict" ] && tic_check_enabled load; then
    density=$(jq -r '.scores["information-density"].score // empty' <<<"$verdict" 2>/dev/null) || density=
    if [ -n "$density" ]; then
      if [ -n "$transcript" ]; then
        load=$(tic_json_or_null "$(claude-turn-load --density "$density" --transcript "$transcript" <<<"$message" 2>/dev/null)")
      else
        load=$(tic_json_or_null "$(claude-turn-load --density "$density" <<<"$message" 2>/dev/null)")
      fi
    fi
  fi
  if [ -n "$transcript" ] && tic_check_enabled coinage; then
    coinage=$(tic_json_or_null "$(claude-coinage-check --config "$judge" --transcript "$transcript" <<<"$message" 2>/dev/null)")
  fi
  if [ -n "$transcript" ] && tic_check_enabled references; then
    references=$(tic_json_or_null "$(claude-reference-check --config "$judge" --transcript "$transcript" <<<"$message" 2>/dev/null)")
  fi
  tic_assemble_checks "$load" "$coinage" "$references"
}

# shellcheck disable=SC2329
tic_write_coinage() {
  local text=$1 transcript=$2 coinage=null
  if [ -n "$transcript" ] && tic_check_enabled coinage; then
    coinage=$(tic_json_or_null "$(claude-coinage-check --config "$judge" --transcript "$transcript" --write <<<"$text" 2>/dev/null)")
  fi
  tic_assemble_checks null "$coinage" null
}

# shellcheck disable=SC2329
tic_write_ghosts() {
  local text=$1 replaced=$2 transcript=$3 file='' args=() ghosts=null
  if tic_check_enabled ghosts; then
    if [ -n "$replaced" ] && file=$(mktemp 2>/dev/null); then
      printf '%s' "$replaced" > "$file" 2>/dev/null && args=(--replaced "$file")
    fi
    [ -z "$transcript" ] || args+=(--transcript "$transcript")
    ghosts=$(tic_json_or_null "$(claude-ghost-check --config "$judge" "${args[@]}" <<<"$text" 2>/dev/null)")
    [ -z "$file" ] || rm -f "$file" 2>/dev/null || true
  fi
  jq -cn --slurpfile c "$judge" --argjson g "$ghosts" '
    $c[0] as $c
    | ($g.sentences // []) as $s
    | {findings: ([$s[] | select(.action == "block")
                   | "\n- arguing-with-ghosts (judge \((.p * 100 | round) / 100)): \($c.ghosts.rule)\n    sentence: \(.sentence)"]
                  | add // ""),
       report: [$s[] | select(.action == "report")]}
  ' 2>/dev/null || printf '{"findings": "", "report": []}'
}
