# syntax=docker/dockerfile:1
# SPDX-License-Identifier: MIT
# The real-Proton sandbox: CachyOS with its proton-cachyos package, a virtual X display and
# MinGW (to build the stand-in Cyberpunk2077.exe). Runs sandbox/e2e/experiments.sh and
# sandbox/e2e/install-and-launch.sh as an ordinary user.
FROM cachyos/cachyos:latest
RUN --mount=type=secret,id=extra_ca \
    if [ -s /run/secrets/extra_ca ]; then \
        cp /run/secrets/extra_ca /etc/ca-certificates/trust-source/anchors/extra-ca.crt && update-ca-trust; \
    fi
RUN pacman -Syu --noconfirm --needed bash coreutils curl diffutils findutils git libarchive procps-ng python util-linux \
        mingw-w64-gcc proton-cachyos-native vulkan-icd-loader xorg-server-xvfb xorg-xwininfo \
 && yes | pacman -Scc >/dev/null \
 && useradd -m -u 1000 gamer \
 && git config --system --add safe.directory '*'
USER gamer
RUN mkdir -p /home/gamer/.cache/nightcoop-sandbox
ENV DISPLAY=:99
WORKDIR /src
