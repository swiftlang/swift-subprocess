#!/usr/bin/env bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift.org open source project
##
## Copyright (c) 2026 Apple Inc. and the Swift project authors
## Licensed under Apache License v2.0 with Runtime Library Exception
##
## See https://swift.org/LICENSE.txt for license information
##
##===----------------------------------------------------------------------===##
# test-using-qemu.sh
#
# Boots a Linux VM under QEMU to run commands (default: swift test) against a
# specific distro+kernel combination.  Supports two modes:
#
#   disk mode   — downloads a pre-built disk.qcow2 from images.linuxcontainers.org
#                 and injects credentials via a cloud-init seed ISO.
#
#   rootfs mode — downloads a rootfs.tar.xz from images.linuxcontainers.org and
#                 fetches the kernel separately (e.g. from an RPM repo), then
#                 builds the disk image locally with mkfs.ext4 -d.
#
# Known profiles live in the PROFILES table near the top of this file.
# Must run as root on Linux.

set -euo pipefail

LXC_BASE="https://images.linuxcontainers.org/images"
LXC_GPG_KEY_IDS=(
    "602F567663359FCDE9BCD0E79F93B4C4F3D4444A"
    "C2DE3F5BDE2F6068"
)

# ── Defaults ──────────────────────────────────────────────────────────────────
WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}/qemu-swift-$$}"
VM_MEMORY="${VM_MEMORY:-2048}"
VM_CPUS="${VM_CPUS:-2}"
SSH_HOST_PORT="${SSH_PORT:-2222}"
KEEP_WORK="${KEEP_WORK:-false}"

QEMU_PID=""
SSH_OPTS=()

# ── Logging ───────────────────────────────────────────────────────────────────
info()  { printf '\033[32m[INFO]\033[0m  %s\n'  "$*"; }
warn()  { printf '\033[33m[WARN]\033[0m  %s\n'  "$*" >&2; }
error() { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
step()  { printf '\033[36m[STEP]\033[0m  %s\n'  "$*"; }

# ── Profile registry ──────────────────────────────────────────────────────────
# Each entry is a pipe-separated string:
#   LXC_SPEC | USERSPACE_FILE | KERNEL_MODE | KERNEL_DONOR_SPEC
#
# USERSPACE_FILE:      "disk.qcow2"  → disk mode (cloud-init SSH injection)
#                      "rootfs.tar.xz" → rootfs mode (direct SSH config, -kernel boot)
#
# KERNEL_MODE:         "disk"     → kernel lives inside the disk.qcow2 (GRUB boots it)
#                      "lxc-disk" → extract kernel+initrd from a second LXC disk.qcow2;
#                                   KERNEL_DONOR_SPEC names that donor image's LXC path
#
# KERNEL_DONOR_SPEC:   LXC path (distro/release/arch/variant) of the kernel donor image.
#                      Used only for lxc-disk mode.  Debian Bullseye ships kernel 5.10 LTS
#                      and is publicly accessible, making it a good donor for AL2 userspace.
#
# To add a new combination, append a line here — no other code changes needed.

declare -A PROFILES
#                               LXC spec                          | file            | kernel    | kernel donor spec
PROFILES["al2-5.10"]="amazonlinux/2/amd64/default                | rootfs.tar.xz  | lxc-disk  | debian/bullseye/amd64/cloud"
PROFILES["al2-5.10-arm64"]="amazonlinux/2/arm64/default          | rootfs.tar.xz  | lxc-disk  | debian/bullseye/arm64/cloud"
# almalinux/8/amd64/default (not cloud) carries kernel 4.18 and has disk.qcow2;
# no arm64 equivalent exists on LXC so this profile is amd64-only.
PROFILES["al2-4.18"]="amazonlinux/2/amd64/default                | rootfs.tar.xz  | lxc-disk  | almalinux/8/amd64/default"
PROFILES["almalinux-8"]="almalinux/8/amd64/cloud                 | disk.qcow2     | disk      | "
PROFILES["almalinux-8-arm64"]="almalinux/8/arm64/cloud           | disk.qcow2     | disk      | "
PROFILES["almalinux-9"]="almalinux/9/amd64/cloud                 | disk.qcow2     | disk      | "
PROFILES["almalinux-9-arm64"]="almalinux/9/arm64/cloud           | disk.qcow2     | disk      | "
PROFILES["rockylinux-8"]="rockylinux/8/amd64/cloud               | disk.qcow2     | disk      | "
PROFILES["rockylinux-8-arm64"]="rockylinux/8/arm64/cloud         | disk.qcow2     | disk      | "
PROFILES["rockylinux-9"]="rockylinux/9/amd64/cloud               | disk.qcow2     | disk      | "
PROFILES["rockylinux-9-arm64"]="rockylinux/9/arm64/cloud         | disk.qcow2     | disk      | "
PROFILES["ubuntu-22.04"]="ubuntu/jammy/amd64/cloud               | disk.qcow2     | disk      | "
PROFILES["ubuntu-22.04-arm64"]="ubuntu/jammy/arm64/cloud         | disk.qcow2     | disk      | "
PROFILES["ubuntu-24.04"]="ubuntu/noble/amd64/cloud               | disk.qcow2     | disk      | "
PROFILES["ubuntu-24.04-arm64"]="ubuntu/noble/arm64/cloud         | disk.qcow2     | disk      | "
PROFILES["debian-12"]="debian/bookworm/amd64/cloud               | disk.qcow2     | disk      | "
PROFILES["debian-12-arm64"]="debian/bookworm/arm64/cloud         | disk.qcow2     | disk      | "

list_profiles() {
    echo "Available profiles:"
    for key in $(echo "${!PROFILES[@]}" | tr ' ' '\n' | sort); do
        local lxc_spec; lxc_spec=$(awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$1); print $1}' <<< "${PROFILES[$key]}")
        printf "  %-20s  %s\n" "$key" "$lxc_spec"
    done
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
    set +e
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        info "Shutting down VM (PID $QEMU_PID)..."
        ssh "${SSH_OPTS[@]}" root@localhost "poweroff" 2>/dev/null || true
        sleep 3
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    if [[ "$KEEP_WORK" != "true" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    elif [[ "$KEEP_WORK" == "true" ]]; then
        info "Work directory preserved: $WORK_DIR"
    fi
}
trap cleanup EXIT INT TERM

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [<profile>] [-- <guest-command>]

Boot a Linux VM under QEMU and run a command inside it.

OPTIONS:
  -h, --help             Show this help
  --list-profiles        List available profiles and exit
  -m, --memory MB        VM RAM in MB              (default: $VM_MEMORY, env: VM_MEMORY)
  -c, --cpus N           VM CPU count              (default: $VM_CPUS,   env: VM_CPUS)
  -w, --workdir DIR      Host directory to copy to /mnt/host (default: CWD)
  -p, --ssh-port PORT    Host-side SSH forwarding port (default: $SSH_HOST_PORT, env: SSH_PORT)
      --keep-image       Reuse existing disk image in WORK_DIR (skip download/build)
      --keep-work        Preserve WORK_DIR after exit
      --skip-install     Skip tool installation
      --no-swift         Skip Swift toolchain installation

PROFILE (default: al2-5.10):
  A named entry from the built-in profile table.  Run --list-profiles to see all.
  Examples:  al2-5.10   almalinux-8   ubuntu-22.04   debian-12

GUEST COMMAND (after --):
  Runs as root inside the VM, in /mnt/host, with Swift on PATH.
  Default: swift test

ENVIRONMENT: VM_MEMORY  VM_CPUS  SSH_PORT  KEEP_WORK  WORK_DIR  VM_DISK_SIZE  TMPDIR
  Note: use "sudo VAR=val ./$(basename "$0")" — plain "VAR=val sudo ..." is stripped by sudo.

NOTES:
  - Host must be Ubuntu (apt-get is used for tool installation); python3 must be available.
  - disk mode images require cloud-init in the guest (Ubuntu, Debian, Fedora, AlmaLinux do).
  - rootfs mode (e.g. al2-5.10) fetches userspace from LXC and kernel from a donor disk image.
  - lxc-disk kernel mode downloads a second LXC disk.qcow2 and extracts vmlinuz+initrd via debugfs.
  - rootfs mode waits up to 10 min for SSH; first boot installs openssh-server if absent.
  - amd64: QEMU's built-in SeaBIOS handles GRUB boot; no extra firmware needed.
  - arm64: install qemu-efi-aarch64 for UEFI firmware.
EOF
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
HOST_WORKDIR="$(pwd)"
PROFILE_NAME="al2-5.10"
GUEST_COMMAND="swift test"
KEEP_IMAGE=false
SKIP_INSTALL=false
NO_SWIFT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)            usage ;;
        --list-profiles)      list_profiles; exit 0 ;;
        -m|--memory)          VM_MEMORY="$2";     shift 2 ;;
        -c|--cpus)            VM_CPUS="$2";       shift 2 ;;
        -w|--workdir)         HOST_WORKDIR="$2";  shift 2 ;;
        -p|--ssh-port)        SSH_HOST_PORT="$2"; shift 2 ;;
        --keep-image)         KEEP_IMAGE=true;    shift ;;
        --keep-work)          KEEP_WORK=true;     shift ;;
        --skip-install)       SKIP_INSTALL=true;  shift ;;
        --no-swift)           NO_SWIFT=true;      shift ;;
        --)                   shift; GUEST_COMMAND="$*"; break ;;
        -*)                   error "Unknown option: $1" ;;
        *)                    PROFILE_NAME="$1";  shift ;;
    esac
