#!/bin/bash
# Pterodactyl entrypoint. Wings replaces {{VARIABLES}} in the egg's startup
# command and passes the result as STARTUP; we expand it and exec it.
cd /home/container || exit 1

# Tell the panel which address the node is on, since the container only ever
# sees its internal IP.
printf '\033[1;36mpeers container booting\033[0m\n'

MODIFIED_STARTUP=$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')
printf '\033[1;33m:/home/container$\033[0m %s\n' "$(eval echo "${MODIFIED_STARTUP}")"

# shellcheck disable=SC2086
exec env ${MODIFIED_STARTUP:+} bash -c "$(eval echo "${MODIFIED_STARTUP}")"
