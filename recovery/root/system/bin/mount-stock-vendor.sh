#!/system/bin/sh

# Wait for logical mapper nodes, then mount the stock crypto runtime needed
# by KeyMint and NXP Weaver.
set -u

log_file="/tmp/recovery.log"

log() {
    echo "mount-stock-vendor.sh: $1" >> "$log_file"
    /system/bin/log -t twrp "$1"
}

wait_for_node() {
    node="$1"
    i=0
    while [ ! -e "$node" ] && [ "$i" -lt 30 ]; do
        sleep 1
        i=$((i + 1))
    done
    [ -e "$node" ]
}

mount_logical() {
    name="$1"
    target="$2"
    node="/dev/block/mapper/${name}"
    mkdir -p "$target"
    if grep -q "[[:space:]]${target}[[:space:]]" /proc/mounts; then
        return 0
    fi
    wait_for_node "$node" || return 1

    # Logical dm nodes can appear before their contents are ready to mount.
    i=0
    while [ "$i" -lt 30 ]; do
        mount -t erofs -o ro "$node" "$target" 2>/dev/null && return 0
        mount -t ext4 -o ro "$node" "$target" 2>/dev/null && return 0
        sleep 1
        i=$((i + 1))
    done

    log "failed to mount $name ($node) at $target after ${i}s"
    return 1
}

slot_suffix="$(getprop ro.boot.slot_suffix)"
case "$slot_suffix" in
    _a|_b) ;;
    *)
        log "invalid boot slot suffix: $slot_suffix"
        setprop twrp.stock_vendor_mounted 0
        exit 1
        ;;
esac

# Clear stale readiness before repairing mounts after TWRP's vendor probe.
setprop twrp.stock_vendor_mounted 0

# Setup_Fstab_Partitions writes this after its module/vendor probes and before
# requesting metadata decryption. The ramdisk has no /etc/fstab at boot.
if ! wait_for_node /etc/fstab; then
    log "TWRP partition probe did not finish"
    exit 1
fi

if [ "$(getprop ro.twrp.weaver)" = "nxp" ] && [ ! -e /dev/nq-nci ]; then
    # TWRP replaces /vendor/lib/modules while loading touch drivers. Stock
    # modules.dep also contains absolute paths there. Keep this module outside
    # both of those temporary mounts and use its already-loaded dependency.
    module_mount=/mnt/twrp-vendor-dlkm
    if ! mount_logical "vendor_dlkm${slot_suffix}" "$module_mount"; then
        log "stock vendor_dlkm unavailable for the NXP eSE driver"
        exit 1
    fi
    if ! wait_for_node /sys/module/smcinvoke_dlkm; then
        log "smcinvoke_dlkm dependency missing for the NXP eSE driver"
        exit 1
    fi
    if ! insmod "$module_mount/lib/modules/nxp-nci.ko" >> "$log_file" 2>&1; then
        log "failed to load the stock nxp-nci module"
        exit 1
    fi
    if ! wait_for_node /dev/nq-nci; then
        log "nxp-nci loaded but /dev/nq-nci did not appear"
        exit 1
    fi
fi

if ! mount_logical "vendor${slot_suffix}" /vendor ||
   ! mount_logical "odm${slot_suffix}" /odm; then
    log "stock vendor/odm unavailable for slot $slot_suffix"
    exit 1
fi

# The QTI Secure Element binary loads its TA from this exact stock path.
# /firmware alone is insufficient. The directory already exists in stock vendor.
firmware_node="/dev/block/bootdevice/by-name/modem${slot_suffix}"
if ! grep -q '[[:space:]]/vendor/firmware_mnt[[:space:]]' /proc/mounts ||
   [ ! -d /vendor/firmware_mnt/image ]; then
    # A new parent /vendor mount can hide an older child still in /proc/mounts.
    if ! wait_for_node "$firmware_node" ||
       ! mount -t vfat -o ro,uid=1000,gid=1000,dmask=227,fmask=337 \
           "$firmware_node" /vendor/firmware_mnt; then
        log "cannot mount eSE firmware at /vendor/firmware_mnt"
        exit 1
    fi
fi
if [ ! -d /vendor/firmware_mnt/image ]; then
    log "eSE firmware image directory missing"
    exit 1
fi

setprop twrp.stock_vendor_mounted 1
log "stock vendor, odm, eSE firmware and driver ready for slot $slot_suffix"
