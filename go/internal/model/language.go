package model

// Language is the UI-language seam (Language.swift). This is a minimal stub for
// the first PR: the parse layer accepts it but sets only neutral, structural
// fields — the full EN/RU label catalog (Labels/Language port) lands in a later
// PR. English is the default; Russian is selected by system locale in the shell.
type Language int

const (
	En Language = iota
	Ru
)

// String returns the BCP-47-ish short tag, matching the Swift `Language` raw values.
func (l Language) String() string {
	if l == Ru {
		return "ru"
	}
	return "en"
}
