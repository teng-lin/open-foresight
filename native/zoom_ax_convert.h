#pragma once
// Conversion of Accessibility attribute values (CoreFoundation objects) into
// the collector's plain types. Split from the helper so it can be tested with
// ordinary CFString/AXValue objects, without Accessibility permission.
#include "zoom_collector.h"

namespace foresight::zoom {

// An AXError code mapped to a status: a missing attribute is an observed
// absence, API-disabled is a loss of trust, anything else is a failed read.
AttrStatus attr_status_from_ax_error(int ax_error);

// If `object` is the AXValue wrapper copy-multiple uses for a failed attribute,
// the wrapped AXError code; 0 otherwise. `object` is a CFTypeRef or null.
int ax_error_in_object(const void *object);

// A string attribute: Absent for a missing or non-string value, failure for an
// error wrapper, `lossy` for text with no faithful UTF-8 (unpaired surrogates)
// or that would be cut at an embedded NUL. Drains its own autorelease pool.
TextAttr text_attr_from_object(const void *object);

} // namespace foresight::zoom
