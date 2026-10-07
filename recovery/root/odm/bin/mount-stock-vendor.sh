#!/system/bin/sh

# Wait for logical mapper nodes, then mount the stock runtime needed by
# KeyMint and NXP Weaver.
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
if ! mount_logical "vendor${slot_suffix}" /vendor ||
   ! mount_logical "odm${slot_suffix}" /odm; then
    log "stock vendor/odm unavailable for slot $slot_suffix"
    exit 1
fi

# The QTI Secure Element binary loads its TA from this exact stock path.
# /firmware alone is insufficient. The directory already exists in stock vendor.
firmware_node="/dev/block/bootdevice/by-name/modem${slot_suffix}"
if ! grep -q '[[:space:]]/vendor/firmware_mnt[[:space:]]' /proc/mounts; then
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

# vendor_dlkm is for modules, not a prerequisite for these userspace HALs.
# TWRP's module loader manages it separately.
setprop twrp.stock_vendor_mounted 1
log "stock vendor, odm and eSE firmware ready for slot $slot_suffix"
