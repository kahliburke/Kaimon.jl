# ACP lab environment. Source before running anything under dev/acp:
#
#     source dev/acp/env.sh
#
# Everything the lab starts keeps its state and its ports away from the primary
# Kaimon/Slate install, so a wedged experiment can't corrupt the real one and
# both can run at once.

ACPLAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)/.acplab"
export ACPLAB_ROOT

# XDG is the whole isolation story: Kaimon, KaimonSlate and opencode all resolve
# their config, cache and data through it. Redirecting these three moves every
# credential file, session store and log into the lab directory.
export XDG_CONFIG_HOME="$ACPLAB_ROOT/config"
export XDG_CACHE_HOME="$ACPLAB_ROOT/cache"
export XDG_DATA_HOME="$ACPLAB_ROOT/data"

# Ports, offset from each service's default so a lab process and the primary
# install can be up simultaneously.
export ACPLAB_OPENCODE_PORT=4196        # `opencode serve`, default 4096
export KAIMON_EVENT_PUB_TCP_PORT=5757   # Kaimon event bus
export KAIMONSLATE_PORT=2830            # Slate hub, `slate --ai` default 2828
export KAIMONSLATE_HOME="$ACPLAB_ROOT/slate"
export KAIMONSLATE_NO_AUTOREGISTER=1    # never advertise into the primary registry

# Ollama is shared with the host on its default port: inference is read-only and
# the models are large enough that a second copy isn't worth the disk.
export ACPLAB_OLLAMA_URL="${ACPLAB_OLLAMA_URL:-http://localhost:11434/v1}"
export ACPLAB_MODEL="${ACPLAB_MODEL:-ollama/qwen2.5:14b}"

# `opencode acp` also opens a control port; 0 would be ephemeral (fine for
# concurrent probes), we pin it so a stray process is identifiable by port.
export ACPLAB_AGENT_CMD="${ACPLAB_AGENT_CMD:-opencode acp --port $ACPLAB_OPENCODE_PORT}"

mkdir -p "$XDG_CONFIG_HOME/opencode" "$XDG_CACHE_HOME" "$XDG_DATA_HOME/opencode" "$ACPLAB_ROOT/logs"

# `opencode auth login` writes to whichever XDG_DATA_HOME was set when it ran, so
# a login done in a normal shell lands in the primary install and the lab then
# sees only the unauthenticated free tier. Seed a copy rather than make the login
# itself a step you have to remember to run inside the lab environment.
if [ ! -f "$XDG_DATA_HOME/opencode/auth.json" ] && [ -f "$HOME/.local/share/opencode/auth.json" ]; then
  cp "$HOME/.local/share/opencode/auth.json" "$XDG_DATA_HOME/opencode/auth.json"
  chmod 600 "$XDG_DATA_HOME/opencode/auth.json"
fi

# The checked-in files are the source of truth; the XDG copies are disposable, so
# editing under dev/acp and re-sourcing is the way to change providers or hooks.
_acpsrc="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
cp "$_acpsrc/opencode.json" "$XDG_CONFIG_HOME/opencode/opencode.json"

# `plugin/`, singular — the docs say `plugins/`, which loads nothing. Measured by
# counting plugin.loaded records with each directory present on its own.
mkdir -p "$XDG_CONFIG_HOME/opencode/plugin"
cp "$_acpsrc/plugin/"*.js "$XDG_CONFIG_HOME/opencode/plugin/"
unset _acpsrc

echo "acplab: XDG -> $ACPLAB_ROOT, model $ACPLAB_MODEL"
