import 'package:flutter/widgets.dart';
import 'workspace_tab.dart';

enum DesktopFeature {
  integrations,
  settings,
  sources,
  meetings,
  chat,
  onboarding,
}

/// Presentation identities follow the public facts each feature consumes.
/// Unknown service events and the global operation gate retain broad refreshes.
class FeatureUpdates {
  int _global = 0;
  final _versions = <DesktopFeature, int>{};
  final _views = <WorkspaceTab, ((int, int, int), Widget)>{};
  final _presentation = <String, ((int, Object), Widget)>{};
  void all() => _global++;
  void changed(DesktopFeature feature) {
    final affected = switch (feature) {
      DesktopFeature.integrations => {
        feature,
        DesktopFeature.settings,
        DesktopFeature.meetings,
        DesktopFeature.onboarding,
      },
      DesktopFeature.settings => {feature, DesktopFeature.onboarding},
      DesktopFeature.meetings => {
        feature,
        DesktopFeature.settings,
        DesktopFeature.chat,
      },
      DesktopFeature.chat => {feature, DesktopFeature.meetings},
      DesktopFeature.sources || DesktopFeature.onboarding => {feature},
    };
    for (final owner in affected) {
      _versions.update(owner, (version) => version + 1, ifAbsent: () => 1);
    }
  }

  Widget view(WorkspaceTab tab, int serviceRevision, Widget Function() create) {
    final owner = switch (tab) {
      WorkspaceTab.sources || WorkspaceTab.notes => DesktopFeature.sources,
      WorkspaceTab.chat => DesktopFeature.chat,
      WorkspaceTab.meetings => DesktopFeature.meetings,
      WorkspaceTab.models ||
      WorkspaceTab.settings ||
      WorkspaceTab.stats => DesktopFeature.settings,
    };
    final key = (_global, serviceRevision, _versions[owner] ?? 0);
    final previous = _views[tab];
    if (previous != null && previous.$1 == key) return previous.$2;
    final widget = create();
    _views[tab] = (key, widget);
    return widget;
  }

  Widget presentation(String name, Object facts, Widget Function() create) {
    final key = (_global, facts);
    final previous = _presentation[name];
    if (previous != null && previous.$1 == key) return previous.$2;
    final widget = create();
    _presentation[name] = (key, widget);
    return widget;
  }
}
