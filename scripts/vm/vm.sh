#!/usr/bin/env bash
# Boot a real Linux distribution in a KVM virtual machine and run commands in it (sandbox system tests).
#
#   scripts/vm/vm.sh boot <system> <workdir>     download the cloud image, boot it, wait for SSH
#   scripts/vm/vm.sh ssh <workdir> <user> CMD    run CMD in the machine as <user> ("admin" has sudo, "tester" not)
#   scripts/vm/vm.sh copy <workdir> <user> SRC DEST   copy a local file or directory into the machine
#   scripts/vm/vm.sh stop <workdir>
#
# <system> is ubuntu-24.04 or debian-13. Each machine is the distribution's official cloud image with its own
# kernel, AppArmor enabled as shipped, and two users created by cloud-init: "admin" (sudo, for preparing the system)
# and "tester" (a normal user without sudo, for every test). Needs qemu-system-x86, qemu-utils, cloud-image-utils
# and /dev/kvm (GitHub's Linux runners have it).
set -euo pipefail

image_url() {
  case "$1" in
    ubuntu-24.04) echo "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img" ;;
    debian-13) echo "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2" ;;
    *) echo "unknown system: $1" >&2; exit 2 ;;
  esac
}

ssh_opts() {
  echo "-i $1/key -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"
}

cmd="$1"; shift
case "$cmd" in
  boot)
    system="$1"; work="$2"
    mkdir -p "$work"
    url="$(image_url "$system")"
    curl -fsSL --retry 3 -o "$work/base.img" "$url"
    qemu-img convert -O qcow2 "$work/base.img" "$work/disk.qcow2"
    qemu-img resize -q "$work/disk.qcow2" 12G
    rm -f "$work/base.img"
    ssh-keygen -q -t ed25519 -N "" -f "$work/key"
    pub="$(cat "$work/key.pub")"
    cat >"$work/user-data" <<EOF
#cloud-config
users:
  - name: admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys: ["$pub"]
  - name: tester
    shell: /bin/bash
    ssh_authorized_keys: ["$pub"]
ssh_pwauth: false
EOF
    printf 'instance-id: nodestro-%s\nlocal-hostname: %s\n' "$system" "$system" >"$work/meta-data"
    cloud-localds "$work/seed.iso" "$work/user-data" "$work/meta-data"
    qemu-system-x86_64 -enable-kvm -cpu host -m 6144 -smp 4 \
      -drive "file=$work/disk.qcow2,if=virtio" -drive "file=$work/seed.iso,if=virtio,format=raw" \
      -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0 \
      -display none -serial "file:$work/console.log" -daemonize -pidfile "$work/qemu.pid"
    # shellcheck disable=SC2046
    for _ in $(seq 1 90); do
      if ssh $(ssh_opts "$work") tester@127.0.0.1 true 2>/dev/null \
        && ssh $(ssh_opts "$work") admin@127.0.0.1 "cloud-init status --wait >/dev/null 2>&1; true"; then
        echo "$system is up"
        exit 0
      fi
      sleep 5
    done
    echo "$system did not come up; console:" >&2
    tail -50 "$work/console.log" >&2 || true
    exit 1
    ;;
  ssh)
    work="$1"; user="$2"; shift 2
    # shellcheck disable=SC2046
    exec ssh $(ssh_opts "$work") "$user@127.0.0.1" "$@"
    ;;
  copy)
    work="$1"; user="$2"; src="$3"; dest="$4"
    # shellcheck disable=SC2046
    exec scp -q -r $(ssh_opts "$work" | sed 's/-p 2222/-P 2222/') "$src" "$user@127.0.0.1:$dest"
    ;;
  stop)
    work="$1"
    if [ -f "$work/qemu.pid" ]; then kill "$(cat "$work/qemu.pid")" || true; fi
    ;;
  *)
    echo "usage: vm.sh boot|ssh|copy|stop ..." >&2; exit 2 ;;
esac
