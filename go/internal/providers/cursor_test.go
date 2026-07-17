package providers

import (
	"testing"

	"github.com/DjentieY/limit-monitor/go/internal/model"
)

// Swift check 15: sample → 2 buckets, auto=round(1.527…)=2, api=round(6.466…)=6.
func TestCursorSampleFixture(t *testing.T) {
	limits := ParseCursor(loadFixture(t, "cursor_usage_summary_sample.json"))

	if len(limits) != 2 {
		t.Fatalf("expected 2 cursor limits, got %d", len(limits))
	}
	eq(t, kinds(limits), []string{"cursor_auto", "cursor_api"}, "15. cursor kinds auto/api")
	eq(t, percents(limits), []int{2, 6}, "15. cursor percents 2/6 (rounded)")
	eq(t, providersOf(limits), []string{"cursor", "cursor"}, "15. cursor provider stamped")
	for i, l := range limits {
		if l.ResetsAt == nil {
			t.Fatalf("15. bucket %d billingCycleEnd did not parse", i)
		}
	}
	eq(t, utcSeconds(limits[0].ResetsAt), "2026-08-07T05:27:30", "15. resets_at = billingCycleEnd exact UTC")
	if !limits[0].ResetsAt.Equal(*limits[1].ResetsAt) {
		t.Error("15. both buckets reset at billingCycleEnd")
	}
	for _, l := range limits {
		if l.Kind == "cursor_on_demand" {
			t.Error("15. onDemand.enabled == false → no on-demand entry")
		}
	}
}

// Swift check 16: on-demand fixture → 3 entries 92/96/75, levels red/red/orange.
func TestCursorOnDemandFixture(t *testing.T) {
	limits := ParseCursor(loadFixture(t, "cursor_usage_summary_ondemand.json"))

	if len(limits) != 3 {
		t.Fatalf("expected 3 cursor limits, got %d", len(limits))
	}
	eq(t, kinds(limits), []string{"cursor_auto", "cursor_api", "cursor_on_demand"}, "16. kinds incl. on-demand")
	eq(t, percents(limits), []int{92, 96, 75}, "16. percents 92/96/75 (on-demand = 100*1500/2000)")
	eq(t, levels(limits), []model.Level{model.Red, model.Red, model.Orange}, "16. levels red/red/orange")
	eq(t, []bool{limits[0].Unlimited, limits[1].Unlimited, limits[2].Unlimited},
		[]bool{false, false, false}, "16. bounded buckets are not unlimited")
}

// Swift check 16 edge: null / zero on-demand limit → unlimited on-demand entry.
func TestCursorOnDemandUnlimited(t *testing.T) {
	for _, tc := range []struct {
		name  string
		limit any
	}{
		{"null", nil},
		{"zero", "0"}, // json.Number "0"; floatValue → 0 → unlimited branch
	} {
		root := decodeFixture(t, "cursor_usage_summary_ondemand.json")
		onDemand := root["individualUsage"].(map[string]any)["onDemand"].(map[string]any)
		if tc.limit == nil {
			onDemand["limit"] = nil
		} else {
			onDemand["limit"] = mustNumber(tc.limit.(string))
		}
		limits := ParseCursorRoot(root)
		if len(limits) != 3 {
			t.Fatalf("16.%s: expected 3 entries, got %d", tc.name, len(limits))
		}
		if !limits[2].Unlimited {
			t.Errorf("16.%s: on-demand limit should yield an unlimited entry", tc.name)
		}
		eq(t, limits[2].Level(), model.Green, "16."+tc.name+" unlimited on-demand level green")
	}
}

// Swift check 17: numeric percent fields stripped → recovered from display strings.
func TestCursorDisplayMessageFallback(t *testing.T) {
	root := decodeFixture(t, "cursor_usage_summary_sample.json")
	plan := root["individualUsage"].(map[string]any)["plan"].(map[string]any)
	delete(plan, "totalPercentUsed")
	delete(plan, "apiPercentUsed")
	delete(plan, "autoPercentUsed")

	limits := ParseCursorRoot(root)
	eq(t, kinds(limits), []string{"cursor_auto", "cursor_api"}, "17. buckets recovered from display strings")
	eq(t, percents(limits), []int{2, 6}, "17. Auto 2 / API 6 recovered from messages")
}

// The Adapter interface path (CursorAdapter.Parse) must return State=Ok and the
// same entries as ParseCursor. Cursor ignores now/lang, but the wrapper still has
// to satisfy the uniform (raw, status, now, lang) contract and stay a no-fail Ok.
func TestCursorAdapterInterface(t *testing.T) {
	raw := loadFixture(t, "cursor_usage_summary_sample.json")

	res := CursorAdapter{}.Parse(raw, 200, codexNow, model.En)
	eq(t, res.State, model.StateOk, "cursor adapter state ok")
	if res.State.IsCheckFailure() {
		t.Error("cursor ok state must not be a check failure")
	}
	if !limitsEqual(res.Entries, ParseCursor(raw)) {
		t.Errorf("cursor adapter entries must equal ParseCursor\n got=%+v", res.Entries)
	}
}
