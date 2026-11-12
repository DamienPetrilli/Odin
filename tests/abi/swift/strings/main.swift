// This fixture deliberately imports only the Swift standard library.
@frozen public struct TaggedWord {
	public var value: Int64
	public var tag: UInt8
}

@_silgen_name("swift_string_tagged_word")
public func taggedWord(_ input: TaggedWord) -> TaggedWord {
	TaggedWord(value: input.value &+ 3, tag: input.tag ^ 0xa5)
}

@_silgen_name("swift_string_optional_count")
public func optionalCount(_ value: Int64) -> Int? {
	value < 0 ? nil : Int(value)
}

@_silgen_name("odin_string_tagged_word")
func taggedWordFromOdin(_ input: TaggedWord) -> TaggedWord

@frozen public struct TaggedVector {
	public var first: Int64
	public var second: Double
	public var third: UInt64
	public var tag: UInt8
}

@_silgen_name("swift_string_tagged_vector")
public func taggedVector(_ input: TaggedVector) -> TaggedVector { input }
@_silgen_name("odin_string_tagged_vector")
func taggedVectorFromOdin(_ input: TaggedVector) -> TaggedVector

@_silgen_name("odin_string_round_trip")
func roundTrip(_ value: String, _ bytes: UnsafePointer<UInt8>, _ count: Int64) -> String

@_silgen_name("odin_string_checks")
func checkStrings()

precondition(MemoryLayout<TaggedWord>.size == 9)
precondition(MemoryLayout<TaggedWord>.stride == 16)
precondition(MemoryLayout<TaggedWord>.offset(of: \.tag) == 8)
for tag: UInt8 in [0, 1, 0x80, 0xff] {
	let value = TaggedWord(value: 0x1234_5678_9abc_def0, tag: tag)
	let result = taggedWordFromOdin(value)
	precondition(result.value == value.value + 4 && result.tag == tag ^ 0xff)
}

// Four components are still direct. Tail padding is not a component.
precondition(MemoryLayout<TaggedVector>.size == 25 && MemoryLayout<TaggedVector>.stride == 32)
let vector = TaggedVector(first: -41, second: 0.25, third: UInt64.max, tag: 0xff)
let vectorResult = taggedVectorFromOdin(vector)
precondition(vectorResult.first == vector.first && vectorResult.second == vector.second)
precondition(vectorResult.third == vector.third && vectorResult.tag == vector.tag)

checkStrings()
let samples = [
	"", "hello", "a\0b", "é", "e\u{301}", "日本語 🦉",
	String(repeating: "x", count: 15), String(repeating: "x", count: 16),
	String(repeating: "日本語 🦉\0", count: 8192),
	String("prefix: café 🦉 :suffix".dropFirst(8).dropLast(8)),
	String(decoding: [UInt16(0xD83E), 0xDD89, 0, 0x00e9], as: UTF16.self),
]
for sample in samples {
	let expected = Array(sample.utf8)
	// Include a sentinel so even the empty sample has a nonnil base address.
	let bytes = expected + [0xa5]
	let result = bytes.withUnsafeBufferPointer {
		roundTrip(sample, $0.baseAddress!, Int64(expected.count))
	}
	precondition(Array(result.utf8) == expected)
	precondition(Array(sample.utf8) == expected)
}
print("Swift-only string tests passed")
