package swift_set_object_test

import "base:runtime"
import "core:encoding/uuid"
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

@(export)
check_foundation_layouts :: proc "c" () -> bool {
	context = runtime.default_context()
	ids := [3]uuid.Identifier{{0 = 1, 15 = 3}, {0 = 2}, {0 = 2}}
	date := fixture.dated_identifiers(-1.25, ids[:]) or_return
	id := fixture.echo_identifier(ids[0]) or_return
	return date == 0.75 && id == ids[0]
}
