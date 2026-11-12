package swift_strings

import "base:runtime"
import "core:mem"
import "core:strings"
import swift "core:sys/darwin/Swift"

Tagged_Word :: struct {
	value: i64,
	tag: u8,
}

#assert(offset_of(Tagged_Word, tag) == 8)
#assert(size_of(Tagged_Word) == 16)

foreign {
	swift_string_tagged_word :: proc "swift" (value: Tagged_Word) -> Tagged_Word ---
	swift_string_optional_count :: proc "swift" (value: i64) -> Tagged_Word ---
}

@(export)
odin_string_tagged_word :: proc "swift" (value: Tagged_Word) -> Tagged_Word {
	result := swift_string_tagged_word(value)
	result.value += 1
	result.tag ~= 0x5a
	return result
}

@(export)
odin_string_round_trip :: proc "swift" (value: swift.Native_String, bytes: [^]u8, count: i64) -> swift.Native_String {
	context = runtime.default_context()
	expected := string(bytes[:int(count)])
	text := swift.string_to_odin(value) or_else panic("Swift string output")
	assert(text == expected)
	result := swift.string_from_odin(text) or_else panic("Odin string input")
	// Swift must own independent storage before this input is overwritten/freed.
	if len(text) > 0 { mem.set(raw_data(text), 0xff, len(text)) }
	delete(text)
	return result
}

@(export)
odin_string_checks :: proc "swift" () {
	context = runtime.default_context()
	for value in ([3]i64{0, 1, 0x1234_5678_9abc_def0}) {
		result := swift_string_optional_count(value)
		assert(result.tag == 0 && result.value == value)
	}
	absent := swift_string_optional_count(-1)
	assert(absent.tag & 1 == 1) // A nil Optional's value bits are unspecified.

	for invalid in ([]string{"\xff", "\xc0\x80", "\xed\xa0\x80", "\xf0\x9f", "x\x00\xff"}) {
		_, ok := swift.string_from_odin(invalid)
		assert(!ok)
	}
	// Optional<String>.none must remain distinct from an owned empty String.
	empty := swift.string_from_odin("") or_else panic("Empty input")
	empty_copy := swift.string_to_odin(empty) or_else panic("Empty output")
	assert(empty_copy == "")
	swift.string_destroy(&empty)

	// Exercise validation beyond its word-sized ASCII fast path, including
	// misaligned inputs and malformed suffixes after a long valid prefix.
	for length in ([8]int{1, 7, 15, 16, 17, 31, 32, 65536}) {
		storage := make([]u8, length+1)
		mem.set(raw_data(storage), 'a', len(storage))
		input := string(storage[1:])
		value := swift.string_from_odin(input) or_else panic("Misaligned input")
		copy := swift.string_to_odin(value) or_else panic("Misaligned output")
		swift.string_destroy(&value)
		assert(copy == input)
		delete(copy)
		storage[len(storage)-1] = 0xff
		_, valid := swift.string_from_odin(input)
		assert(!valid)
		storage[len(storage)-1] = 0xc2 // Truncated two-byte scalar.
		_, valid = swift.string_from_odin(input)
		assert(!valid)
		delete(storage)
	}
	original := "Independent long UTF-8 storage: 日本語, café, 🦉\x00tail"
	for _ in 0..<128 {
		input := strings.clone(original)
		value := swift.string_from_odin(input) or_else panic("Input conversion")
		mem.set(raw_data(input), 0xff, len(input))
		delete(input)

		allocator := context.allocator
		context.allocator = mem.nil_allocator()
		failed, ok := swift.string_to_odin(value)
		assert(!ok && len(failed) == 0)
		context.allocator = allocator

		first := swift.string_to_odin(value) or_else panic("First output")
		second := swift.string_to_odin(value) or_else panic("Second output")
		swift.string_destroy(&value)
		assert(first == original && second == original)
		mem.set(raw_data(first), 0xff, len(first))
		delete(first)
		assert(second == original)
		delete(second)
	}
}

Tagged_Vector :: struct {
	first: i64,
	second: f64,
	third: u64,
	tag: u8,
}

foreign {
	swift_string_tagged_vector :: proc "swift" (value: Tagged_Vector) -> Tagged_Vector ---
}

@(export)
odin_string_tagged_vector :: proc "swift" (value: Tagged_Vector) -> Tagged_Vector {
	return swift_string_tagged_vector(value)
}
