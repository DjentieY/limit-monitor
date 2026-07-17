// Package jsonpath is the Go port of LimitMonitorCore/JSONPath.swift: dot-path
// extraction over a decoded JSON tree plus Decimal coercion (JSON number OR
// decimal string, thousands commas stripped) with scale/clampMin. It is the
// numeric foundation the config/generic adapters build on. Money uses
// shopspring/decimal so cents/1e-4 units stay exact and percent rounding is
// half-away-from-zero, matching NSDecimalNumber `.plain`.
package jsonpath

import (
	"bytes"
	"encoding/json"
	"strings"

	"github.com/shopspring/decimal"
)

// Parse decodes JSON into a generic tree using json.Number for every numeric
// literal, so no float precision is lost before Decimal coercion (mirrors the
// exactness of Swift's NSNumber-backed JSONSerialization values).
func Parse(data []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var root any
	if err := dec.Decode(&root); err != nil {
		return nil, err
	}
	return root, nil
}

// Value walks `path` (split on ".", an integer segment indexes an array,
// anything else is a map key) and returns the value, or nil for a missing key,
// out-of-range index, non-container mid-path, empty path or a JSON null.
func Value(path string, root any) any {
	if path == "" {
		return nil
	}
	current := root
	for _, seg := range strings.Split(path, ".") {
		switch node := current.(type) {
		case map[string]any:
			next, ok := node[seg]
			if !ok {
				return nil
			}
			current = next
		case []any:
			idx, ok := parseIndex(seg)
			if !ok || idx < 0 || idx >= len(node) {
				return nil
			}
			current = node[idx]
		default:
			return nil
		}
	}
	if current == nil { // JSON null
		return nil
	}
	return current
}

func parseIndex(seg string) (int, bool) {
	if seg == "" {
		return 0, false
	}
	n := 0
	for _, r := range seg {
		if r < '0' || r > '9' {
			return 0, false
		}
		n = n*10 + int(r-'0')
	}
	return n, true
}

// Decimal coerces a JSON number or a decimal string ("1,234.56" → 1234.56;
// thousands commas stripped, surrounding whitespace trimmed) to a Decimal.
// Booleans, nulls and non-numeric strings yield ok=false (JSONPath.decimal).
func Decimal(v any) (decimal.Decimal, bool) {
	switch x := v.(type) {
	case string:
		cleaned := strings.TrimSpace(strings.ReplaceAll(x, ",", ""))
		if cleaned == "" {
			return decimal.Decimal{}, false
		}
		d, err := decimal.NewFromString(cleaned)
		if err != nil {
			return decimal.Decimal{}, false
		}
		return d, true
	case json.Number:
		d, err := decimal.NewFromString(x.String())
		if err != nil {
			return decimal.Decimal{}, false
		}
		return d, true
	default:
		return decimal.Decimal{}, false
	}
}

// DecimalAt is Decimal(Value(path, root)).
func DecimalAt(path string, root any) (decimal.Decimal, bool) {
	return Decimal(Value(path, root))
}

// Bool extracts a strict JSON boolean only (a numeric 0/1 is not a flag).
func Bool(v any) (bool, bool) {
	b, ok := v.(bool)
	return b, ok
}

// BoolAt is Bool(Value(path, root)).
func BoolAt(path string, root any) (bool, bool) {
	return Bool(Value(path, root))
}

// Int truncates a JSON number toward zero (JSONPath.int → NSNumber.intValue);
// booleans and non-numbers yield ok=false.
func Int(v any) (int, bool) {
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
	return int(f), true // truncates toward zero
}

// IntAt is Int(Value(path, root)).
func IntAt(path string, root any) (int, bool) {
	return Int(Value(path, root))
}

// RoundedInt is half-away-from-zero rounding to an integer (25.5→26, 37.4→37,
// 6.6→7, -25.5→-26), matching NSDecimalNumber `.plain` used for percent math.
func RoundedInt(v decimal.Decimal) int {
	return int(v.Round(0).IntPart())
}

// FieldSpec is the balance/limit extraction spec (ProvidersConfig.swift
// `FieldSpec`): a dot-path, a multiplicative Scale (unit conversion, e.g.
// cents→dollars 0.01, 1e-4-USD 0.0001, inverted-sign -0.01) and an optional
// ClampMin floor. Scale must be set explicitly (Swift's init defaults it to 1).
type FieldSpec struct {
	Path     string
	Scale    decimal.Decimal
	ClampMin *decimal.Decimal
}

// Resolve reads the raw Decimal at Path, multiplies by Scale, then floors at
// ClampMin when set. ok=false when the path is missing/unparseable.
func (f FieldSpec) Resolve(root any) (decimal.Decimal, bool) {
	raw, ok := DecimalAt(f.Path, root)
	if !ok {
		return decimal.Decimal{}, false
	}
	value := raw.Mul(f.Scale)
	if f.ClampMin != nil && value.LessThan(*f.ClampMin) {
		value = *f.ClampMin
	}
	return value, true
}
