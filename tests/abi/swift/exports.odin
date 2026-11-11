package swift_abi

foreign import fixture "Fixture.o"

Reading :: struct {
	page:     i64,
	progress: f64,
}

Transaction_ID :: struct {
	value: u64,
}

Text_View :: struct {
	bytes: [^]u8,
	count: u64,
}

Transaction_Key :: struct {
	id:           u64,
	original_id:  u64,
	purchased_at: f64,
	status:       u64,
}

Transaction_Info :: struct {
	id:             u64,
	original_id:    u64,
	purchased_at:   f64,
	status:         u64,
	product_offset: u64,
	product_count:  u64,
}

#assert(size_of(Transaction_ID) == 8)
#assert(size_of(Text_View) == 16)
#assert(offset_of(Text_View, count) == 8)
#assert(size_of(Transaction_Key) == 32)
#assert(offset_of(Transaction_Key, purchased_at) == 16)
#assert(size_of(Transaction_Info) == 48)
#assert(size_of([2]Transaction_Info) == 96)
#assert(align_of(Transaction_Info) == 8)
#assert(offset_of(Transaction_Info, id) == 0)
#assert(offset_of(Transaction_Info, original_id) == 8)
#assert(offset_of(Transaction_Info, purchased_at) == 16)
#assert(offset_of(Transaction_Info, status) == 24)
#assert(offset_of(Transaction_Info, product_offset) == 32)
#assert(offset_of(Transaction_Info, product_count) == 40)

Reading_Callback :: proc "swift" (user_data: rawptr, reading: Reading) -> Reading
Callback_State_Ref :: distinct rawptr

#assert(size_of(Reading) == 16)
#assert(size_of([2]Reading) == 32)
#assert(align_of(Reading) == 8)
#assert(offset_of(Reading, page) == 0)
#assert(offset_of(Reading, progress) == 8)

foreign fixture {
	@(link_name="$s15SwiftABIFixture9addScalarySds5Int64V_SdtF")
	add_scalar :: proc "swift" (whole: i64, fraction: f64) -> f64 ---

	@(link_name="$s15SwiftABIFixture7advanceyAA7ReadingVs5Int64V_ADSdtF")
	advance :: proc "swift" (pages: i64, reading: Reading, fraction: f64) -> Reading ---

	@(link_name="$s15SwiftABIFixture13changeInPlaceySpyAA7ReadingVGAE_s5Int64VSdtF")
	change_in_place :: proc "swift" (reading: ^Reading, pages: i64, fraction: f64) -> ^Reading ---

	@(link_name="$s15SwiftABIFixture9fillBytesys5Int64VSpys5UInt8VG_ADtF")
	fill_bytes :: proc "swift" (output: [^]u8, capacity: i64) -> i64 ---

	@(link_name="$s15SwiftABIFixture12callCallbackyAA7ReadingVADSv_ADtXf_SvADtF")
	call_callback :: proc "swift" (callback: Reading_Callback, user_data: rawptr, reading: Reading) -> Reading ---

	@(link_name="$s15SwiftABIFixture19updateCallbackStateyAA7ReadingVSv_ADtF")
	update_callback_state :: proc "swift" (user_data: rawptr, reading: Reading) -> Reading ---

	@(link_name="$s15SwiftABIFixture19retainCallbackStateyS2vF")
	retain_callback_state :: proc "swift" (state: Callback_State_Ref) -> Callback_State_Ref ---

	@(link_name="$s15SwiftABIFixture20releaseCallbackStateyySvF")
	release_callback_state :: proc "swift" (state: Callback_State_Ref) ---

	@(link_name="$s15SwiftABIFixture6nextIDyAA011TransactionD0VADF")
	next_id :: proc "swift" (id: Transaction_ID) -> Transaction_ID ---

	@(link_name="$s15SwiftABIFixture10dropPrefixyAA8TextViewVAD_s6UInt64VtF")
	drop_prefix :: proc "swift" (text: Text_View, prefix: u64) -> Text_View ---

	@(link_name="$s15SwiftABIFixture9updateKeyyAA011TransactionD0Vs6UInt64V_ADSdtF")
	update_key :: proc "swift" (status: u64, key: Transaction_Key, seconds: f64) -> Transaction_Key ---

	@(link_name="$s15SwiftABIFixture17updateTransactionyAA0D4InfoVs6UInt64V_ADSdtF")
	update_transaction :: proc "swift" (status: u64, transaction: Transaction_Info, seconds: f64) -> Transaction_Info ---

	@(link_name="$s15SwiftABIFixture24updateTransactionInPlaceySpyAA0D4InfoVGAE_s6UInt64VSdtF")
	update_transaction_in_place :: proc "swift" (transaction: ^Transaction_Info, status: u64, seconds: f64) -> ^Transaction_Info ---
}

@(export)
odin_swift_abi_add_scalar :: proc "swift" (whole: i64, fraction: f64) -> f64 {
	return f64(whole) + fraction
}

@(export)
odin_swift_abi_advance :: proc "swift" (pages: i64, reading: Reading, fraction: f64) -> Reading {
	return {page = reading.page + pages, progress = reading.progress + fraction}
}

@(export)
odin_swift_abi_change_in_place :: proc "swift" (reading: ^Reading, pages: i64, fraction: f64) -> ^Reading {
	reading^ = odin_swift_abi_advance(pages, reading^, fraction)
	return reading
}

@(export)
odin_swift_abi_fill_bytes :: proc "swift" (output: [^]u8, capacity: i64) -> i64 {
	if capacity < 3 {
		return 0
	}
	output[0] = 13
	output[1] = 29
	output[2] = 61
	return 3
}

