package providers

import (
	"testing"
	"time"

	"github.com/DjentieY/limit-monitor/go/internal/model"
)

// Mirrors Swift check 10 (SPEC.md v0.2 "checks additions"): the canonical and
// alias fixtures normalize IDENTICALLY at the fixed now=1784203200.
func TestCodexSampleFixture(t *testing.T) {
	limits := ParseCodex(loadFixture(t, "codex_usage_sample.json"), codexNow)

	if len(limits) != 3 {
		t.Fatalf("expected 3 codex limits, got %d", len(limits))
	}
	eq(t, kinds(limits), []string{"session", "weekly_all", "weekly_scoped"}, "10. codex kinds")
	eq(t, percents(limits), []int{12, 40, 55}, "10. codex percents 12/40/55")
	eq(t, providersOf(limits), []string{"codex", "codex", "codex"}, "10. codex provider stamped")
	eq(t, windowMinutes(limits), []int{300, 10080, 10080}, "10. codex window minutes")
	eq(t, limits[2].ScopeName, "Spark", "10. codex scoped name Spark")

	// resets computed from now + resets_in_seconds
	eq(t, limits[0].ResetsAt.Unix(), int64(1784210400), "10. primary reset = now + 7200 s")
	eq(t, limits[1].ResetsAt.Unix(), int64(1784635200), "10. secondary reset = now + 432000 s")
	eq(t, limits[2].ResetsAt.Unix(), int64(1784635200), "10. scoped reset = now + 432000 s")
	// numeric resets carry no raw string
	eq(t, limits[0].ResetsAtRaw, "", "10. numeric reset → empty raw")
}

func TestCodexAliasNormalizesIdentically(t *testing.T) {
	canonical := ParseCodex(loadFixture(t, "codex_usage_sample.json"), codexNow)
	alias := ParseCodex(loadFixture(t, "codex_usage_alias.json"), codexNow)

	if len(alias) != 3 {
		t.Fatalf("expected 3 codex alias limits, got %d", len(alias))
	}
	if !limitsEqual(alias, canonical) {
		t.Errorf("10. alias fixture must normalize identically to canonical\n alias=%+v\n canon=%+v", alias, canonical)
	}
}

// The Adapter interface path (CodexAdapter.Parse) must return State=Ok, the same
// entries as ParseCodex at the same instant, AND actually thread `now` through:
// shifting `now` shifts a relative (resets_in_seconds) reset by the same delta.
func TestCodexAdapterInterface(t *testing.T) {
	raw := loadFixture(t, "codex_usage_sample.json")

	res := CodexAdapter{}.Parse(raw, 200, codexNow, model.En)
	eq(t, res.State, model.StateOk, "codex adapter state ok")
	if res.State.IsCheckFailure() {
		t.Error("codex ok state must not be a check failure")
	}
	if !limitsEqual(res.Entries, ParseCodex(raw, codexNow)) {
		t.Errorf("codex adapter entries must equal ParseCodex at the same now\n got=%+v", res.Entries)
	}

	const shift = 1000 * time.Second
	shifted := CodexAdapter{}.Parse(raw, 200, codexNow.Add(shift), model.En)
	if len(res.Entries) == 0 || res.Entries[0].ResetsAt == nil ||
		len(shifted.Entries) == 0 || shifted.Entries[0].ResetsAt == nil {
		t.Fatal("codex adapter primary reset missing")
	}
	eq(t, shifted.Entries[0].ResetsAt.Unix()-res.Entries[0].ResetsAt.Unix(), int64(shift/time.Second),
		"codex adapter threads now: relative reset shifts with now")
}
