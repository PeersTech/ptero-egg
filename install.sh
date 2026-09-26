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
# Pinned to an immutable commit, not a branch. A tag or `main` can be moved
# after review, which would silently change what this egg builds. Override
# deliberately for local testing; production installs should stay pinned.
PEERS_REF="${PEERS_REF:-5ee4331402a5138f155bd342357c76aa0e11c0da}"
PEERS_REPO="${PEERS_REPO:-https://github.com/PeersTech/Peers.git}"
PEERS_RELEASE_SHA256="${PEERS_RELEASE_SHA256:-}"
RUSTUP_INIT_SHA256="${RUSTUP_INIT_SHA256:-}"
BUILD_DIR="/mnt/server/.peers-build"
RELEASE_ASSET="peers-linux-x86_64"

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
IDENTITY_DIR="/mnt/server/.config/peers"
IDENTITY="${IDENTITY_DIR}/node_identity.json"
if [ -f "${IDENTITY}" ]; then
    say "existing node identity found, peer ID will not change"
else
    say "no existing identity; one will be generated on first boot"
fi

# Do not pre-create this directory as root. The runtime container runs as the
# server user and must create node_identity.json on first boot. If an older
# install already created the config directory as root, repair the parent as
# well as the identity directory when Wings provides its runtime IDs. Repairing
# the existing tree recursively is important: changing only the directory
# leaves an old root-owned node_identity.json unreadable or unwritable.
if [ -d /mnt/server/.config ]; then
    if [ -n "${PUID:-}" ] || [ -n "${PGID:-}" ]; then
        if [ -z "${PUID:-}" ] || [ -z "${PGID:-}" ]; then
            die "PUID and PGID must be provided together so identity ownership can be recovered"
        fi
        case "${PUID}${PGID}" in
            *[!0-9]*)
                die "PUID and PGID must be numeric"
                ;;
        esac
        OWNER="${PUID}:${PGID}"
    else
        OWNER="$(stat -c '%u:%g' /mnt/server)"
    fi

    say "recovering ownership of /mnt/server/.config for ${OWNER}"
    chown "${OWNER}" -- /mnt/server/.config
    if [ -d "${IDENTITY_DIR}" ]; then
        chown -R "${OWNER}" -- "${IDENTITY_DIR}"
    fi
fi

case "${INSTALL_METHOD}" in
release)
    if [ "$(uname -m)" != "x86_64" ]; then
        die "release assets are currently x86_64-only; use INSTALL_METHOD=source on this host."
    fi
    if ! [[ "${PEERS_RELEASE_SHA256}" =~ ^[0-9a-fA-F]{64}$ ]]; then
        die "INSTALL_METHOD=release requires PEERS_RELEASE_SHA256, a 64-character SHA-256 checksum supplied from a trusted source"
    fi

    say "looking for the exact Linux x86_64 release asset"
    API="https://api.github.com/repos/PeersTech/Peers/releases/latest"
    ASSETS="$(curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL "${API}" 2>/dev/null \
        | jq -c --arg asset "${RELEASE_ASSET}" \
            '[.assets[]? | select(.name == $asset) | .browser_download_url]')" \
        || die "could not query the latest Peers release"

    if [ "$(jq 'length' <<<"${ASSETS}")" -ne 1 ]; then
        die "expected exactly one release asset named '${RELEASE_ASSET}'.

