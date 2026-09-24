#!/bin/sh
# Reset a dedicated Alpine LiteVMM test host to a near-fresh state.
# Keeps the Alpine base system and OpenSSH. Git is kept by default.
# If invoked through sudo, sudo is also kept to avoid locking out the admin user.
set -eu
umask 022

KEEP_GIT=1
KEEP_SUDO=auto
ASSUME_YES=0

usage() {
    cat <<'EOF'
Usage: reset-alpine-host.sh [--yes] [--no-git] [--keep-sudo|--purge-sudo]

Destructively removes the installed LiteVMM/VMAPI stack from an Alpine host:
  - stops LiteVMM, VM, Docker, Lighttpd, NFS and tunnel processes
  - removes LiteVMM bridges/TAPs, mounts, services, binaries, config and data
  - removes Docker state, LiteVMM certificates and Let's Encrypt state
  - removes the vmapi user/groups and LiteVMM cron entries
  - purges packages installed by the LiteVMM Alpine installer
  - leaves Alpine base + OpenSSH + CA certificates; Git is kept by default
  - keeps sudo automatically when the script was invoked through sudo

This script is intended for disposable/dedicated LiteVMM development VMs.
EOF
}

log() {
    printf '\n==> %s\n' "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes|-y) ASSUME_YES=1 ;;
        --no-git) KEEP_GIT=0 ;;
        --keep-sudo) KEEP_SUDO=1 ;;
        --purge-sudo) KEEP_SUDO=0 ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || die "Run as root, for example: sudo ./reset-alpine-host.sh --yes"
[ -r /etc/os-release ] || die "/etc/os-release is missing"
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = "alpine" ] || die "This reset script only supports Alpine Linux"

if [ "$KEEP_SUDO" = auto ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-root}" != root ]; then
        KEEP_SUDO=1
    else
        KEEP_SUDO=0
    fi
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    cat >&2 <<'EOF'
This is DESTRUCTIVE.

It deletes all LiteVMM VMs, disks, backups, replicas, peer state, Docker
containers/images/volumes, certificates, generated web configuration and
installed LiteVMM tooling from this host. It also purges the packages that
LiteVMM installs through APK.

The source checkout containing this script is NOT deleted.
EOF
    printf '\nType PURGE-LITEVMM to continue: ' >&2
    read -r answer
    [ "$answer" = "PURGE-LITEVMM" ] || die "Cancelled"
fi

service_stop_disable() {
    svc=$1
    if command -v rc-service >/dev/null 2>&1; then
        rc-service "$svc" stop >/dev/null 2>&1 || true
    fi
    if command -v rc-update >/dev/null 2>&1; then
        rc-update del "$svc" default >/dev/null 2>&1 || true
        rc-update del "$svc" boot >/dev/null 2>&1 || true
    fi
}

