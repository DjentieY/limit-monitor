package providers

import (
	"fmt"
	"math"
	"strconv"
	"time"

	"github.com/DjentieY/limit-monitor/go/internal/model"
)

// CodexAdapter parses GET chatgpt.com/backend-api/wham/usage (SPEC.md v0.2
// "Codex provider"). The community-documented schema drifts across versions, so
// every level is alias-tolerant; `now` anchors relative reset offsets. Port of
// CodexParsing.swift.
type CodexAdapter struct{}

type codexRole int

const (
	rolePrimary codexRole = iota
	roleSecondary
	roleAdditional
)

// Parse implements Adapter.
func (CodexAdapter) Parse(raw []byte, _ int, now time.Time, _ model.Language) AdapterResult {
	return AdapterResult{Entries: ParseCodex(raw, now), State: model.StateOk}
}

// ParseCodex parses the raw usage response at the given `now`.
func ParseCodex(raw []byte, now time.Time) []model.Limit {
	root, ok := decodeObject(raw)
	if !ok {
		return nil
	}
	return ParseCodexRoot(root, now)
}

// ParseCodexRoot parses a decoded root: primary/secondary windows (each under
// rate_limit/rate_limits or top-level, name-aliased) plus additional_rate_limits.
func ParseCodexRoot(root map[string]any, now time.Time) []model.Limit {
	var entries []model.Limit
	if w, ok := codexWindow([]string{"primary_window", "primary"}, root); ok {
		if e, ok := codexEntry(w, rolePrimary, now); ok {
			entries = append(entries, e)
		}
	}
	if w, ok := codexWindow([]string{"secondary_window", "secondary"}, root); ok {
		if e, ok := codexEntry(w, roleSecondary, now); ok {
			entries = append(entries, e)
		}
	}
	for _, w := range codexAdditionalWindows(root) {
		if e, ok := codexEntry(w, roleAdditional, now); ok {
			entries = append(entries, e)
		}
	}
	return entries
}

// codexContainers: windows may sit under rate_limit / rate_limits or at the top.
func codexContainers(root map[string]any) []map[string]any {
	var result []map[string]any
	if d, ok := root["rate_limit"].(map[string]any); ok {
		result = append(result, d)
	}
	if d, ok := root["rate_limits"].(map[string]any); ok {
		result = append(result, d)
	}
	return append(result, root)
}

func codexWindow(names []string, root map[string]any) (map[string]any, bool) {
	for _, container := range codexContainers(root) {
		for _, name := range names {
			if d, ok := container[name].(map[string]any); ok {
				return d, true
			}
		}
	}
	return nil, false
}

func codexAdditionalWindows(root map[string]any) []map[string]any {
	for _, container := range codexContainers(root) {
		if arr, ok := container["additional_rate_limits"].([]any); ok {
			var out []map[string]any
			for _, el := range arr {
				if d, ok := el.(map[string]any); ok {
					out = append(out, d)
				}
			}
			return out
		}
	}
	return nil
}

func codexEntry(dict map[string]any, role codexRole, now time.Time) (model.Limit, bool) {
	percent, ok := codexPercent(dict)
	if !ok {
		return model.Limit{}, false
	}
	minutes := codexWindowMinutes(dict)
	resetsAt, resetsAtRaw := codexResetDate(dict, now)

	scopeName := ""
	if role == roleAdditional {
		scopeName, _ = codexFirstPresent(dict, "name", "label", "display_name").(string)
	}

	group := "weekly"
	if role == rolePrimary {
		group = "session"
	}

	return model.Limit{
		Provider:      model.ProviderCodex,
		Kind:          codexKind(role, minutes),
		Group:         group,
		Percent:       percent,
		Severity:      "normal",
		ResetsAtRaw:   resetsAtRaw,
		ResetsAt:      resetsAt,
		ScopeName:     scopeName,
		WindowMinutes: minutes,
	}, true
}

