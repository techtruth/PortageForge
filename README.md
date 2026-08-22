# PortageForge

PortageForge builds Gentoo binary packages for target machines inside a QEMU
TCG Gentoo VM. The VM applies each target's Portage policy and target CPU
flags, then serves the resulting binhosts itself over HTTP.

```text
target Gentoo machines
  export hostname-named target snapshots and package lists

QEMU TCG Gentoo VM
  runs emerge --sync
  applies one target Portage policy at a time
  builds @portageforge-binhost-packages for each target
  runs emaint binhost --fix
  writes each target's binpkgs/distfiles to a host shared directory
  serves the target binhost directories on port 8080

target Gentoo machines
  install optimized binary packages from their VM binhost paths
```

## Why QEMU

A normal container cannot safely build `-march=znver4` packages on a host CPU
that cannot execute `znver4` binaries. The builder eventually runs programs it
has built, such as Python, GCC helpers, build tools, tests, and generated
utilities.

QEMU TCG gives the build environment an emulated CPU instead of the host CPU.
That makes the VM the correct place to run the target-optimized Gentoo system.
It is much slower than native hardware, but it keeps the model honest.

## Target Snapshot

Generate the snapshot on each target Gentoo machine:

```sh
make export-target-state
```

By default this writes:

```text
vm/targets/<target-hostname>.tar
vm/targets/<target-hostname>.packages
```

The `*.tar` file contains target configuration/state. The `*.packages` sidecar
contains unversioned, unslotted package atoms derived from the target's installed
package database. The VM reads `vm/targets/` through a read-only QEMU 9p share.

The snapshot contains:

```text
metadata/hostname
metadata/profile
metadata/exported-at
etc/env.d/                      # when present
etc/eselect/                    # when present
etc/java-config-2/              # when present
etc/locale.gen                  # when present
etc/python-exec/                # when present
etc/portage/
usr/src/linux                   # when present
```

The primary build target is stored outside the tar:

```text
vm/targets/<target-hostname>.packages
```

The builder copies that sidecar into the VM as the
`@portageforge-binhost-packages` Portage set, then compiles the newest visible
versions allowed by the target profile, `make.conf`, USE flags, masks, keywords,
package config, and overlays.

The snapshot may contain private overlay URLs, package environment files, local
paths, hostnames, and other machine-specific Portage data. Treat it as private
host configuration, not as a public artifact.

## Package Requests

When you want the VM to prebuild software for every target that is not yet in
the exported binhost package sets, add package atoms on the QEMU host:

```text
vm/targets/requested-packages
```

## Host Setup

The host only needs these tools:

```text
curl
genisoimage
qemu-img
qemu-system-x86_64
sha256sum
OVMF firmware at /usr/share/OVMF/OVMF_CODE_4M.fd, or set OVMF_CODE
```

Install QEMU with the host OS package manager. The host can be Debian, Gentoo,
or anything else that can run QEMU.

The Makefile is the normal host interface:

```sh
make help
```

Fetch a ready-to-boot Gentoo cloud-init QCOW2 image:

```sh
make setup
```

To use a specific SSH public key for the VM root login:

```sh
make setup SSH_PUBLIC_KEY=~/.ssh/id_ed25519.pub
```

To set a root password for console login and SSH password login:

```sh
make setup ROOT_PASSWORD='change-me'
```

You can provide both:

```sh
make setup SSH_PUBLIC_KEY=~/.ssh/id_ed25519.pub ROOT_PASSWORD='change-me'
```

If neither value is provided, setup uses `~/.ssh/id_ed25519.pub` or
`~/.ssh/id_rsa.pub` when present. Passwords are written into
`images/cloud-init/user-data` and `images/seed.iso`, so treat those files as
sensitive.

That gives you:

```text
images/portageforge.qcow2   # bootable Gentoo VM image
images/seed.iso             # first-boot cloud-init bootstrap only
vm/targets/                 # target snapshots, package lists, and requests
vm/data/targets/            # host-visible per-target binpkg and distfile storage
```

The boot QCOW2 is resized to 300 GiB of virtual capacity so
`PORTAGE_TMPDIR` has working room. QCOW2 storage is sparse, so the file grows
as the VM actually writes data.

`images/seed.iso` exists because the downloaded Gentoo cloud image expects
cloud-init data on first boot. PortageForge uses it only to:

```text
install your SSH public key for root and/or set a root password
write /usr/local/sbin/portageforge-builder into the VM
write a systemd service for the builder into the VM
enable sshd and the PortageForge builder service
```

