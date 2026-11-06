# syntax=docker/dockerfile:1
# SPDX-License-Identifier: MIT
# CachyOS userland (CachyOS's own builds of Python, coreutils, procps-ng, ...) for the test suite.
FROM cachyos/cachyos:latest
RUN --mount=type=secret,id=extra_ca \
    if [ -s /run/secrets/extra_ca ]; then \
        cp /run/secrets/extra_ca /etc/ca-certificates/trust-source/anchors/extra-ca.crt && update-ca-trust; \
    fi
RUN pacman -Syu --noconfirm --needed bash coreutils curl diffutils findutils git procps-ng python util-linux \
 && yes | pacman -Scc >/dev/null
WORKDIR /src
