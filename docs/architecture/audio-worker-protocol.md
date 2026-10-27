# Audio worker protocol

The service freezes one shared pause-compacted sample timeline for both sources.
Its settings/input identity uses `shared-spans-sample-exact-v2`; the
FSAMF001 header field at180 remains wire revision1. Each continuous source run
quantizes its first acquisition anchor once with
`floor((runCaptureUs-spanCaptureUs)*48000/1000000)`. Later chunks add exact source
sample deltas and retain every sample, including one-frame tails. A source
discontinuity or explicit acquisition gap starts a new anchor. An overlapping or
ambiguous new run is refused visibly; its original files are retained.

Each shared span extent is the maximum of its clock duration on the sample grid
and every known source sample end. Known missing/quarantined chunks participate
in that geometry; metadata-only reservations do not. The next span begins at the
previous shared frame end, removing intentional pauses globally. Unavailable
sources and acquisition outages remain uncovered frames rendered as silence.
No source is independently compacted, shifted or normalized. This preserves
sample counts without claiming physical microphone/playback alignment bounds.

## Operations and native API

The existing operation numbers remain stable. Operations 4 `assemble-mp3-v1`, 5
`assemble-opus-v1` and6 `assemble-pcm-v1`. The latter is a bounded playback decode
of up to240000 mono PCM16 frames (5 seconds/480000 bytes). Existing op2
`decode-pcm` also widens from4800 to240000 frames. RPC transport can continue to
page at4800 frames; it must not spawn one child per100ms transport page.

Existing `fs_owned_media_start(operation,input_fd,second_fd,output_fd,lock_fd,
options_json)` remains the launch ABI. For operations4–6, input is a private
frozen manifest, second_fd must be-1, and native MediaOwner creates and owns a
private AF_UNIX SOCK_DGRAM socketpair. Worker capabilities are manifest3,
pager4,output5,owner-flock7; macOS watcher8 remains internal. Input/output/lock are
duplicated before start returns. Verified, watcher-ready SCM bootstrap still
precedes every media transfer. No path, executable argument vector or arbitrary
file request is accepted from worker messages or RPC.

`char *fs_owned_media_input_poll(uint64_t owner)`: null if no request is
pending, otherwise bounded JSON `{"version":1,"sequence":N,"manifest_sha256":
"64 lowercase hex","indices":[I,J]}` with one or two indices. Repeated polling
returns the same outstanding request. Invalid/released owners also return null;
callers already own the media task and use its typed poll/closed state.

`int fs_owned_media_input_reply(uint64_t owner,uint64_t sequence,int status,
int first_fd,int second_fd)`. status0 supplies exactly the outstanding count of
borrowed source FDs (second_fd=-1 for one). status1 refuses the page and both FDs
must be-1. Replies synchronously duplicate borrowed descriptors before sending;
0 means accepted,-1 means invalid,stale,duplicate,closed or send failure. Exactly
one request can be outstanding; sequence is strictly monotonic and row indices
must match. A refusal or missing input visibly fails the job. The service leases
the frozen representation rows before opening any FD and retains these leases
through actual native retirement. Cancellation closes the pager, kills/stops the
worker and waits the existing actual-exit fence; timeout never means closed.

The service reads the requested fixed row from its trusted manifest, resolves
`input_position` against that job's frozen DB inputs, verifies representation ID,
SHA and current media/workspace generation, then opens a protected read-only FD.
The worker does not send a filename. Service paging never constructs an entire
meeting's decoded PCM or a Dart list of all chunks.

## Binary manifest

All integers are little-endian; UUIDs are canonical lowercase36-byte ASCII with
no terminator. Fixed-width ID strings are nonempty printable ASCII excluding
slash/backslash, NUL-terminated and zero-padded; they are identifiers, never paths.
SHA strings are64 lowercase ASCII hex. Unknown versions,flags,reserved bytes,
formats,trailing bytes and arithmetic overflows fail closed.

Header size256 bytes, magic `FSAMF001`. Exactly
`256 + 384*(source0_count + source1_count)` bytes; at most131072 rows,50331904
bytes (48MiB plus256 bytes), and24h/4147200000 timeline frames. Rows for source0
come first,then source1; each source is sorted and nonoverlapping on the shared
timeline. Both counts may individually be0 but their sum must be positive.

| Offset | Bytes | Meaning |
| --- | --- | --- |
|0|8|magic FSAMF001|
|8|4|schema1|
|12|4|header size256|
|16|4|row size384|
|20|4|source0 row count|
|24|4|source1 row count|
|28|4|operation4,5 or6|
|32|36|session UUID|
|68|36|job UUID|
|104|36|storage generation UUID|
|140|8|native request epoch|
|148|8|whole compacted timeline frames|
|156|8|requested range start;0 for export|
|164|4|requested range count;0 for export,1..240000 for PCM|
|168|4|source selection mask1 microphone,2 playback,3 both|
|172|4|sample rate48000|
|176|4|channels1|
|180|4|shared-spans timeline revision1|
|184|64|frozen DB input_identity SHA|
|248|8|reserved zero|

