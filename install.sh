#!/bin/bash
# Peers node. Pterodactyl installation script.
#
# Runs in a throwaway Debian container with the server's data volume mounted
# at /mnt/server. Nothing outside /mnt/server survives.
#
# This file is the source of truth. `./build-egg.sh` embeds it into
# egg-peers-node.json, which is what you actually import into the panel.

set -euo pipefail

INSTALL_METHOD="${INSTALL_METHOD:-source}"
PEERS_REF="${PEERS_REF:-main}"
PEERS_REPO="${PEERS_REPO:-https://github.com/PeersTech/Peers.git}"

say() { printf '\n\033[1;36m[peers]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[peers] %s\033[0m\n' "$*" >&2; exit 1; }

mkdir -p /mnt/server
say "install method: ${INSTALL_METHOD}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl git file jq

# --------------------------------------------------------------------------
# The node's identity is its peer ID. Every client stores that ID in its
# nodes.json, so losing this file silently breaks every one of them. They
# keep dialling an address that now answers as somebody else. Nothing below
# writes to this path, but say so loudly either way.
# --------------------------------------------------------------------------
IDENTITY="/mnt/server/.config/peers/node_identity.json"
if [ -f "${IDENTITY}" ]; then
    say "existing node identity found, peer ID will not change"
else
    say "no existing identity; one will be generated on first boot"
fi
mkdir -p /mnt/server/.config/peers

case "${INSTALL_METHOD}" in
release)
    say "looking for a published release binary"
    API="https://api.github.com/repos/PeersTech/Peers/releases/latest"
    URL="$(curl -fsSL "${API}" 2>/dev/null \
        | jq -r '.assets[]?.browser_download_url | select(test("linux|x86_64"))' \
        | head -n1 || true)"

    if [ -z "${URL}" ] || [ "${URL}" = "null" ]; then
        die "No release asset found.

PeersTech/Peers has not published any GitHub Releases yet, so there is
nothing for this option to download. Until a release is cut, set the
INSTALL_METHOD variable to 'source' and reinstall.

(If you have just published one, make sure the asset filename contains
'linux' or 'x86_64' so this script can identify it.)"
    fi

    say "downloading ${URL}"
    curl -fsSL -o /mnt/server/peers "${URL}" || die "download failed"
    ;;

source)
    say "installing build dependencies (this is the slow part)"
    # Tauri is an unconditional dependency of the crate, so even the headless
    # --node build links against webkit/GTK and needs their -dev packages
    # present at compile time.
    apt-get install -y -qq --no-install-recommends \
        build-essential pkg-config \
        libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev \
        librsvg2-dev patchelf libxdo-dev libssl-dev

    say "installing rust"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --default-toolchain stable >/dev/null
    # shellcheck disable=SC1091
    . "${HOME}/.cargo/env"

    say "cloning ${PEERS_REPO} @ ${PEERS_REF}"
    rm -rf /tmp/peers
    git clone --depth 1 --branch "${PEERS_REF}" "${PEERS_REPO}" /tmp/peers \
        || die "clone failed. Is PEERS_REF '${PEERS_REF}' a real branch or tag?"
    cd /tmp/peers

    # ---------------------------------------------------------------------
    # tauri_build::build() runs generate_context!(), which reads the compiled
    # frontend from frontend/dist. That directory is gitignored, so it does
    # not exist in a fresh clone and the build dies with an error that never
    # mentions the frontend. A node serves no UI, so a stub is enough.
    # Upstream CI does exactly this.
    # ---------------------------------------------------------------------
    mkdir -p frontend/dist
    if [ ! -f frontend/dist/index.html ]; then
        printf '<!doctype html><title>peers node</title>' > frontend/dist/index.html
    fi

    # backend/ is a standalone crate, not a workspace member.
    cd backend

    # Linking a full Tauri binary is memory-hungry; unbounded parallelism is
    # what turns a slow install into an OOM kill on a small node.
    JOBS="${CARGO_BUILD_JOBS:-2}"
    say "building (jobs=${JOBS}). Expect 10-25 minutes on a small VPS"
    cargo build --release --jobs "${JOBS}" \
        || die "cargo build failed.

The usual cause is the install container running out of memory while
linking. Give this server more RAM for the install, or lower the
CARGO_BUILD_JOBS variable to 1 and reinstall."

    cp target/release/peers /mnt/server/peers
    ;;

*)
    die "unknown INSTALL_METHOD '${INSTALL_METHOD}' (expected 'source' or 'release')"
    ;;
esac

chmod +x /mnt/server/peers
file /mnt/server/peers || true

# --------------------------------------------------------------------------
# Launcher. This exists rather than putting everything in the egg's startup
# command because two of the variables cannot be passed unconditionally:
#
#   PEERS_NO_RELAY is presence-checked by the node (`env::var(..).is_ok()`),
#   so exporting it as an empty string still disables relaying, silently
#   turning a relay node into one that forwards nothing.
#
#   PEERS_ANNOUNCE must carry the same port the node is listening on, and
#   getting that pairing wrong is the single most common node misconfiguration.
#   Building it here from SERVER_PORT means it cannot drift.
# --------------------------------------------------------------------------
cat > /mnt/server/start.sh <<'LAUNCHER'
#!/bin/bash
set -u
cd /home/container || exit 1

PORT="${SERVER_PORT:-4001}"
export PEERS_PORT="${PORT}"

# Cloud and container hosts almost never have the public IP on the interface
# the node can see, so it cannot work this out for itself.
IP="${PEERS_PUBLIC_IP:-}"
if [ "${IP}" = "auto" ]; then
    IP="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    if [ -z "${IP}" ]; then
        echo "[peers] could not auto-detect a public IP; set PEERS_PUBLIC_IP manually" >&2
    else
        echo "[peers] detected public IP: ${IP}"
    fi
fi

# An explicit PEERS_ANNOUNCE always wins, for setups this cannot express
# (IPv6, DNS names, a different external port).
if [ -n "${PEERS_ANNOUNCE:-}" ]; then
    export PEERS_ANNOUNCE
elif [ -n "${IP}" ]; then
    export PEERS_ANNOUNCE="/ip4/${IP}/tcp/${PORT},/ip4/${IP}/udp/${PORT}/quic-v1"
fi

if [ -n "${PEERS_NODES:-}" ]; then
    export PEERS_NODES
else
    unset PEERS_NODES
fi

# Presence, not value, is what disables relaying, so only set it when on.
case "${PEERS_NO_RELAY:-0}" in
    1|true|TRUE|yes|on) export PEERS_NO_RELAY=1 ;;
    *)                  unset PEERS_NO_RELAY ;;
esac

echo "[peers] port ${PEERS_PORT} (tcp+udp)  announce=${PEERS_ANNOUNCE:-<none>}"
exec ./peers --node
LAUNCHER
chmod +x /mnt/server/start.sh

say "install complete"
