import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

/// Follow new output until the reader deliberately scrolls away from the end.
class ChatHistoryViewport extends StatefulWidget {
  const ChatHistoryViewport({
    super.key,
    required this.revision,
    required this.answering,
    required this.children,
  });
  final Object revision;
  final bool answering;
  final List<Widget> children;
  @override
  State<ChatHistoryViewport> createState() => _ChatHistoryViewportState();
}

class _ChatHistoryViewportState extends State<ChatHistoryViewport> {
  final scroll = ScrollController();
  bool following = true, unseen = false, movingToLatest = false;
  @override
  void initState() {
    super.initState();
    followAfterLayout();
  }

  @override
  void didUpdateWidget(ChatHistoryViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision == widget.revision) return;
    if (widget.answering && !oldWidget.answering) following = true;
    if (following) {
      followAfterLayout();
    } else {
      unseen = true;
    }
  }

  void followAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scroll.hasClients || !following) return;
      movingToLatest = true;
      try {
        scroll.jumpTo(scroll.position.maxScrollExtent);
      } finally {
        movingToLatest = false;
      }
      if (unseen) setState(() => unseen = false);
    });
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (!movingToLatest &&
              (notification is UserScrollNotification &&
                      notification.direction != ScrollDirection.idle ||
                  notification is ScrollUpdateNotification)) {
            following = notification.metrics.extentAfter < 48;
            if (following && unseen) setState(() => unseen = false);
          }
          return false;
        },
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: (_) {
            if (following) followAfterLayout();
            return false;
          },
          child: ListView(controller: scroll, children: widget.children),
        ),
      ),
      if (unseen)
        Align(
          alignment: Alignment.bottomCenter,
          child: FilledButton.tonal(
            onPressed: () {
              following = true;
              followAfterLayout();
            },
            child: const Text('Show latest answer'),
          ),
        ),
    ],
  );
}
