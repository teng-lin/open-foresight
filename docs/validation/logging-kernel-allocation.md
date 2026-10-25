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

The initial allocator checkpoint `8c1463e0` subsequently passed fresh
repository-root builds and native CTest: Linux 34/34 and Mac 37/37, zero skipped.
Those counts precede the additional interruption and fault tests below.

The Darwin fault fixture compiles the unchanged allocator into a test-only
translation unit with syscall substitutions. It checks failed low-descriptor
duplication without descriptor growth, and a substituted unlink failure that
retains exactly one descriptor and an externally observed directory lease until
the child exits. An abrupt `_exit` immediately after real exclusive kernel-object
creation leaves a zero-size object that the next allocation safely reclaims.
These checks passed on the actual Mac; substitution is not an OS-generated
unlink failure, and `_exit` is not a SIGKILL interruption.

Both Mac fixtures serialize invocations with their private base-directory lease
and recover only exact known test leftovers with verified metadata. Unknown or
nonempty ordinary files, external hardlinks and oversized kernel objects remain
untouched. CTest interruption setup and guarded cleanup also cover setup-only
test filtering. The focused extracted CMake project passed six tests, zero
skipped, on Mac; each setup-only selection ran its setup and cleanup successfully.
The full native suite has not yet run with these additional fixture changes.

## Outstanding acceptance

The full repository-root native suite and matching Dart, compiled-service and
isolated desktop suites remain required for the integrated logging change.
Current component results do not qualify the eventual child, launcher-to-child
handshake, watchdog, lifetime owner, build identities or installed application.

Actual SIGKILL during unlink, OS-generated unlink failure, cleaner/name replacement
and nested unsupported mounts need their own runtime controls. Minimum supported operating
systems, other qualified filesystems and packaging targets remain separate
acceptance lanes. Resource accounting must include the retained lease, kernel
mapping, directory scan workspace and complete composed owner lifetime.

Private development evidence is retained under `/var/tmp/of-logging-worker`,
`/var/tmp/of-kernel-cmake`, and `/var/tmp/of-exec-1024/b1-kernel-review-1` on Linux;
the Mac component project is `/private/var/tmp/of-kernel-cmake`. These paths are
local evidence, not CI artifacts or portable acceptance attestations.
