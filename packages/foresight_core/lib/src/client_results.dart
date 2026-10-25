import 'audio_device.dart';
import 'client_contract.dart';
import 'desktop_status.dart';
import 'model_asset_status.dart';
import 'read_models.dart';

/// Result codecs are attached to the original operation descriptors. An
/// acknowledgement has no payload; data-bearing results retain concrete types.
final class ResultCodec<R> implements ClientResultDecoder<R> {
  const ResultCodec(this.decodeValue);
  final R Function(Object?) decodeValue;
  @override
  R decode(Object? value) => decodeValue(value);
}

Map<String, Object?> resultObject(Object? value) =>
    Map<String, Object?>.from(value as Map);
List<R> resultList<R>(Object? value, R Function(Object?) decode) =>
    List<R>.unmodifiable((value as List).map(decode));

/// The v1 void contract leaves acknowledgement metadata unspecified. Discard
/// it without exposing a dynamic payload or narrowing an existing wire reply.
void decodeNothing(Object? _) {}

bool decodeBoolean(Object? value) => value as bool;
int decodeInteger(Object? value) => value as int;
String decodeString(Object? value) => value as String;

final class IntegerIdentityResult {
  IntegerIdentityResult.fromWire(Object? value)
    : id = resultObject(value)['id'] as int;
  final int id;
}

final class SourceIdentityResult {
  SourceIdentityResult.fromWire(Object? value)
    : id = resultObject(value)['id'] as String;
  final String id;
}

final class AnswerTextResult {
  AnswerTextResult.fromWire(Object? value)
    : text = resultObject(value)['text'] as String;
  final String text;
}

SourceDocument decodeSource(Object? value) =>
    SourceDocument.fromRow(resultObject(value));
List<SourceSummary> decodeSources(Object? value) =>
    resultList(value, (row) => SourceSummary.fromRow(resultObject(row)));
List<ExportNote> decodeNotes(Object? value) =>
    resultList(value, (row) => ExportNote.fromRow(resultObject(row)));
List<MeetingCollectionEntry> decodeMeetings(Object? value) => resultList(
  value,
  (row) => MeetingCollectionEntry.fromRow(resultObject(row)),
);
List<MeetingTask> decodeTasks(Object? value) =>
    resultList(value, (row) => MeetingTask.fromRow(resultObject(row)));

final class MeetingDetailResult {
  MeetingDetailResult.fromWire(Object? value) : this._(resultObject(value));
  MeetingDetailResult._(Map<String, Object?> value)
    : meeting = MeetingDetails.fromRow(resultObject(value['meeting'])),
      notes = resultList(
        value['notes'],
        (row) => MeetingNoteData.fromRow(resultObject(row)),
      ),
      transcript = resultList(
        value['transcript'],
        (row) => TranscriptSegment.fromRow(resultObject(row)),
      ),
      artifacts = resultList(
        value['artifacts'],
        (row) => MeetingArtifact.fromRow(resultObject(row)),
      ),
      questions = resultList(
        value['questions'],
        (row) => MeetingQuestion.fromRow(resultObject(row)),
      );
  final MeetingDetails meeting;
  final List<MeetingNoteData> notes;
  final List<TranscriptSegment> transcript;
  final List<MeetingArtifact> artifacts;
  final List<MeetingQuestion> questions;
}

final class SourceSearchResult {
  SourceSearchResult.fromWire(Object? value) : this._(resultObject(value));
  SourceSearchResult._(Map<String, Object?> value)
    : id = value['id'] as String,
      text = value['text'] as String,
      title = value['title'] as String,
      provenance = value['provenance'] as String,
      trust = value['trust'] as String,
      revision = value['revision'] as int,
      score = (value['score'] as num).toDouble();
  final String id, text, title, provenance, trust;
  final int revision;
  final double score;
}

List<SourceSearchResult> decodeSearch(Object? value) =>
    resultList(value, SourceSearchResult.fromWire);
Map<String, List<double>> decodeVectors(Object? value) => Map.unmodifiable(
  resultObject(value).map(
    (key, vector) => MapEntry(
      key,
      resultList(vector, (coordinate) => (coordinate as num).toDouble()),
    ),
  ),
);