The builder script is embedded into `images/seed.iso` as cloud-init `write_files`
content and written into the VM at `/usr/local/sbin/portageforge-builder`.
Its source lives at `scripts/portageforge-builder`; `vm/targets/` is only for
target input files such as target snapshot tars, package lists, and requests.

All QEMU host filesystem shares are inside this project's `vm/` directory. The
launcher exports `vm/targets/` as read-only and `vm/data/` as writable.

Re-run `make setup` when you need to recreate the VM disks, change the
bootstrap SSH key, change the root password, or update the in-VM
builder/service scripts embedded in `images/seed.iso`. Replacing target
snapshots, package lists, or request files does not require rebuilding the seed.

The QEMU launcher uses:

```text
-accel tcg,thread=multi
-cpu max
UEFI/OVMF firmware
first-boot cloud-init seed ISO for SSH/bootstrap
read-only vm/targets directory shared into the VM with QEMU 9p
writable vm/data directory shared into the VM with QEMU 9p
host port 2222 -> VM port 22
host port 8080 -> VM port 8080
```

`make run` calls `scripts/run-portageforge-builder`, which is only a small
wrapper around the QEMU command. It uses one fewer vCPU than the host reports, with
a minimum of one.

## Run The Builder

Boot the prepared VM:

```sh
make run
```

Cloud-init handles the in-VM service install on first boot. To watch logs with
the default QEMU SSH forward:

```sh
ssh -p 2222 root@localhost
tail -f /var/log/portageforge-builder.log
```

If you set `ROOT_PASSWORD`, the QEMU console login is `root` with that password.

On start, `portageforge-builder` mounts `vm/data/` from the host at
`/mnt/portageforge-data` in the VM. Binary packages and distfiles stay directly
visible on the host. Portage build temp stays inside the VM at
`/var/tmp/portageforge/targets/<target-hostname>`, because package builds need
normal VM filesystem behavior and create a lot of small-file churn.

The service runs:

```text
/usr/local/sbin/portageforge-builder
```

It serves binary packages from per-target URLs:

```text
http://<qemu-host>:8080/targets/<target-hostname>/binpkgs/
```

It repeats the sync/build/index cycle once every 24 hours.

## Builder Behavior

The VM builder does this on each cycle:

```text
mount host vm/targets at /mnt/portageforge-targets
mount host vm/data at /mnt/portageforge-data
run emerge --sync
for each /mnt/portageforge-targets/*.tar:
  load /mnt/portageforge-targets/<target-hostname>.packages
  restore target /etc/portage policy
  set the target Gentoo profile
  append PortageForge output paths to make.conf
  build @portageforge-binhost-packages and @portageforge-requested
  run emaint binhost --fix
serve /mnt/portageforge-data over HTTP
sleep 24 hours
```

The binhost emits modern `.gpkg.tar` binary packages. The legacy `xpak` format
is not supported by this project.

## Target Setup

On each target Gentoo machine, point binary package downloads at that target's
QEMU binhost path:

```ini
# /etc/portage/binrepos.conf/portageforge.conf
[portageforge]
priority = 50
sync-uri = http://<qemu-host>:8080/targets/<target-hostname>/binpkgs/
```

To prefer this binhost by default:

```conf
# /etc/portage/make.conf
FEATURES="${FEATURES} getbinpkg"
```

Packages from this project are unsigned by default, so leave
`binpkg-request-signature` disabled unless you add signing.

## Notes

The VM and target should sync against compatible Gentoo repository state. This
version assumes both systems run `emerge --sync` normally. If exact repository
matching becomes necessary, the VM can grow a repository snapshot service later.

QEMU TCG is slow. It is the correctness path when the physical build host cannot
execute the target CPU instructions, but a real target-compatible build machine
will be much faster.

If the target package set includes kernel/module/EFI packages and `make.conf`
points at secureboot keys, those keys must exist at the same paths inside the VM
or those packages may fail.

If QEMU does not emulate an instruction exposed by the VM CPU model or generated
by the target flags, affected packages may fail at build or test time. Start
with the default `-cpu max`; use `qemu-system-x86_64 -cpu help` to inspect other
CPU models.

References:

- Gentoo Binary Package Guide: <https://wiki.gentoo.org/wiki/Binary_package_guide>
- Gentoo binary package handbook notes: <https://wiki.gentoo.org/wiki/Handbook:Parts/Working/Features>
- QEMU system emulation: <https://www.qemu.org/docs/master/system/introduction.html>
