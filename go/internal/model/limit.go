package model

import "time"

// Provider id constants for the builtin adapters (Providers.swift).
const (
	ProviderClaude = "claude"
	ProviderCodex  = "codex"
	ProviderCursor = "cursor"
)

// Limit is one rate-limit / balance row. It is the Go port of Models.swift
// `LimitEntry` (per research/go-core-design.md §2), minus the AppKit-only
// concerns. Optional Swift fields map to Go pointers; Swift `String?` fields
// that render as "absent" map to plain strings where the empty string already
// means "none" (Group, ScopeName, ProviderName, BalanceText, ResetsAtRaw).
type Limit struct {
	Provider    string // "claude" | "codex" | "cursor" | config id
	Kind        string // "session" | "weekly_all" | "cursor_auto" | "custom" | ...
	Group       string // "session" | "weekly" | "" (absent)
	Percent     int
	Severity    string // "normal" unless the API flags otherwise
	ResetsAtRaw string // raw reset string kept for display; "" when absent/derived
	ResetsAt    *time.Time
	ScopeName   string // scope/model display name (e.g. "Fable", "Spark"); "" when none
	// WindowMinutes is the raw window size; classifies codex/config labels at
	// ±60/±1440 tolerance. nil when the window is unknown.
	WindowMinutes *int
	// WindowLabel is an explicit bar window label ("1m", "" for none);
	// nil means "derive from kind/group".
	WindowLabel *string
	// Unlimited renders as ∞ (green) and is excluded from notification planning
	// (cursor isUnlimited / null-or-0 on-demand limit).
	Unlimited bool
	// MenuOnly rows (zhipu TIME_LIMIT) are excluded from the bar segments.
	MenuOnly bool
	// ProviderName is the config display name ("OpenRouter"); "" for builtins.
	ProviderName string
	// BalanceText is the formatted remaining amount for balance-mode ("$23.45").
	BalanceText string
	// LevelOverride forces a threshold-driven level (balance-mode / okFlag).
	LevelOverride *Level
	// ExhaustedOverride forces exhaustion (<=0 balance / okFlag false),
	// independent of Percent.
	ExhaustedOverride *bool
}

// Level is the effective level: LevelOverride when set, else derived from
// Percent+Severity (Models.swift `LimitEntry.level`).
func (l Limit) Level() Level {
	if l.LevelOverride != nil {
		return *l.LevelOverride
	}
	return LevelFrom(l.Percent, l.Severity)
}

// IsExhausted is ExhaustedOverride when set, else Percent >= 100
// (Models.swift `LimitEntry.isExhausted`).
func (l Limit) IsExhausted() bool {
	if l.ExhaustedOverride != nil {
		return *l.ExhaustedOverride
	}
	return l.Percent >= 100
}
