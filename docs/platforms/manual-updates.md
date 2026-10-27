# Manual updates and rollback

Update checks are disabled by default. In Settings, enable **Allow manual update
checks**, then choose **Check for updates**. Enabling the setting, opening the
window and starting the service do not make an update request.

A check reads public stable-release metadata from the project's fixed GitHub API
endpoint over certificate-validated HTTPS. It sends no profile, source, audio or
account data. A failed connection, timeout, invalid release identity or wrong
channel produces no update link. Equal and older versions are ignored. Checks
never download or run an installer.

**Open release page** opens the verified project release page in your browser.
Choose the installer for your platform and follow the existing
[release verification instructions](../../RELEASING.md). Authenticating release
metadata does not verify an installer's signature, checksum or attestation.
Installation remains manual.

Before replacing an installation, finish recordings and stop its service and
clients. Preserve a complete profile backup. For rollback, use a backup whose
schema is supported by the intended application, together with compatible
application/helper binaries. Never point older code at a newer schema or
overwrite the only good profile. See [storage recovery](../validation/storage-recovery.md)
for backup integrity, the data-loss point and offline restore requirements.
