# syntax=docker/dockerfile:1
# SPDX-License-Identifier: MIT
# Arch Linux with makepkg and namcap, for building packaging/arch/PKGBUILD (sandbox/e2e/package.sh).
FROM archlinux:latest
RUN --mount=type=secret,id=extra_ca \
    if [ -s /run/secrets/extra_ca ]; then \
        cp /run/secrets/extra_ca /etc/ca-certificates/trust-source/anchors/extra-ca.crt && update-ca-trust; \
    fi
COPY --chmod=755 retry /usr/local/bin/retry
RUN retry pacman -Syu --noconfirm --needed base-devel diffutils git namcap python \
 && yes | pacman -Scc >/dev/null \
 && useradd -m builder \
 && git config --system --add safe.directory '*'
USER builder
WORKDIR /src
