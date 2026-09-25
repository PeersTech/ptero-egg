#!/bin/bash
# Pterodactyl entrypoint. Wings replaces {{VARIABLES}} in the egg's startup
# command and passes the result as STARTUP; we expand it and exec it.
set -euo pipefail

cd /home/container || exit 1

# Tell the panel which address the node is on, since the container only ever
# sees its internal IP.
printf '\033[1;36mpeers container booting\033[0m\n'

# Convert Wings' {{VARIABLE}} placeholders to shell parameter expansions. The
# resulting command is intentionally passed as one quoted argument to bash;
# interpreting it in the entrypoint would execute twice and could interpret
# command substitutions in the command before bash -c receives it.
MODIFIED_STARTUP="$(printf '%s' "${STARTUP:-}" | sed -e 's/{{/${/g' -e 's/}}/}/g')"
printf '\033[1;33m:/home/container$\033[0m %s\n' "$MODIFIED_STARTUP"

# bash -c is the boundary where Wings' placeholders are expanded. Quoting the
# command here preserves Pterodactyl's normal shell startup behavior without
# an extra shell interpretation in the entrypoint.
exec bash -c "$MODIFIED_STARTUP"