final class NotificationResult {
  NotificationResult.fromWire(Object? value) : this._(resultObject(value));
  NotificationResult._(Map<String, Object?> value)
    : available = value['available'] as bool? ?? false,
      granted = value['granted'] as bool? ?? false,
      backend = value['backend'] as String? ?? '';
  final bool available, granted;
  final String backend;
}

/// Optional fields retain their presence because permission replies can be
/// partial updates merged into an existing capability presentation.
final class AudioCapabilityResult {
  AudioCapabilityResult.fromWire(Object? value) : this._(resultObject(value));
  AudioCapabilityResult._(Map<String, Object?> value)
    : microphone = _optional<String>(value, 'microphone'),
      systemAudio = _optional<String>(value, 'system_audio'),
      systemAudioRequest = _optional<String>(value, 'system_audio_request'),
      permissionVerified = _optional<bool>(value, 'permission_verified'),
      microphonePurposePresent = _optional<bool>(
        value,
        'microphone_purpose_present',
      ),
      systemAudioPurposePresent = _optional<bool>(
        value,
        'system_audio_purpose_present',
      ),
      granted = _optional<bool>(value, 'granted'),
      message = _optional<String>(value, 'message'),
      code = _optional<String>(value, 'code'),
      backend = _optional<String>(value, 'backend'),
      settingsUrl = _optional<String>(value, 'settings_url'),
      devices = _optionalList(
        value,
        'devices',
        (row) => AudioDevice.fromWire(resultObject(row)),
      );
  final WireField<String?> microphone,
      systemAudio,
      systemAudioRequest,
      message,
      code,
      backend,
      settingsUrl;
  final WireField<bool?> permissionVerified,
      microphonePurposePresent,
      systemAudioPurposePresent,
      granted;
  final WireField<List<AudioDevice>?> devices;
  Map<String, dynamic> toWire() => {
    if (microphone.present) 'microphone': microphone.value,
    if (systemAudio.present) 'system_audio': systemAudio.value,
    if (systemAudioRequest.present)
      'system_audio_request': systemAudioRequest.value,
    if (permissionVerified.present)
      'permission_verified': permissionVerified.value,
    if (microphonePurposePresent.present)
      'microphone_purpose_present': microphonePurposePresent.value,
    if (systemAudioPurposePresent.present)
      'system_audio_purpose_present': systemAudioPurposePresent.value,
    if (granted.present) 'granted': granted.value,
    if (message.present) 'message': message.value,
    if (code.present) 'code': code.value,
    if (backend.present) 'backend': backend.value,
    if (settingsUrl.present) 'settings_url': settingsUrl.value,
    if (devices.present)
      'devices': devices.value?.map((device) => device.toWire()).toList(),
  };
}

WireField<T?> _optional<T>(Map<String, Object?> value, String key) =>
    value.containsKey(key)
    ? WireField(value[key] as T?)
    : const WireField.absent();

WireField<List<R>?> _optionalList<R>(
  Map<String, Object?> value,
  String key,
  R Function(Object?) decode,
) => value.containsKey(key)
    ? WireField(value[key] == null ? null : resultList(value[key], decode))
    : const WireField.absent();

final class DriveCapabilitiesResult {
  DriveCapabilitiesResult.fromWire(Object? value)
    : canDownload = _optional<bool>(resultObject(value), 'canDownload');
  final WireField<bool?> canDownload;
  Map<String, Object?> toWire() => {
    if (canDownload.present) 'canDownload': canDownload.value,
  };
}

