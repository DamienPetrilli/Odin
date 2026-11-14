package rejected_enums

when #config(CASE_COLLISION, false) {
	Code :: enum u32 { Read_Value, ReadValue }
} else when #config(DUPLICATE, false) {
	Code :: enum u32 { First = 10, Second = 10 }
} else when #config(EMPTY, false) {
	Code :: enum u32 {}
} else when #config(NESTED, false) {
	Inner :: enum u32 { First, Second }
	Code :: struct { value: Inner }
}

@(export)
echo :: proc "swift" (value: Code) -> Code { return value }
