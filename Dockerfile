# Runtime image for a Peers relay node on Pterodactyl.
#
# Why this exists: `peers` is one binary that decides at runtime whether to
# open a window (`peers`) or run headless (`peers --node`). Tauri is an
# unconditional dependency of the crate, so the binary is *linked* against
# webkit2gtk/GTK even in `--node` mode. The dynamic loader resolves those
# libraries at process start, before any of your code runs, so the node will
# not boot without them. None of the stock yolks images carry them.
#
# These are the runtime (non `-dev`) counterparts of the build dependencies
# used in upstream CI. The install container needs the `-dev` versions; this
# one does not.
#
# If upstream ever gates Tauri behind a cargo feature, this image collapses to
# a plain debian-slim and you should switch to that.
FROM debian:bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/PeersTech/ptero-egg"
LABEL org.opencontainers.image.description="Runtime image for Peers relay nodes"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      iproute2 \
      libwebkit2gtk-4.1-0 \
      libgtk-3-0 \
      libayatana-appindicator3-1 \
      librsvg2-2 \
      libxdo3 \
      libssl3 \
      tzdata \
 && rm -rf /var/lib/apt/lists/*

# Pterodactyl convention: unprivileged user, cwd /home/container.
RUN useradd -m -d /home/container container
USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

COPY ./entrypoint.sh /entrypoint.sh
CMD ["/bin/bash", "/entrypoint.sh"]
