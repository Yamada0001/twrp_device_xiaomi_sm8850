#!/system/bin/sh
#=================================================
# Auto-set device properties based on hardware SKU
#=================================================
set -u

variant=$(getprop ro.boot.hardware.sku)
setprop ro.twrp.hardware_sku "$variant"
base_name="Xiaomi"
log_file="/tmp/recovery.log"

log() {
    echo "variant-script.sh: $1" | tee -a "$log_file"
}

#-------------------------------------------------
# Helper: set multiple vibrator-related properties
#-------------------------------------------------
set_vibrator_props() {
    resetprop ro.odm.mm.vibrator.audio_haptic_support "true"
    resetprop ro.odm.mm.vibrator.lowPowerMode "true"
    resetprop ro.odm.mm.vibrator.resonant_frequency "$1"
    resetprop ro.odm.mm.vibrator.slide_effect_protect_time "$2"
    resetprop ro.odm.mm.vibrator.sys_path "$3"
    resetprop ro.odm.mm.vibrator.device_type "$4"
    resetprop ro.vendor.mm.vibrator.sys_path "/sys/class/qcom-haptics"
}

#-------------------------------------------------
# Only expose recovery on the two supported SKUs. Other SM8850 products use
# different display, touch, security and partition configurations.
#-------------------------------------------------
case "$variant" in
"popsicle")
    model="$base_name 17 Pro Max"
    resetprop ro.twrp.device_version "Xiaomi_17_Pro_Max"
    resetprop ro.twrp.y_offset "116"
    resetprop ro.twrp.h_offset "-116"
    resetprop ro.odm.mm.vibrator.cirrus "true"
    resetprop vendor.display.enable_spr "1"
    resetprop vendor.display.enable_spr_bypass "1"
    # Popsicle uses the NXP Weaver implementation in its stock ODM.
    resetprop ro.twrp.weaver "nxp"
    set_vibrator_props "130" "20" "/sys/bus/i2c/drivers/cs40l26/13-0043" "ff"
    ;;

"byron")
    model="$base_name 17 Max"
    resetprop ro.twrp.device_version "Xiaomi_17_Max"
    resetprop ro.twrp.y_offset "116"
    resetprop ro.twrp.h_offset "-116"
    resetprop vendor.display.enable_spr "1"
    resetprop vendor.display.enable_spr_bypass "1"
    resetprop ro.twrp.weaver "nxp"
    set_vibrator_props "170" "35" "/sys/class/qcom-haptics" "ff"
    ;;

"pudding"|"pandora"|"nezha"|"myron"|"athens"|"songyuan")
    log "Unsupported recovery SKU: $variant"
    setprop ro.twrp.unsupported_device "1"
    exit 1
    ;;

*)
    log "Unknown recovery SKU: $variant"
    setprop ro.twrp.unsupported_device "1"
    exit 1
    ;;
esac

# TWRP 3.7's legacy crypto probe reads this property before requesting
# Weaver data. Qualcomm KeyMint on SM8850 implements KeyMint 4.
setprop keymaster_ver 4

#-------------------------------------------------
# Common configuration
#-------------------------------------------------
echo "$model" >/config/usb_gadget/g1/strings/0x409/product
resetprop vendor.usb.product_string "$model"
mkdir -p /usbotg

#-------------------------------------------------
# Set product & model properties
#-------------------------------------------------
for prop in \
    ro.build.product ro.product.device ro.product.odm.device \
    ro.product.vendor.device ro.product.product.device \
    ro.product.system_ext.device ro.product.system.device \
    ro.product.bootimage.device ro.product.name ro.product.odm.name \
    ro.product.vendor.name ro.product.product.name \
    ro.product.system_ext.name ro.product.system.name; do
    resetprop "$prop" "$variant"
done

for prop in \
    ro.product.model ro.product.odm.model ro.product.vendor.model \
    ro.product.product.model ro.product.system_ext.model \
    ro.product.system.model; do
    resetprop "$prop" "$model"
done

#-------------------------------------------------
# Copy variant-specific files
#-------------------------------------------------
if [ -d "/odm/variant/$variant/odm" ]; then
    # Overlay contents are optional across SKUs. Do not abort recovery
    # startup when a vendor image omits an optional file or directory.
    cp -rf /odm/variant/$variant/odm/. /odm/ 2>/dev/null || \
        log "Warning: failed to copy all $variant overlay files"
    chmod -R 755 /odm/bin/* 2>/dev/null || true
else
    log "No overlay for $variant, keeping the base odm"
fi
setprop twrp.variant.files_copied "1"

#-------------------------------------------------
# Done
#-------------------------------------------------
log "Applied variant props for: $model ($variant)"
exit 0
