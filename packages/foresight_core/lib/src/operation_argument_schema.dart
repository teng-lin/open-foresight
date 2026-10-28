import 'operation_requests/graph_inputs.dart';
import 'rpc_error.dart';

enum ArgumentKind {
  boolean,
  string,
  integer,
  trueSwitch,
  falseSwitch,
  dateTime,
  strings,
  graphSources,
  vectors,
  points,
  clusters,
}

/// A service argument's decoder and schema share this single declaration.
/// Tool projections may narrow exposure, requiredness and enum values.
class ArgumentField {
  const ArgumentField(
    this.name,
    this.kind, {
    this.nullable = false,
    this.defaultValue,
    this.minimum,
    this.maximum,
    this.choices,
    this.minimumItems,
    this.maximumItems,
    this.distinct = false,
    this.description,
    this.minimumLength,
    this.maximumLength,
  });
  final String name;
  final ArgumentKind kind;
  final bool nullable;
  final Object? defaultValue;
  final int? minimum, maximum, minimumItems, maximumItems;
  final int? minimumLength, maximumLength;
  final List<String>? choices;
  final bool distinct;
  final String? description;
  bool get required =>
      !nullable &&
      defaultValue == null &&
      kind != ArgumentKind.trueSwitch &&
      kind != ArgumentKind.falseSwitch;

  Object? decode(Map<String, dynamic> raw) {
    final value = raw[name];
    if (kind == ArgumentKind.trueSwitch) return value == true;
    if (kind == ArgumentKind.falseSwitch) return value != false;
    if (value == null) {
      if (defaultValue != null) return defaultValue;
      if (nullable) return null;
      invalidArgument(name, 'is required');
    }
    final Object decoded;
    switch (kind) {
      case ArgumentKind.boolean:
        if (value is! bool) invalidArgument(name, 'must be a boolean');
        decoded = value;
      case ArgumentKind.string:
        if (value is! String) invalidArgument(name, 'must be a string');
        if (minimumLength != null && value.length < minimumLength!) {
          invalidArgument(name, 'is too short');
        }
        if (maximumLength != null && value.length > maximumLength!) {
          invalidArgument(name, 'is too long');
        }
        if (choices != null && !choices!.contains(value)) {
          invalidArgument(name, 'must be one of ${choices!.join(', ')}');
        }
        decoded = value;
      case ArgumentKind.integer:
        if (value is! int) invalidArgument(name, 'must be an integer');
        if ((minimum != null && value < minimum!) ||
            (maximum != null && value > maximum!)) {
          invalidArgument(name, 'is out of range');
        }
        decoded = value;
      case ArgumentKind.dateTime:
        if (value is! String) {
          invalidArgument(name, 'must be an ISO date string');
        }
        final parsed = DateTime.tryParse(value);
        if (parsed == null) invalidArgument(name, 'must be an ISO date string');
        decoded = parsed;
      case ArgumentKind.strings:
        if (value is! List || value.any((item) => item is! String)) {
          invalidArgument(name, 'must be a list of strings');
        }
        final strings = List<String>.unmodifiable(value.cast<String>());
        if ((minimumItems != null && strings.length < minimumItems!) ||
            (maximumItems != null && strings.length > maximumItems!)) {
          invalidArgument(name, 'has an invalid number of items');
        }
        if (distinct && strings.toSet().length != strings.length) {
          invalidArgument(name, 'must contain distinct values');
        }
        decoded = strings;
      case ArgumentKind.graphSources:
        decoded = decodeGraphSources(value, name);
      case ArgumentKind.vectors:
        decoded = decodeGraphVectors(value, name);
      case ArgumentKind.points:
        decoded = decodeGraphPoints(value, name);
      case ArgumentKind.clusters:
        decoded = decodeGraphClusters(value, name);
      case ArgumentKind.trueSwitch:
      case ArgumentKind.falseSwitch:
        throw StateError('Boolean switches were decoded above');
    }
    return decoded;
  }

  Map<String, dynamic> get schemaJson => {
    'type': switch (kind) {
      ArgumentKind.integer => 'integer',
      ArgumentKind.boolean ||
      ArgumentKind.trueSwitch ||
      ArgumentKind.falseSwitch => 'boolean',
      ArgumentKind.strings ||
      ArgumentKind.graphSources ||
      ArgumentKind.clusters => 'array',
      ArgumentKind.vectors || ArgumentKind.points => 'object',
      _ => 'string',
    },
    if (kind == ArgumentKind.strings) 'items': {'type': 'string'},
    if (kind == ArgumentKind.graphSources || kind == ArgumentKind.clusters)
      'items': {'type': 'object', 'additionalProperties': true},
    if (minimum != null) 'minimum': minimum,
    if (maximum != null) 'maximum': maximum,
    if (minimumLength != null) 'minLength': minimumLength,
    if (maximumLength != null) 'maxLength': maximumLength,
    if (minimumItems != null) 'minItems': minimumItems,
    if (maximumItems != null) 'maxItems': maximumItems,
    if (distinct) 'uniqueItems': true,
    if (choices != null) 'enum': choices,
    if (description != null) 'description': description,
  };
}

class DecodedOperationArguments {
  DecodedOperationArguments(Map<String, Object?> values)
    : _values = Map.unmodifiable(values);
  final Map<String, Object?> _values;

  /// Type erasure is confined to generated boundary construction. Handlers
  /// receive the individual request's concrete fields and never use this map.
  T value<T>(String name) => _values[name] as T;
}

class OperationArgumentSchema {
  const OperationArgumentSchema(this.fields);
  final List<ArgumentField> fields;
  ArgumentField field(String name) =>
      fields.firstWhere((field) => field.name == name);
  DecodedOperationArguments decode(Map<String, dynamic> raw) =>
      DecodedOperationArguments({
        for (final field in fields) field.name: field.decode(raw),
      });

  Map<String, dynamic> get schemaJson => {
    'type': 'object',
    'properties': {for (final field in fields) field.name: field.schemaJson},
    'required': fields
        .where((field) => field.required)
        .map((field) => field.name)
        .toList(),
    // v1 service maps accept additive fields; MCP projects a closed subset.
    'additionalProperties': true,
  };
}

Never invalidArgument(String field, String message) =>
    throw RpcError(RpcErrorCode.invalidArgument, '$field $message');
