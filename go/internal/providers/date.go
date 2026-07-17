package providers

import "time"

// parseISODate ports LimitMonitorCore/DateParsing.swift (ISODateParser). The
// live `resets_at` carries 6-digit fractional seconds with a `+00:00` offset
// (the documented trap); cursor's billingCycleEnd carries 3-digit fractions
// with a trailing `Z`. Go's `Z07:00` clause parses both `Z` and `±hh:mm`, so
// the layouts are tried longest-fraction first, matching the Swift fallback
// chain, then RFC3339(Nano) as a final catch-all.
var isoLayouts = []string{
	"2006-01-02T15:04:05.000000Z07:00", // 6-digit fraction + offset (claude)
	"2006-01-02T15:04:05.000Z07:00",    // 3-digit fraction + offset/Z (cursor)
	"2006-01-02T15:04:05Z07:00",        // no fraction + offset/Z
	time.RFC3339Nano,                   // variable fraction fallback
	time.RFC3339,
}

// parseISODate returns the parsed instant (ok=false when no layout matches).
func parseISODate(s string) (time.Time, bool) {
	for _, layout := range isoLayouts {
		if t, err := time.Parse(layout, s); err == nil {
			return t, true
		}
	}
	return time.Time{}, false
}

// utcString is the canonical UTC serialization (seconds precision, literal
// `+00:00` suffix) shared by notification stamps and snapshot dates
// (ISODateParser.utcString).
func utcString(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05") + "+00:00"
}
