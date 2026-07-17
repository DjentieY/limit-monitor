package jsonpath

import (
	"testing"

	"github.com/shopspring/decimal"
)

func mustParse(t *testing.T, s string) any {
	t.Helper()
	root, err := Parse([]byte(s))
	if err != nil {
		t.Fatalf("parse %q: %v", s, err)
	}
	return root
}

func dec(t *testing.T, s string) decimal.Decimal {
	t.Helper()
	d, err := decimal.NewFromString(s)
	if err != nil {
		t.Fatalf("decimal %q: %v", s, err)
	}
	return d
}

// Mirrors Swift check 22 (SPEC.md v0.4 "checks additions"): dot-path + Decimal.
func TestDotPathDecimal(t *testing.T) {
	root := mustParse(t, `{"a":[{"v":"1,234.56"},{"v":42}],"total":{"val":"-2317"},"credits":2350,"flag":true}`)

	cases := []struct {
		name string
		path string
		want string // "" means expect ok=false
	}{
		{"array-index + thousands-comma string", "a.0.v", "1234.56"},
		{"JSON number via dot-path", "a.1.v", "42"},
		{"nested decimal string", "total.val", "-2317"},
		{"JSON number", "credits", "2350"},
	}
	for _, tc := range cases {
		got, ok := DecimalAt(tc.path, root)
		if !ok {
			t.Errorf("22. %s: expected a value at %q", tc.name, tc.path)
			continue
		}
		if !got.Equal(dec(t, tc.want)) {
			t.Errorf("22. %s: got %s, want %s", tc.name, got, tc.want)
		}
	}

	// Missing / out-of-range / boolean → nil (ok=false).
	for _, tc := range []struct{ name, path string }{
		{"out-of-range array index", "a.5.v"},
		{"missing path", "nope.x"},
		{"boolean is not a number", "flag"},
		{"empty path", ""},
	} {
		if _, ok := DecimalAt(tc.path, root); ok {
			t.Errorf("22. %s: expected nil at %q", tc.name, tc.path)
		}
	}

	// okFlag-style strict bool extraction.
	if b, ok := BoolAt("flag", root); !ok || !b {
		t.Error("22. okFlag-style bool extraction should be true")
	}
	if _, ok := BoolAt("credits", root); ok {
		t.Error("22. a number is not a strict bool")
	}
}

// Mirrors Swift check 22 FieldSpec.resolve: scale (0.01/0.0001/-0.01) + clampMin.
func TestFieldSpecResolve(t *testing.T) {
	root := mustParse(t, `{"a":[{"v":"1,234.56"},{"v":42}],"total":{"val":"-2317"},"credits":2350,"flag":true}`)
	novita := mustParse(t, `{"availableBalance":"1234500"}`)
	xaiPositive := mustParse(t, `{"total":{"val":"100"}}`)
	zero := decimal.NewFromInt(0)

	cases := []struct {
		name string
		spec FieldSpec
		root any
		want string
	}{
		{"hyperbolic cents scale 0.01", FieldSpec{Path: "credits", Scale: dec(t, "0.01")}, root, "23.5"},
		{"novita 1/10000-USD scale 0.0001 stays exact", FieldSpec{Path: "availableBalance", Scale: dec(t, "0.0001")}, novita, "123.45"},
		{"xAI inverted-sign scale -0.01", FieldSpec{Path: "total.val", Scale: dec(t, "-0.01"), ClampMin: &zero}, root, "23.17"},
		{"clampMin 0 floors a negative result", FieldSpec{Path: "total.val", Scale: dec(t, "-0.01"), ClampMin: &zero}, xaiPositive, "0"},
	}
	for _, tc := range cases {
		got, ok := tc.spec.Resolve(tc.root)
		if !ok {
			t.Errorf("22. %s: expected a value", tc.name)
			continue
		}
		if !got.Equal(dec(t, tc.want)) {
			t.Errorf("22. %s: got %s, want %s", tc.name, got, tc.want)
		}
	}

	// Missing path → ok=false.
	if _, ok := (FieldSpec{Path: "nope", Scale: decimal.NewFromInt(1)}).Resolve(root); ok {
		t.Error("22. FieldSpec on a missing path should be nil")
	}
}

// RoundedInt must be half-away-from-zero, matching NSDecimalNumber `.plain`.
func TestRoundedIntHalfUp(t *testing.T) {
	cases := []struct {
		in   string
		want int
	}{
		{"25.5", 26}, {"37.4", 37}, {"6.6", 7}, {"6.466666666666667", 6},
		{"1.527536231884058", 2}, {"-25.5", -26}, {"0.5", 1}, {"-0.5", -1},
	}
	for _, tc := range cases {
		if got := RoundedInt(dec(t, tc.in)); got != tc.want {
			t.Errorf("RoundedInt(%s) = %d, want %d", tc.in, got, tc.want)
		}
	}
}

// Int truncates toward zero (NSNumber.intValue); bools are not numbers.
func TestIntTruncation(t *testing.T) {
	root := mustParse(t, `{"n":42,"f":42.9,"neg":-3.9,"flag":true}`)
	if v, ok := IntAt("n", root); !ok || v != 42 {
		t.Errorf("IntAt n = %d,%v", v, ok)
	}
	if v, ok := IntAt("f", root); !ok || v != 42 {
		t.Errorf("IntAt f (truncate) = %d,%v", v, ok)
	}
	if v, ok := IntAt("neg", root); !ok || v != -3 {
		t.Errorf("IntAt neg (truncate toward zero) = %d,%v", v, ok)
	}
	if _, ok := IntAt("flag", root); ok {
		t.Error("IntAt flag: a bool is not an int")
	}
}
