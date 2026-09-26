# Peers node on Pterodactyl

Runs an always-on [Peers](https://github.com/PeersTech/Peers) relay node as a
Pterodactyl server.

A node is what lets two people behind ordinary home routers talk to each other.
Both peers dial the node, reserve a circuit through it, and their messages flow;
then DCUtR hole-punches a direct connection and the node drops out of the path.
It is a switchboard, not a bottleneck.

The node never decrypts sealed direct messages. It does process signed
control traffic and server-channel messages, so it can observe that metadata
and plaintext protocol content. Running one does not make you a trusted party
for the full protocol.

---

## Message and attachment visibility

The relay can observe routing metadata, signed control traffic, server/Plaza
traffic, and DHT blob requests. Small server-channel attachments are raw DHT
blobs and are not E2E encrypted. Direct-message attachments are sealed inside
the DM envelope. Do not treat this node as a privacy boundary for every message
type.

---

## Files

| File | What it is |
|---|---|
| `egg-peers-node.json` | **Import this into the panel.** Generated. Do not hand-edit. |
| `install.sh` | The install script. Source of truth. |
| `egg.meta.json` | Egg metadata and variables. Source of truth. |
| `build-egg.sh` | Regenerates the egg JSON from the two files above. |
| `Dockerfile` | Runtime image. You need to build and host this. See below. |
| `entrypoint.sh` | Container entrypoint, baked into the image. |

After changing `install.sh` or `egg.meta.json`, run `./build-egg.sh` and
re-import.

---

## You must build the Docker image first

This is not optional and no stock image will work.

`peers` is a single binary that decides at runtime whether to open a window or
run headless. Tauri is an unconditional dependency of the crate, so the binary
is *linked* against webkit2gtk and GTK even in `--node` mode. The dynamic loader
resolves those libraries at process start, before any code runs, so without
them the node does not fail gracefully, it fails to boot at all. None of the
`parkervcp/yolks` images carry desktop libraries.

```sh
git clone https://github.com/PeersTech/ptero-egg.git
cd ptero-egg
docker login ghcr.io
docker build -t ghcr.io/peerstech/ptero-egg:latest .
docker push ghcr.io/peerstech/ptero-egg:latest
```

If you would rather not push anywhere, build it as `peers-node:local` on each
Wings host and pick the "build locally" image in the egg. The egg marks that
option `~peers-node:local` so Wings uses the local image without trying to
pull it from a registry.

> This is worth fixing upstream. If Peers ever puts Tauri behind a cargo
> feature, `--node` becomes a plain static-ish binary and this image collapses
> to a bare `debian-slim`.

---

## Setup

### 1. Import the egg

Panel → **Nests** → **Import Egg** → upload `egg-peers-node.json`.

### 2. Create the server

- **Docker image:** the one you built above.
- **Memory:** 1 GB is plenty to *run* a node. The **install** needs more.
  See the note on build memory below.
- **Disk:** 3 GB for a source install. The installer builds in a temporary
  directory on the server volume so Pterodactyl's memory-backed `/tmp` does
  not fill during linking. 200 MB is enough after installation.
- **Allocation:** one port. Peers uses it for **both TCP and QUIC/UDP**.

### 3. Open the port for both protocols

The single most common reason a node looks healthy and nobody can use it.

```sh
sudo ufw allow <port>/tcp
sudo ufw allow <port>/udp
```

On a cloud host, do the same in the provider's security group. That is a
separate firewall from `ufw` and blocks traffic before it reaches the machine.

### 4. Set the public IP

Leave `PEERS_PUBLIC_IP` on `auto` and the node detects it at boot. If detection
fails, or the container sits behind a load balancer, set the address explicitly.

This matters because a container only ever sees its internal address. Without
this variable the node advertises something like `172.18.0.5`, which is a real
listener, and completely useless to anyone outside the host.

### 5. Start it, and read two lines

```
peers node peer id: 12D3KooW…
announcing: /ip4/203.0.113.7/tcp/4001/p2p/12D3KooW…
  → PEERS_NODES=/ip4/203.0.113.7/tcp/4001/p2p/12D3KooW…
peers node is up.
reachability: public (peers dialed us successfully)
```

Give clients the `PEERS_NODES=` line.

Then wait for `reachability:`. This is an AutoNAT result. Other peers were
asked to dial the node back and it reports whether they got through. It is a
measurement, not a guess.

- `public` means it works.
- `PRIVATE` means packets are not arriving. Firewall, security group, or a wrong
  `PEERS_PUBLIC_IP`. No client can use this node until it says `public`.
- `unknown` means not enough peers to probe with yet. Give it a few minutes.

### 6. Point clients at it

On each client machine, write `<config>/peers/nodes.json`:

```json
["/ip4/203.0.113.7/tcp/4001/p2p/12D3KooW…"]
```

| Platform | Path |
|---|---|
| Linux | `~/.config/peers/nodes.json` |
| macOS | `~/Library/Application Support/peers/nodes.json` |
| Windows | `%APPDATA%\peers\nodes.json` |

Both people who want to talk must point at the **same** node.

---

## Keep the identity file

The node's identity lives at `/home/container/.config/peers/node_identity.json`
and is generated on first boot.

A normal Pterodactyl reinstall preserves the server volume and this file.
The install script repairs ownership of an existing `/mnt/server/.config` and
its `peers` subtree when Wings supplies both `PUID` and `PGID`; this is what
allows an old root-owned identity file to be read and updated by the runtime
user. If the install container does not provide both IDs, fix ownership on the
host instead:

```sh
sudo chown -R <PUID>:<PGID> /mnt/server/.config
```

Replace `<PUID>:<PGID>` with the server's actual runtime user and group. Do not
delete the identity file as a workaround. A failed ownership repair or an
unreadable identity should be fixed before starting the node; otherwise the
node may be unable to use its existing peer ID.

Deleting/recreating the server, replacing the volume, or manually removing the
file gives the node a new peer ID, and every client still holding the old one
keeps dialling an address that now answers as somebody else. Back up the file
before destructive server operations.

The same applies to the port: pin the allocation. Clients store the port
alongside the peer ID, and an ephemeral one invalidates every config on each
restart.

Restarting the node itself is safe. Clients re-establish reservations
automatically, retrying with exponential backoff from 10 seconds up to a
5-minute ceiling.

---

## Variables

| Variable | Default | Notes |
|---|---|---|
| `INSTALL_METHOD` | `source` | `source` or `release`. See below. |
| `PEERS_REF` | pinned commit | Commit SHA to build. A full 40-char SHA is verified against the clone and the install aborts on mismatch. |
| `PEERS_REPO` | `https://github.com/PeersTech/Peers.git` | Change only for a fork. |
| `PEERS_RELEASE_SHA256` | none | Required for `release`; the checksum of the exact Linux x86_64 asset. |
| `RUSTUP_INIT_SHA256` | none | Required for `source`; the checksum of `rustup-init`. The installer will not run an unverified rustup. |
| `PEERS_PUBLIC_IP` | `auto` | The address clients dial. |
| `PEERS_ANNOUNCE` | none | Full multiaddr override. Advanced. |
| `PEERS_NODES` | none | Upstream nodes to chain to. |
| `PEERS_NO_RELAY` | `0` | `1` forwards nothing. |
| `CARGO_BUILD_JOBS` | `2` | Lower to `1` if the install is OOM-killed. |

### `INSTALL_METHOD=release` is intentionally strict

Release mode is supported only on Linux `x86_64` and only when the latest
PeersTech/Peers release contains exactly one asset named
`peers-linux-x86_64`. Set `PEERS_RELEASE_SHA256` to that asset's 64-character
SHA-256 checksum, obtained from a trusted source, before installing. The
installer downloads to a temporary file and refuses to move it into place if
the checksum is missing, malformed, or does not match. It never selects an
asset by a broad `linux`/`x86_64` substring.

PeersTech/Peers has not published this exact asset yet, so the default
`source` method remains the supported path. If a future release uses this
contract, verify the checksum independently before entering it in the panel;
a checksum from the same untrusted mutable page is not a substitute for a
trusted value.

### `INSTALL_METHOD=source` verifies the toolchain too

`PEERS_REF` defaults to a pinned commit, not a branch, so a tag or `main` that
moves after review cannot change what gets built. If you supply a full
40-character commit SHA, the installer compares it against the resolved clone
and aborts on any mismatch.

Source installs also require `RUSTUP_INIT_SHA256`:

```
RUSTUP_INIT_SHA256=$(curl -fsSL https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init.sha256 | cut -d' ' -f1)
```

`rustup-init` is downloaded as a file, checksum-verified, and only then
executed. The previous `curl https://sh.rustup.rs | sh` ran whatever the mirror
returned with no integrity check, which is arbitrary code execution on the
install container's root before a single Peers line is built.

### Build memory

Linking a Tauri binary is memory-hungry. If the install stops partway through
with no error, it was OOM-killed. Either raise the server's memory limit for
the duration of the install, or set `CARGO_BUILD_JOBS=1`.

A source build takes 10-25 minutes.

---

## Troubleshooting

**Install fails immediately with a message about releases or a checksum.**
Working as intended if the exact `peers-linux-x86_64` asset has not been
published, the checksum is missing, or the downloaded file does not match it.
Use `INSTALL_METHOD=source` unless you have a verified release checksum.

**Install dies silently around the linking stage.**
Out of memory. `CARGO_BUILD_JOBS=1`, or more RAM.

**Node starts, logs look fine, no client can connect.**
Check the `reachability:` line. If it says `PRIVATE`, the port is not actually
open. Check the provider's security group separately from `ufw`, and confirm
you opened **both** TCP and UDP.

**Node boots and exits instantly with a library error.**
The Docker image lacks the webkit/GTK runtime libraries. You are on a stock
image; build the one in this repo.

**`peer connected` but never `relay reservation granted`.**
Clients reach the node but cannot reserve a slot. It is at capacity. A node
tier allows 64 reservations. Add a second node.

**Clients reconnect every few seconds.**
Reservations are being granted then lost. Usually capacity, or an intermediate
firewall dropping idle connections.

---

## See also

- [Running a node](https://github.com/PeersTech/Peers/blob/main/docs/running-a-node.md),
  the general guide, not Pterodactyl-specific.
