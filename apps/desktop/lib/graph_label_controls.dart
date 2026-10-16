import 'dart:async';
import 'package:flutter/material.dart';
import 'graph_labels.dart';
import 'graph_rendering.dart';

class GraphLabelControls extends StatefulWidget {
  final List<DocumentLabel> labels;
  final TextEditingController controller;
  final Future<void> Function(String) onAdd;
  final void Function(String) onRemove;
  final bool enabled;
  const GraphLabelControls({
    super.key,
    required this.labels,
    required this.controller,
    required this.onAdd,
    required this.onRemove,
    this.enabled = true,
  });
  @override
  State<GraphLabelControls> createState() => _GraphLabelControlsState();
}

class _GraphLabelControlsState extends State<GraphLabelControls> {
  bool editing = false;
  final focus = FocusNode();
  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final label in widget.labels)
          Container(
            key: ValueKey('inspector-label-${label.name}'),
            height: 24,
            constraints: const BoxConstraints(maxWidth: 280),
            padding: const EdgeInsets.fromLTRB(13, 3, 13, 3),
            decoration: BoxDecoration(
              color: graphLabelColor(label.colorHex, scheme.primary),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  key: ValueKey('inspector-remove-${label.name}'),
                  onTap: widget.enabled
                      ? () => widget.onRemove(label.name)
                      : null,
                  child: const Icon(Icons.close, size: 12, color: Colors.white),
                ),
              ],
            ),
          ),
        if (!editing)
          InkWell(
            key: const ValueKey('inspector-add-label'),
            onTap: !widget.enabled
                ? null
                : () {
                    setState(() => editing = true);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && editing) focus.requestFocus();
                    });
                  },
            customBorder: const CircleBorder(),
            child: Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primary.withAlpha((.12 * 255).round()),
              ),
              child: Icon(Icons.add, size: 14, color: scheme.primary),
            ),
          )
        else
          Container(
            width: 140,
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('inspector-label-input'),
                    controller: widget.controller,
                    focusNode: focus,
                    enabled: widget.enabled,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurface.withAlpha((.9 * 255).round()),
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: '+ Add Label',
                      contentPadding: const EdgeInsets.symmetric(vertical: 6),
                      hintStyle: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurface.withAlpha((.5 * 255).round()),
                      ),
                    ),
                    onSubmitted: (value) {
                      unawaited(widget.onAdd(value));
                      setState(() => editing = false);
                    },
                  ),
                ),
                GestureDetector(
                  key: const ValueKey('inspector-cancel-label'),
                  onTap: () {
                    widget.controller.clear();
                    setState(() => editing = false);
                  },
                  child: Icon(
                    Icons.close,
                    size: 12,
                    color: scheme.onSurface.withAlpha((.5 * 255).round()),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
