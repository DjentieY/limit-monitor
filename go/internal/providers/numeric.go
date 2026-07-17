package providers

import (
	"bytes"
	"encoding/json"
	"math"
)

// decodeObject decodes the response bytes into a generic object tree with
// json.Number for numeric literals (so fractional percents keep full IEEE-754
// precision, matching Swift's NSNumber-backed JSONSerialization). ok=false when
// the bytes are not a JSON object — mirroring the Swift parsers' `guard ... as?
// [String: Any] else { return [] }`.
func decodeObject(data []byte) (map[string]any, bool) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var root any
	if err := dec.Decode(&root); err != nil {
		return nil, false
	}
	obj, ok := root.(map[string]any)
	return obj, ok
}

// floatValue coerces a decoded JSON number to float64 (Swift `doubleValue`:
// Double | Int | NSNumber → Double). Non-numbers (bool, string, null) → false.
func floatValue(v any) (float64, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return 0, false
	}
	f, err := n.Float64()
	if err != nil {
		return 0, false
	}
	return f, true
}

// intRounded coerces a decoded JSON number to int, mirroring the claude parser's
// `intValue`: an integral literal is taken as-is; a fractional one is rounded
// half-away-from-zero (Swift `Int(double.rounded())`, default
// `.toNearestOrAwayFromZero`). Non-numbers → false.
func intRounded(v any) (int, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return 0, false
	}
	if i, err := n.Int64(); err == nil {
		return int(i), true
	}
	f, err := n.Float64()
	if err != nil {
		return 0, false
	}
	return int(math.Round(f)), true
}

// intPtr is a small helper for the optional Limit fields.
func intPtr(v int) *int { return &v }
