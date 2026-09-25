# Pterodactyl egg hardening plan

**Goal:** Make relay installation and startup safer for operators.

**Approach:** Remove `eval`, harden release artifact selection and verification, add generated-egg/shell checks to CI, and improve identity/data-volume recovery guidance.

**Files touched:** `entrypoint.sh`, `install.sh`, `egg.meta.json`, `Dockerfile`, `.github/workflows/docker-publish.yml`, and documentation.

**Verification:** `bash -n`, egg regeneration, shell lint if available, and Docker build where the environment permits.

**Status:** done — startup injection removed, release artifacts checksum-gated, ownership recovery improved, and CI validation added.
