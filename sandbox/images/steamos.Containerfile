# syntax=docker/dockerfile:1
# SPDX-License-Identifier: MIT
# SteamOS userland, from Valve's own package repositories, for the test suite.
# holo-base is a SteamOS image kept by the Steam Deck Homebrew project. STEAMOS_BRANCH
# moves it to another SteamOS release by pointing pacman at that release's repositories
# (SteamOS 3.8 and later have no [community]), then upgrading.
ARG HOLO_BASE=ghcr.io/steamdeckhomebrew/holo-base:latest
FROM ${HOLO_BASE}
ARG STEAMOS_BRANCH=3.8
RUN --mount=type=secret,id=extra_ca \
    if [ -s /run/secrets/extra_ca ]; then \
        cp /run/secrets/extra_ca /etc/ca-certificates/trust-source/anchors/extra-ca.crt && update-ca-trust; \
    fi
RUN set -e; mirror=https://steamdeck-packages.steamos.cloud/archlinux-mirror; \
    for repo in jupiter holo core extra community multilib; do \
        name="$repo-$STEAMOS_BRANCH"; \
        if curl -fs -r 0-0 -o /dev/null "$mirror/$name/os/x86_64/$name.db"; then \
            printf '\n[%s]\nInclude = /etc/pacman.d/mirrorlist\n' "$name" >> /tmp/repos.conf; \
        fi; \
    done; \
    grep -q "jupiter-$STEAMOS_BRANCH" /tmp/repos.conf || { echo "no SteamOS $STEAMOS_BRANCH repositories" >&2; exit 1; }; \
    sed -i '/^\[\(jupiter\|holo\|core\|extra\|community\|multilib\)-[0-9.a-z]*\]/,/^Include/d' /etc/pacman.conf; \
    sed -i 's/^CheckSpace/#CheckSpace/' /etc/pacman.conf; \
    cat /tmp/repos.conf >> /etc/pacman.conf; \
    pacman -Syy --noconfirm --needed holo-keyring archlinux-keyring; \
    pacman -Su --noconfirm; \
    pacman -S --noconfirm --needed bash coreutils curl diffutils findutils git procps-ng python util-linux; \
    yes | pacman -Scc >/dev/null
WORKDIR /src
