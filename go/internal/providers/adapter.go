// Package providers holds the pure, alias-tolerant response parsers for every
// supported provider. Each adapter is a PURE parse function of
// (raw bytes, httpStatus, now, lang) → AdapterResult: no network, no
// credentials, no I/O. Networking and credential resolution live in the shell,
// exactly as they do on the Swift side. The first PR ports the three builtins
// (claude/codex/cursor) 1:1 from UsageParser/CodexParsing/CursorParsing; the
// config/generic engine and the remaining builtins land in later PRs.
package providers

import (
	"time"

	"github.com/DjentieY/limit-monitor/go/internal/model"
)

// AdapterResult is the Go analogue of the Swift AdapterResult: the normalized
// entries plus the provider state, a localized (never value/secret-bearing)
// reason and the OpenRouter /key→/credits chaining flag.
type AdapterResult struct {
	Entries      []model.Limit
	State        model.ProviderState
	Reason       string
	NeedsCredits bool
}

// Adapter is a pure parse function. httpStatus and lang are part of the uniform
// contract used by the config/generic adapters (zhipu HTTP-200 errors,
// OpenRouter chaining, localized reasons); the three builtin extractors ported
// here mirror the Swift UsageParser/CodexParsing/CursorParsing, which take only
// the response bytes (+ now for codex) and never compute a provider state or
// interpret the status code in the parse layer — token-expiry/fetch errors are
// the shell's job. They therefore return State=StateOk on the success path.
type Adapter interface {
	Parse(raw []byte, httpStatus int, now time.Time, lang model.Language) AdapterResult
}