@(export)
odin_swift_abi_call_callback :: proc "swift" (callback: Reading_Callback, user_data: rawptr, reading: Reading) -> Reading {
	return callback(user_data, reading)
}

@(export)
odin_swift_abi_swift_callback :: proc "swift" () -> Reading_Callback {
	return update_callback_state
}

@(export)
odin_swift_abi_retain_callback_state :: proc "swift" (state: Callback_State_Ref) -> Callback_State_Ref {
	return retain_callback_state(state)
}

@(export)
odin_swift_abi_release_callback_state :: proc "swift" (state: Callback_State_Ref) {
	release_callback_state(state)
}

update_callback_count :: proc "swift" (user_data: rawptr, reading: Reading) -> Reading {
	calls := cast(^i64)user_data
	calls^ += 1
	return {page = reading.page + calls^, progress = reading.progress + 0.125}
}

@(export)
odin_swift_abi_check_imports :: proc "swift" () -> i64 {
	if add_scalar(41, 0.5) != 41.5 {
		return 1
	}

	advance_reading := advance
	original := Reading{page = 41, progress = 0.25}
	reading := advance_reading(5, original, 0.125)
	if reading != (Reading{page = 46, progress = 0.375}) || original != (Reading{page = 41, progress = 0.25}) {
		return 2
	}

	before := Reading{page = 111, progress = 0.75}
	after := Reading{page = 222, progress = 1.25}
	records := [3]Reading{before, original, after}
	middle := &records[1]
	if change_in_place(middle, 5, 0.125) != middle || records != ([3]Reading{before, reading, after}) {
		return 3
	}

	initial := [6]u8{0xa5, 255, 255, 255, 255, 0x5a}
	bytes := initial
	output := raw_data(bytes[1:5])
	if fill_bytes(output, 0) != 0 || fill_bytes(output, 2) != 0 || bytes != initial {
		return 4
	}
	if fill_bytes(output, 4) != 3 || bytes != ([6]u8{0xa5, 13, 29, 61, 255, 0x5a}) {
		return 5
	}

	callback_data := [3]i64{111, 0, 222}
	user_data := rawptr(&callback_data[1])
	first := call_callback(update_callback_count, user_data, original)
	second := call_callback(update_callback_count, user_data, original)
	if first != (Reading{page = 42, progress = 0.375}) ||
	   second != (Reading{page = 43, progress = 0.375}) ||
	   callback_data != ([3]i64{111, 2, 222}) {
		return 6
	}
	return 0
}

@(export)
odin_swift_abi_next_id :: proc "swift" (id: Transaction_ID) -> Transaction_ID {
	return {value = id.value + 1}
}

@(export)
odin_swift_abi_drop_prefix :: proc "swift" (text: Text_View, prefix: u64) -> Text_View {
	if text.count == 0 || u64(text.bytes[0]) != prefix {
		return text
	}
	return {bytes = text.bytes[1:], count = text.count - 1}
}

@(export)
odin_swift_abi_update_key :: proc "swift" (status: u64, key: Transaction_Key, seconds: f64) -> Transaction_Key {
	result := key
	result.id += 1
	result.status = status
	result.purchased_at += seconds
	return result
}

@(export)
odin_swift_abi_update_transaction :: proc "swift" (status: u64, transaction: Transaction_Info, seconds: f64) -> Transaction_Info {
	result := transaction
	result.id += 1
	result.status = status
	result.purchased_at += seconds
	result.product_offset += 1
	result.product_count -= 1
	return result
}

@(export)
odin_swift_abi_update_transaction_in_place :: proc "swift" (transaction: ^Transaction_Info, status: u64, seconds: f64) -> ^Transaction_Info {
	transaction^ = odin_swift_abi_update_transaction(status, transaction^, seconds)
	return transaction
}

@(export)
odin_swift_abi_check_records :: proc "swift" () -> i64 {
	id :: 0x8000_0000_0000_0041
	if next_id({value = id}).value != id + 1 {
		return 1
	}

	bytes := [4]u8{0xa5, '$', '3', 0x5a}
	text := Text_View{bytes = raw_data(bytes[1:3]), count = 2}
	empty := Text_View{bytes = text.bytes[2:], count = 0}
	view := drop_prefix(text, '$')
	if view.bytes != text.bytes[1:] || view.count != 1 || view.bytes[0] != '3' ||
	   drop_prefix(text, '%') != text || drop_prefix(empty, 0x5a) != empty ||
	   bytes != ([4]u8{0xa5, '$', '3', 0x5a}) {
		return 2
	}

	key := Transaction_Key{id = id, original_id = 99, purchased_at = 42.25, status = 0}
	if update_key(3, key, 0.5) != (Transaction_Key{id = id + 1, original_id = 99, purchased_at = 42.75, status = 3}) {
		return 3
	}

	original := Transaction_Info{id = id, original_id = 99, purchased_at = 42.25, status = 0, product_offset = 16, product_count = 7}
	updated := Transaction_Info{id = id + 1, original_id = 99, purchased_at = 42.75, status = 3, product_offset = 17, product_count = 6}
	result := update_transaction(3, original, 0.5)
	if result != updated || original != (Transaction_Info{id = id, original_id = 99, purchased_at = 42.25, status = 0, product_offset = 16, product_count = 7}) {
		return 4
	}

	before := Transaction_Info{id = 111, status = 12, product_count = 14}
	after := Transaction_Info{id = 222, status = 15, product_count = 17}
	records := [3]Transaction_Info{before, original, after}
	middle := &records[1]
	if update_transaction_in_place(middle, 3, 0.5) != middle || records != ([3]Transaction_Info{before, updated, after}) {
		return 5
	}
	return 0
}
