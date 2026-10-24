// This is a generated file - do not edit.
//
// Generated from transcript_index.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

class TranscriptKey_Channel extends $pb.ProtobufEnum {
  static const TranscriptKey_Channel MICROPHONE =
      TranscriptKey_Channel._(0, _omitEnumNames ? '' : 'MICROPHONE');
  static const TranscriptKey_Channel PLAYBACK =
      TranscriptKey_Channel._(1, _omitEnumNames ? '' : 'PLAYBACK');
  static const TranscriptKey_Channel IMPORTED =
      TranscriptKey_Channel._(2, _omitEnumNames ? '' : 'IMPORTED');

  static const $core.List<TranscriptKey_Channel> values =
      <TranscriptKey_Channel>[
    MICROPHONE,
    PLAYBACK,
    IMPORTED,
  ];

  static final $core.List<TranscriptKey_Channel?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static TranscriptKey_Channel? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const TranscriptKey_Channel._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
