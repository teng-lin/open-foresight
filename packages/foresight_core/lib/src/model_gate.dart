/// Answer generation only needs the orchestration gate, not an Application.
abstract interface class ModelGate {
  bool get modelBusy;
}

class IdleModelGate implements ModelGate {
  const IdleModelGate();
  @override
  bool get modelBusy => false;
}
