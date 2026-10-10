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
  readiness. Wait for TWRP's generated `/etc/fstab` before mounting them.
  On NXP devices, mount stock vendor_dlkm independently at
  `/mnt/twrp-vendor-dlkm` and load nxp-nci when `/dev/nq-nci` is absent;
  verify the already-loaded smcinvoke dependency. Do not publish readiness if
  any step fails.
* Start qseecomd after those mounts, then KeyMint/SE/Weaver when its listener
  readiness property is true. Property actions do not block init waiting for a
  failing service. KeyMint is disabled for implicit class startup, explicitly
  started by this dependency action.
* Mount vendor, odm and firmware before credential decryption; restore the
  firmware child mount after TWRP's temporary vendor-fstab inspection.
* Keep the touch-report executable in `/system/bin`, outside the stock ODM
  mount. Start it once modules, variant setup and stock mounts are ready, with
  `/odm/lib64` in its library path.
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
Twenty shell tests execute the production mount script with sandboxed paths,
fake mounts and module loading. RC command names/argument counts are checked
against selected init source; framework VINTF duplicates and XML syntax are
checked as well.

The October 7 host checks alone did not establish on-device decryption. The
October 10 device validation below provides subsequent runtime evidence. With
the user's approval, the patched image was written only to recovery_a and
read back to verify its hash. A fresh recovery boot initialized the driver,
KeyMint, eSE and Weaver and decrypted metadata automatically. The final image
also starts the touch-report daemon from its persistent path. User PIN entry
then completed CE decryption, as confirmed by the recovery success message,
user-decryption properties and accessible CE directories.

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
with status -129. KeyMint and both NXP HALs now preload recovery `libbinder.so`.

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
The recovery partition was backed up before flashing. The first candidate
boot exposed a race: TWRP temporarily replaces `/vendor/lib/modules` and
unmounts vendor and its firmware child while probing partitions. The stock
modules.dep contains absolute `/vendor/lib/modules` paths, so merely changing
modprobe's search directory does not avoid that race. Direct insmod from an
independent read-only vendor_dlkm mount, after the generated `/etc/fstab`
appears, avoids both temporary mounts. A stale firmware child mount hidden by
a new parent vendor mount is repaired when its image directory is absent.
KeyMint also needed the Binder preload when started from mounted stock vendor.

The second candidate contains five corrected files and deletes the old ODM
helper. All 1308 cpio entries were compared; exactly those six paths differ,
with unrelated contents and metadata preserved. Header fields were checked.
Magiskboot retained the old AVB hash descriptor, so the unsigned footer was
regenerated with the original salt, partition size, flags, rollback index and
properties. Avbtool verified the resulting recovery SHA-256 descriptor.

After the authorized flash, recovery_a readback SHA-256 matched:

```
8ad4271c9d348f4c87a06e7b1f32c727c565b772b177241155b964804ff1bf86
```

A fresh boot of that image, with no temporary HAL wrappers or manual module
loading, created `/dev/nq-nci`, opened the eSE TA, connected OMAPI, and returned
the Weaver configuration above. KeyMint, eSE and Weaver process mappings all
use recovery Binder. Recovery logged successful metadata decryption to
`/dev/block/mapper/userdata` and displayed the PIN page.

The user reported unavailable touch after the second candidate boot. Both
kernel modules and `Xiaomi_Touch_Input_0` were present; the stock ODM mount hid
the ramdisk-only `/odm/bin/touch_report` executable. Temporarily running the
same binary from `/system/bin` loaded the stock touch libraries and restored
operation, after which PIN unlock succeeded. That temporary daemon ended when
the USB connection changed, so it did not establish persistence.

The final V3 image moves the binary to `/system/bin/touch_report` and starts it
as the existing init service, with `/odm/lib64` explicitly searched after stock
mount readiness. Its binary bytes are unchanged. All 1308 cpio entries were
compared again; exactly nine intended paths differ from the original. AVB
verification and recovery_a readback matched the final SHA-256:

```
f410850645aac90b30c46af67c57a98340a66ca39f4234a819a2e0832ac88c68
```

After reboot, init started `odm.touch_report` with parent PID 1 from the new
path. Touch libraries were mapped from stock ODM, and the recovery UI recorded
page changes. This fresh boot logged `User 0 Decrypted Successfully!`, with
`twrp.user.0.decrypt=1`, `twrp.all.users.decrypted=true` and accessible
`/data/media/0` and `/data/system_ce/0`. No PIN value was requested or recorded
by these diagnostics. These results validate the connected byron device and
installed OS; other SKUs and other vendor/kernel revisions were not boot-tested.
