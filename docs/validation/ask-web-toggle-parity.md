# Ask web-search control parity

Compared the installed original Foresight Ask screen on 2026-10-17 using the
meetings-parity agent's live computer-use screenshot and accessibility tree.
The original has one grey capsule above the bottom-left of the composer,
approximately 36 × 28 logical pixels, containing a globe-with-search icon. Its
accessibility label is `Search the web`, with the observed off-state value
`Answer does not use web search`. The screenshot was returned inline by the
computer-use tool; this pass did not save a separate image artifact.

The shared Ask/meeting-chat composer now has one globe-with-search capsule,
removing its extra Knowledge sources shortcut. Sources remain accessible in
the sidebar. The single control displays the requested state tooltips
`Answer does not use web search` and `Answer include web search result`;
selection uses the existing per-conversation web-search routing. The original
active-state appearance and tooltip were not independently observed in this
pass; the active wording follows the user's supplied reference.

Widget verification covers one toolbar icon, state/tooltips, local/web request
routing, isolated Ask/meeting states, keyboard activation, selected semantics,
answer-in-progress disabling, and switching off an active scope when web
credentials become unavailable. The unavailable-build explanation and existing
citation validation remain covered. The existing composer/keyboard, Sources
sidebar navigation, and screen-size regression tests also pass. No live web
request or pixel-equality comparison is claimed.