done

[[ ! -d "$HOST_WORKDIR" ]] && error "Workdir not found: $HOST_WORKDIR"
[[ "$(id -u)" -ne 0 ]] && error "Must run as root."

# ── Load profile ──────────────────────────────────────────────────────────────
[[ -z "${PROFILES[$PROFILE_NAME]+_}" ]] && {
    error "Unknown profile '$PROFILE_NAME'. Run --list-profiles to see available profiles."
}

IFS='|' read -r P_LXC_SPEC P_USERSPACE_FILE P_KERNEL_MODE P_KERNEL_DONOR_SPEC \
    <<< "${PROFILES[$PROFILE_NAME]}"

# Trim whitespace from each field
P_LXC_SPEC=$(echo "$P_LXC_SPEC" | xargs)
P_USERSPACE_FILE=$(echo "$P_USERSPACE_FILE" | xargs)
P_KERNEL_MODE=$(echo "$P_KERNEL_MODE" | xargs)
P_KERNEL_DONOR_SPEC=$(echo "$P_KERNEL_DONOR_SPEC" | xargs)

IFS='/' read -r DISTRO RELEASE ARCH VARIANT <<< "$P_LXC_SPEC"
VARIANT="${VARIANT:-default}"

info "Profile:  $PROFILE_NAME  ($P_LXC_SPEC, $P_USERSPACE_FILE, kernel: $P_KERNEL_MODE)"
info "Workdir:  $HOST_WORKDIR"
info "Command:  $GUEST_COMMAND"
info "VM:       ${VM_MEMORY} MB RAM, ${VM_CPUS} CPU(s)"
info "SSH port: $SSH_HOST_PORT"

mkdir -p "$WORK_DIR"

# ── Architecture ──────────────────────────────────────────────────────────────
# amd64: q35 + built-in SeaBIOS — no firmware file needed.
# arm64: virt machine needs UEFI (EDK2); install qemu-efi-aarch64.
case "$ARCH" in
    amd64|x86_64)
        QEMU_BIN="qemu-system-x86_64"
        # -cpu max exposes the broadest feature set QEMU can emulate (SSE4, AES-NI,
        # AVX, etc.).  Without it QEMU defaults to qemu64 — a bare x86-64 baseline
        # that causes SIGILL in Swift/LLVM binaries that use SSE4.2 or newer.
        # When -enable-kvm is also present, max becomes equivalent to host.
        # mpx=off,pku=off: MPX and Protection Keys (PKU) require QEMU TCG to JIT
        # BNDMOV/WRPKRU instructions; under macOS Rosetta this fills the JIT page
        # budget and triggers mprotect(ENOMEM) → SIGTRAP.  Neither feature is needed
        # by Swift/LLVM, and Linux 5.6+ already dropped MPX support.
        # shellcheck disable=SC2054
        QEMU_MACHINE_ARGS=(-machine q35 -cpu max,mpx=off,pku=off)
        UEFI_PKG=""
        UEFI_FIRMWARE_SEARCH=()
        ;;
    arm64|aarch64)
        QEMU_BIN="qemu-system-aarch64"
        QEMU_MACHINE_ARGS=(-machine virt -cpu cortex-a57)
        UEFI_PKG="qemu-efi-aarch64"
        UEFI_FIRMWARE_SEARCH=(
            /usr/share/qemu-efi-aarch64/QEMU_EFI.fd
            /usr/share/edk2/aarch64/QEMU_EFI.fd
            /usr/share/edk2-aarch64/QEMU_EFI.fd
        )
        ;;
    *)  error "Unsupported architecture: $ARCH" ;;
