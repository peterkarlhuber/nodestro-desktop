#!/usr/bin/env bash
# Inside the test machine, as the sudo user "maint": make the cloud image a clean desktop base for the tests.
# Cloud images ship Python for cloud-init; apt refuses to remove it on Ubuntu (metapackages depend on it), so dpkg
# removes it regardless of dependencies. Nothing in the tests needs it. Fails if Python, Node.js, Rust, Docker or
# bubblewrap is still on the machine.
set -euo pipefail
mapfile -t pkgs < <(dpkg-query -W -f='${Package}\n' 'python3*' 'libpython3*' bubblewrap 2>/dev/null || true)
if [ "${#pkgs[@]}" -gt 0 ]; then
  # Maintainer scripts of some packages fail once Python is gone; the check below decides, not dpkg's status.
  # shellcheck disable=SC2024 # the log belongs to this user on purpose
  if ! sudo dpkg --purge --force-depends "${pkgs[@]}" >"$HOME/dpkg-purge.log" 2>&1; then
    echo "dpkg reported errors (continuing; the check below decides):"
    grep -iE "error|warning" "$HOME/dpkg-purge.log" | tail -15 || true
  fi
fi
echo "removed ${#pkgs[@]} packages: ${pkgs[*]}"
clean=1
for tool in python3 python node nodejs rustc cargo docker bwrap; do
  if command -v "$tool" >/dev/null; then echo "still installed: $tool"; clean=0; fi
done
if compgen -G '/usr/bin/python3*' >/dev/null; then echo "still installed: /usr/bin/python3*"; clean=0; fi
[ "$clean" = 1 ] && echo "clean: no Python, Node.js, Rust, Docker or bubblewrap"
