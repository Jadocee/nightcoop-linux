#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# package.sh: build packaging/arch/PKGBUILD from the repository's current commit with
# makepkg (whose check() runs the test suite), check it with namcap, list its contents and
# confirm .SRCINFO matches the PKGBUILD. Uncommitted changes are not part of the build.
#
#   docker compose -f sandbox/compose.yaml run --rm package
set -euo pipefail
SRC="${SRC:-/src}"
work="$(mktemp -d)"
git clone -q "$SRC" "$work/repo"
git -C "$work/repo" branch -f sandbox-build HEAD
mkdir "$work/pkg"
cp "$SRC/packaging/arch/PKGBUILD" "$work/pkg/"
sed -i "s|^source=.*|source=(\"\$_name::git+file://$work/repo#branch=sandbox-build\")|" "$work/pkg/PKGBUILD"
cd "$work/pkg"
makepkg -f --noconfirm
echo "== namcap"
# With Arch's own PATH: Docker's default lists /usr/sbin (a symlink to bin) before /usr/bin,
# and namcap then looks for a package owning usr/sbin/bash and finds none.
PATH=/usr/local/sbin:/usr/local/bin:/usr/bin namcap PKGBUILD ./*.pkg.tar.zst
echo "== package contents"
bsdtar -tf ./*.pkg.tar.zst | grep -v '^\.'
echo "== .SRCINFO"
cp "$SRC/packaging/arch/PKGBUILD" "$SRC/packaging/arch/.SRCINFO" "$work/"
(cd "$work" && makepkg --printsrcinfo | diff -u .SRCINFO -) && echo ".SRCINFO matches the PKGBUILD"
