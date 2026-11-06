# syntax=docker/dockerfile:1
# SPDX-License-Identifier: MIT
# Arch Linux userland for the test suite (tests/run-tests.sh).
FROM archlinux:latest
# Optional: trust an extra CA, for networks with a TLS-inspecting proxy (see sandbox/README.md).
RUN --mount=type=secret,id=extra_ca \
    if [ -s /run/secrets/extra_ca ]; then \
        cp /run/secrets/extra_ca /etc/ca-certificates/trust-source/anchors/extra-ca.crt && update-ca-trust; \
    fi
RUN pacman -Syu --noconfirm --needed bash coreutils curl diffutils findutils git procps-ng python util-linux \
 && yes | pacman -Scc >/dev/null
WORKDIR /src