PeersTech/Peers has not published the exact Linux x86_64 binary required by
this egg, or the release contains duplicate assets. Set INSTALL_METHOD to
'source' and reinstall."
    fi
    URL="$(jq -r '.[0]' <<<"${ASSETS}")"
    case "${URL}" in
        https://github.com/PeersTech/Peers/releases/download/*/"${RELEASE_ASSET}")
            ;;
        *)
            die "the selected release asset did not resolve to the expected GitHub URL"
            ;;
    esac

    say "downloading ${URL}"
    DOWNLOAD_PATH="$(mktemp /mnt/server/.peers-release.XXXXXX)" \
        || die "could not create a temporary release download"
    if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL \
        -o "${DOWNLOAD_PATH}" "${URL}"; then
        rm -f -- "${DOWNLOAD_PATH}"
        die "release download failed"
    fi
    if ! printf '%s  %s\n' "${PEERS_RELEASE_SHA256,,}" "${DOWNLOAD_PATH}" \
        | sha256sum --check --status -; then
        rm -f -- "${DOWNLOAD_PATH}"
        die "release binary checksum verification failed; refusing to install it"
    fi
    say "release binary checksum verified"
    mv -- "${DOWNLOAD_PATH}" /mnt/server/peers
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
    # Fetch rustup-init as a file and verify it before executing it. Piping
    # straight into `sh` runs whatever the CDN serves at that moment with no
    # integrity check at all.
    RUSTUP_HOST="https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu"

    # The published checksum is the only trust anchor available in the install
    # container, so the operator has to supply it out of band.
    if ! [[ "${RUSTUP_INIT_SHA256}" =~ ^[0-9a-fA-F]{64}$ ]]; then
        die "RUSTUP_INIT_SHA256 is required and must be a 64-character SHA-256.

Fetch the published checksum and pass it as an install variable:

  RUSTUP_INIT_SHA256=\$(curl -fsSL ${RUSTUP_HOST}/rustup-init.sha256 | cut -d' ' -f1)

Verifying rustup-init is the only thing between a compromised mirror and root
on the host, so this is not optional."
    fi

    # BUILD_DIR does not exist yet (the clone happens below), so stage the
    # download in a directory we create here and clean up ourselves.
    RUSTUP_STAGE="$(mktemp -d /mnt/server/.rustup-stage.XXXXXX)" \
        || die "could not stage rustup-init"
    RUSTUP_BIN="${RUSTUP_STAGE}/rustup-init"
    if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL \
        -o "${RUSTUP_BIN}" "${RUSTUP_HOST}/rustup-init"; then
        rm -rf -- "${RUSTUP_STAGE}"
        die "rustup-init download failed"
    fi
    if ! printf '%s  %s\n' "${RUSTUP_INIT_SHA256,,}" "${RUSTUP_BIN}" \
        | sha256sum --check --status -; then
        rm -rf -- "${RUSTUP_STAGE}"
        die "rustup-init checksum verification failed; refusing to execute it"
    fi
    say "rustup-init checksum verified"

    chmod +x "${RUSTUP_BIN}"
    if ! "${RUSTUP_BIN}" -y --profile minimal --default-toolchain stable >/dev/null; then
        rm -rf -- "${RUSTUP_STAGE}"
        die "rustup-init failed"
    fi
    rm -rf -- "${RUSTUP_STAGE}"
    # shellcheck disable=SC1091
    . "${HOME}/.cargo/env"

    say "cloning ${PEERS_REPO} @ ${PEERS_REF}"
    rm -rf "${BUILD_DIR}"
    # Build on the server volume, not Pterodactyl's memory-backed /tmp.
    trap 'rm -rf "${BUILD_DIR}"' EXIT
    git clone --depth 1 "${PEERS_REPO}" "${BUILD_DIR}" \
        || die "clone failed. Check PEERS_REPO '${PEERS_REPO}'."
    git -C "${BUILD_DIR}" fetch --depth 1 origin "${PEERS_REF}" \
        || die "fetch failed. Is PEERS_REF '${PEERS_REF}' a branch, tag, or commit?"
    git -C "${BUILD_DIR}" checkout --detach FETCH_HEAD \
        || die "checkout failed for PEERS_REF '${PEERS_REF}'."

    # Confirm what we actually built. A branch or tag resolves at fetch time,
    # so a ref that moved between review and install would otherwise go
    # unnoticed. A full 40-hex PEERS_REF must resolve to exactly itself.
    RESOLVED="$(git -C "${BUILD_DIR}" rev-parse HEAD)"
    if [[ "${PEERS_REF}" =~ ^[0-9a-fA-F]{40}$ ]] && [ "${RESOLVED,,}" != "${PEERS_REF,,}" ]; then
        die "PEERS_REF pinned to ${PEERS_REF} but the clone resolved to ${RESOLVED}.
Refusing to build a commit other than the one that was pinned."
    fi
    say "building Peers commit ${RESOLVED}"
    cd "${BUILD_DIR}"

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
    cargo build --release --locked --jobs "${JOBS}" \
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
