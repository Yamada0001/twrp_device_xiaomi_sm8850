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

if mount_logical "vendor${slot_suffix}" /vendor &&
   mount_logical "odm${slot_suffix}" /odm &&
   mount_logical "vendor_dlkm${slot_suffix}" /vendor_dlkm; then
    # Start crypto HALs only after their stock libraries and manifests are
    # visible. This avoids relying on custom init property triggers, which
    # recovery init rejects on some Android releases.
    start vendor.qseecomd
    start vendor.keymint
    start vendor.secure_element
    case "$(getprop ro.twrp.weaver)" in
        nxp) start odm.weaver_nxp ;;
        thales) start odm.weaver_hal_service ;;
        goodix)
            start odm.secure_element_hal_service
            start odm.goodix_weaver_hal_service
            ;;
    esac
    setprop twrp.stock_vendor_mounted 1
else
    log "stock logical vendor stack is unavailable for slot $slot_suffix"
    setprop twrp.stock_vendor_mounted 0
fi