esac

# ── Install host tools (host must be Ubuntu) ──────────────────────────────────
install_tools() {
    step "Installing required tools..."
    apt-get update -qq
    local pkgs=(qemu-utils openssh-client gpg curl genisoimage xz-utils)
    case "$ARCH" in
        amd64|x86_64) pkgs+=(qemu-system-x86) ;;
        arm64|aarch64) pkgs+=(qemu-system-arm qemu-efi-aarch64) ;;
    esac
    # rootfs mode additionally needs e2fsprogs (debugfs) for lxc-disk kernel extraction
    [[ "$P_USERSPACE_FILE" != "disk.qcow2" ]] && pkgs+=(e2fsprogs)
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
}

[[ "$SKIP_INSTALL" != "true" ]] && install_tools

# Verify required binaries
command -v "$QEMU_BIN" &>/dev/null || error "$QEMU_BIN not found."
command -v ssh         &>/dev/null || error "ssh not found."
command -v curl        &>/dev/null || error "curl not found."
command -v sha256sum   &>/dev/null || error "sha256sum not found."

MKISO_CMD=""
for c in genisoimage mkisofs xorriso; do
    command -v "$c" &>/dev/null && { MKISO_CMD="$c"; break; }
done

# ── Locate UEFI firmware (arm64 only) ────────────────────────────────────────
UEFI_FIRMWARE=""
for f in "${UEFI_FIRMWARE_SEARCH[@]:-}"; do
    [[ -f "$f" ]] && { UEFI_FIRMWARE="$f"; break; }
done
[[ "${#UEFI_FIRMWARE_SEARCH[@]}" -gt 0 && -z "$UEFI_FIRMWARE" ]] && \
    error "ARM64 UEFI firmware not found. Install: $UEFI_PKG"
[[ -n "$UEFI_FIRMWARE" ]] && info "UEFI firmware: $UEFI_FIRMWARE"

# ── Find latest complete LXC build ───────────────────────────────────────────
# Builds are published incrementally: SHA256SUMS appears before the images are
# fully uploaded.  Walk candidates newest-first and stop at the first build
# whose SHA256SUMS already lists the file we need.
step "Finding latest build for $P_LXC_SPEC..."
IMAGE_URL_BASE="$LXC_BASE/$DISTRO/$RELEASE/$ARCH/$VARIANT"
BUILDS=$(curl -sf "$IMAGE_URL_BASE/" \
    | grep -oE '[0-9]{8}_[0-9]{2}:[0-9]{2}' \
    | sort -r) || true
[[ -z "$BUILDS" ]] && error "No builds found at $IMAGE_URL_BASE/"

SHA256SUMS_FILE="$WORK_DIR/SHA256SUMS"
SHA256SUMS_SIG="$WORK_DIR/SHA256SUMS.asc"
BUILD=""
for candidate in $BUILDS; do
    if curl -sf "$IMAGE_URL_BASE/$candidate/SHA256SUMS" -o "$SHA256SUMS_FILE" && \
       grep -qE '(^|\s)\.?/?'"$P_USERSPACE_FILE"'(\s|$)' "$SHA256SUMS_FILE"; then
        BUILD="$candidate"
        break
    fi
done
[[ -z "$BUILD" ]] && error "No complete build found for $P_LXC_SPEC (tried all candidates)"
info "Latest complete build: $BUILD"
BUILD_URL="$IMAGE_URL_BASE/$BUILD"


# ── Download userspace image ──────────────────────────────────────────────────
USERSPACE_FILE="$WORK_DIR/$P_USERSPACE_FILE"

if [[ "$KEEP_IMAGE" == "true" && -f "$USERSPACE_FILE" ]]; then
    info "Reusing existing userspace image: $USERSPACE_FILE"
else
    step "Downloading $P_USERSPACE_FILE..."
    curl -f --progress-bar -o "$USERSPACE_FILE" "$BUILD_URL/$P_USERSPACE_FILE"
fi

if ! curl -f -sS -o "$SHA256SUMS_SIG" "$BUILD_URL/SHA256SUMS.asc" 2>/dev/null; then
    curl -f -sS -o "$SHA256SUMS_SIG" "$BUILD_URL/SHA256SUMS.gpg" 2>/dev/null || \
        warn "No signature file; skipping GPG verification."
fi

# ── Verify checksum ───────────────────────────────────────────────────────────
step "Verifying image integrity..."
export GNUPGHOME="$WORK_DIR/.gnupg"
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"

if [[ -s "$SHA256SUMS_SIG" ]]; then
    GPG_VERIFIED=false
    for key_id in "${LXC_GPG_KEY_IDS[@]}"; do
        if gpg --keyserver hkp://keyserver.ubuntu.com --recv-keys "$key_id" 2>/dev/null ||
           gpg --keyserver hkps://keys.openpgp.org    --recv-keys "$key_id" 2>/dev/null; then
            if gpg --verify "$SHA256SUMS_SIG" "$SHA256SUMS_FILE" 2>/dev/null; then
                info "GPG signature verified (key: $key_id)"
                GPG_VERIFIED=true; break
            fi
        fi
    done
    [[ "$GPG_VERIFIED" != "true" ]] && warn "GPG verification failed; continuing with SHA256 only."
else
    warn "No signature file; skipping GPG verification."
fi

EXPECTED_HASH=$(awk -v f="$P_USERSPACE_FILE" '$2==f || $2=="./"f {print $1}' "$SHA256SUMS_FILE")
[[ -z "$EXPECTED_HASH" ]] && error "No checksum for $P_USERSPACE_FILE in SHA256SUMS"
ACTUAL_HASH=$(sha256sum "$USERSPACE_FILE" | awk '{print $1}')
[[ "$EXPECTED_HASH" == "$ACTUAL_HASH" ]] || \
    error "SHA256 mismatch!\n  Expected: $EXPECTED_HASH\n  Actual:   $ACTUAL_HASH"
info "SHA256 checksum OK"

