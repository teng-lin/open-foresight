# Audio export publication

The service owns `AudioExportDestinations`. RPC callers never receive media paths
or file descriptors. Destination authorization binds one unpredictable grant to
an actual service-side caller object, workspace epoch, current storage generation,
recording session, output format, explicit overwrite choice and explicit partial
recording choice. Unused grants expire on a monotonic clock and are invalidated
when their caller disconnects. Attempting to consume a grant burns it even when
its supplied choices do not match.

The broker rejects application profile/cache roots, symlinked path components,
unsafe directory ownership or permissions, hardlinked outputs and unsupported
filesystems. It anchors the selected parent directory and keeps the authorized
existing output open. It rechecks the output inode, size and modification time
before worker admission and publication. The caller provides cache roots in
addition to the profile root that is always excluded.

## Job admission and worker ownership

Consume the grant, create the durable export job with `frozenJobSettings`, then
call `bindJob`. The grant ID participates in the job's frozen input identity;
a second destination cannot reuse a previously admitted job. Bind creates an
unpredictable private staging directory inside the destination parent and writes
a durable receipt inside the managed recording session directory. The private
staging inode and both directory identities are frozen in that receipt.

The scheduler attaches the current DB lease with `fenceTo` and calls
`beginWorker` before launching a worker. Keep borrowed descriptors until native
launch has duplicated them; keep DB reader references until actual native exit.
`markWorkerClosed` is a service-only acknowledgement of that exit, independent of
the worker result. A result does not permit cleanup, publication or lease release.
Transient interruption uses `resetForRetry`; explicit cancellation uses `abort`
only after actual exit. The concrete coordinator must call `invalidateCaller`
on connection closure for unused grants. An admitted background job uses its
own service lifecycle callback rather than the settled UI request callback.

## Publication and recovery

The fixed codec worker validates the complete format, frame count and codec
invariants. The broker separately hashes the exact staged inode in an isolate,
then rechecks current recording authority and destination identities. It writes
a receipt with the verified hash, byte count and frame count before publication.
For an absent target it uses an anchored no-replace rename. Explicit overwrite
uses atomic exchange, preserving the displaced file in the private staging
area. Platforms lacking these filesystem operations fail closed.

If an exchange reveals an unexpected displaced inode, rollback occurs only
while both names still have the identities just observed. Otherwise all files
are retained and the operation reports a recoverable conflict. Database commit
precedes removal of the authorized displaced file. Cleanup is idempotent and
never erases an unexpected inode. User-owned completed exports are outside
managed profile erasure.

Startup recovery receives an explicit current DB job. It reads that job's exact
receipt, checks frozen choices, generation, epoch, directory identities and file
identities, and rehashes a published output before admitting its durable result.
It does not scan output directories or infer authority from filenames. An
unvalidated partial is truncated and rerun, never adopted as completed output.
Same-process recovery additionally requires the known actual worker exit fence;
new-process recovery relies on `RecordingMedia.open` holding the inherited worker
ownership lock. Recovered ownership is persisted before another worker starts.
Metadata-only restore cannot authorize recovery of original media or exports.

The final staged-file unlink is deliberately limited to an unpredictable name
inside the verified private staging directory, which has no other legitimate
writers. Identity is checked immediately before unlink. This is not an atomic
conditional unlink and does not defend against arbitrary same-UID mutation
inside that private staging area. Uncertain identities preserve bytes instead.
