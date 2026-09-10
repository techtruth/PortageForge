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
  produces builder-runnable helper binaries

x86_64-pc-linux-gnu-gcc
  target-side compiler name
  runs on the builder
  passes --sysroot=<target sysroot>
  receives the target's explicit CFLAGS/CXXFLAGS from make.conf
```

Wrapper commands are discovered from the isolated BROOT's installed
`<target-CHOST>-*` executables instead of a fixed binutils command list.

That makes cross-aware ebuilds do the important split:

```text
build helper binaries -> CBUILD wrappers, builder-runnable
installed package code -> CHOST wrappers, target-optimized
```

The target `CHOST` stays normal, so target machines do not need a custom
`ACCEPT_CHOSTS` just to consume the binhost.

On startup, the builder syncs the builder repository, verifies that the builder
already has the native commands needed to build packages, then updates the
builder root from source.

After repository sync, the builder runs wrapper probes before starting package
builds. Builder-side probes are compiled and executed. Target-side probes are
compiled only, using the target `CFLAGS` and `CXXFLAGS`.

## Root Role Policy

PortageForge should use the same root roles for microarchitecture-only and
cross-architecture targets:

```text
/                         builder runtime and control plane
<broot>/<target>           builder-runnable native build tools
<sysroot>/<target>         target packages, headers, and libraries
```

The builder runtime owns QEMU startup, mounts, syncs, logging, and binhost
serving. It keeps its own profile and compiler policy and should not receive
target feature overlays.

The target sysroot owns target output policy. It receives the target profile,
target repositories, target selected package roots, target `USE`,
`package.use`, masks, licenses, `ACCEPT_KEYWORDS`, `CHOST`, `CTARGET`,
compiler flags, CPU flags, ABI flags, and package environment files.

The native `BROOT` owns build-time tools that must execute on the builder CPU.
It may receive target feature policy such as global `USE`, `package.use`,
masks, licenses, language targets, `VIDEO_CARDS`, and `LLVM_TARGETS`, but it
must keep builder-runnable output policy. It must not receive target `CHOST`,
`CTARGET`, `CFLAGS`, `CXXFLAGS`, `FCFLAGS`, `FFLAGS`, `LDFLAGS`, CPU flags,
ABI flags, or package environment files that make its binaries target-only.

Keyword policy has to be role-aware. The target sysroot uses the target's
literal keywords, such as `~arm64`. A cross-architecture `BROOT` uses the
builder-architecture equivalent, such as `~amd64`, while preserving the same
stable or testing intent. In same-architecture microarchitecture builds, those
keywords are usually identical.

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
etc/locale.conf                 # when present
etc/locale.gen                  # when present
etc/portage/
```

Package-managed runtime state such as `etc/env.d`, `etc/eselect`,
`etc/python-exec`, and `etc/java-config-2` is intentionally excluded. Packages
create that state when they merge into the fresh target sysroot.

