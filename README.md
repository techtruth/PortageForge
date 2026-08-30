# PortageForge

PortageForge builds Gentoo binary packages for target machines using a
true-cross build model. The target keeps its normal Gentoo `CHOST`, while the
builder uses a deliberately different `CBUILD` identity so Portage and upstream
build systems take the cross-compilation paths.

```text
builder VM
  CBUILD=x86_64-portageforge-linux-gnu
  runs Portage, shell, Python, GCC, pkg-config, CMake, Ninja, etc.
  never executes target-optimized package binaries

target sysroot
  CHOST=x86_64-pc-linux-gnu
  uses the target machine's /etc/portage policy and CPU flags
  receives target headers, libraries, package database, and merge state

target Gentoo machines
  install normalized x86_64-pc-linux-gnu binpkgs from PortageForge
```

This is meant for the hard case where the physical builder, container host, or
QEMU CPU cannot execute the target's CPU instructions. For example, the builder
can be unable to run `-march=znver4` binaries while still compiling binpkgs that
the Zen 4 target will run later.

PortageForge is deliberately scoped to microarchitecture-only builds. The
builder's native GCC target, reported by `gcc -dumpmachine`, must match the
target snapshot's `CHOST`. The fake builder `CBUILD` may only change the
vendor/name field, such as:

```text
native GCC target: x86_64-pc-linux-gnu
builder CBUILD:    x86_64-portageforge-linux-gnu
target CHOST:      x86_64-pc-linux-gnu
```

If the target changes architecture, ABI, libc, or OS tuple, PortageForge stops
early instead of pretending the wrapper model is a real cross toolchain.

## Build Model

PortageForge does not chroot into the target root. It runs `emerge` from the
builder root with:

```text
CBUILD=x86_64-portageforge-linux-gnu
CHOST=<target CHOST, usually x86_64-pc-linux-gnu>
ROOT=<target sysroot>
SYSROOT=<target sysroot>
PORTAGE_CONFIGROOT=<target sysroot>
```

The builder creates two wrapper toolchain views:

```text
x86_64-portageforge-linux-gnu-gcc
  builder-side compiler name
  runs on the builder
  uses builder-safe flags

x86_64-pc-linux-gnu-gcc
  target-side compiler name
  runs on the builder
  passes --sysroot=<target sysroot>
  receives the target's explicit CFLAGS/CXXFLAGS from make.conf
```

That makes cross-aware ebuilds do the important split:

```text
build helper binaries -> CBUILD wrappers, builder-safe
installed package code -> CHOST wrappers, target-optimized
```

The target `CHOST` stays normal, so target machines do not need a custom
`ACCEPT_CHOSTS` just to consume the binhost.

On startup, the builder verifies that the builder root has native toolchain
basics such as `gcc`, `g++`, `make`, and binutils. If they are missing, it asks
Portage to install them as builder-native packages before any target build
starts.

After repository sync, the builder runs wrapper probes before starting package
builds. Builder-side probes are compiled and executed. Target-side probes are
compiled only, using the target `CFLAGS` and `CXXFLAGS`.

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

The snapshot tar contains:

```text
metadata/hostname
metadata/profile
metadata/chost
metadata/exported-at
etc/env.d/                      # when present
etc/eselect/                    # when present
etc/java-config-2/              # when present
etc/locale.conf                 # when present
etc/locale.gen                  # when present
etc/python-exec/                # when present
etc/portage/
usr/src/linux                   # when present
```

The package sidecar contains repo-qualified package entries derived from the
target's installed package database, such as `category/package::gentoo`.
`::gentoo` package entries are active by default; non-`::gentoo` entries are
preserved but commented out. To build additional packages for a target, add or
uncomment repo-qualified entries in that target's `*.packages` file.

True-cross snapshots reject `-march=native` and `-mtune=native`. Use explicit
target flags instead:

