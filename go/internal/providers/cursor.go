package providers

import (
	"math"
	"regexp"
	"strconv"
	"time"

	"github.com/DjentieY/limit-monitor/go/internal/model"
)

// CursorAdapter parses GET cursor.com/api/usage-summary (SPEC.md v0.3). Cursor
// has no session/weekly windows — every bucket resets at billingCycleEnd.
// Buckets: Auto+Composer (plan.totalPercentUsed — NOT autoPercentUsed, whose
// denominator does not match the Cursor UI), API (plan.apiPercentUsed),
// On-demand (only when onDemand.enabled). Port of CursorParsing.swift.
type CursorAdapter struct{}

var cursorPercentRe = regexp.MustCompile(`[0-9]+%`)

// Parse implements Adapter.
func (CursorAdapter) Parse(raw []byte, _ int, _ time.Time, _ model.Language) AdapterResult {
	return AdapterResult{Entries: ParseCursor(raw), State: model.StateOk}
}

// ParseCursor parses the raw usage-summary response.
func ParseCursor(raw []byte) []model.Limit {
	root, ok := decodeObject(raw)
	if !ok {
		return nil
	}
	return ParseCursorRoot(root)
}

// ParseCursorRoot parses a decoded root into cursor buckets.
func ParseCursorRoot(root map[string]any) []model.Limit {
	resetsAtRaw, _ := root["billingCycleEnd"].(string)
	resetsAt := parsedResetPtr(resetsAtRaw)

	if b, ok := root["isUnlimited"].(bool); ok && b {
		return []model.Limit{{
			Provider:    model.ProviderCursor,
			Kind:        "cursor_unlimited",
			Percent:     0,
			Severity:    "normal",
			ResetsAtRaw: resetsAtRaw,
			ResetsAt:    resetsAt,
			Unlimited:   true,
		}}
	}

	individual, _ := root["individualUsage"].(map[string]any)
	plan, _ := individual["plan"].(map[string]any)

	var entries []model.Limit
	if p, ok := cursorBucketPercent(plan["totalPercentUsed"], stringField(root, "autoModelSelectedDisplayMessage")); ok {
		entries = append(entries, cursorEntry("cursor_auto", p, resetsAtRaw, resetsAt))
	}
	if p, ok := cursorBucketPercent(plan["apiPercentUsed"], stringField(root, "namedModelSelectedDisplayMessage")); ok {
		entries = append(entries, cursorEntry("cursor_api", p, resetsAtRaw, resetsAt))
	}
	if onDemand, ok := individual["onDemand"].(map[string]any); ok {
		if enabled, _ := onDemand["enabled"].(bool); enabled {
			limit, limitOK := floatValue(onDemand["limit"])
			if !limitOK || limit == 0 {
				e := cursorEntry("cursor_on_demand", 0, resetsAtRaw, resetsAt)
				e.Unlimited = true
				entries = append(entries, e)
			} else if used, ok := floatValue(onDemand["used"]); ok {
				entries = append(entries, cursorEntry("cursor_on_demand",
					int(math.Round(100*used/limit)), resetsAtRaw, resetsAt))
			}
		}
	}
	return entries
}

func cursorEntry(kind string, percent int, resetsAtRaw string, resetsAt *time.Time) model.Limit {
	return model.Limit{
		Provider:    model.ProviderCursor,
		Kind:        kind,
		Percent:     percent,
		Severity:    "normal", // LimitEntry defaults severity to "normal" (Models.swift)
		ResetsAtRaw: resetsAtRaw,
		ResetsAt:    resetsAt,
	}
}

// cursorBucketPercent takes the numeric percent field first; fallback: the first
// integer before "%" in the display message ("You've used 2% of ..." → 2). Both
// missing → ok=false, and the bucket is skipped defensively.
func cursorBucketPercent(numeric any, message string) (int, bool) {
	if v, ok := floatValue(numeric); ok {
		return int(math.Round(v)), true
	}
	if message == "" {
		return 0, false
	}
	match := cursorPercentRe.FindString(message)
	if match == "" {
		return 0, false
	}
	n, err := strconv.Atoi(match[:len(match)-1]) // drop trailing '%'
	if err != nil {
		return 0, false
	}
	return n, true
}

func stringField(m map[string]any, key string) string {
	s, _ := m[key].(string)
	return s
}
