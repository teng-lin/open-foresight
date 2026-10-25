import '../client_contract.dart';

final class SecurityAttachDesktopInput extends ClientArguments {
  const SecurityAttachDesktopInput({
    super.envelope,
    required this.token,
    this.visible = const WireField.absent(),
  });
  final String token;
  final WireField<bool?> visible;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'token': token,
    if (visible.present) 'visible': visible.value,
  });
}

final class SecurityDetachDesktopInput extends ClientArguments {
  const SecurityDetachDesktopInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class SecurityDesktopVisibilityInput extends ClientArguments {
  const SecurityDesktopVisibilityInput({
    super.envelope,
    this.visible = const WireField.absent(),
  });
  final WireField<bool?> visible;
  @override
  Map<String, dynamic> toWire() =>
      envelope.attach({if (visible.present) 'visible': visible.value});
}

final class SecurityDecideInput extends ClientArguments {
  const SecurityDecideInput({
    super.envelope,
    required this.approvalId,
    this.allow = const WireField.absent(),
  });
  final String approvalId;
  final WireField<bool?> allow;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'approval_id': approvalId,
    if (allow.present) 'allow': allow.value,
  });
}

final class SecurityAllowImportRootInput extends ClientArguments {
  const SecurityAllowImportRootInput({super.envelope, required this.path});
  final String path;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'path': path});
}