The package sidecar contains the target's selected package roots from
`/var/lib/portage/world`. PortageForge also builds `@system` and the dependency
closure, so dependency packages are not forced into the resolver as independent
top-level requests. To build additional packages for a target, add package atoms
to that target's `*.packages` file or add them to the target's world file before
exporting.

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
mkfs.ext4
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
images/portageforge-data.raw
images/seed.iso
vm/targets/
vm/data/
```

`portageforge-data.raw` is a sparse 500 GiB ext4 data disk by default. Override
its size when it is first created with, for example,
`PORTAGEFORGE_DATA_DISK_SIZE=1T make setup`. The launcher attaches it as a
VirtIO block device. The guest owns its normal Unix permissions, ACLs, xattrs,
and file capabilities without a host-filesystem translation layer.

The launcher exports `vm/targets/` and `vm/data/` as read-only shares.
`vm/targets/` supplies target snapshots; `vm/data/` supplies only optional
builder configuration. Writable target-build state and binpackages live on the
data disk. Binpackages remain available through the HTTP service, but are no
longer ordinary files under `vm/data/` on the host.
Cloud-init installs the current `scripts/portageforge-builder` into the VM at
`/usr/local/sbin/portageforge-builder` and starts it through systemd.

Older `vm/data/targets/` caches are not imported into the new data disk. The
first run therefore starts a fresh binhost cache. `make pristine` removes both
the VM boot disk and the persistent data disk.

Re-run `make setup` when you need to recreate the VM disks, change bootstrap
SSH access, update the in-VM builder script, or change the service embedded in
`images/seed.iso`. Replacing target snapshots, package lists, or runtime config
does not require rebuilding the seed.

Optional runtime settings can be placed in:

```text
vm/data/portageforge-builder.env
```

Example:

```sh
PORTAGEFORGE_BUILDER_CHOST=x86_64-portageforge-linux-gnu
PORTAGEFORGE_BUILDER_COMMON_FLAGS="-O2 -pipe -march=x86-64"
PORTAGEFORGE_BUILD_JOBS=2
PORTAGEFORGE_SYNC_ATTEMPTS=3
PORTAGEFORGE_SYNC_RETRY_SECONDS=60
PORTAGEFORGE_BUILD_INTERVAL_SECONDS=86400
PORTAGEFORGE_BINHOST_PORT=8080
```

`PORTAGEFORGE_BUILD_JOBS` defaults to the lower of one fewer than the
VM-visible CPU count and a conservative memory limit. The memory limit reserves
2 GiB for the guest and budgets 2 GiB per build job. The same value limits
Portage concurrency and the GNU make load average. An explicit setting overrides
both default limits.

The QEMU launcher also accepts:

```sh
PORTAGEFORGE_QEMU_ACCEL=kvm
PORTAGEFORGE_QEMU_CPU=host
PORTAGEFORGE_MEMORY_MB=16384
PORTAGEFORGE_HOST_SSH_BIND=127.0.0.1
PORTAGEFORGE_HOST_SSH_PORT=2222
PORTAGEFORGE_HOST_BINHOST_BIND=127.0.0.1
PORTAGEFORGE_HOST_BINHOST_PORT=8080
```

The VM receives 8192 MiB by default; QEMU does not automatically assign all
host memory to it. Set `PORTAGEFORGE_MEMORY_MB` in the environment that runs
`make run`, while leaving enough RAM for the host.

Using KVM is fine for true-cross mode because target package binaries are not
executed by the builder.

The QEMU host forwards bind to `127.0.0.1` by default. To intentionally expose
the SSH or binhost ports to other machines, set the corresponding
`PORTAGEFORGE_HOST_*_BIND` value to the host address you want to listen on.

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
http://127.0.0.1:8080/targets/<target-hostname>/binpkgs/
```

## Builder Behavior

On VM startup, PortageForge does this:

```text
mount host vm/targets at /mnt/portageforge-targets
mount host vm/data read-only at /mnt/portageforge-config
mount the ext4 data disk at /var/lib/portageforge-data
validate builder build commands
update the builder runtime @world
validate ACL, xattr, and file capability copying on the data disk
start the HTTP binhost server
```

Each build cycle then does this:

```text
for each /mnt/portageforge-targets/*.tar:
  validate and load the target snapshot and package list
  confirm the target CHOST matches the builder GCC target
  recreate /var/lib/portageforge-data/state/targets/<target>/sysroot from stage3
  recreate /var/lib/portageforge-data/state/broots/<target>/root from stage3
  prepare binpkg, distfiles, and Portage temp directories for the portage user
  copy the target /etc/portage policy and locale configuration into that sysroot
  append PortageForge cross-build settings
  select the target profile from the synced repository
  copy target feature policy into the isolated native BROOT
  write builder-safe compiler settings into the isolated native BROOT
  select the isolated BROOT profile from the synced repository
  declare target executables non-runnable through Gentoo's shared sysroot policy
  create CBUILD wrappers in isolated BROOT /usr/local/bin and CHOST wrappers
  mount repo, data, target sysroot, and target tmp paths into the isolated BROOT
  run emerge --sync from inside the isolated BROOT with the target config root
  compile/run BROOT wrapper probes and compile target wrapper probes
  emptytree-install target build dependencies for @system and the target package roots
  refresh discovered wrappers and rerun the wrapper probes
  emerge @system and the target package roots with --emptytree --buildpkg
  run emaint binhost --fix for the target PKGDIR
  unmount the isolated BROOT runtime filesystems
sleep 24 hours
```

PortageForge emits modern `.gpkg.tar` binary packages. The legacy `xpak` format
is not supported.

The target sysroot and isolated native BROOT are disposable builder state. They
are recreated from stage3 for each target build so stale packages from earlier
resolver attempts cannot stay installed and poison slot transitions. The raw
data disk persists between VM boots and holds the binpkg cache, shared
distfiles, build trees, sysroots, and BROOTs; the sysroot and BROOT contents are
replaced at the start of each target build.

