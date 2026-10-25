# Logging kernel allocation component

This component implements the fixed shared page allocation described in
[the storage worker design](logging-storage-worker-design.md). It does not yet
provide the support-library product, process owner, storage child, application
startup composition or packaging integration.

The parent allocator accepts no data descriptor or filesystem path. Linux
creates an anonymous, sealed 16 KiB memfd. Darwin uses a fixed private directory
lease and PSXSHM namespace, validates actual directory mounts, and unlinks the
fresh kernel object before returning its mapping. All returned descriptors are
at least 11 and atomically close on exec. Ordinary application file candidates
are never data-opened by this allocator.

The eventual process owner must allow only one allocation attempt. On Darwin,
an unsuccessful fresh-name unlink deliberately retains its directory lease until
process exit; retrying allocations could accumulate retained leases. The
allocator is an internal implementation function, not a public retryable API.

## Executed component checks

Strict C11 builds with warnings treated as errors passed on Linux x86-64 and
HanSolo Apple Silicon macOS 26.6, using deployment target 15.0. Linux also passed
AddressSanitizer and UndefinedBehaviorSanitizer. A deployment target is not
evidence of execution on macOS 15.

The real kernel-object fixture checks:

- Initial zero bytes, exact size, UID, mode, link count and descriptor flags.
- Shared writes visible across an actual fork.
- Rejection of zero, shrink and grow truncations in the parent, fork child and
  deliberately inheriting exec child.
- Descriptor closure across ordinary exec and intentional inheritance at fd 10.
- Allocation and exec with each of the seven nonempty closed-stdio masks.
- A real external-process POSIX lock probe: closing an ordinary hardlink alias
  first proves that the fixture detects lock loss; allocating and releasing the
  kernel page then preserves the reacquired application-file lock.
- Darwin refusal of an unexpected locked ordinary file in the staging root and
  a nonempty slot, refusal when all 64 slot leases are held, safe zero-size stale
  object replacement, preservation of an unsafe mode-0400 stale object, and
  successful allocation after fixture cleanup.

Darwin tests compile an explicit test context, a private fixture base and a
nonproduct kernel prefix. CMake derives the test prefix from the build directory
so separate build roots do not reclaim each other's test objects. No fixture
executes the production `/ofdg1` namespace. The fixture creates at most the 64
known slot directories under its private build root.

The actual kernel-target CMake block was also extracted unchanged into a small
component project and built and tested on both hosts: one CTest passed, zero
skipped, on each. This checks the new target and private test definitions; it is
not a replacement for the full repository-root native suite.

## Outstanding acceptance

The full repository-root native suite and matching Dart, compiled-service and
isolated desktop suites remain required for the integrated logging change.
Current component results do not qualify the eventual child, launcher-to-child
handshake, watchdog, lifetime owner, build identities or installed application.

Crash-before-unlink, forced unlink failure, cleaner/name replacement and nested
unsupported mounts need their own runtime controls. Minimum supported operating
systems, other qualified filesystems and packaging targets remain separate
acceptance lanes. Resource accounting must include the retained lease, kernel
mapping, directory scan workspace and complete composed owner lifetime.

Private development evidence is retained under `/var/tmp/of-logging-worker`,
`/var/tmp/of-kernel-cmake`, and `/var/tmp/of-exec-1024/b1-kernel-review-1` on Linux;
the Mac component project is `/private/var/tmp/of-kernel-cmake`. These paths are
local evidence, not CI artifacts or portable acceptance attestations.
