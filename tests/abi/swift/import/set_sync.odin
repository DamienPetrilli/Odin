package swift_set_sync_test

foreign import fixture "swift:fixture/SwiftSetSync"

main :: proc() {
	count := fixture.unique_count([]u64{7, 7, 9}) or_else panic("Set conversion")
	assert(count == 2)
}
