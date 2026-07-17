package providers

import (
	"testing"

	"github.com/DjentieY/limit-monitor/go/internal/model"
)

// Mirrors Swift checks 1–3 (SPEC.md "checks must cover") over usage_sample.json.
func TestClaudeSampleFixture(t *testing.T) {
	limits := ParseClaude(loadFixture(t, "usage_sample.json"))

	if len(limits) != 3 {
		t.Fatalf("expected 3 limits, got %d", len(limits))
	}
	eq(t, kinds(limits), []string{"session", "weekly_all", "weekly_scoped"}, "1. kinds in API order")
	eq(t, percents(limits), []int{10, 23, 39}, "1. percents 10/23/39")
	eq(t, limits[2].ScopeName, "Fable", "1. scope display_name Fable on third limit")
	eq(t, limits[0].ScopeName, "", "1. session has no scope")
	eq(t, providersOf(limits), []string{"claude", "claude", "claude"}, "1. provider stamped claude")
	eq(t, limits[0].Group, "session", "1. session group")
	eq(t, limits[1].Group, "weekly", "1. weekly_all group")
}

// Swift check 2: the 6-digit-fractional-seconds date trap.
func TestClaudeDateParsing(t *testing.T) {
	limits := ParseClaude(loadFixture(t, "usage_sample.json"))

	for i, l := range limits {
		if l.ResetsAt == nil {
			t.Fatalf("2. limit %d resets_at did not parse", i)
		}
	}
	eq(t, utcSeconds(limits[0].ResetsAt), "2026-07-16T22:59:59", "2. session resets_at exact UTC instant")
	eq(t, utcSeconds(limits[1].ResetsAt), "2026-07-18T07:59:59", "2. weekly_all resets_at exact UTC instant")
	if !(limits[0].ResetsAt.Before(*limits[1].ResetsAt) && limits[0].ResetsAt.Before(*limits[2].ResetsAt)) {
		t.Error("2. session reset should be earlier than both weekly resets")
	}
}

// Swift check 3: legacy fallback from five_hour/seven_day when `limits` absent.
func TestClaudeLegacyFallback(t *testing.T) {
	root := decodeFixture(t, "usage_sample.json")
	delete(root, "limits")
	legacy := ParseClaudeRoot(root)

	if len(legacy) != 2 {
		t.Fatalf("3. legacy fallback should synthesize 2 entries, got %d", len(legacy))
	}
	eq(t, kinds(legacy), []string{"session", "weekly_all"}, "3. legacy kinds")
	eq(t, percents(legacy), []int{10, 23}, "3. legacy percents from utilization")
	for i, l := range legacy {
		if l.ResetsAt == nil {
			t.Fatalf("3. legacy entry %d resets_at did not parse", i)
		}
	}
}

// Scope parity with UsageParser.swift for scope.model.display_name. Swift assigns
// `scopeName = model["display_name"] as? String` and only falls back to
// scope.display_name `if scopeName == nil` — so a PRESENT-but-empty model name
// stays "" and must NOT trigger the fallback; only an ABSENT one does.
func TestClaudeScopeModelDisplayNameEmptyVsAbsent(t *testing.T) {
	for _, tc := range []struct {
		name  string
		scope map[string]any
		want  string
	}{
		{
			name: "present-but-empty model name kept, no fallback",
			scope: map[string]any{
				"model":        map[string]any{"display_name": ""},
				"display_name": "ScopeFallback",
			},
			want: "",
		},
		{
			name: "absent model name falls back to scope.display_name",
			scope: map[string]any{
				"model":        map[string]any{},
				"display_name": "ScopeFallback",
			},
			want: "ScopeFallback",
		},
		{
			name: "non-empty model name wins over scope.display_name",
			scope: map[string]any{
				"model":        map[string]any{"display_name": "ModelName"},
				"display_name": "ScopeFallback",
			},
			want: "ModelName",
		},
		{
			name: "no model dict falls back to scope.display_name",
			scope: map[string]any{
				"display_name": "ScopeFallback",
			},
			want: "ScopeFallback",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := map[string]any{"limits": []any{map[string]any{
				"kind":    "session",
				"percent": mustNumber("10"),
				"scope":   tc.scope,
			}}}
			limits := ParseClaudeRoot(root)
			if len(limits) != 1 {
				t.Fatalf("expected 1 limit, got %d", len(limits))
			}
			eq(t, limits[0].ScopeName, tc.want, tc.name)
		})
	}
}

// The Adapter interface path returns the same entries with State=Ok.
func TestClaudeAdapterInterface(t *testing.T) {
	res := ClaudeAdapter{}.Parse(loadFixture(t, "usage_sample.json"), 200, codexNow, model.En)
	eq(t, len(res.Entries), 3, "claude adapter entries")
	eq(t, res.State, model.StateOk, "claude adapter state ok")
	if res.State.IsCheckFailure() {
		t.Error("claude ok state must not be a check failure")
	}
}