The isolated native BROOT receives a copy of the target's Portage feature
policy, including global `USE`, `package.use`, `package.accept_keywords`,
masks, unmask files, licenses, and non-CPU `USE_EXPAND` values such as
`VIDEO_CARDS`, `LLVM_TARGETS`, `PYTHON_TARGETS`, and `LUA_SINGLE_TARGET`.
PortageForge replaces the BROOT `make.conf` with generated builder-safe output
policy: `CBUILD` and `CHOST` are the fake builder tuple, `ACCEPT_CHOSTS`
permits both the fake builder tuple and the target tuple during stage3
bootstrap, and `COMMON_FLAGS`, `CFLAGS`, `CXXFLAGS`, `FCFLAGS`, and `FFLAGS`
use `PORTAGEFORGE_BUILDER_COMMON_FLAGS`. Target `package.env` and target
`/etc/portage/env` are not copied into BROOT.

Target compiler flags, CPU flags, target `CHOST`, target `CTARGET`, and target
package environment files stay on the target sysroot side. Cross emerges run
inside the isolated BROOT chroot with `BROOT=/`,
`ROOT=<target sysroot>`, `SYSROOT=<target sysroot>`, and
`PORTAGE_CONFIGROOT=<target sysroot>`.

Target build dependencies are installed with `--emptytree --onlydeps` so
stage3's preinstalled package database does not decide target-policy USE or
Python slot transitions. Target package outputs are merged under
`ROOT=<target sysroot>` with `SYSROOT=<target sysroot>` and the target
snapshot's `/etc/portage` policy. Native `BDEPEND` tools resolve against the
isolated BROOT; target `DEPEND` and `RDEPEND` resolve against the target
sysroot. Cross emerges use `--autounmask=n`; missing USE, keyword, or
USE_EXPAND target policy must be fixed on the target and exported again.

Gentoo's shared `sysroot.eclass` normally assumes that target executables can
run directly when `CBUILD` and `CHOST` use the same ISA. That assumption does
not hold when the builder CPU lacks the target microarchitecture features.
PortageForge creates a per-target eclass override from the currently synced
Gentoo eclass and makes its standard `sysroot_make_run_prefixed` interface
report that target execution is unavailable. Build-system eclasses consume
that shared answer without package or build-system-specific handling.

`PKGDIR`, `DISTDIR`, and `PORTAGE_TMPDIR` are prepared as writable directories
for the VM's `portage` user before each target build. This matters because
Portage fetch/build workers do not always run as root. PortageForge also removes
stale `.__portage_test_write__` and `*.__download__` files, then verifies the
`portage` user can create and remove a probe file before `emerge` starts.
PortageForge does not disable or exclude xattrs. Startup fails immediately if
the data disk cannot create and copy a POSIX ACL, ordinary xattr, and file
capability.

## Target Setup

On each target Gentoo machine:

```ini
# /etc/portage/binrepos.conf/portageforge.conf
[portageforge]
priority = 50
sync-uri = http://127.0.0.1:8080/targets/<target-hostname>/binpkgs/
```

If the target is not the same host running QEMU, expose or proxy the binhost
deliberately and use that reachable address instead.

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

then Portage is not seeing a non-empty target `ROOT`/`SYSROOT`, or that ebuild
phase is still trying to execute a freshly built target binary. In the
true-cross runner, glibc is merged into the target sysroot with
`--root=<target sysroot>`, so Gentoo's glibc preinstall sanity check should not
execute the freshly built target loader on the builder CPU.

Check the builder log for:

```text
[portageforge] starting true-cross microarchitecture-only builder
[portageforge] isolated BROOT: /var/lib/portageforge-data/state/broots/<target>/root
[portageforge] target Portage tmpdir: /var/lib/portageforge-data/tmp/targets/<target>
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

If dependency resolution reports package-specific USE or USE_EXPAND
constraints, update the target's `/etc/portage` policy and export a fresh
target snapshot.

For packages that need incompatible Lua implementations, keep that policy
package-specific on the target instead of forcing one global Lua target for
everything:

```conf
# /etc/portage/package.use/lua
media-video/wireplumber LUA_SINGLE_TARGET: -* lua5-4
app-editors/neovim LUA_SINGLE_TARGET: -* luajit
```

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
