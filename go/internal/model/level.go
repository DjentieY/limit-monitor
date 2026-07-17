// Package model holds the pure, OS-free domain types shared by every adapter and
// by the CLI/tray shells. It is the Go port of the Swift LimitMonitorCore
// Models.swift + ProviderState.swift and carries no I/O, no network and no
// localization state.
package model

// Level is the severity of a single limit, ordered Green < Yellow < Orange < Red.
// Port of Models.swift `Level` (raw values preserved so the ordering is stable).
type Level int

const (
	Green  Level = 0
	Yellow Level = 1
	Orange Level = 2
	Red    Level = 3
)

// LevelFrom mirrors Models.swift `Level.level(percent:severity:)`:
//   - percent < 50           → green
//   - 50..<75                → yellow
//   - 75..<90                → orange
//   - >= 90 (incl. 100+)     → red
//
// A non-"normal" severity bumps the level to at least orange.
func LevelFrom(percent int, severity string) Level {
	var base Level
	switch {
	case percent < 50:
		base = Green
	case percent < 75:
		base = Yellow
	case percent < 90:
		base = Orange
	default:
		base = Red
	}
	if severity != "normal" && base < Orange {
		return Orange
	}
	return base
}

// String is the neutral level token used in the snapshot and parity output
// (Models.swift `Level.name`).
func (l Level) String() string {
	switch l {
	case Green:
		return "green"
	case Yellow:
		return "yellow"
	case Orange:
		return "orange"
	case Red:
		return "red"
	default:
		return "green"
	}
}
