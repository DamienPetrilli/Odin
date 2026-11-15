package export_fixture

import "core:encoding/uuid"
import "base:runtime"
foreign import reply "swift:reply/SwiftReply"

@(export)
change_identifier :: proc "swift" (id: uuid.Identifier, delta: u64) -> uuid.Identifier {
	result := id
	for &b in result { b += u8(delta) }
	return result
}

@(export)
choose_identifier :: proc "swift" (a: uuid.Identifier, choose_a: bool, b: uuid.Identifier) -> uuid.Identifier {
	if choose_a { return a }
	return b
}

@(export)
identifier_checksum :: proc "swift" (id: uuid.Identifier) -> u64 {
	result: u64
	for b, index in id { result += u64(b)*u64(index+1) }
	return result
}

@(export)
zero_identifier :: proc "swift" () -> uuid.Identifier {
	return {}
}

@(export)
round_trip_identifier :: proc "swift" (id: uuid.Identifier) -> uuid.Identifier {
	context = runtime.default_context()
	return reply.identity_uuid(id) or_else panic("UUID export/import round trip")
}
