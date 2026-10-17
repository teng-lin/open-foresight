# Credentials and exported notes

New Google authorizations store their refresh credential in macOS Keychain or
Linux Secret Service. Linux packages depend on the distribution's `secret-tool`
provider. Entries are scoped to this app and the profile path; separate profiles
do not share credentials. Credentials go through standard input, never process
arguments. Store commands have a deadline. Tests inject a store and do not write
to the developer's Keychain.

When no usable platform store exists (for example a headless session), a private
file fallback is used. `google/tokens.json` must be a regular private file inside
a private, user-owned, nonsymlink directory. Existing public directories are
refused instead of silently repaired. With a platform store, this file holds
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
assets refuse startup rather than loading bytes under a stale recorded digest.
