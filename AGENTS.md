# Agent Guide

## Project

Pterodactyl egg and container image for running a Peers relay node.

## Commands

- Generate egg: `./build-egg.sh`
- Shell syntax: `bash -n install.sh entrypoint.sh`
- Docker build: `docker build -t ptero-egg:test .`

## Conventions

- `install.sh` is the source of truth; regenerate `egg-peers-node.json` after changes.
- Use `set -euo pipefail` in shell scripts.
- Do not download or execute mutable artifacts without verification.
- Keep node identity and its data on the mounted server volume.
- Avoid `eval` and other command-injection patterns.

## Verification

Run shell syntax checks, regenerate the egg, and smoke-test the generated startup path before committing.
