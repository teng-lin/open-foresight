import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../presentation/workspace_presentation.dart';
import 'capture_waveform.dart';

/// Recording presentation receives values and callbacks; capture ownership stays
/// with the controller and application service.
class RecordingHeader extends StatelessWidget {
  final String clock;
  final bool paused;
  final ValueListenable<List<double>> captureVolumes;
  final List<double>? fallbackVolumes;
  final VoidCallback onToggleWorkspace, onOpenWorkspace;
  final VoidCallback? onPauseResume, onStop;
  const RecordingHeader({
    super.key,
    required this.clock,
    required this.paused,
    required this.captureVolumes,
    this.fallbackVolumes,
    required this.onToggleWorkspace,
    required this.onOpenWorkspace,
    this.onPauseResume,
    this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: onToggleWorkspace,
      child: Container(
        key: const ValueKey('recording-pill'),
        width: MediaQuery.sizeOf(context).width > 1100 ? 400 : 310,
        padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        decoration: BoxDecoration(
          color: workspaceBlue,
          borderRadius: BorderRadius.circular(40),
        ),
        child: Row(
          children: [
            Text(
              clock,
              key: const ValueKey('recording-clock'),
              style: const TextStyle(
                color: workspaceInk,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: 30,
                child: ValueListenableBuilder<List<double>>(
                  valueListenable: captureVolumes,
                  builder: (context, volumes, child) => CustomPaint(
                    key: const ValueKey('capture-waveform'),
                    painter: CaptureWaveform(fallbackVolumes ?? volumes),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: paused ? 'Resume recording' : 'Pause recording',
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              padding: const EdgeInsets.all(6),
              onPressed: onPauseResume,
              icon: Icon(
                paused ? Icons.play_arrow : Icons.pause,
                color: workspaceInk,
                size: 23,
              ),
            ),
            IconButton(
              tooltip: 'Stop recording',
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              padding: const EdgeInsets.all(6),
              onPressed: onStop,
              icon: const Icon(
                Icons.stop_circle_outlined,
                color: workspaceInk,
                size: 23,
              ),
            ),
            IconButton(
              tooltip: 'Open transcription workspace',
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              padding: const EdgeInsets.all(6),
              onPressed: onOpenWorkspace,
              icon: const Icon(Icons.fullscreen, color: workspaceInk, size: 23),
            ),
          ],
        ),
      ),
    );
  }
}
