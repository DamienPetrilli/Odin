package swift_set_object_test

import "base:runtime"
foreign import fixture "swift:fixture/SwiftSetSync"

@(export)
count_set_members :: proc "c" () -> i32 {
	context = runtime.default_context()
	if empty, ok := fixture.unique_count(nil); !ok || empty != 0 { return -1 }
	numbers, ok := fixture.unique_count({7, 7, 9})
	if !ok { return -2 }
	words, converted := fixture.word_count({"one", "two", "two", "three"})
	if !converted { return -3 }
	return i32(numbers + words)
}
