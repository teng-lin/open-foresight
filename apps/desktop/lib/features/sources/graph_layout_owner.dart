part of 'sources_controller.dart';

extension _GraphLayoutOwner on SourcesController {
  bool _graphLayoutCurrent(String key, FeatureRequestIdentity owner) =>
      graphLayoutKey == key &&
      identical(_graphLayoutOwner, owner) &&
      owner.isCurrent(d, alive: mounted);

  void _graphLayoutFailed(
    String key,
    FeatureRequestIdentity owner,
    Object error, {
    bool clearScene = false,
  }) {
    if (!_graphLayoutCurrent(key, owner)) return;
    update(() {
      if (clearScene) {
        graphPoints = {};
        graphEdges = [];
        graphSceneVectors = {};
        graphSelectionRevision++;
        graphSelectionEdges = [];
      }
      graphOrganizing = false;
      graphLayoutError = error.toString();
    });
    // Render the failure with its key still deduplicated. A later external
    // refresh can retry the same inputs without an error/rebuild retry loop.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_graphLayoutCurrent(key, owner)) graphLayoutKey = '';
    });
  }

  void _featureScheduleGraphLayout(List<SourceSummary> all) {
    final selected = graphSelectedDocument;
    if (selected != null && !all.any((row) => row.id == selected)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            graphSelectedDocument == selected &&
            !_reads.sources.any((row) => row.id == selected)) {
          selectGraphDocument(null);
        }
      });
    }
    final labelSet = _reads.labelSet;
    final labelRecords = _reads.labels;
    final forceLabels = <String, List<String>>{};
    final forceNames = <String>{};
    for (final source in all) {
      final id = source.id;
      forceLabels[id] = labelRecords
          .where((label) => label.documentId == id)
          .map((label) => label.name)
          .toList();
      forceNames.addAll(forceLabels[id]!);
    }
    forceNames.addAll(
      labelRecords
          .where(
            (label) =>
                label.source == 'user_defined' ||
                label.source == 'user_attached',
          )
          .map((label) => label.name),
    );
    final snapshot = d.helper.snapshot;
    if (snapshot?.pipeline != 'ready') {
      var sources = all.where((s) => s.title.trim().isNotEmpty).toList();
      final registered = _reads.currentEmbedding;
      final key = jsonEncode([
        'cached',
        snapshot?.pipeline,
        registered?.digest,
        typedGraphDocumentSet(sources),
        labelSet,
        graphOrganizationRevision,
      ]);
      if (key == graphLayoutKey &&
          (_graphLayoutOwner?.isCurrent(d, alive: mounted) ?? false)) {
        return;
      }
      graphLayoutKey = key;
      final owner = _graphLayoutOwner = FeatureRequestIdentity.capture(d);
      bool current() => _graphLayoutCurrent(key, owner);
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!current()) return;
        try {
          var saved = await readGraphLayout(
            d.store,
            sources,
            labelSet: labelSet,
          );
          if (!current()) return;
          sources = typedGraphSceneSources(sources, saved.vectors);
          saved = await readGraphLayout(d.store, sources, labelSet: labelSet);
          if (!current()) return;
          update(() {
            graphPoints = saved.points;
            graphEdges = [];
            graphSceneVectors = saved.vectors;
            graphSelectionRevision++;
            graphSelectionEdges = [];
            graphOrganizing = true;
            graphLayoutError = '';
          });
          final scene = saved.complete
              ? null
              : await organizeForceGraphSceneInBackground(
                  saved.vectors,
                  forceLabels,
                  forceNames.toList(),
                  saved.points,
                  documents: sources.map((s) => s.id).toList(),
                );
          if (!current()) return;
          final edges =
              scene?.edges ?? await graphEdgesInBackground(saved.vectors);
          if (!current()) return;
          if (scene != null &&
              saved.identity != null &&
              scene.points.length == sources.length &&
              sources.length >= 2) {
            final published = await saveGraphLayout(
              saved.identity!,
              sources,
              saved.vectors,
              scene.points,
              labelSet: labelSet,
              clusters: scene.clusters,
            );
            if (!current()) return;
            if (!published) {
              update(() {
                graphLayoutKey = '';
                graphOrganizing = false;
              });
              return;
            }
          }
          update(() {
            if (scene != null) graphPoints = scene.points;
            graphEdges = edges;
            graphOrganizing = false;
          });
          refreshGraphSelection();
          scheduleGraphFit();
        } catch (e) {
          _graphLayoutFailed(key, owner, e);
        }
      });
      return;
    }
    if (d.sourcesPaused) {
      graphLayoutKey = '';
      graphOrganizing = false;
      return;
    }
    var sources = all.where((s) => s.title.trim().isNotEmpty).toList();
    final identity = snapshot!.model.writeToJson();
    final instance = snapshot.instanceId;
    final generation = snapshot.activeGeneration.toString();
    final persistentIdentity = jsonEncode([
      graphLayoutAlgorithmVersion,
      snapshot.model.modelDigest,
      snapshot.model.tokenizerDigest,
      snapshot.model.preprocessing,
      snapshot.model.backend,
      snapshot.model.dimensions,
    ]);
    final key = jsonEncode([
      identity,
      instance,
      generation,
      sources.map((s) => [s.id, s.revision]).toList(),
      labelSet,
      graphOrganizationRevision,
    ]);
    if (key == graphLayoutKey &&
        (_graphLayoutOwner?.isCurrent(d, alive: mounted) ?? false)) {
      return;
    }
    graphLayoutKey = key;
    final owner = _graphLayoutOwner = FeatureRequestIdentity.capture(d);
    bool current() => _graphLayoutCurrent(key, owner);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!current()) return;
      // Results computed for this layout apply only to the same model run.
      bool helperChanged() {
        final current = d.helper.snapshot;
        return d.sourcesPaused ||
            current?.pipeline != 'ready' ||
            current!.model.writeToJson() != identity ||
            current.instanceId != instance ||
            current.activeGeneration.toString() != generation;
      }

      try {
        final saved = await readGraphLayout(
          d.store,
          sources,
          identity: persistentIdentity,
          dimensions: snapshot.model.dimensions,
          labelSet: labelSet,
        );
        if (!current() || helperChanged()) return;
        for (final source in sources) {
          final vector = saved.vectors[source.id];
          if (vector != null) {
            graphVectorCache[jsonEncode([
                  identity,
                  source.id,
                  source.revision,
                ])] =
                vector;
          }
        }
        update(() {
          graphPoints = saved.points;
          graphEdges = [];
          graphSceneVectors = saved.vectors;
          graphSelectionRevision++;
          graphSelectionEdges = [];
          graphOrganizing = true;
          graphLayoutError = '';
        });
        if (saved.complete) {
          final edges = await graphEdgesInBackground(saved.vectors);
          if (!current() || helperChanged()) return;
          update(() {
            graphEdges = edges;
            graphOrganizing = false;
          });
          refreshGraphSelection();
          scheduleGraphFit();
          return;
        }
        final missing = sources
            .where(
              (s) =>
                  s.state == 'indexed' &&
                  !graphVectorCache.containsKey(
                    jsonEncode([identity, s.id, s.revision]),
                  ),
            )
            .toList();
        // Cache each batch as it arrives, so a later failure keeps progress.
        for (
          var start = 0;
          start < missing.length;
          start += _graphEmbeddingBatch
        ) {
          final batch = missing.sublist(
            start,
            math.min(start + _graphEmbeddingBatch, missing.length),
          );
          final fresh = await d.graphEmbeddings(graphSourceArguments(batch));
          // Never cache vectors from a model run that has since changed.
          if (!current() || helperChanged()) return;
          for (final source in batch) {
            final vector = fresh[source.id];
            if (vector != null)
              graphVectorCache[jsonEncode([
                    identity,
                    source.id,
                    source.revision,
                  ])] =
                  vector;
          }
        }
        final vectors = <String, List<double>>{};
        final retained = <String>{};
        for (final source in sources) {
          final cacheKey = jsonEncode([identity, source.id, source.revision]);
          retained.add(cacheKey);
          final vector = graphVectorCache[cacheKey];
          if (vector != null) vectors[source.id] = vector;
        }
        graphVectorCache.removeWhere((key, _) => !retained.contains(key));
        sources = typedGraphSceneSources(sources, vectors);
        final scene = await organizeForceGraphSceneInBackground(
          vectors,
          forceLabels,
          forceNames.toList(),
          saved.points,
          documents: sources.map((s) => s.id).toList(),
        );
        final layout = scene.points;
        if (!current() || helperChanged()) return;
        if (layout.length == sources.length && sources.length >= 2) {
          final published = await saveGraphLayout(
            persistentIdentity,
            sources,
            vectors,
            layout,
            labelSet: labelSet,
            clusters: scene.clusters,
          );
          if (!current() || helperChanged()) return;
          if (!published) {
            update(() {
              graphLayoutKey = '';
              graphOrganizing = false;
            });
            return;
          }
        }
        update(() {
          graphPoints = layout;
          graphEdges = scene.edges;
          graphSceneVectors = vectors;
          graphOrganizing = false;
        });
        refreshGraphSelection();
        scheduleGraphFit();
      } catch (e) {
        if (!current() || helperChanged()) return;
        _graphLayoutFailed(key, owner, e, clearScene: true);
      }
    });
  }
}