final class DriveFileResult {
  DriveFileResult.fromWire(Object? value) : this._(resultObject(value));
  DriveFileResult._(Map<String, Object?> value)
    : id = value['id'] as String,
      name = _optional<String>(value, 'name'),
      mimeType = _optional<String>(value, 'mimeType'),
      modifiedTime = _optional<String>(value, 'modifiedTime'),
      parents = _optionalList(value, 'parents', decodeString),
      size = _optional<String>(value, 'size'),
      webViewLink = _optional<String>(value, 'webViewLink'),
      capabilities = value.containsKey('capabilities')
          ? WireField(
              value['capabilities'] == null
                  ? null
                  : DriveCapabilitiesResult.fromWire(value['capabilities']),
            )
          : const WireField.absent();
  final String id;
  final WireField<String?> name, mimeType, modifiedTime, size, webViewLink;
  final WireField<List<String>?> parents;
  final WireField<DriveCapabilitiesResult?> capabilities;
  Map<String, dynamic> toWire() => {
    'id': id,
    if (name.present) 'name': name.value,
    if (mimeType.present) 'mimeType': mimeType.value,
    if (modifiedTime.present) 'modifiedTime': modifiedTime.value,
    if (parents.present) 'parents': parents.value,
    if (size.present) 'size': size.value,
    if (webViewLink.present) 'webViewLink': webViewLink.value,
    if (capabilities.present) 'capabilities': capabilities.value?.toWire(),
  };
}

List<DriveFileResult> decodeDriveFiles(Object? value) =>
    resultList(value, DriveFileResult.fromWire);

extension GooglePresentationWire on GooglePresentation {
  Map<String, dynamic> toWire() => {
    'connected': connected,
    'syncing': syncing,
    'configured': configured,
    'signingIn': signingIn,
    'driveAvailable': driveAvailable,
    'email': email,
    'displayName': displayName,
    'photoUrl': photoUrl,
    'account': account,
    'provider': provider,
    'loadError': loadError,
    'lastRefresh': lastRefreshMilliseconds,
    'accounts': [
      for (final value in accounts)
        {
          'id': value.id,
          'email': value.email,
          'displayName': value.displayName,
          'photoUrl': value.photoUrl,
          'current': value.current,
        },
    ],
  };
}

ModelAssetLocation decodeDownloadLocation(Object? value) =>
    ModelAssetLocation.fromWire(value, requiredPath: true);
ModelAssetLocation decodeInspectionLocation(Object? value) =>
    ModelAssetLocation.fromWire(value, requiredPath: false);

final class GoogleSignInResult {
  GoogleSignInResult.fromWire(Object? value) : this._(resultObject(value));
  GoogleSignInResult._(Map<String, Object?> value)
    : authorizationUrl = value['authorization_url'] as String?,
      status = value['authorization_url'] == null
          ? GooglePresentation.fromWire(value)
          : null;
  final String? authorizationUrl;
  final GooglePresentation? status;
}

final class ServiceStatusResult {
  ServiceStatusResult.fromWire(Object? value) : this._(resultObject(value));
  ServiceStatusResult._(Map<String, Object?> value)
    : pid = value['pid'] as int,
      profileId = value['profile_id'] as String?,
      workspaceEpoch = value['workspace_epoch'] as String?,
      apiVersion = value['application_api_version'] as int?,
      revision = value['revision'] as int? ?? 0,
      sourcesPaused = value['sources_paused'] as bool? ?? false,
      modelsBusy = value['models_busy'] as bool? ?? false,
      webSearchAvailable = value['web_search_available'] as bool? ?? false,
      capture = CapturePresentation.fromWire(value['capture']),
      google = GooglePresentation.fromWire(value['google']),
      generation = GenerationPresentation.fromWire(value['generation']),
      modelAssetDownload = ModelAssetDownloadPresentation.fromWire(
        value['model_asset_download'],
      );
  final int pid, revision;
  final int? apiVersion;
  final String? profileId, workspaceEpoch;
  final bool sourcesPaused, modelsBusy, webSearchAvailable;
  final CapturePresentation capture;
  final GooglePresentation google;
  final GenerationPresentation generation;
  final ModelAssetDownloadPresentation modelAssetDownload;
}

GooglePresentation decodeGoogle(Object? value) =>
    GooglePresentation.fromWire(resultObject(value));

CapturePresentation decodeCapture(Object? value) =>
    CapturePresentation.fromWire(resultObject(value));

final class ServiceStopResult {
  ServiceStopResult.fromWire(Object? value) : this._(resultObject(value));
  ServiceStopResult._(Map<String, Object?> value)
    : stopped = value['stopped'] as bool,
      shutdownVerified = value['shutdown_verified'] as bool;
  final bool stopped, shutdownVerified;
}

GooglePresentation? decodeRefresh(Object? value) =>
    value == null ? null : decodeGoogle(value);
