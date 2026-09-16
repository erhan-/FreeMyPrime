# FreeMyPrime — persistent root SSH on the signed Denon DJ / Engine OS generation

This is the confirmed procedure for getting a
**persistent root SSH** shell on newer Denon DJ devices based on the signed
inMusic `AZ0x` / Engine OS platform.

Questions, corrections or hardware reports: **[@i.erhan.es](https://instagram.com/i.erhan.es)** on Instagram.

Status: **confirmed working on the reference unit** — a real 4.3.1 SC Live 4
(`JP21`, Rockchip RK3288; serial redacted) — **surviving reboots**, with the
signed / dm-verity boot chain completely untouched. The same platform, boot
chain and `/data` layout are shared by **SC Live 2 (`JP20`)**, **Prime GO Plus
(`JP11S`)** and **Prime 4 Plus (`JC11S`)**.

---

## TL;DR

The rootfs is dm-verity protected on every version, so don't touch it. Instead,
`/data` is a plain unsigned partition that backs the `/etc` overlay. Flash one
prepared `/data` image that drops an `/etc/ld.so.preload` payload; glibc runs it
as root when Engine starts, which starts `sshd`.

```sh
# build the payload (once)
arm-linux-gnueabihf-gcc -shared -fPIC -O2 -o tools/preload/freemymprime.so tools/preload/freemymprime.c
tools/make_data_overlay.sh --pubkey ~/.ssh/id_ed25519.pub --password denon \
    --out work/data-ssh.img --size 6240

# enter update mode: power off, hold BACK + FWD + Encoder, power on
fastboot flash data work/data-ssh.img
fastboot reboot

# now and after every reboot
ssh root@<device-ip>          # or: ssh -i ~/.ssh/id_ed25519 root@<device-ip>
```

No signature is broken, no rootfs/kernel/U-Boot is modified, and dm-verity stays
active. Details and pitfalls below.

**Credentials:** user `root`, password `denon` (or the public key you supplied to
`--pubkey`). Both password and key auth are enabled. **Change them when done.**

This is the "`/data` overlay" route. It needs no code execution on an
already-running system, no signature to defeat, and no U-Boot changes. It works
because the writable state that `/etc` is built from is not protected.

---

## Why it works

1. `/data` (`/dev/mmcblk0p11`) is a normal, unsigned, non-verity ext4 partition.
2. `/etc` is an overlayfs whose **upper layer is `/data/system/etc/overlay`**
   (confirmed live: `overlay on /etc type overlay (... upperdir=/data/system/etc/overlay ...)`).
   So files we put in the upper appear in `/etc`.
3. On 4.3.x, `overlayfs.conf` has **no wipe directives** (5.0.4 added removes for
   `passwd`/`shadow`/`group`/`gshadow`/`ssh`). Changes persist.
4. systemd *loads* units from the overlay but does not reliably *start* ones that
   appear after the target was resolved. So a unit is not dependable here.
5. `/etc/ld.so.preload` is dependable: glibc reads it on **every dynamically
   linked exec**, and `engine.service` execs Engine as root after the overlay is
   mounted. A preloaded shared object runs our payload as root without systemd.

So the payload is:

- `/data/ssh/freemymprime.so` — tiny armv7 glibc shared object (only `GLIBC_2.4`
  symbols). Its constructor forks `/data/ssh/setup.sh`, once per boot (marker in
  `/run`).
- `/data/system/etc/overlay/ld.so.preload` containing `/data/ssh/freemymprime.so`.
- `/data/ssh/setup.sh` — sets a fallback root password, generates a host key,
  starts `sshd -f /data/ssh/sshd_config`.
- `/data/ssh/sshd_config` — key + password auth, `UsePAM no`.
- `/data/system/etc/overlay/systemd/system/freemymprime.service` (+ `.wants`
  symlink) — belt-and-braces; not required.

The rootfs, kernel FIT, FIT signatures and dm-verity are never modified. The live
command line still shows:

```
dm-mod.create="rootfs,,,ro,0 1024000 verity 1 /dev/mmcblk0p10 ..."
```

---

## Reproduce

Prerequisites (Debian/Ubuntu/WSL):

```sh
sudo apt install gcc-arm-linux-gnueabihf e2fsprogs
```

```sh
# 1. Build the payload (needs e2fsprogs + an armv7 cross compiler)
arm-linux-gnueabihf-gcc -shared -fPIC -O2 \
    -o tools/preload/freemymprime.so tools/preload/freemymprime.c
tools/make_data_overlay.sh \
    --pubkey ~/.ssh/id_ed25519.pub --password denon \
    --out work/data-ssh.img --size 6240      # full partition size, see gotchas

# 2. Enter update mode (BACK + FWD + Encoder + power) and flash
fastboot flash data work/data-ssh.img
fastboot reboot

# 3. Log in (key you supplied, or root / denon)
ssh -i ~/.ssh/id_ed25519 root@<device-ip>
```

---

## Gotchas (learned the hard way)

- **Do not `resize2fs` `/data` after flashing.** `/sbin/az01-data-mkfs` runs
  `fsck.ext4 -y` and treats any correction (exit 1) as a hard failure, so
  `data.mount` is then skipped and the whole overlay disappears — including
  `/etc/ld.so.preload`. Build the image at the full partition size instead
  (the partition is `6551023` KiB ≈ 6249 MiB; `--size 6240` is safe).
- **Fastboot lies about size.** `fastboot flash` prints
  `Sending sparse 'data' 1/1 (N KB)` where N is the sparse payload, not the
  image size. The device expands it; the write time (~230 s for 6 GiB) is the
  real indicator.
- `oem fetch-pubkey:denon-1` is safe; `oem fetch-pubkey:stage2-denon-1` makes the
  device stream key bytes and desyncs non-interactive `fastboot` clients (replug
  USB to recover).
- Windows transport: the Denon updater uses `libusb-1.0.dll` and works; usbipd
  into WSL works once USBPcap is removed. Once attached, Linux `fastboot` talks
  to it with no driver work.

---

## What is *not* possible (so far)

- **Modified rootfs**: blocked. dm-verity is enforced on every version, including
  the oldest (2.3.3). A modified rootfs boot-loops and falls back to fastboot.
- **Downgrading** to escape signing/verity: no. 2.3.3 is already `AZ0x` +
  `sha256,rsa2048:denon-1` + verity.
- **U-Boot env override of `bootargs`** (the actual signature bypass): the env is
  `nowhere` (non-persistent) and `bootdelay=-2` (autoboot fires with no window),
  so this needs either a live U-Boot console (UART; untested whether input
  reaches U-Boot) or a patched/replaced bootloader (eFuse state unknown). That
  remains the interesting open research question; this method does not need it.

---

## Security notes

- This grants persistent root. Change the password or remove the payload when done.
- Remove by erasing/reformatting `/data` (factory data reset) or deleting
  `/data/ssh` and `/data/system/etc/overlay/ld.so.preload`.
- `/data` is wiped by the procedure, so back up the unit's library first.
- Keep units off untrusted networks while SSH is enabled.

---

## Repository layout

```
README.md                     this document (the whole method)
tools/
  make_data_overlay.sh        build a flashable /data image that enables persistent root SSH
  preload/freemymprime.c      LD_PRELOAD payload (source); build with arm-linux-gnueabihf-gcc
```

No firmware images, vendor source drops, keys or compiled binaries are committed
here — see [`.gitignore`](.gitignore).

---

## Legal / ethical

This is interoperability and security research on hardware we own. Firmware
images are vendor-copyrighted and are **not** committed here (see `.gitignore`).
No vendor source drops, keys or compiled binaries are included.

Modifying a device can brick it. Most situations can be fixed via fastboot.
