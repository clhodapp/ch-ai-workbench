# Claude Code MessageDisplay hook: render ```mermaid fences in the
# streaming assistant message and append one "diagram: <svg>:1" line
# under each, which ghostel's plain file:line detection linkifies
# (the :1 satisfies its required :LINE tail).  Display-only -- the
# stored message and what the model sees keep the bare fence (probed
# facts in docs/development/claude-cli.md "MessageDisplay hooks").
#
# Interactive sessions flush batches of whole completed lines under a
# stable message_id, so a fence can span flushes; deltas are spooled
# per message and complete blocks render as the flush with their
# closing fence arrives -- the SVG therefore exists before the link
# is displayed, which matters because ghostel's detector checks
# file-exists-p when it scans.  Headless sessions deliver the whole
# message in one flush and take the same path.
#
# SVGs are content-addressed (sha256 of the fence body, 12 hex chars)
# in the render-dwim cache under XDG_CACHE_HOME, so the render-dwim
# command and this hook produce the same file and a resumed session
# (where MessageDisplay does not re-fire; probed) can re-render to
# the identical name.  A per-message .done list keeps one link per
# block however many flushes follow.  A quoted ```mermaid fence
# inside a larger fence renders too; that is accepted noise.
#
# Every branch fails open: a broken diagram appends a legible failure
# line, anything else exits 0 silently so a session never blocks on
# rendering.

shopt -s nullglob

payload=$(cat) || exit 0

delta=$(jq -r '.delta // empty' <<<"$payload" 2>/dev/null) || exit 0
[ -n "$delta" ] || exit 0
message_id=$(jq -r '.message_id // empty' <<<"$payload" 2>/dev/null) || exit 0
[ -n "$message_id" ] || exit 0
final=$(jq -r 'if .final == true then "yes" else "no" end' \
  <<<"$payload" 2>/dev/null) || final=no

cache="${XDG_CACHE_HOME:-$HOME/.cache}/render-dwim"
spool="$cache/spool"
mkdir -p "$cache" "$spool" 2>/dev/null || exit 0
chmod 700 "$cache" "$spool" 2>/dev/null || true

msg="$spool/${message_id//[^A-Za-z0-9_-]/}"
printf '%s\n' "$delta" >> "$msg.txt" 2>/dev/null || exit 0

finish() {
  if [ "$final" = yes ]; then
    rm -f "$msg.txt" "$msg.done" 2>/dev/null || true
    # Orphans from interrupted sessions, and last month's diagrams.
    find "$spool" -type f -mmin +1440 -delete 2>/dev/null || true
    find "$cache" -maxdepth 1 -name '*.svg' -mtime +30 -delete \
      2>/dev/null || true
  fi
}

# Fast path: this flush closes no fence.
if ! grep -q '^[[:space:]]*```[[:space:]]*$' <<<"$delta"; then
  finish
  exit 0
fi

config="$cache/htmlLabels-off.json"
# librsvg (Emacs's SVG renderer) silently drops <foreignObject>;
# htmlLabels false makes mermaid emit native <text> labels (both
# keys needed: top-level covers edge labels, flowchart node labels).
[ -s "$config" ] || printf '%s' \
  '{"htmlLabels": false, "flowchart": {"htmlLabels": false}}' \
  > "$config" 2>/dev/null || { finish; exit 0; }

blocks=$(mktemp -d) || { finish; exit 0; }
trap 'rm -rf "$blocks"' EXIT

# Every complete ```mermaid block in the accumulated message, one
# file per block, fence lines excluded.  A stray closing fence (from
# a non-mermaid block) matches neither rule and is ignored.
awk -v dir="$blocks" '
  inb && /^[[:space:]]*```[[:space:]]*$/ { inb = 0; close(dir "/" n); next }
  /^[[:space:]]*```mermaid[[:space:]]*$/ { inb = 1; n++; next }
  inb { print > (dir "/" n) }
' "$msg.txt" 2>/dev/null || { finish; exit 0; }

touch "$msg.done" 2>/dev/null || { finish; exit 0; }
links=""
for block in "$blocks"/*; do
  [ -s "$block" ] || continue
  hash=$(sha256sum "$block" | cut -c1-12) || continue
  # One link per block per message, however many flushes follow;
  # a failed render is recorded too rather than retried each flush.
  grep -qx "$hash" "$msg.done" 2>/dev/null && continue
  printf '%s\n' "$hash" >> "$msg.done" 2>/dev/null || true
  svg="$cache/$hash.svg"
  if [ ! -s "$svg" ]; then
    # Render beside the block first: merman validates the output
    # extension, and a partial file must never land in the cache.
    if ! out=$(timeout 5 merman-cli mmdc -i "$block" -o "$block.svg" \
                 -q -c "$config" 2>&1); then
      rm -f "$block.svg" 2>/dev/null || true
      first=$(printf '%s' "$out" | head -n 1 | cut -c1-160)
      links="$links"$'\n'"diagram: render failed: $first"
      continue
    fi
    mv -f "$block.svg" "$svg" 2>/dev/null || continue
  fi
  links="$links"$'\n'"diagram: $svg:1"
done

if [ -z "$links" ]; then
  finish
  exit 0
fi

jq -cn --arg t "$delta$links" \
  '{hookSpecificOutput: {hookEventName: "MessageDisplay", displayContent: $t}}' \
  2>/dev/null || true
finish
exit 0