delete_vmapi_bridges() {
    if [ -x /usr/local/bin/netctl ]; then
        for f in /etc/vmapi/bridges/*.conf; do
            [ -f "$f" ] || continue
            name=$(basename "$f" .conf)
            /usr/local/bin/netctl bridge-delete "$name" >/dev/null 2>&1 || true
        done
    fi

    if command -v ip >/dev/null 2>&1; then
        for p in /sys/class/net/vmo-* /sys/class/net/tap[0-9]*; do
            [ -e "$p" ] || continue
            name=$(basename "$p")
            ip link delete dev "$name" >/dev/null 2>&1 || true
        done
    fi
}

delete_overlays() {
    if [ -x /usr/local/bin/overlayctl ]; then
        for f in /etc/vmapi/overlays/*.conf; do
            [ -f "$f" ] || continue
            name=$(basename "$f" .conf)
            /usr/local/bin/overlayctl delete "$name" >/dev/null 2>&1 || true
        done
    fi
}

unmount_vmapi() {
    # Unmount deepest paths first. /proc/mounts escaping is irrelevant for the
    # LiteVMM paths, which do not contain whitespace.
    if [ -r /proc/mounts ]; then
        awk '$2 ~ "^/var/lib/vmapi/" { print $2 }' /proc/mounts 2>/dev/null |
            sort -r 2>/dev/null |
            while IFS= read -r mp; do
                umount "$mp" >/dev/null 2>&1 || umount -l "$mp" >/dev/null 2>&1 || true
            done
    fi

    umount /var/lib/vmapi/backplane/shared/isos >/dev/null 2>&1 || true
    umount /proc/fs/nfsd >/dev/null 2>&1 || true
}

remove_cron_entries() {
    if [ -f /etc/crontabs/root ]; then
        tmp=$(mktemp /tmp/litevmm-cron.XXXXXX)
        awk '!/# vmapi-backup:/' /etc/crontabs/root > "$tmp"
        cat "$tmp" > /etc/crontabs/root
        chmod 0600 /etc/crontabs/root 2>/dev/null || true
        rm -f "$tmp"
    fi
    rm -f /etc/cron.d/vmapi-backup-* 2>/dev/null || true
}

remove_tun_module_line() {
    if [ -f /etc/modules ]; then
        tmp=$(mktemp /tmp/litevmm-modules.XXXXXX)
        awk '$0 != "tun"' /etc/modules > "$tmp"
        cat "$tmp" > /etc/modules
        rm -f "$tmp"
    fi
}

remove_litevmm_binaries() {
    tools='
vmapi vmapi-web-reload vmctl imagectl netctl dockerctl dockerexecctl hostexecctl
logctl docker-imagectl docker-netctl docker-volumectl dockercompoectl
docker-federationctl docker-rootfsctl litevmm-docker litevmm-runc metricsctl
consolectl peerctl vmbackupctl replicationctl registryctl peer-volumectl
backplanectl filectl storagectl overlayctl certctl vmapi-console-gc
vmapi-autostart vmapi-stopall websocat wsvpn
vm-list vm-show vm-status vm-create vm-set vm-start vm-stop vm-shutdown vm-reboot
vm-restart vm-delete vm-disk-add vm-disk-remove vm-disk-resize vm-disk-set
vm-nic-add vm-nic-remove vm-nic-set vm-pci-add vm-pci-remove vm-cloud-init-set
vm-cloud-init-show vm-cloud-init-disable vm-console-info vm-command
metrics-host vm-metrics docker-metrics
docker-list docker-show docker-status docker-create docker-update docker-start
docker-stop docker-restart docker-delete
'
    for name in $tools; do
        rm -f "/usr/local/bin/$name"
    done

    # Only remove /usr/local/bin/docker if it is LiteVMM's federation shim.
    if [ -f /usr/local/bin/docker ] &&
       grep -Fq 'LiteVMM Docker CLI federation shim' /usr/local/bin/docker 2>/dev/null; then
        rm -f /usr/local/bin/docker
    fi

    # Older iterations used GOST. Remove it only when it is accompanied by the
    # LiteVMM share/marker tree or looks like a LiteVMM-managed binary path.
    if [ -f /usr/local/bin/gost ] && [ -d /usr/local/share/litevmm ]; then
        rm -f /usr/local/bin/gost
    fi
}

remove_vmapi_account() {
    if command -v deluser >/dev/null 2>&1; then
        deluser vmapi >/dev/null 2>&1 || true
    elif command -v userdel >/dev/null 2>&1; then
        userdel vmapi >/dev/null 2>&1 || true
    fi

    if command -v delgroup >/dev/null 2>&1; then
        delgroup vmapi >/dev/null 2>&1 || true
        delgroup vmapi-admin >/dev/null 2>&1 || true
    elif command -v groupdel >/dev/null 2>&1; then
        groupdel vmapi >/dev/null 2>&1 || true
        groupdel vmapi-admin >/dev/null 2>&1 || true
    fi
}

purge_litevmm_packages() {
    # This is the union of packages currently installed by install.sh on Alpine.
    # apk del removes them from the world set; dependencies are pruned when no
    # remaining package needs them.
    packages='
bash coreutils findutils gawk grep sed shadow util-linux iproute2 iputils curl
openssl sudo tar gzip zip jq fcgiwrap spawn-fcgi lighttpd lighttpd-openrc
lighttpd-mod_auth apache2-utils openssh-client-default
iptables nftables socat kmod tcpdump qemu-img qemu-system-x86_64 ovmf novnc
ttyd xorriso nfs-utils docker docker-openrc docker-cli-compose certbot
'

    remove=''
    for pkg in $packages; do
        [ "$pkg" = sudo ] && [ "$KEEP_SUDO" -eq 1 ] && continue
        if apk info -e "$pkg" >/dev/null 2>&1; then
            remove="$remove $pkg"
        fi
    done

    if [ -n "$remove" ]; then
        # shellcheck disable=SC2086
        apk del --purge $remove || true
    fi
}

log "Stopping LiteVMM workloads and services"

if [ -x /usr/local/bin/vmapi-stopall ]; then
    /usr/local/bin/vmapi-stopall >/dev/null 2>&1 || true
fi
if [ -x /usr/local/bin/replicationctl ]; then
    /usr/local/bin/replicationctl suspend >/dev/null 2>&1 || true
fi
if [ -x /usr/local/bin/backplanectl ]; then
    /usr/local/bin/backplanectl suspend >/dev/null 2>&1 || true
fi

delete_overlays
delete_vmapi_bridges

for svc in \
    vmapi-replication vmapi-overlay vmapi-network vmapi-autostart \
    vmapi-console-gc ttyd-vmapi ttyd-host-vmapi \
    vmapi-backplane vmapi-backplane-server fcgiwrap-vmapi \
    websockify-vmapi docker lighttpd nfs nfs-server
do
    service_stop_disable "$svc"
done

# Kill residue from interrupted iterations. This host reset is intentionally
# dedicated-host destructive.
for proc in \
    qemu-system-x86_64 qemu-kvm wsvpn websocat gost ttyd fcgiwrap lighttpd \
    dockerd containerd
do
    killall "$proc" >/dev/null 2>&1 || true
done

if command -v exportfs >/dev/null 2>&1; then
    exportfs -u '127.0.0.1:/var/lib/vmapi/backplane' >/dev/null 2>&1 || true
fi
if command -v rpc.nfsd >/dev/null 2>&1; then
    rpc.nfsd 0 >/dev/null 2>&1 || true
fi

unmount_vmapi
remove_cron_entries
remove_tun_module_line

log "Removing LiteVMM OpenRC services, binaries and configuration"

rm -f \
    /etc/init.d/fcgiwrap-vmapi \
    /etc/init.d/vmapi-autostart \
    /etc/init.d/vmapi-console-gc \
    /etc/init.d/ttyd-vmapi \
    /etc/init.d/ttyd-host-vmapi \
    /etc/init.d/vmapi-overlay \
    /etc/init.d/vmapi-network \
    /etc/init.d/vmapi-replication \
    /etc/init.d/vmapi-backplane \
    /etc/init.d/vmapi-backplane-server \
    /etc/init.d/websockify-vmapi \
    /etc/sudoers.d/vmapi \
    /etc/vmapi-peer.htpasswd \
    /etc/pam.d/nginx-vmapi

remove_litevmm_binaries

rm -rf \
    /etc/vmapi \
    /usr/local/lib/vmapi \
    /usr/local/share/litevmm \
    /usr/lib/vmapi \
    /usr/share/vmapi \
    /run/vmapi \
     /run/vmapi-overlay \
    /run/vmapi-backplane \
    /var/lib/vmapi \
    /var/log/vmapi

# These stacks are installed only to support LiteVMM on the dedicated Alpine
# development VM. Removing their state prevents one test iteration from
# influencing the next.
rm -rf \
    /etc/lighttpd \
    /var/log/lighttpd \
    /etc/docker \
    /var/lib/docker \
    /var/lib/containerd \
    /run/docker \
    /run/containerd \
    /etc/qemu \
    /etc/letsencrypt \
    /var/lib/letsencrypt \
    /var/log/letsencrypt \
    /var/lib/nfs

remove_vmapi_account

log "Ensuring the packages that must survive are present"

keep='alpine-base openssh ca-certificates'
[ "$KEEP_GIT" -eq 1 ] && keep="$keep git"
[ "$KEEP_SUDO" -eq 1 ] && keep="$keep sudo"

# shellcheck disable=SC2086
apk add --no-cache $keep

log "Purging packages installed by the LiteVMM Alpine installer"
purge_litevmm_packages

# A packae purge may have changed dependency choices. Reassert the minimal keep
# set once more and make sure SSH remains enabled.
# shellcheck disable=SC2086
apk add --no-cache $keep

if command -v rc-update >/dev/null 2>&1; then
    rc-update add sshd default >/dev/null 2>&1 || true
fi
if command -v rc-service >/dev/null 2>&1; then
    rc-service sshd start >/dev/null 2>&1 || true
fi

rm -rf /var/cache/apk/* 2>/dev/null || true

log "Reset complete"
printf 'Kept packages: Alpine base, OpenSSH, CA certificates'
[ "$KEEP_GIT" -eq 1 ] && printf ', Git'
[ "$KEEP_SUDO" -eq 1 ] && printf ', sudo'
printf '.\n'
printf 'LiteVMM installed state and package footprint have been removed.\n'
printf 'The source checkout was intentionally left in place so install.sh can be run again.\n'
