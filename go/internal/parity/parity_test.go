// Package parity is the anti-drift foundation for the Go track: it runs every
// adapter over every captured fixture and checks the result against a canonical
// golden — the SAME normalized values the Swift `checks` assert over the SAME
// fixtures (research/go-core-design.md §1, "fixture-parity CI gate"). Later
// adapters (openrouter/deepseek/moonshot/zhipu/generic) extend this table as
// they are ported, so each is gated the moment it lands.
package parity

import (
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"
	"time"

	"github.com/DjentieY/limit-monitor/go/internal/model"
	"github.com/DjentieY/limit-monitor/go/internal/providers"
)

// codexNow is the fixed anchor the codex fixtures are authored against
// (2026-07-16T12:00:00Z). Both codex fixtures must normalize identically at it.
var codexNow = time.Unix(1784203200, 0).UTC()

// normEntry is the canonical, neutral normalization compared across languages.
type normEntry struct {
	Provider  string
	Kind      string
	Group     string
	Percent   int
	Level     string
	Scope     string
	WindowMin int // -1 when the window is unknown
	Unlimited bool
	ResetUTC  string // seconds-precision UTC, "" when no reset
}

func normalize(limits []model.Limit) []normEntry {
	out := make([]normEntry, len(limits))
	for i, l := range limits {
		n := normEntry{
			Provider:  l.Provider,
			Kind:      l.Kind,
			Group:     l.Group,
			Percent:   l.Percent,
			Level:     l.Level().String(),
			Scope:     l.ScopeName,
			WindowMin: -1,
			Unlimited: l.Unlimited,
		}
		if l.WindowMinutes != nil {
			n.WindowMin = *l.WindowMinutes
		}
		if l.ResetsAt != nil {
			n.ResetUTC = l.ResetsAt.UTC().Format("2006-01-02T15:04:05")
		}
		out[i] = n
	}
	return out
}

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

func load(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(fixturesDir(t), name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return data
}

// The canonical golden. Percents/levels/scopes/windows/resets here are the same
// facts the Swift checks 1–3 / 10 / 15–16 assert.
var parityTable = []struct {
	fixture string
	parse   func(raw []byte) []model.Limit
	want    []normEntry
}{
	{
		fixture: "usage_sample.json",
		parse:   providers.ParseClaude,
		want: []normEntry{
			{"claude", "session", "session", 10, "green", "", -1, false, "2026-07-16T22:59:59"},
			{"claude", "weekly_all", "weekly", 23, "green", "", -1, false, "2026-07-18T07:59:59"},
			{"claude", "weekly_scoped", "weekly", 39, "green", "Fable", -1, false, "2026-07-18T07:59:59"},
		},
	},
	{
		fixture: "codex_usage_sample.json",
		parse:   func(raw []byte) []model.Limit { return providers.ParseCodex(raw, codexNow) },
		want: []normEntry{
			{"codex", "session", "session", 12, "green", "", 300, false, "2026-07-16T14:00:00"},
			{"codex", "weekly_all", "weekly", 40, "green", "", 10080, false, "2026-07-21T12:00:00"},
			{"codex", "weekly_scoped", "weekly", 55, "yellow", "Spark", 10080, false, "2026-07-21T12:00:00"},
		},
	},
	{
		// Alias fixture MUST normalize identically to the canonical codex fixture.
		fixture: "codex_usage_alias.json",
		parse:   func(raw []byte) []model.Limit { return providers.ParseCodex(raw, codexNow) },
		want: []normEntry{
			{"codex", "session", "session", 12, "green", "", 300, false, "2026-07-16T14:00:00"},
			{"codex", "weekly_all", "weekly", 40, "green", "", 10080, false, "2026-07-21T12:00:00"},
			{"codex", "weekly_scoped", "weekly", 55, "yellow", "Spark", 10080, false, "2026-07-21T12:00:00"},
		},
	},
	{
		fixture: "cursor_usage_summary_sample.json",
		parse:   providers.ParseCursor,
		want: []normEntry{
			{"cursor", "cursor_auto", "", 2, "green", "", -1, false, "2026-08-07T05:27:30"},
			{"cursor", "cursor_api", "", 6, "green", "", -1, false, "2026-08-07T05:27:30"},
		},
	},
	{
		fixture: "cursor_usage_summary_ondemand.json",
		parse:   providers.ParseCursor,
		want: []normEntry{
			{"cursor", "cursor_auto", "", 92, "red", "", -1, false, "2026-08-07T05:27:30"},
			{"cursor", "cursor_api", "", 96, "red", "", -1, false, "2026-08-07T05:27:30"},
			{"cursor", "cursor_on_demand", "", 75, "orange", "", -1, false, "2026-08-07T05:27:30"},
		},
	},
}

func TestFixtureParity(t *testing.T) {
	for _, tc := range parityTable {
		t.Run(tc.fixture, func(t *testing.T) {
			got := normalize(tc.parse(load(t, tc.fixture)))
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("parity drift for %s\n got: %+v\nwant: %+v", tc.fixture, got, tc.want)
			}
		})
	}
}

// The alias and canonical codex fixtures must be byte-for-byte identical after
// normalization — the load-bearing "authored to normalize identically" contract.
func TestCodexAliasParity(t *testing.T) {
	canonical := normalize(providers.ParseCodex(load(t, "codex_usage_sample.json"), codexNow))
	alias := normalize(providers.ParseCodex(load(t, "codex_usage_alias.json"), codexNow))
	if !reflect.DeepEqual(alias, canonical) {
		t.Errorf("codex alias must normalize identically\n alias: %+v\n canon: %+v", alias, canonical)
	}
}