# ── Generate SSH key (used by both modes) ─────────────────────────────────────
ssh-keygen -t ed25519 -f "$WORK_DIR/vm_key" -N "" -C "qemu-swift-test" -q
VM_PUBKEY=$(cat "$WORK_DIR/vm_key.pub")

SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o ConnectTimeout=5
    -o BatchMode=yes
    -o LogLevel=ERROR
    -i "$WORK_DIR/vm_key"
    -p "$SSH_HOST_PORT"
)

# ══════════════════════════════════════════════════════════════════════════════
# DISK MODE — pre-built qcow2, cloud-init seed ISO for credentials
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$P_USERSPACE_FILE" == "disk.qcow2" ]]; then

    # Cloud-init NoCloud seed ISO: injects our SSH key into root's authorized_keys
    # on first boot via runcmd.  All images in this mode have cloud-init installed.
    [[ -z "$MKISO_CMD" ]] && error "No ISO tool found. Install genisoimage, mkisofs, or xorriso."

    step "Creating cloud-init seed ISO..."
    CLOUD_DIR="$WORK_DIR/cloud-init"
    mkdir -p "$CLOUD_DIR"

    cat > "$CLOUD_DIR/meta-data" <<METADATA
instance-id: qemu-swift-$$
local-hostname: swift-test
METADATA

    cat > "$CLOUD_DIR/user-data" <<USERDATA
#cloud-config
disable_root: false
ssh_pwauth: false
runcmd:
  - mkdir -p /root/.ssh
  - chmod 700 /root/.ssh
  - echo "${VM_PUBKEY}" > /root/.ssh/authorized_keys
  - chmod 600 /root/.ssh/authorized_keys
  - mkdir -p /etc/ssh/sshd_config.d
  - echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/99-root.conf
  - systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true
  - systemctl reload-or-restart ssh 2>/dev/null || systemctl reload-or-restart sshd 2>/dev/null || true
USERDATA

    SEED_ISO="$WORK_DIR/seed.iso"
    case "$MKISO_CMD" in
        genisoimage|mkisofs)
            "$MKISO_CMD" -output "$SEED_ISO" -volid cidata -joliet -rock \
                "$CLOUD_DIR/user-data" "$CLOUD_DIR/meta-data" 2>/dev/null ;;
        xorriso)
            xorriso -as mkisofs -output "$SEED_ISO" -volid cidata -joliet -rock \
                "$CLOUD_DIR/user-data" "$CLOUD_DIR/meta-data" 2>/dev/null ;;
    esac

    # COW overlay keeps the base image pristine; --keep-image reuses the base.
    # Resize the overlay if VM_DISK_SIZE is set — cloud-init's growpart module
    # will expand the partition and filesystem to fill the new size on first boot.
    OVERLAY_IMAGE="$WORK_DIR/overlay.qcow2"
    qemu-img create -q -f qcow2 -b "$USERSPACE_FILE" -F qcow2 "$OVERLAY_IMAGE"
    if [[ -n "${VM_DISK_SIZE:-}" ]]; then
        qemu-img resize -q "$OVERLAY_IMAGE" "$VM_DISK_SIZE"
        info "Overlay resized to $VM_DISK_SIZE (cloud-init will expand partition on first boot)"
    fi

    # shellcheck disable=SC2054
    QEMU_CMD=(
        "$QEMU_BIN"
        "${QEMU_MACHINE_ARGS[@]}"
        -m "$VM_MEMORY"
        -smp "$VM_CPUS"
        -drive "file=${OVERLAY_IMAGE},if=virtio,format=qcow2"
        -drive "file=${SEED_ISO},if=virtio,format=raw"
        -netdev "user,id=net0,hostfwd=tcp::${SSH_HOST_PORT}-:22"
        -device virtio-net-pci,netdev=net0
        -display none
        -serial "file:${WORK_DIR}/console.log"
    )
    [[ -n "$UEFI_FIRMWARE" ]] && QEMU_CMD+=(-bios "$UEFI_FIRMWARE")
    if [[ -e /dev/kvm ]]; then
        QEMU_CMD+=(-enable-kvm)
    else
        # shellcheck disable=SC2054
        QEMU_CMD+=(-accel tcg,tb-size=512)
    fi

# ══════════════════════════════════════════════════════════════════════════════
# ROOTFS MODE — assemble kernel + userspace from separate sources, -kernel boot
# ══════════════════════════════════════════════════════════════════════════════
else

    ROOTFS_DIR="$WORK_DIR/rootfs"
    DISK_IMAGE="$WORK_DIR/vm.qcow2"

    if [[ "$KEEP_IMAGE" == "true" && -f "$DISK_IMAGE" ]]; then
        info "Reusing existing disk image: $DISK_IMAGE"
    else

        # ── Extract rootfs ────────────────────────────────────────────────────
        step "Extracting rootfs to $ROOTFS_DIR..."
        rm -rf "$ROOTFS_DIR"
        mkdir -p "$ROOTFS_DIR"
        # --no-same-owner avoids chown() failures when CAP_CHOWN is restricted
        tar -C "$ROOTFS_DIR" -xf "$USERSPACE_FILE" --no-same-owner
        [[ -d "$ROOTFS_DIR/etc" ]] || error "Rootfs extraction looks empty; check the tarball."

        # resolv.conf is often a dangling symlink in LXC images.  Use QEMU's
        # built-in DNS proxy (10.0.2.3) as primary: it forwards to the host's
        # resolver, which in CI-on-AWS environments is the VPC DNS that can
        # resolve AWS-internal names like amazonlinux.default.amazonaws.com.
        # Fall back to public DNS for non-AWS environments.  Prevent
        # NetworkManager from overwriting this file.
        rm -f "$ROOTFS_DIR/etc/resolv.conf"
        printf 'nameserver 10.0.2.3\nnameserver 8.8.8.8\nnameserver 1.1.1.1\n' > "$ROOTFS_DIR/etc/resolv.conf"
        mkdir -p "$ROOTFS_DIR/etc/NetworkManager/conf.d"
        printf '[main]\ndns=none\n' > "$ROOTFS_DIR/etc/NetworkManager/conf.d/90-dns-none.conf"

        # LXC container rootfs images have no ifcfg for the VM NIC (containers
        # use host networking).  Without it NetworkManager burns time on DHCP
        # retries.  QEMU SLIRP NAT always uses fixed addresses, so a static
        # config is safe and comes up instantly.
        # Use TYPE=Ethernet (not DEVICE=eth0) so the config matches regardless
        # of whether RHEL 8 udev renames virtio-net to ens3/enp0s2/etc.
        mkdir -p "$ROOTFS_DIR/etc/sysconfig/network-scripts"
        cat > "$ROOTFS_DIR/etc/sysconfig/network-scripts/ifcfg-eth0" << 'EOF'
