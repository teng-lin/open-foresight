# Installed saved-audio worker admission

`tools/package.py` and `tools/package_macos.py` require an explicit
`--media-worker-build` directory. A missing worker is a packaging error. There
is no PATH, RPC-selected executable, or optional legacy package fallback.

Build from the existing hash-pinned codec recipe into an unused directory:

```sh
install -d -m 700 /var/tmp/foresight-media-cache
.venv/bin/python tools/build_media_worker.py --cache /var/tmp/foresight-media-cache \
  --output build/media-worker --fetch --jobs 2
```

The input justification remains the builder's: bundle pinned codecs for offline
retained audio and MP3 export without a system FFmpeg dependency. This adds no
SDK version or artifact-producer trust exception. An existing completed build
can be selected only when its actual bytes and all application source hashes
match the selected source tree. Source changes require a new build/output
receipt. A package copy is never reported as a new compilation.

## Package contract

`tools/media_worker_package.py` verifies the explicit product before staging:

- exact target, codec archive URL/hash pins and all 13 application source hashes,
  including `native/media_assembly.inc` and `native/media_pager_protocol.h`;
- the builder's normalized pre-compilation identity, actual binary hash/size,
  embedded build identity, architecture and fixed worker protocols;
- copied source, archive, static library, relink object and license bytes;
- regular protected files, no-follow child components, bounded reads and
  before/after file metadata.

The worker is `bin/foresight-media-worker` relative to the Linux bundle root or
the macOS `Contents/Resources` payload. Public provenance is
`licenses/media/media-worker-build.json`. Complete verified source/relink
materials are retained in deterministic `licenses/media/relink-materials.tar.gz`,
with notices also available as text. Raw Mach-O relink objects are archived so
bundle relocation/signing cannot alter them or treat them as runnable code.
The archive contains the original receipt, sources, pinned codec archives,
static libraries, relink objects and notices.

The final receipt is `share/open-foresight/media-worker.json` on Linux and
`Contents/Resources/media-worker.json` on macOS. It has schema 1, fixed kind,
target/path, protocol/bootstrap/supervisor-fence versions, immutable build ID,
final SHA-256/size, macOS CDHash (null on Linux), source-receipt SHA-256 and a
closed capability description. Linux copies must remain byte-identical. On
macOS sealing runs after actual leaf signing and relocation and before outer
bundle signatures. It verifies the signature, reads the actual CDHash, hashes
final bytes and rejects any intervening change. The existing signing-policy
implementation is unchanged.

A four-operation receipt receives `assembly_protocol: 0`; its fixed
`mix-export-mp3` operation does not authorize whole-meeting manifest assembly.
The integrated assembly worker receives protocol 1 only with the exact seven
operations and `max_range_frames: 240000`, bound to the current 13-source recipe.
Long export/playback advertising additionally requires the complete native
pager/output suite. The verifier preserves actual closed capabilities rather
than attributing assembly to a historical four-operation product.

## Service loader

`loadInstalledAudioMediaInstallation(configuration)` accepts only the service's
immutable resolved installation configuration. It derives fixed paths, walks
physical directories with no-follow descriptors, enforces the closed installed
ownership/permission policy, rejects hardlinks/special files, verifies bounded
receipt/provenance/binary hashes and target headers, and rechecks the installation
anchor. Hashing runs in a separate isolate. It returns an immutable
`InstalledAudioMediaInstallation` containing `executable`, `operations` and
`assemblyProtocol`. Compression can use the convenience
`loadInstalledAudioMediaExecutable(configuration)` wrapper.

No executable path or receipt is accepted through RPC. Native media admission
still independently re-verifies executable identity and the loaded macOS
CodeDirectory immediately before transferring file capabilities. The loader's
metadata check alone is not a claim of native worker admission, a codec run,
outer-bundle signing or notarization. The service composes this capability into retained-audio processing; unavailable
codecs preserve saved raw audio and refuse unsupported conversions.
