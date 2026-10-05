#!/system/bin/sh

# Wait for logical mapper nodes, then mount the stock runtime needed by
# KeyMint and NXP Weaver.
set -u

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
    mkdir -p "$target"
    if grep -q "[[:space:]]$target[[:space:]]" /proc/mounts; then
        return 0
    fi
    wait_for_node "/dev/block/mapper/${name}" || return 1
    mount -o ro "/dev/block/mapper/${name}" "$target" 2>/dev/null && return 0
    mount -t erofs -o ro "/dev/block/mapper/${name}" "$target" 2>/dev/null && return 0
    mount -t ext4 -o ro "/dev/block/mapper/${name}" "$target" 2>/dev/null
}

if mount_logical vendor_a /vendor &&
   mount_logical odm_a /odm &&
   mount_logical vendor_dlkm_a /vendor_dlkm; then
    setprop twrp.stock_vendor_mounted 1
else
    log -t twrp "stock logical vendor stack is unavailable"
    setprop twrp.stock_vendor_mounted 0
fi
