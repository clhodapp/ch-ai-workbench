# Shared by the tic-check hooks (prepended to each script by its
# package wrapper, after `table=` is set to the JSON array of
# {name, pattern, rule} rendered from ticChecks).
#
# tic_findings TEXT prints one block per matching entry -- the entry
# name, the occurrence count, the rule, and up to three matching
# lines -- or nothing when TEXT is clean.  Code fences and backtick
# spans are removed first: quoted paths, commands, and output are not
# the model's prose.  Patterns are GNU grep EREs, matched
# case-insensitively.

tic_findings() {
  local text=$1 prose name pattern rule hits count lines
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
}
