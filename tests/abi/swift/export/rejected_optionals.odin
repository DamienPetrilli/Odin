package rejected_optionals

when #config(LOOKALIKE, false) {
	Lookalike :: union {bool}
	@(export)
	lookalike :: proc "swift" (x: Lookalike) {}
}
when #config(DISTINCT, false) {
	Flag :: distinct Maybe(bool)
	@(export)
	distinct_flag :: proc "swift" (x: Flag) {}
}
when #config(NESTED, false) {
	@(export)
	nested :: proc "swift" (x: Maybe(Maybe(u64))) {}
}
when #config(OWNED, false) {
	@(export)
	owned :: proc "swift" () -> Maybe(string) { return nil }
}
when #config(FOREIGN, false) {
	foreign {
		raw_optional :: proc "swift" (x: Maybe(u64)) ---
	}
}
