package rejected_uuids

import "core:encoding/uuid"

when #config(FOREIGN, false) {
	foreign {
		bad :: proc "swift" (value: uuid.Identifier) -> uuid.Identifier ---
	}
} else when #config(UNEXPORTED, false) {
	bad :: proc "swift" (value: uuid.Identifier) -> uuid.Identifier { return value }
} else when #config(LOOKALIKE, false) {
	Identifier :: distinct [16]u8
	@(export)
	bad :: proc "swift" (value: Identifier) -> Identifier { return value }
} else when #config(MODULE, false) {
	@(export)
	bad :: proc "swift" (value: uuid.Identifier) -> uuid.Identifier { return value }
} else when #config(SHADOW, false) {
	Foundation :: struct { value: u64 }
	@(export)
	bad :: proc "swift" (value: uuid.Identifier, other: Foundation) -> uuid.Identifier { return value }
}
