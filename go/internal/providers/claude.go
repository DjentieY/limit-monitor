package providers

import (
	"time"

	"github.com/DjentieY/limit-monitor/go/internal/model"
)

// ClaudeAdapter parses GET api.anthropic.com/api/oauth/usage.
// SPEC.md "Data source" / §"checks must cover" 1–3. Port of UsageParser.swift.
type ClaudeAdapter struct{}

// Parse implements Adapter. The claude parser is a pure entry extractor: state
// (token-expiry etc.) is the shell's concern, so success → StateOk.
func (ClaudeAdapter) Parse(raw []byte, _ int, _ time.Time, _ model.Language) AdapterResult {
	return AdapterResult{Entries: ParseClaude(raw), State: model.StateOk}
}

// ParseClaude parses the raw usage response. Malformed input yields no entries
// (Swift `guard ... else { return [] }`).
func ParseClaude(raw []byte) []model.Limit {
	root, ok := decodeObject(raw)
	if !ok {
		return nil
	}
	return ParseClaudeRoot(root)
}

// ParseClaudeRoot parses a decoded root. Prefer the `limits` array; when it is
// missing or empty, synthesize from the legacy top-level five_hour/seven_day.
func ParseClaudeRoot(root map[string]any) []model.Limit {
	if arr, ok := root["limits"].([]any); ok {
		var parsed []model.Limit
		for _, el := range arr {
			if entry, ok := parseClaudeEntry(el); ok {
				parsed = append(parsed, entry)
			}
		}
		if len(parsed) > 0 {
			return parsed
		}
	}
	return legacyClaudeEntries(root)
}

func parseClaudeEntry(el any) (model.Limit, bool) {
	dict, ok := el.(map[string]any)
	if !ok {
		return model.Limit{}, false
	}
	kind, ok := dict["kind"].(string)
	if !ok {
		return model.Limit{}, false
	}
	percent, ok := intRounded(dict["percent"])
	if !ok {
		return model.Limit{}, false
	}

	scopeName := ""
	if scope, ok := dict["scope"].(map[string]any); ok {
		// Mirror UsageParser.swift: scope.model.display_name wins when PRESENT as a
		// string (even ""); only its ABSENCE (Swift `scopeName == nil`) falls back
		// to scope.display_name. A present-but-empty model name must NOT trigger the
		// fallback — otherwise "" and "absent" collapse and diverge from Swift.
		haveModelName := false
		if m, ok := scope["model"].(map[string]any); ok {
			if s, ok := m["display_name"].(string); ok {
				scopeName = s
				haveModelName = true
			}
		}
		if !haveModelName {
			if s, ok := scope["display_name"].(string); ok {
				scopeName = s
			}
		}
	}

	group, _ := dict["group"].(string)
	severity, ok := dict["severity"].(string)
	if !ok {
		severity = "normal"
	}
	raw, _ := dict["resets_at"].(string)

	return model.Limit{
		Provider:    model.ProviderClaude,
		Kind:        kind,
		Group:       group,
		Percent:     percent,
		Severity:    severity,
		ResetsAtRaw: raw,
		ResetsAt:    parsedResetPtr(raw),
		ScopeName:   scopeName,
	}, true
}

func legacyClaudeEntries(root map[string]any) []model.Limit {
	var entries []model.Limit
	if e, ok := legacyClaudeEntry(root["five_hour"], "session", "session"); ok {
		entries = append(entries, e)
	}
	if e, ok := legacyClaudeEntry(root["seven_day"], "weekly_all", "weekly"); ok {
		entries = append(entries, e)
	}
	return entries
}

func legacyClaudeEntry(el any, kind, group string) (model.Limit, bool) {
	dict, ok := el.(map[string]any)
	if !ok {
		return model.Limit{}, false
	}
	percent, ok := intRounded(dict["utilization"])
	if !ok {
		return model.Limit{}, false
	}
	raw, _ := dict["resets_at"].(string)
	return model.Limit{
		Provider:    model.ProviderClaude,
		Kind:        kind,
		Group:       group,
		Percent:     percent,
		Severity:    "normal",
		ResetsAtRaw: raw,
		ResetsAt:    parsedResetPtr(raw),
	}, true
}

// parsedResetPtr parses a raw reset string to a *time.Time (Swift
// `raw.flatMap(ISODateParser.parse)`); nil when absent/unparseable.
func parsedResetPtr(raw string) *time.Time {
	if raw == "" {
		return nil
	}
	if t, ok := parseISODate(raw); ok {
		return &t
	}
	return nil
}