```conf
COMMON_FLAGS="-O2 -pipe -march=znver4 -mtune=znver4"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
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

QEMU is used as a convenient Gentoo builder appliance. It is not used to run
target binaries, so the QEMU CPU model does not need to support the target's
spicy CPU flags.

The Makefile is the normal host interface:

```sh
make help
make setup
make run
```

To use a specific SSH public key for the VM root login:

```sh
make setup SSH_PUBLIC_KEY=~/.ssh/id_ed25519.pub
```

To set a root password for console login and SSH password login:

```sh
make setup ROOT_PASSWORD='change-me'
```

If neither value is provided, setup uses `~/.ssh/id_ed25519.pub` or
`~/.ssh/id_rsa.pub` when present. Passwords are written into
`images/cloud-init/user-data` and `images/seed.iso`, so treat those files as
sensitive.

This creates:

```text
images/portageforge.qcow2
images/seed.iso
vm/targets/
vm/data/targets/
```

The launcher exports `vm/targets/` as read-only and `vm/data/` as writable.
Re-run `make setup` when you need to recreate the VM disks, change bootstrap
SSH access, or update the in-VM builder script embedded in `images/seed.iso`.
Replacing target snapshots or package lists does not require rebuilding the
seed.

Optional runtime settings can be placed in:

```text
vm/data/portageforge-builder.env
```

Example:

```sh
PORTAGEFORGE_BUILDER_CHOST=x86_64-portageforge-linux-gnu
PORTAGEFORGE_BUILDER_COMMON_FLAGS="-O2 -pipe -march=x86-64"
PORTAGEFORGE_BUILD_JOBS=8
PORTAGEFORGE_BUILD_INTERVAL_SECONDS=86400
PORTAGEFORGE_BINHOST_PORT=8080
```

The QEMU launcher also accepts:

```sh
PORTAGEFORGE_QEMU_ACCEL=kvm
PORTAGEFORGE_QEMU_CPU=host
PORTAGEFORGE_MEMORY_MB=16384
PORTAGEFORGE_HOST_SSH_PORT=2222
PORTAGEFORGE_HOST_BINHOST_PORT=8080
```

Using KVM is fine for true-cross mode because target package binaries are not
executed by the builder.

## Run The Builder

Boot the prepared VM:

```sh
make run
```

Watch logs through the default SSH forward:

```sh
ssh -p 2222 root@localhost
tail -f /var/log/portageforge-builder.log
```

The builder serves each target binhost at:

```text
http://<qemu-host>:8080/targets/<target-hostname>/binpkgs/
```

## Builder Behavior

Each cycle does this:

```text
mount host vm/targets at /mnt/portageforge-targets
mount host vm/data at /mnt/portageforge-data
for each /mnt/portageforge-targets/*.tar:
  validate and load the target snapshot and package list
  confirm the target CHOST matches the builder GCC target
  create or reuse /var/lib/portageforge/targets/<target>/sysroot from stage3
  prepare binpkg, distfiles, and Portage temp directories for the portage user
  restore the target /etc/portage policy into that sysroot
  append PortageForge cross-build settings
  create CBUILD and CHOST wrapper toolchains
  run emerge --sync with the target config root
  compile/run builder wrapper probes and compile target wrapper probes
  update already-installed private sysroot packages for current target policy
  install/update private cross-build dependencies
  emerge target packages with --buildpkg into the target sysroot
  run emaint binhost --fix for the target PKGDIR
serve /mnt/portageforge-data over HTTP
sleep 24 hours
```

PortageForge emits modern `.gpkg.tar` binary packages. The legacy `xpak` format
is not supported.

The target sysroot is long-lived builder state. PortageForge keeps it aligned
with the current target policy by updating already-installed private build
dependencies before resolving new ones. Cross-build resolver calls request
changed-use, changed-deps, and changed-slot rebuilds, while disabling
complete-graph preservation that would otherwise keep stale private build
dependencies in the graph.

`PKGDIR`, `DISTDIR`, and `PORTAGE_TMPDIR` are prepared as writable directories
for the VM's `portage` user before each target build. This matters because
Portage fetch/build workers do not always run as root.

## Target Setup

On each target Gentoo machine:

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

## Known Hard Parts

True-cross builds depend on ebuilds and upstream build systems respecting
`CBUILD` versus `CHOST`. Packages that try to execute freshly built target
binaries will fail. That is useful: it exposes the exact packages that need
patches, cache answers, disabled PGO/tests, or package-specific overrides.

If `sys-libs/glibc` fails in `pkg_preinst` with:

```text
Last-minute run tests with ./ld-linux-x86-64.so.2
Illegal instruction
simple run test (/usr/bin/cal) failed
```

then the builder is still running a native/chroot-style install path, or Portage
is not seeing a non-empty target `ROOT`. In the true-cross runner, glibc is
merged into the target sysroot with `--root=<target sysroot>`, so Gentoo's glibc
preinstall sanity check should not execute the freshly built target loader on
the builder CPU.

Check the builder log for:

```text
[portageforge] starting true-cross microarchitecture-only builder
[portageforge] target Portage tmpdir: /var/tmp/portageforge/targets/<target>
```

If the build log still uses `/var/tmp/portageforge/portage/...`, recreate the
VM seed and boot state so the current builder script is actually running:

```sh
make pristine
make setup
make run
```

If cloud-init logs stop after:

```text
Running command ['/var/lib/cloud/instance/scripts/runcmd']
```

then the first-boot bootstrap is stuck before the builder service starts. Make
sure the generated `portageforge-builder.service` does not include
`After=cloud-final.service`, then rerun `make setup` so `images/seed.iso`
contains the fixed unit.

If dependency resolution reports multiple package instances in one slot, such
as an installed private dependency with one USE or `PYTHON_TARGETS` shape and a
scheduled dependency with another, PortageForge should update that stale sysroot
package in place. If the conflict survives with the current script, the next
place to look is the package-specific USE or `PYTHON_TARGETS` constraint shown
by Portage's verbose conflict output.

Expect the first rough edges around:

```text
sys-devel/gcc
sys-devel/llvm and clang
dev-lang/rust
dev-lang/go
dev-lang/python
dev-lang/perl
dev-lang/ruby
Qt
ICU
protobuf
Firefox and Chromium-class packages
packages with PGO or test-heavy build phases
```

References:

- Gentoo `CBUILD`/`CHOST` and `BDEPEND`/`DEPEND`: <https://devmanual.gentoo.org/general-concepts/dependencies/>
- Portage `ROOT`, `SYSROOT`, and `PORTAGE_CONFIGROOT`: <https://dev.gentoo.org/~zmedico/portage/doc/man/emerge.1.html>
- Portage `ACCEPT_CHOSTS`: <https://dev.gentoo.org/~zmedico/portage/doc/man/make.conf.5.html>
- Gentoo binary package notes: <https://wiki.gentoo.org/wiki/Handbook:Parts/Working/Features>
- Gentoo amd64 stage3 autobuilds: <https://distfiles.gentoo.org/releases/amd64/autobuilds/>
