/// Pure display checks shared with the service's Drive import policy.
bool supportsGoogleDriveMime(String mime) =>
    mime.startsWith('text/') ||
    [
      'application/pdf',
      'application/rtf',
      'application/vnd.google-apps.document',
      'application/vnd.google-apps.spreadsheet',
      'application/vnd.google-apps.presentation',
    ].contains(mime);
bool canDownloadGoogleDriveFile(Map<String, dynamic> file) =>
    (file['capabilities'] as Map?)?['canDownload'] != false;

String googleImportFailure(String name, Object error) {
  final message = error is StateError
      ? error.message.toString()
      : error.toString();
  return message.startsWith('$name:') || message.startsWith('$name ')
      ? message
      : '$name: $message';
}
