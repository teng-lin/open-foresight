part of 'settings_controller.dart';

extension _StatsView on SettingsController {
  Widget _buildStats() {
    final meetings = recordedMeetings;
    final sources = sourceCount;
    final answers = completedAnswers;
    final weekly = localOutputWeekly;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading('Stats'),
          SizedBox(
            width: double.infinity,
            child: Card(
              shape: const RoundedRectangleBorder(
                borderRadius: DesktopVisuals.panelRadius,
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Wrap(
                  spacing: 30,
                  runSpacing: 24,
                  children: [
                    Container(
                      width: 280,
                      height: 230 * MediaQuery.textScalerOf(context).scale(1),
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: const Color(0xffe2edf8),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Local output words',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          DesktopMetricValue(localWords(), fontSize: 52),
                          const Spacer(),
                          const Text('Estimated from saved local AI output'),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: math.max(
                        280,
                        MediaQuery.sizeOf(context).width - 650,
                      ),
                      height: 230 * MediaQuery.textScalerOf(context).scale(1),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Your weekly output words',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 24),
                          Expanded(
                            child: CustomPaint(
                              size: const Size(
                                double.infinity,
                                double.infinity,
                              ),
                              painter: SettingsUsageChart(
                                weekly,
                                weeks: _stats.displayPeriod?.weeks ?? const [],
                                textStyle: Theme.of(
                                  context,
                                ).textTheme.bodySmall!,
                                textScaler: MediaQuery.textScalerOf(context),
                                textDirection: Directionality.of(context),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (_, constraints) {
              final cardWidth = constraints.maxWidth > 900
                  ? (constraints.maxWidth - 32) / 3
                  : math.min(320.0, constraints.maxWidth);
              return Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  statCard(
                    meetings,
                    'Meetings transcribed',
                    'Fully processed on-device',
                    Icons.mic_none,
                    width: cardWidth,
                  ),
                  statCard(
                    sources,
                    'Knowledge sources added',
                    'Indexed with ${embeddingName()}',
                    Icons.folder_outlined,
                    width: cardWidth,
                  ),
                  statCard(
                    answers,
                    'AI answers provided',
                    'Zero cloud API calls',
                    Icons.auto_awesome,
                    width: cardWidth,
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          Card(
            shape: const RoundedRectangleBorder(
              borderRadius: DesktopVisuals.panelRadius,
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: LayoutBuilder(
                builder: (_, constraints) {
                  final introduction = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Foresight is built with on-device AI models that process your data locally on your computer.',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Get to know on-device AI models such as Gemma:',
                        style: TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 10,
                        children: [
                          pill(
                            'What is Gemma?',
                            () => _host.update(() => gemmaExplanation = true),
                            selected: gemmaExplanation,
                          ),
                          pill(
                            'What is on-device AI?',
                            () => _host.update(() => gemmaExplanation = false),
                            selected: !gemmaExplanation,
                          ),
                        ],
                      ),
                    ],
                  );
                  final explanation = Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: const Color(0xfff2f4fa),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      children: [
                        Image.asset(
                          'assets/images/gemma-mark.png',
                          width: 100,
                          height: 100,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          gemmaExplanation
                              ? 'Gemma is a family of lightweight AI models built by Google DeepMind using the same research and technology behind the Gemini models. Designed to run directly on local hardware such as a laptop without needing an internet connection.'
                              : 'Embedding, transcription and answer generation run on this computer using registered local models. After importing files, questions and recordings do not require a cloud AI service.',
                          style: const TextStyle(fontSize: 14),
                        ),
                      ],
                    ),
                  );
                  return constraints.maxWidth >= 800
                      ? Row(
                          children: [
                            Expanded(
                              flex: 9,
                              child: Padding(
                                padding: const EdgeInsets.only(right: 24),
                                child: introduction,
                              ),
                            ),
                            const SizedBox(width: 28),
                            Expanded(flex: 11, child: explanation),
                          ],
                        )
                      : Column(
                          children: [
                            introduction,
                            const SizedBox(height: 24),
                            explanation,
                          ],
                        );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget statCard(
    int value,
    String title,
    String subtitle,
    IconData icon, {
    double width = 320,
  }) => SizedBox(
    width: width,
    child: Card(
      shape: const RoundedRectangleBorder(
        borderRadius: DesktopVisuals.panelRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: icon == Icons.mic_none
                  ? const Color(0xffebe6f8)
                  : icon == Icons.auto_awesome
                  ? const Color(0xffe1f3f2)
                  : const Color(0xffe2f2ff),
              child: Icon(
                icon,
                color: icon == Icons.mic_none
                    ? const Color(0xff673ab7)
                    : icon == Icons.auto_awesome
                    ? const Color(0xff008577)
                    : const Color(0xff006cda),
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DesktopMetricValue(value),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(subtitle, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
