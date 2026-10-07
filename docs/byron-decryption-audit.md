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
  readiness. Remove vendor_dlkm as a prerequisite for userspace crypto services.
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
Eight shell tests execute the production mount script with sandboxed paths and
fake mounts. RC command names/argument counts are checked against selected init
source; framework VINTF duplicates and XML syntax are checked as well.

These checks are not an Android build or an on-device Binder/eSE integration
test. No full recovery image has been built or booted during this audit. No
successful PIN-to-CE unlock has been observed. Firmware compatibility, eSE
applet access and any vendor-specific Android 17 synthetic-password extensions
remain runtime validation requirements. No phone partitions were written.

Useful success evidence is: source revision file matches the release,
`Weaver: configuration ready`, successful authenticated blob unwrap, and
`User 0 Decrypted Successfully!` with accessible CE files. Do not infer success
from service PIDs, a successful build, or a clean `git diff --check` alone.
