import '../client_contract.dart';

final class LabelsAutoAssignInput extends ClientArguments {
  const LabelsAutoAssignInput({super.envelope, required this.name});
  final String name;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'name': name});
}

final class LabelsPutInput extends ClientArguments {
  const LabelsPutInput({
    super.envelope,
    required this.id,
    required this.name,
    required this.source,
    this.color = const WireField.absent(),
    this.rationale = const WireField.absent(),
  });
  final String id;
  final String name;
  final String source;
  final WireField<String?> color;
  final WireField<String?> rationale;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'id': id,
    'name': name,
    'source': source,
    if (color.present) 'color': color.value,
    if (rationale.present) 'rationale': rationale.value,
  });
}

final class LabelsSetInput extends ClientArguments {
  LabelsSetInput({
    super.envelope,
    required this.id,
    required List<String> labels,
  }) : labels = List.unmodifiable(labels);
  final String id;
  final List<String> labels;
  @override
  Map<String, dynamic> toWire() =>
      envelope.attach({'id': id, 'labels': labels});
}

final class LabelsClusterInput extends ClientArguments {
  const LabelsClusterInput({super.envelope, required this.name});
  final String name;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'name': name});
}

final class LabelsDeleteInput extends ClientArguments {
  const LabelsDeleteInput({super.envelope, required this.name});
  final String name;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'name': name});
}
