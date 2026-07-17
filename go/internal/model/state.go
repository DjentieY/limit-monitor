package model

// ProviderState is the unified per-provider outcome (ProviderState.swift). The
// Swift enum carries an inline message per case; here the human-readable reason
// travels alongside in AdapterResult.Reason, so the state is a plain tag.
type ProviderState int

const (
	// StateOk carries no message.
	StateOk ProviderState = iota
	// StateConfigError: entry-level config validation failed.
	StateConfigError
	// StateKeyError: key resolution failed (command non-zero, env unset, empty).
	StateKeyError
	// StateBadKey: the endpoint rejected the key (HTTP 401/403 or auth envelope).
	StateBadKey
	// StateNoPlan: zhipu code 500 + "coding plan" — key works, no Coding Plan.
	StateNoPlan
	// StateBlocked: OpenRouter RU geo-block.
	StateBlocked
	// StateInfo: informational, NOT a failure (OpenRouter /credits denied).
	StateInfo
	// StateFetchError: network/HTTP failure.
	StateFetchError
	// StateParseError: response could not be parsed.
	StateParseError
)

// IsCheckFailure mirrors ProviderState.swift `isCheckFailure`: `ok` and the
// `info` state do not fail the `--check`/CI contract; every other state does.
func (s ProviderState) IsCheckFailure() bool {
	switch s {
	case StateOk, StateInfo:
		return false
	default:
		return true
	}
}
