package providers

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"
	"time"

	"github.com/DjentieY/limit-monitor/go/internal/model"
)

// eq is a deep-equality assertion mirroring the Swift `eq(...)` check helper.
func eq[T any](t *testing.T, got, want T, msg string) {
	t.Helper()
	if !reflect.DeepEqual(got, want) {
		t.Errorf("%s: got %v, want %v", msg, got, want)
	}
}

// codexNow is the fixed anchor the codex fixtures are authored against
// (2026-07-16T12:00:00Z, epoch 1784203200 — SPEC.md v0.2 "Fixtures"). The
// canonical and alias fixtures must normalize identically at this instant.
var codexNow = time.Unix(1784203200, 0).UTC()

// fixturesDir resolves macos/fixtures relative to this test file (runtime.Caller
// → ../../../macos/fixtures), so the SAME captured responses feed both
// `swift run checks` and `go test` with no fixture move (HARD RULE: zero-touch
// on the Swift side).
func fixturesDir(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	dir := filepath.Join(filepath.Dir(file), "..", "..", "..", "macos", "fixtures")
	if _, err := os.Stat(dir); err != nil {
		t.Fatalf("fixtures dir not found at %s: %v", dir, err)
	}
	return dir
}

// mustNumber wraps a literal as a json.Number, so edge-case tests can inject
// numeric values into a decoded tree exactly as the UseNumber decoder would.
func mustNumber(s string) json.Number { return json.Number(s) }

func loadFixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(fixturesDir(t), name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return data
}

// decodeFixture decodes a fixture into a generic object tree with json.Number,
// matching the adapters' own decoding (used by the legacy/edge-case tests that
// mutate the root before re-parsing, mirroring the Swift checks).
func decodeFixture(t *testing.T, name string) map[string]any {
	t.Helper()
	dec := json.NewDecoder(bytes.NewReader(loadFixture(t, name)))
	dec.UseNumber()
	var root map[string]any
	if err := dec.Decode(&root); err != nil {
		t.Fatalf("decode fixture %s: %v", name, err)
	}
	return root
}

// utcSeconds formats an instant as the seconds-precision UTC string the Swift
// checks assert against ("2026-07-16T22:59:59").
func utcSeconds(t *time.Time) string {
	if t == nil {
		return "<nil>"
	}
	return t.UTC().Format("2006-01-02T15:04:05")
}

func kinds(limits []model.Limit) []string {
	out := make([]string, len(limits))
	for i, l := range limits {
		out[i] = l.Kind
	}
	return out
}

func percents(limits []model.Limit) []int {
	out := make([]int, len(limits))
	for i, l := range limits {
		out[i] = l.Percent
	}
	return out
}

func providersOf(limits []model.Limit) []string {
	out := make([]string, len(limits))
	for i, l := range limits {
		out[i] = l.Provider
	}
	return out
}

func windowMinutes(limits []model.Limit) []int {
	out := make([]int, len(limits))
	for i, l := range limits {
		if l.WindowMinutes != nil {
			out[i] = *l.WindowMinutes
		} else {
			out[i] = -1
		}
	}
	return out
}

func levels(limits []model.Limit) []model.Level {
	out := make([]model.Level, len(limits))
	for i, l := range limits {
		out[i] = l.Level()
	}
	return out
}

// --- pointer-aware Limit equality (for codex alias == canonical parity) ------

func timeEqual(a, b *time.Time) bool {
	if a == nil || b == nil {
		return a == b
	}
	return a.Equal(*b)
}

func intPtrEqual(a, b *int) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}

func limitEqual(a, b model.Limit) bool {
	return a.Provider == b.Provider &&
		a.Kind == b.Kind &&
		a.Group == b.Group &&
		a.Percent == b.Percent &&
		a.Severity == b.Severity &&
		a.ResetsAtRaw == b.ResetsAtRaw &&
		timeEqual(a.ResetsAt, b.ResetsAt) &&
		a.ScopeName == b.ScopeName &&
		intPtrEqual(a.WindowMinutes, b.WindowMinutes) &&
		a.Unlimited == b.Unlimited &&
		a.MenuOnly == b.MenuOnly &&
		a.ProviderName == b.ProviderName &&
		a.BalanceText == b.BalanceText
}

func limitsEqual(a, b []model.Limit) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if !limitEqual(a[i], b[i]) {
			return false
		}
	}
	return true
}
