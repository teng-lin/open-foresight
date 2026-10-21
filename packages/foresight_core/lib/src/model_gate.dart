/// Answer generation only needs the orchestration gate, not an Application.
abstract interface class ModelGate {
  bool get modelBusy;
}

/// A multi-request generation workflow retains ownership between native calls.
abstract interface class GenerationReservationGate {
  bool get generationReserved;
}

class IdleModelGate implements ModelGate {
  const IdleModelGate();
  @override
  bool get modelBusy => false;
}