// codexKind maps a role+window to a kind: primary → session when the window is
// ≈≤6h (or missing); secondary/additional → weekly_all/weekly_scoped when the
// window is ≈7d (or missing); otherwise a generic window_<minutes>m kind.
func codexKind(role codexRole, minutes *int) string {
	switch role {
	case rolePrimary:
		if minutes == nil || *minutes <= 360 {
			return "session"
		}
		return fmt.Sprintf("window_%dm", *minutes)
	case roleSecondary:
		if minutes == nil || abs(*minutes-10080) <= 1440 {
			return "weekly_all"
		}
		return fmt.Sprintf("window_%dm", *minutes)
	default: // roleAdditional
		if minutes == nil || abs(*minutes-10080) <= 1440 {
			return "weekly_scoped"
		}
		return fmt.Sprintf("window_%dm", *minutes)
	}
}

// codexPercent: used_percent | percent_used | 100-percent_left | 100-percent_remaining.
func codexPercent(dict map[string]any) (int, bool) {
	if v, ok := floatValue(dict["used_percent"]); ok {
		return int(math.Round(v)), true
	}
	if v, ok := floatValue(dict["percent_used"]); ok {
		return int(math.Round(v)), true
	}
	if v, ok := floatValue(dict["percent_left"]); ok {
		return int(math.Round(100 - v)), true
	}
	if v, ok := floatValue(dict["percent_remaining"]); ok {
		return int(math.Round(100 - v)), true
	}
	return 0, false
}

// codexResetDate: resets_at (ISO8601 | epoch s) | reset_at | reset_time_ms (ms
// epoch) | now+resets_in_seconds | now+reset_after_seconds. Returns the parsed
// instant (nil when unknown) and the raw string (kept only for the ISO/string case).
func codexResetDate(dict map[string]any, now time.Time) (*time.Time, string) {
	for _, key := range []string{"resets_at", "reset_at"} {
		v, present := dict[key]
		if !present {
			continue
		}
		if s, ok := v.(string); ok {
			if t, ok := parseISODate(s); ok {
				return &t, s
			}
			if f, err := strconv.ParseFloat(s, 64); err == nil {
				t := epochToTime(f)
				return &t, ""
			}
			return nil, s
		}
		if f, ok := floatValue(v); ok {
			t := epochToTime(f)
			return &t, ""
		}
		// present but null/other → fall through to the next key
	}
	if ms, ok := floatValue(dict["reset_time_ms"]); ok {
		t := epochToTime(ms / 1000)
		return &t, ""
	}
	for _, key := range []string{"resets_in_seconds", "reset_after_seconds"} {
		if sec, ok := floatValue(dict[key]); ok {
			t := now.Add(time.Duration(sec * float64(time.Second)))
			return &t, ""
		}
	}
	return nil, ""
}

// codexWindowMinutes: window_minutes | limit_window_seconds/60. nil when absent.
func codexWindowMinutes(dict map[string]any) *int {
	if m, ok := floatValue(dict["window_minutes"]); ok {
		return intPtr(int(math.Round(m)))
	}
	if s, ok := floatValue(dict["limit_window_seconds"]); ok {
		return intPtr(int(math.Round(s / 60)))
	}
	return nil
}

// codexFirstPresent returns the value of the first present key (mirroring
// Swift's `dict["name"] ?? dict["label"] ?? dict["display_name"]` on Any?,
// where a present-but-null value stops the fall-through just like NSNull does).
func codexFirstPresent(dict map[string]any, keys ...string) any {
	for _, k := range keys {
		if v, ok := dict[k]; ok {
			return v
		}
	}
	return nil
}

// epochToTime converts fractional Unix seconds to a UTC time.Time without
// int64 overflow for large epochs (Swift Date(timeIntervalSince1970:)).
func epochToTime(sec float64) time.Time {
	secs := math.Trunc(sec)
	nsec := math.Round((sec - secs) * 1e9)
	return time.Unix(int64(secs), int64(nsec)).UTC()
}

func abs(n int) int {
	if n < 0 {
		return -n
	}
	return n
}
