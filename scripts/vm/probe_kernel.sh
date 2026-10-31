#!/usr/bin/env bash
# Print the kernel features the built-in sandbox depends on, as seen by the user running this script.
set -u
echo "== system"
. /etc/os-release && echo "os: $PRETTY_NAME"
echo "kernel: $(uname -r)"
echo "user: $(id)"
echo "lsm: $(cat /sys/kernel/security/lsm 2>/dev/null || echo unreadable)"
for s in kernel.unprivileged_userns_clone kernel.apparmor_restrict_unprivileged_userns \
  kernel.apparmor_restrict_unprivileged_unconfined user.max_user_namespaces kernel.yama.ptrace_scope \
  kernel.unprivileged_bpf_disabled; do
  printf '%s = %s\n' "$s" "$(cat /proc/sys/${s//.//} 2>/dev/null || echo absent)"
done
echo "seccomp: $(grep -E '^Seccomp' /proc/self/status | tr '\n' ' ')"
echo "cgroup: $(stat -fc %T /sys/fs/cgroup) delegated=$(cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers 2>/dev/null || echo none)"
if command -v python3 >/dev/null; then
  python3 - <<'PY'
import ctypes
libc = ctypes.CDLL(None, use_errno=True)
abi = libc.syscall(444, None, 0, 1)  # landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION)
print("landlock abi:", abi if abi >= 0 else f"unavailable (errno {ctypes.get_errno()})")
PY
fi
echo "== bubblewrap"
for b in /usr/bin/bwrap "$HOME/bwrap-copy"; do
  [ -x "$b" ] || { echo "$b: missing"; continue; }
  if out=$("$b" --unshare-all --ro-bind / / --proc /proc --dev /dev true 2>&1); then
    echo "$b: works"
  else
    echo "$b: FAILS: $out"
  fi
done
echo "unshare -Ur: $(unshare -Ur id -u 2>&1)"
echo "== apparmor"
ls /etc/apparmor.d 2>/dev/null | grep -E -i 'bwrap|userns|webkit|flatpak' | tr '\n' ' '; echo
