# Shared by the hooks that run while the user waits on a turn (prepended
# to each script by its package wrapper, after `judge=` is set to the
# rendered judge config).
#
# tic_wake_endpoints starts the systemd user unit of every judge
# endpoint that names one (judge.endpoints.<name>.wakeUnit) and does not
# wait for it: `systemctl --user start --no-block` queues the start and
# returns, and starting a unit that is already running does nothing.  A
# server that takes a while to load is then usually up by the time the
# Stop hook asks it.  systemctl comes from the PATH of the session, the
# one that matches the running systemd; without it the hooks go on with
# the endpoints as they are.

tic_wake_endpoints() {
  local unit
  command -v systemctl > /dev/null 2>&1 || return 0
  while IFS= read -r unit; do
    [ -z "$unit" ] || systemctl --user start --no-block "$unit" > /dev/null 2>&1 || true
  done < <(jq -r '.endpoints[] | .wakeUnit // empty' "$judge" 2>/dev/null)
}
