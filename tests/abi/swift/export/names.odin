package swift_names

AnyObject :: struct { first, second: u64 }

@(export)
named_0 :: proc "swift" (value: AnyObject) -> AnyObject {
	return {value.first + 1, value.second + 2}
}

Self :: struct { first, second: u64 }

@(export)
named_1 :: proc "swift" (value: Self) -> Self {
	return {value.first + 1, value.second + 2}
}

Type :: struct { first, second: u64 }

@(export)
named_2 :: proc "swift" (value: Type) -> Type {
	return {value.first + 1, value.second + 2}
}

Protocol :: struct { first, second: u64 }

@(export)
named_3 :: proc "swift" (value: Protocol) -> Protocol {
	return {value.first + 1, value.second + 2}
}

String :: struct { first, second: u64 }

@(export)
named_4 :: proc "swift" (value: String) -> String {
	return {value.first + 1, value.second + 2}
}

Bool :: struct { first, second: u64 }

@(export)
named_5 :: proc "swift" (value: Bool) -> Bool {
	return {value.first + 1, value.second + 2}
}

Int64 :: struct { first, second: u64 }

@(export)
named_6 :: proc "swift" (value: Int64) -> Int64 {
	return {value.first + 1, value.second + 2}
}

UInt64 :: struct { first, second: u64 }

@(export)
named_7 :: proc "swift" (value: UInt64) -> UInt64 {
	return {value.first + 1, value.second + 2}
}

Double :: struct { first, second: u64 }

@(export)
named_8 :: proc "swift" (value: Double) -> Double {
	return {value.first + 1, value.second + 2}
}

Never :: struct { first, second: u64 }

@(export)
named_9 :: proc "swift" (value: Never) -> Never {
	return {value.first + 1, value.second + 2}
}

Optional :: struct { first, second: u64 }

@(export)
named_10 :: proc "swift" (value: Optional) -> Optional {
	return {value.first + 1, value.second + 2}
}

UnsafeMutableBufferPointer :: struct { first, second: u64 }

@(export)
named_11 :: proc "swift" (value: UnsafeMutableBufferPointer) -> UnsafeMutableBufferPointer {
	return {value.first + 1, value.second + 2}
}

Sendable :: struct { first, second: u64 }

@(export)
named_12 :: proc "swift" (value: Sendable) -> Sendable {
	return {value.first + 1, value.second + 2}
}

Copyable :: struct { first, second: u64 }

@(export)
named_13 :: proc "swift" (value: Copyable) -> Copyable {
	return {value.first + 1, value.second + 2}
}

Fields :: struct {
	self, p0, init, class: u64,
}

@(export)
fields :: proc "swift" (value: Fields) -> Fields {
	return {value.self+1, value.p0+2, value.init+3, value.class+4}
}

@(export)
initialize :: proc "swift" () -> u64 { return 11 }

@(export)
finalize :: proc "swift" () -> u64 { return 22 }

@(export)
_leading_name :: proc "swift" () -> u64 { return 33 }