TYPE=Ethernet
ONBOOT=yes
BOOTPROTO=none
IPADDR=10.0.2.15
PREFIX=24
GATEWAY=10.0.2.2
NM_CONTROLLED=yes
DEFROUTE=yes
PEERDNS=no
IPV4_FAILURE_FATAL=no
IPV6INIT=no
EOF

        # AL2 .repo files use yum variables ($awsproto, $amazonlinux, $awsregion,
        # $awsdomain) that resolve to AWS-internal hostnames — only reachable from
        # inside an AWS VPC.  Override the vars so the URL template
        #   $awsproto://$amazonlinux.$awsregion.$awsdomain/...
        # expands to the public CloudFront CDN instead:
        #   http://cdn.amazonlinux.com/...
        # (same path structure; works everywhere, including in AWS CI)
        if [[ -d "$ROOTFS_DIR/etc/yum.repos.d" ]]; then
            mkdir -p "$ROOTFS_DIR/etc/yum/vars"
            printf 'cdn\n'         > "$ROOTFS_DIR/etc/yum/vars/amazonlinux"
            printf 'amazonlinux\n' > "$ROOTFS_DIR/etc/yum/vars/awsregion"
            printf 'com\n'         > "$ROOTFS_DIR/etc/yum/vars/awsdomain"
            printf 'https\n'       > "$ROOTFS_DIR/etc/yum/vars/awsproto"

            # QEMU's DNS proxy (10.0.2.3) may not resolve in Docker CI environments
            # (libslirp skips 127.0.0.11, direct UDP to 8.8.8.8:53 is blocked).
            # Pre-resolve the CDN hostname on the HOST (where DNS always works) and
            # pin it in the VM's /etc/hosts so the bootstrap install needs no DNS.
            CDN_IP=$(python3 -c "
import socket
r = socket.getaddrinfo('cdn.amazonlinux.com', 80, socket.AF_INET)
print(r[0][4][0])
" 2>/dev/null || true)
            if [[ -n "$CDN_IP" ]]; then
                printf '%s\t%s\n' "$CDN_IP" "cdn.amazonlinux.com" >> "$ROOTFS_DIR/etc/hosts"
                info "  Pinned cdn.amazonlinux.com → $CDN_IP in /etc/hosts"
            else
                warn "  Could not resolve cdn.amazonlinux.com on host; VM must use in-VM DNS"
            fi
        fi

        step "Rootfs network/repo state:"
        info "  resolv.conf: $(tr '\n' ' ' < "$ROOTFS_DIR/etc/resolv.conf" 2>/dev/null)"
        info "  ifcfg-eth0:  $(grep -s BOOTPROTO "$ROOTFS_DIR/etc/sysconfig/network-scripts/ifcfg-eth0" 2>/dev/null || echo 'absent')"
        info "  yum repos:   $(grep -rh 'mirrorlist\|baseurl' "$ROOTFS_DIR/etc/yum.repos.d/" 2>/dev/null | tr '\n' '|' || echo 'none')"
        info "  yum vars:    awsproto=$(cat "$ROOTFS_DIR/etc/yum/vars/awsproto" 2>/dev/null || echo 'unset') amazonlinux=$(cat "$ROOTFS_DIR/etc/yum/vars/amazonlinux" 2>/dev/null || echo 'unset') awsregion=$(cat "$ROOTFS_DIR/etc/yum/vars/awsregion" 2>/dev/null || echo 'unset') awsdomain=$(cat "$ROOTFS_DIR/etc/yum/vars/awsdomain" 2>/dev/null || echo 'unset')"

        # The AlmaLinux 8 dracut initrd is built for local-disk boot and does not
        # include the network module, so ip= on the kernel cmdline is ignored.
        # The Debian initrd does DHCP in early boot, which is why al2-5.10 gets
        # a working network for free.  For al2-4.18 we inject a minimal early
        # service that configures the first non-loopback NIC with QEMU SLIRP's
        # fixed addresses before network.target is reached.
        # NOTE: net.ifnames=0 suppresses the kernel's own predictable naming, but
        # RHEL 8 udev's 80-net-setup-link.rules may still rename virtio-net to
        # e.g. ens3 or enp0s2 via the "path" policy in 99-default.link.  The
        # service therefore detects the interface name dynamically instead of
        # hardcoding eth0.
        mkdir -p "$ROOTFS_DIR/etc/systemd/system"
        cat > "$ROOTFS_DIR/etc/systemd/system/qemu-network-setup.service" << 'SVCEOF'
[Unit]
Description=QEMU SLIRP NAT early network setup
Before=network.target network-pre.target
After=basic.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '\
  echo "NETSETUP: finding interface..."; \
  IFACE=; \
  for i in $(seq 60); do \
    IFACE=$(ip link | grep -v ": lo:" | grep -m1 "^[0-9]*:" | cut -d: -f2 | tr -d " " | sed "s/@.*//"); \
    [ -n "$IFACE" ] && break; \
    sleep 0.5; \
  done; \
  echo "NETSETUP: configuring ${IFACE:-NONE}"; \
  [ -z "$IFACE" ] && exit 1; \
  ip link set "$IFACE" up; \
  ip addr add 10.0.2.15/24 dev "$IFACE" 2>/dev/null || true; \
  ip route add default via 10.0.2.2 2>/dev/null || true'
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=network.target
SVCEOF
        mkdir -p "$ROOTFS_DIR/etc/systemd/system/network.target.wants"
        ln -sf /etc/systemd/system/qemu-network-setup.service \
            "$ROOTFS_DIR/etc/systemd/system/network.target.wants/qemu-network-setup.service"

        # ── Configure SSH access (no chroot needed) ───────────────────────────
        step "Configuring SSH access in rootfs..."
        mkdir -p "$ROOTFS_DIR/root/.ssh"
        chmod 700 "$ROOTFS_DIR/root/.ssh"
        echo "$VM_PUBKEY" > "$ROOTFS_DIR/root/.ssh/authorized_keys"
        chmod 600 "$ROOTFS_DIR/root/.ssh/authorized_keys"

        mkdir -p "$ROOTFS_DIR/etc/ssh/sshd_config.d"
        echo "PermitRootLogin yes" > "$ROOTFS_DIR/etc/ssh/sshd_config.d/99-root.conf"

        # Pre-generate SSH host keys so sshd can start without /dev/urandom issues
        ssh-keygen -A -f "$ROOTFS_DIR" 2>/dev/null || true

        # Enable sshd at boot via systemd wants symlink
        mkdir -p "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants"
        for svc in \
            "$ROOTFS_DIR/usr/lib/systemd/system/sshd.service" \
            "$ROOTFS_DIR/lib/systemd/system/sshd.service" \
            "$ROOTFS_DIR/usr/lib/systemd/system/ssh.service" \
            "$ROOTFS_DIR/lib/systemd/system/ssh.service"; do
            if [[ -f "$svc" ]]; then
                ln -sf "${svc#"$ROOTFS_DIR"}" \
                    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/$(basename "$svc")"
                break
            fi
        done

        # ── Bootstrap sshd if not pre-installed ──────────────────────────────────
        # LXC container images are minimal; openssh-server is often absent (e.g. AL2).
        # If sshd is missing, drop a one-shot systemd unit that installs it on first
        # boot via the guest's own package manager.  QEMU's user-mode NAT gives the VM
        # internet access, so yum/apt can reach their public CDN mirrors.
        # The ConditionPathExists guard makes it a no-op on subsequent boots.
        if [[ ! -f "$ROOTFS_DIR/usr/sbin/sshd" && ! -f "$ROOTFS_DIR/sbin/sshd" ]]; then
            warn "sshd not found in rootfs — adding first-boot service to install it (~30–60 s extra)."
            cat > "$ROOTFS_DIR/etc/systemd/system/qemu-bootstrap-sshd.service" <<'SVCEOF'
[Unit]
Description=Bootstrap: install openssh-server for QEMU SSH access
After=network.target
Wants=network.target
ConditionPathExists=!/root/.qemu-sshd-bootstrapped

[Service]
Type=oneshot
TimeoutStartSec=300
ExecStart=/bin/bash -c '\
    echo "BOOTSTRAP: configuring network..."; \
    IFACE=$(ip link | grep -v ": lo:" | grep -m1 "^[0-9]*:" | cut -d: -f2 | tr -d " " | sed "s/@.*//"); \
    echo "BOOTSTRAP: iface=${IFACE:-NONE}"; \
    if [ -n "$IFACE" ]; then \
        ip link set "$IFACE" up 2>/dev/null || true; \
        ip addr add 10.0.2.15/24 dev "$IFACE" 2>/dev/null || true; \
        ip route add default via 10.0.2.2 dev "$IFACE" 2>/dev/null || true; \
    fi; \
    echo "BOOTSTRAP: addrs=$(ip addr show dev "$IFACE" 2>/dev/null | grep "inet " | tr -s " ")"; \
    echo "BOOTSTRAP: routes=$(ip route 2>/dev/null | tr "\n" "|")"; \
    echo "BOOTSTRAP: redirecting yum to public CDN..."; \
    if [ -d /etc/yum.repos.d ]; then \
        mkdir -p /etc/yum/vars; \
        printf cdn > /etc/yum/vars/amazonlinux; \
        printf amazonlinux > /etc/yum/vars/awsregion; \
        printf com > /etc/yum/vars/awsdomain; \
        printf https > /etc/yum/vars/awsproto; \
    fi; \
    printf "nameserver 10.0.2.3\nnameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf; \
    echo "BOOTSTRAP: waiting for TCP connectivity to cdn.amazonlinux.com:443..."; \
    CONNECTED=false; \
    for i in $(seq 1 30); do \
        bash -c "exec 3<>/dev/tcp/cdn.amazonlinux.com/443" 2>/dev/null && CONNECTED=true && break; \
        sleep 2; \
    done; \
    echo "BOOTSTRAP: TCP connected=$CONNECTED"; \
    echo "BOOTSTRAP: hosts=$(grep cdn.amazon /etc/hosts 2>/dev/null || echo none)"; \
    echo "BOOTSTRAP: installing openssh-server"; \
    if command -v yum >/dev/null 2>&1; then \
        yum install -y openssh-server; \
    elif command -v apt-get >/dev/null 2>&1; then \
        DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server; \
    fi'
ExecStartPost=/bin/bash -c 'systemctl enable --now sshd 2>/dev/null || systemctl enable --now ssh 2>/dev/null || true'
ExecStartPost=/bin/bash -c 'touch /root/.qemu-sshd-bootstrapped'
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SVCEOF
            ln -sf /etc/systemd/system/qemu-bootstrap-sshd.service \
                "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/qemu-bootstrap-sshd.service"
        fi

        printf '/dev/vda  /     ext4  defaults  0 1\ntmpfs  /tmp  tmpfs  defaults  0 0\n' \
            > "$ROOTFS_DIR/etc/fstab"

        # ── Fetch kernel from LXC donor disk image (lxc-disk mode) ──────────────
        if [[ "$P_KERNEL_MODE" == "lxc-disk" ]]; then
            [[ -z "$P_KERNEL_DONOR_SPEC" ]] && error "lxc-disk mode requires a KERNEL_DONOR_SPEC"
            step "Fetching kernel from LXC donor: $P_KERNEL_DONOR_SPEC..."

            IFS='/' read -r D_DISTRO D_RELEASE D_ARCH D_VARIANT <<< "$P_KERNEL_DONOR_SPEC"
            D_VARIANT="${D_VARIANT:-cloud}"
            DONOR_URL_BASE="$LXC_BASE/$D_DISTRO/$D_RELEASE/$D_ARCH/$D_VARIANT"

            DONOR_BUILD=$(curl -sf "$DONOR_URL_BASE/" \
                | grep -oE '[0-9]{8}_[0-9]{2}:[0-9]{2}' \
                | sort | tail -1) || true
            [[ -z "$DONOR_BUILD" ]] && error "No builds found for kernel donor at $DONOR_URL_BASE/"
            info "Donor build: $DONOR_BUILD"

            DONOR_QCOW="$WORK_DIR/kernel-donor.qcow2"
            step "Downloading donor disk.qcow2..."
            curl -f --progress-bar -o "$DONOR_QCOW" "$DONOR_URL_BASE/$DONOR_BUILD/disk.qcow2"

            # Convert to raw so dd can extract partitions without losetup
            DONOR_RAW="$WORK_DIR/kernel-donor.raw"
            step "Converting donor image to raw..."
            qemu-img convert -f qcow2 -O raw "$DONOR_QCOW" "$DONOR_RAW"
            rm -f "$DONOR_QCOW"

            # Parse the partition table with Python3 — reads MBR/GPT bytes directly
            # from the raw file, no sfdisk/losetup/block device access needed.
            # Outputs one "START SIZE" line per partition (in 512-byte sectors).
            VMLINUZ_FOUND=false
            DONOR_PART="$WORK_DIR/donor-part.raw"
            while IFS=' ' read -r START SIZE; do
                [[ -z "$START" || -z "$SIZE" ]] && continue
                dd if="$DONOR_RAW" of="$DONOR_PART" bs=512 \
                    skip="$START" count="$SIZE" conv=sparse 2>/dev/null
                # Kernel files may be at root level (separate /boot partition on RHEL-style)
                # or inside /boot (single-partition Debian-style root).
                LS_ROOT=$(debugfs -R "ls /" "$DONOR_PART" 2>/dev/null || true)
                LS_BOOT=$(debugfs -R "ls /boot" "$DONOR_PART" 2>/dev/null || true)
                KDIR=""
                LS_OUT=""
                if echo "$LS_ROOT" | grep -q "vmlinuz-"; then
                    KDIR="/"; LS_OUT="$LS_ROOT"
                elif echo "$LS_BOOT" | grep -q "vmlinuz-"; then
                    KDIR="/boot/"; LS_OUT="$LS_BOOT"
                else
                    continue
                fi
                step "Extracting kernel+initrd from partition at sector $START (kdir=$KDIR)..."
                VMLINUZ_NAME=$(echo "$LS_OUT" | grep -oE 'vmlinuz-[^ <]+' | grep -v '\.hmac$' | sort -V | tail -1 || true)
                # RHEL names it initramfs-*.img; Debian names it initrd.img-*
                INITRD_NAME=$(echo "$LS_OUT" | grep -oE 'initramfs-[^ <]+\.img' | sort -V | tail -1 || true)
                if [[ -z "$INITRD_NAME" ]]; then
                    INITRD_NAME=$(echo "$LS_OUT" | grep -oE 'initrd\.img-[^ <]+' | sort -V | tail -1 || true)
                fi
                [[ -z "$VMLINUZ_NAME" ]] && continue
                debugfs -R "dump ${KDIR}${VMLINUZ_NAME} $WORK_DIR/vmlinuz" "$DONOR_PART" 2>/dev/null || true
                [[ -s "$WORK_DIR/vmlinuz" ]] || { warn "debugfs dump of vmlinuz empty (tried ${KDIR}${VMLINUZ_NAME})"; continue; }
                if [[ -n "$INITRD_NAME" ]]; then
                    debugfs -R "dump ${KDIR}${INITRD_NAME} $WORK_DIR/initrd.img" "$DONOR_PART" 2>/dev/null || true
                fi
                VMLINUZ_FOUND=true
                info "Kernel: $VMLINUZ_NAME"
                [[ -n "$INITRD_NAME" ]] && info "Initrd: $INITRD_NAME"
                break
            done < <(python3 - "$DONOR_RAW" <<'PYEOF'
import struct, sys

def parse(path):
    with open(path, 'rb') as f:
        s0 = f.read(512)
    if len(s0) < 512 or s0[510:512] != b'\x55\xaa':
        return
    if s0[446 + 4] == 0xEE:           # protective MBR → GPT disk
        with open(path, 'rb') as f:
            f.seek(512); h = f.read(512)
        if h[:8] != b'EFI PART':
            return
        elba = struct.unpack_from('<Q', h, 72)[0]
        ne   = struct.unpack_from('<I', h, 80)[0]
        es   = struct.unpack_from('<I', h, 84)[0]
        with open(path, 'rb') as f:
            f.seek(elba * 512); ed = f.read(ne * es)
        for i in range(ne):
            e = ed[i * es:(i + 1) * es]
            if all(b == 0 for b in e[:16]):   # empty type GUID → unused entry
                continue
            s, end = struct.unpack_from('<QQ', e, 32)
            if s > 0:
                print(s, end - s + 1)
    else:                              # MBR / DOS partition table
        for i in range(4):
            e = s0[446 + i * 16:462 + i * 16]
            s, n = struct.unpack_from('<II', e, 8)
            if s > 0 and n > 0 and e[4] != 0:
                print(s, n)

parse(sys.argv[1])
PYEOF
)
            # When kdir=/boot/ the donor partition IS the root filesystem;
            # /lib/modules/ lives on the same partition.  LXC container rootfs
            # images (AL2, etc.) ship no kernel modules because containers share
            # the host kernel.  Copy the donor's modules into the rootfs so that
            # udev can load virtio_net (and other drivers) after switch_root.
            if [[ "$VMLINUZ_FOUND" == "true" && "$KDIR" == "/boot/" && -n "$VMLINUZ_NAME" ]]; then
                KERN_VER="${VMLINUZ_NAME#vmlinuz-}"
                if [[ ! -d "$ROOTFS_DIR/lib/modules/$KERN_VER" ]]; then
                    step "Extracting kernel modules from donor (for $KERN_VER)..."
                    DONOR_MOD_TMP="$WORK_DIR/donor-mod-tmp"
                    rm -rf "$DONOR_MOD_TMP"
                    mkdir -p "$DONOR_MOD_TMP"
                    # debugfs rdump SOURCE DEST creates SOURCE's last path component
                    # as a subdirectory of DEST, so /lib/modules → DEST/modules/
                    debugfs -R "rdump /lib/modules $DONOR_MOD_TMP" "$DONOR_PART" 2>/dev/null || true
                    DONOR_KERN_DIR=""
                    for _cand in \
                        "$DONOR_MOD_TMP/modules/$KERN_VER" \
                        "$DONOR_MOD_TMP/$KERN_VER"; do
                        [[ -d "$_cand" ]] && DONOR_KERN_DIR="$_cand" && break
                    done
                    if [[ -n "$DONOR_KERN_DIR" ]]; then
                        mkdir -p "$ROOTFS_DIR/lib/modules"
                        cp -a "$DONOR_KERN_DIR" "$ROOTFS_DIR/lib/modules/"
                        info "  Kernel modules ($KERN_VER) installed in rootfs"
                    else
                        warn "  Could not find /lib/modules/$KERN_VER in donor; virtio_net may not load"
                    fi
                    rm -rf "$DONOR_MOD_TMP"
                fi
            fi

            rm -f "$DONOR_PART" "$DONOR_RAW"
            [[ "$VMLINUZ_FOUND" != "true" ]] && error "No vmlinuz found in donor disk image"
        fi

        # ── Create disk image from rootfs directory (no mount needed) ─────────
        step "Creating disk image via mkfs.ext4 -d (no losetup required)..."
        RAW_IMAGE="$WORK_DIR/vm.raw"
        DISK_SIZE="${VM_DISK_SIZE:-10G}"
        truncate -s "$DISK_SIZE" "$RAW_IMAGE"
        # Write the filesystem directly onto the raw file — no partition table needed
        # since we boot with -kernel (root=/dev/vda, no partition suffix).
        # This also eliminates the parted + losetup dependency entirely.
        mkfs.ext4 -F -L root -d "$ROOTFS_DIR" "$RAW_IMAGE"
        # Some e2fsprogs versions size the filesystem to directory contents rather
        # than the full file when -d is used; resize2fs corrects that.
        resize2fs "$RAW_IMAGE" &>/dev/null || true

        step "Converting to qcow2..."
        qemu-img convert -f raw -O qcow2 "$RAW_IMAGE" "$DISK_IMAGE"
        rm -f "$RAW_IMAGE"
        info "Disk image ready: $DISK_IMAGE"
    fi

    # Build QEMU command for direct kernel boot
    QEMU_KERNEL="$WORK_DIR/vmlinuz"
    QEMU_INITRD="$WORK_DIR/initrd.img"
    [[ -f "$QEMU_KERNEL" ]] || error "Kernel not found at $QEMU_KERNEL"

    # net.ifnames=0: use eth0 naming so NetworkManager/ifcfg finds the NIC
    KERNEL_APPEND="root=/dev/vda rw console=ttyS0,115200n8 net.ifnames=0 biosdevname=0 ip=10.0.2.15::10.0.2.2:255.255.255.0::eth0:off"

    # shellcheck disable=SC2054
    QEMU_CMD=(
        "$QEMU_BIN"
        "${QEMU_MACHINE_ARGS[@]}"
        -m "$VM_MEMORY"
        -smp "$VM_CPUS"
        -kernel "$QEMU_KERNEL"
        -append "$KERNEL_APPEND"
        -drive "file=${DISK_IMAGE},if=virtio,format=qcow2"
        -netdev "user,id=net0,hostfwd=tcp::${SSH_HOST_PORT}-:22"
        -device virtio-net-pci,netdev=net0
        -display none
        -serial "file:${WORK_DIR}/console.log"
    )
    [[ -f "$QEMU_INITRD" ]] && QEMU_CMD+=(-initrd "$QEMU_INITRD")
    [[ -n "$UEFI_FIRMWARE" ]] && QEMU_CMD+=(-bios "$UEFI_FIRMWARE")
    if [[ -e /dev/kvm ]]; then
        QEMU_CMD+=(-enable-kvm)
    else
        # Without KVM (macOS/Rosetta), QEMU uses TCG software emulation.  The
        # default 32 MB JIT translation-block cache fills up during a heavy
        # dracut initrd boot (full systemd init), and the subsequent forced
        # tb_flush triggers mprotect(PROT_WRITE) on exec pages — which Rosetta
        # blocks with ENOMEM.  A 512 MB cache avoids eviction entirely.
        # shellcheck disable=SC2054
        QEMU_CMD+=(-accel tcg,tb-size=512)
    fi

fi

# ── Boot ──────────────────────────────────────────────────────────────────────
step "Booting VM..."
info "QEMU: ${QEMU_CMD[*]}"
: > "$WORK_DIR/console.log"
"${QEMU_CMD[@]}" &
QEMU_PID=$!
info "QEMU PID: $QEMU_PID"

# ── Wait for SSH ──────────────────────────────────────────────────────────────
# rootfs mode may need extra time on first boot to install openssh-server via yum/apt.
SSH_MAX_WAIT=60
[[ "$P_USERSPACE_FILE" != "disk.qcow2" ]] && SSH_MAX_WAIT=120
step "Waiting for VM SSH (up to $((SSH_MAX_WAIT * 5 / 60)) min)..."
SSH_CONNECTED=false
for i in $(seq 1 $SSH_MAX_WAIT); do
    if ssh "${SSH_OPTS[@]}" root@localhost "echo ok" &>/dev/null; then
        SSH_CONNECTED=true
        info "SSH connected (${i}×5 s = $((i*5)) s elapsed)."
        break
    fi
    sleep 5
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        warn "QEMU exited unexpectedly. Boot console:"
        cat "$WORK_DIR/console.log" >&2
        error "VM boot failed."
    fi
done

if [[ "$SSH_CONNECTED" != "true" ]]; then
    warn "SSH timeout. Boot console:"
    cat "$WORK_DIR/console.log" >&2
    error "Could not SSH into VM after $((SSH_MAX_WAIT * 5 / 60)) minutes."
fi

# ── Copy working directory into VM ───────────────────────────────────────────
step "Copying workdir to VM at /mnt/host..."
ssh "${SSH_OPTS[@]}" root@localhost "mkdir -p /mnt/host"
scp -r -P "$SSH_HOST_PORT" -i "$WORK_DIR/vm_key" \
    -o StrictHostKeyChecking=no -o BatchMode=yes -o LogLevel=ERROR \
    "$HOST_WORKDIR/." root@localhost:/mnt/host/

# ── Install Swift toolchain ───────────────────────────────────────────────────
if [[ "$NO_SWIFT" != "true" ]]; then
    step "Installing Swift toolchain via swiftly..."
    ssh "${SSH_OPTS[@]}" root@localhost \
        "cd /mnt/host && bash scripts/prep-linux-swift.sh --install-swiftly"
fi

# ── Run guest command ─────────────────────────────────────────────────────────
step "Running guest command: $GUEST_COMMAND"
# $GUEST_COMMAND is intentionally expanded on the client side.
# shellcheck disable=SC2087
ssh "${SSH_OPTS[@]}" root@localhost bash <<ENDSSH
[ -f /root/.local/share/swiftly/env.sh ] && . /root/.local/share/swiftly/env.sh
cd /mnt/host
$GUEST_COMMAND
ENDSSH

info "Guest command completed successfully."
