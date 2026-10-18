# Credentials and exported notes

New Google authorizations store their refresh credential in macOS Keychain or
Linux Secret Service. Linux packages depend on the distribution's `secret-tool`
provider. Entries are scoped to this app and the profile path.

macOS uses Security.framework inside the application service, with a Keychain
ACL restricted to the current service executable. It never delegates protected
reads to an unrestricted helper executable or `/usr/bin/security`. Background
queries forbid interactive authentication, so an unavailable or changed access
principal reports an authorization error instead of blocking the domain on a
Keychain dialog. Protected-store errors never enable the plaintext fallback.
Legacy command-owned entries migrate only after protected write/readback succeeds;
the old entry is then deleted. Ad-hoc signature continuity across service updates
and denial of unrelated Terminal reads require packaged macOS acceptance evidence.
Unit tests with injected stores prove migration ordering, not OS ACL enforcement.

On Linux, a headless session without a usable platform store can use the private
file fallback. `google/tokens.json` must be a regular private file inside a
private, user-owned, nonsymlink directory. With a platform store, this file holds
account/access metadata and a credential-store marker, without the refresh token.
Existing private file authorizations migrate on the next token refresh.

Credential persistence and erasure run through one queue. Sign-in and client
changes are refused while disconnect/forget is pending, so an obsolete save
cannot delete or restore a later authorization. Workspace clearing removes local
credentials before attempting remote revocation.

Meeting exports are first written to a private temporary file with mode 0600,
then renamed to the selected destination. A selected symlink is replaced without
following it. The mode does not depend on the caller's umask.

The service rehashes every registered model using the registration digest contract
before constructing Domain or native/model workers. Changed or missing stored
assets lose their model registration before workers start. Their files remain
untouched, and the service stays available so setup can download a verified
replacement. Rejected registrations record an integrity error in preferences.
