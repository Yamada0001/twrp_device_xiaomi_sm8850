# Byron decryption audit (2026-10-07)

## What was actually established

* The builder defaults to manifest branch `lvgl`. Before this repair, its remote
  head was `ffeeac4`; the vold fork change `4be7a1d` existed only on the remote
  `twrp-16.0` branch. Local `lvgl` being ahead did not update CI.
* `Decrypt_User_Synth_Pass()` tests the Weaver connection before `GetKeySize()`.
  The previously reported `Failed to get weaver key size` therefore does not
  establish that no service registered. It identifies a configuration-query
  failure. The previous client's AIDL failure path discarded the Binder error.
* `Get_Weaver_Data()` advanced an `int*` by one, reading four bytes at offset 4
  of a five-byte file. Android stores a version byte followed by a big-endian
  signed integer at offset 1. The old code also handled only one or two leading
  zeroes, unlike the fixed-width 16-digit protector filenames.
* The inner synthetic-password AES-GCM decrypt supplied an uninitialized tag,
  included the real tag in the ciphertext, and ignored authentication failure.
* The actual selected init builtin table has neither `install_keyring` nor
  `sleep`. Reintroducing these in `5c18159` was incorrect. Removing them does
  not imply a proven explanation for the reported Fastboot loop.

## Device-specific evidence

The local reference archive is
`OurSky_Mi17Max_OS4.0.0.22.XAFCNXM_4158d4_17.zip`. This is a third-party ROM
reference, not a verified official factory image or proof of the installed OS.
Its vendor_boot fstab mounts `modem` at `/vendor/firmware_mnt`. The checked-in
QTI Secure Element ELF contains `/vendor/firmware_mnt/image` as its TA path.
Recovery previously mounted that partition only at `/firmware`.

The checked-in qseecomd ELF publishes `vendor.sys.listeners.registered`.
The NXP Weaver transport links OMAPI/SE interfaces. Registration or a running
PID alone is not evidence that its applet is usable. Root/recovery credentials
are retained: differing stock UIDs alone do not prove an access-control failure.

## Changes

* Mount stock vendor/odm and the eSE firmware path read-only before publishing
  readiness. On NXP devices, mount stock vendor_dlkm and load nxp-nci when
  /dev/nq-nci is absent; do not publish readiness if either step fails.
* Start qseecomd after those mounts, then KeyMint/SE/Weaver when its listener
  readiness property is true. Property actions do not block init waiting for a
  failing service. KeyMint is disabled for implicit class startup, explicitly
  started by this dependency action.
* Mount vendor, odm and firmware before credential decryption; restore the
  firmware child mount after TWRP's temporary vendor-fstab inspection.
* Fix the packed Weaver slot parser and full filename padding in vold; check
  config/slot/key/value bounds; retry only discovery/configuration, never a
  credential read, and preserve failure/status/timeout diagnostics.
* Authenticate the inner GCM envelope before deriving a CE storage secret.
* Pin the vold fork by full commit on both manifest branches. CI verifies that
  pin, runs host regression tests and records resolved source revisions both
  in the release and inside `/system/etc/crypto-source-revisions.txt`.

## Validation and limits

Local tests execute the production Weaver client with fake Binder transports;
they cover absent services, transient/permanent config failures, AIDL/HIDL,
invalid slots and lengths, incorrect keys and throttling with no read retry.
The packed-format tests cover nonzero/multibyte slots and malformed files.
The production GCM helper passes an AES-256-GCM known-answer vector and rejects
altered IV/ciphertext/tag/key and truncated input, using real OpenSSL.
Fifteen shell tests execute the production mount script with sandboxed paths,
fake mounts and module loading. RC command names/argument counts are checked
against selected init source; framework VINTF duplicates and XML syntax are
checked as well.

The October 7 host checks alone did not establish on-device decryption. The
October 10 device validation below provides subsequent runtime evidence. No
phone partitions have been written during this repair; reboot persistence of
the patched image still requires flashing and boot validation.

Useful success evidence is: source revision file matches the release,
`Weaver: configuration ready`, successful authenticated blob unwrap, and
`User 0 Decrypted Successfully!` with accessible CE files. Do not infer success
from service PIDs, a successful build, or a clean `git diff --check` alone.

## Connected-device validation (2026-10-10)

The connected byron phone booted recovery with device-tree revision `923f0e1`,
manifest `719b741` and vold `31534de`. Metadata decryption succeeded, but the
Weaver configuration query returned `Failed to retrieve slots info` before any
PIN-bearing read. Running HAL processes did not establish usable eSE access.

The boot lacked `/dev/nq-nci`. The live device tree identifies `qcom,sn-nci`,
and its installed `vendor_dlkm_a` contains the matching `nxp-nci.ko`. Loading
that module created the node and changed the HAL result from an unknown eSE
vendor to a detected chip. The QTI TA then opened successfully from stock
`/vendor/firmware_mnt/image`.

Mounting stock ODM hid `/odm/bin/mount-stock-vendor.sh`, making subsequent
repair requests exit 127. The helper now lives in `/system/bin`, outside both
stock mounts. Starting the HALs after stock vendor mounts also selected stock
`libbinder.so` alongside recovery `libbinder_ndk.so` and aborted registration
with status -129. Both NXP HALs now preload recovery `libbinder.so`.

The user confirmed that entering the correct PIN successfully decrypted after
the initial live driver/mount/Binder repair. Rebooting the unchanged recovery
partition lost that temporary repair and reproduced the absent device node.
The new mount helper was then executed on-device, and HAL restart wrappers
applied the exact `LD_PRELOAD` value planned for init. The read-only probe
`tests/weaver_config_probe.c` returned:

```
Weaver configuration ready: slots=64 keySize=16 valueSize=16
```

That probe invokes only `IWeaver.getConfig`; it does not call credential `read`
or destructive `write`. It was compiled with Android NDK 28.2 for arm64 API 35.
The recovery partition was backed up and a candidate image was repacked with
the four corrected files, deleting the old ODM helper. All 1308 cpio entries
were compared; exactly those five paths differ, with unrelated contents and
metadata preserved. Header fields were checked. Magiskboot retained the old
AVB hash descriptor, so the unsigned footer was regenerated with the original
salt, partition size, flags, rollback index and properties. Avbtool verified
the resulting recovery SHA-256 descriptor. The original partition remains
unchanged. The candidate has not yet been booted, so its startup ordering and
PIN unlock after a fresh recovery boot remain to be verified.