Each row is384 bytes. `index` equals physical row index. `input_position` is a
permutation of0..total_rows-1, identifying its frozen DB job input; representation
IDs can be UUIDs or existing `<chunk UUID>.raw` IDs. Read ranges are half-open.
`read_start + take_frames <= representation_frames`; take_frames>0;
`timeline_start + take_frames <= timeline_frames`. A representation is at most
240000 decoded mono frames. WAV pre_skip is0; Opus pre_skip must match its actual
Ogg OpusHead/EOS validation. Input format1 means pcm_s16le/wav/recording-wav-v1;
format2 means opus/ogg/ogg-opus-mono-v1. No raw/header autodetection is allowed.

|Offset|Bytes|Meaning|
|---|---|---|
|0|4|physical index|
|4|4|source0 or1|
|8|4|format1 WAV or2 Opus|
|12|4|native source flags; known mask0xc0000001, lowbit matches source|
|16|8|destination start frame on shared compacted timeline|
|24|4|read start frame within this representation|
|28|4|frames to take|
|32|4|full decoded representation frames|
|36|4|expected Opus pre_skip,or0 for WAV|
|40|8|exact encoded file byte count|
|48|8|source_sample/source sample-start identity|
|56|8|chunk sequence|
|64|8|native span ordinal|
|72|8|signed capture_start_us|
|80|36|chunk UUID|
|116|36|storage generation UUID,matches header|
|152|128|representation ID,at most127 ASCII bytes plusNUL|
|280|64|full representation file SHA256|
|344|36|recording span UUID|
|380|4|frozen DB input_position|

For WAV, compare every embedded196-byte identity field: session,generation,chunk,
source/known flags,sequence,span ordinal,source_sample and capture_start_us; check
PCM extent exactly196+2*representation_frames. For Opus, check exact byte length,
full SHA,mono48k format,Ogg CRC/sequence/serial/BOS/EOS,pre_skip/final granule and
full decoded sample count. Existing Opus files contain no intrinsic recording
UUID tags: their recording identity is the authoritative frozen manifest-row
binding plus full-file SHA. Never invent a decoded-PCM hash from an Opus hash.

Manifest bytes are copied and hashed into a process-private immutable const
snapshot before parsing/use. This fixed snapshot is at most48MiB plus256B,typically
~12.7MiB for24h of5s chunks across2 sources. Each source representation is likewise
copied+hashed into a private immutable buffer before decoding: WAV<=480196B,
Opus<=131072B. At most one active chunk per source and960-frame mixing blocks are
needed. Rehash the original manifest descriptor before accepting output; a file
mutated and restored cannot affect reads from the private snapshot. No mmap view
of mutable source bytes is treated as immutable authority.

## Descriptor page wire protocol

AF_UNIX SOCK_DGRAM is deliberately used: a local Mac probe supports it while
SOCK_SEQPACKET returns EPROTONOSUPPORT. Each datagram has exactly64 data bytes.
Requests use magic `FSMRQ001`,replies `FSMRP001`. The worker sends no descriptors;
a successful reply has exactly one SCM_RIGHTS control block carrying count FDs.
No extra/truncated ancillary data or datagram bytes are accepted. At most one
request and two source FDs can be outstanding. Broker idle deadline10s; parent
operation total/idle deadlines and cancel/kill/wait fence still apply.

|Offset|Bytes|Meaning|
|---|---|---|
|0|8|request/reply magic|
|8|4|sequence,starts1|
|12|4|status0 request/success,1 refusal|
|16|4|count1..2 for request/success;0 refusal|
|20|4|first physical row index|
|24|4|second index,UINT32_MAX if unused|
|28|4|reserved0|
|32|32|raw32-byte expected full manifest SHA|

Reply sequence and indices echo the request. A refusal echoes the indices but
has count0 and no descriptors. Stale/duplicate replies are refused before FDs are
sent. The worker only requests its next required row(s),validates the returned
private source FD's exact frozen format,length/hash/identity,and closes it after
making its private immutable chunk snapshot. The service's DB leases and owner
flock remain held through actual child exit and native retirement.

## Rendering and publication

Single-source selection preserves full gain. Both-source selection uses fixed
one-half gain per source,including when one source is absent; no loudness
normalization or timing inference occurs. Missing intervals are explicit zero
samples at their shared timeline positions. PCM output is exactly2*range_count
bytes. MP3 uses existing64kbps mono LAME encoder/delay-tag handling. Mixed archival
Opus uses existing32kbps VBR mono settings and is a newly encoded export; retained
source representations are unchanged. Opus output is checked through CRC/EOS,
granule/pre_skip and full decoded duration. MP3 exact sample/delay fidelity is
independently decoder-qualified; no production FFmpeg/MP3 decoder is implied.
WAV export is not part of these operations.

Success keeps the existing15-field protocol1 JSON. For assembly input_sha256 is
the full manifest SHA,second_input_sha256 is empty,source_frames is whole timeline
frames;frames/range_start describe the PCM range or full export. Opus reports
actual pre_skip/final_granule;MP3/PCM report0. Output SHA/bytes and build/session/
job/epoch/operation must match the owned request. Partial outputs remain
unpublished. Every manifest,input and output check plus actual worker exit must
succeed before durable publication. Failure/cancellation retains the original
recording and follows the owned reader/reap fences.
