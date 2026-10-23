part of 'meetings_controller.dart';

extension _RecordingView on MeetingsController {
  Widget _recordingHeader() {
    final elapsed =
        recordingElapsed +
        (recording!.paused
            ? Duration.zero
            : DateTime.now().difference(recordingElapsedAt));
    final clock =
        '${elapsed.inMinutes.toString().padLeft(2, '0')}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: () => update(() {
        _navigation.navigate(WorkspaceTab.meetings);
        meetingId = recordingMeeting;
        meetingSidecarVisible = true;
        meetingImmersive = !meetingImmersive;
      }),
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
                  valueListenable: _host.captureVolumes,
                  builder: (context, volumes, child) => CustomPaint(
                    key: const ValueKey('capture-waveform'),
                    painter: CaptureWaveform(
                      d is CaptureLevelEvents
                          ? volumes
                          : recording!.currentVolumes,
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: recording!.paused
                  ? 'Resume transcribing'
                  : 'Pause transcribing',
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              padding: const EdgeInsets.all(6),
              onPressed: _operations.busy || recording!.finishing
                  ? null
                  : () => _operations.run(() async {
                      await d.command(
                        recording!.paused
                            ? Operation.meetingsResume
                            : Operation.meetingsPause,
                        {'id': recordingMeeting},
                      );
                      if (mounted) update(syncCapture);
                    }),
              icon: Icon(
                recording!.paused ? Icons.play_arrow : Icons.pause,
                color: workspaceInk,
                size: 23,
              ),
            ),
            IconButton(
              tooltip: 'Stop transcribing',
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              padding: const EdgeInsets.all(6),
              onPressed: recording!.finishing
                  ? null
                  : () => _operations.run(stopRecording),
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
              onPressed: () => update(() {
                _navigation.navigate(WorkspaceTab.meetings);
                meetingId = recordingMeeting;
                meetingSidecarVisible = true;
              }),
              icon: const Icon(Icons.fullscreen, color: workspaceInk, size: 23),
            ),
          ],
        ),
      ),
    );
  }
}
