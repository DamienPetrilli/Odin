#+build darwin, arm64
#+vet tabs style semicolon
package darwin_Swift

// Finite decimal value. A nonzero coefficient has no trailing decimal zeros.
Decimal :: struct {
	coefficient: u128,
	exponent:    i16,
	negative:    bool,
}

// Register result of a Darwin NSDecimal getter. Only the low 32 bits of
// the last register belong to the value.
Native_Decimal :: struct {
	first, second: u64,
	last:          u32,
}

Native_Optional_Decimal :: struct {
	first, second, last: u64,
}

@(require_results)
optional_decimal_from_native :: proc "contextless" (v: Native_Optional_Decimal) -> (value: Maybe(Decimal), ok: bool) #optional_ok {
	if v.last & (1 << 32) != 0 { return nil, true }
	amount := decimal_from_native({v.first, v.second, u32(v.last)}) or_return
	return amount, true
}

@(require_results)
decimal_from_native :: proc "contextless" (v: Native_Decimal) -> (value: Decimal, ok: bool) #optional_ok {
	length := (v.first >> 8) & 0xf
	negative := v.first & (1 << 12) != 0
	if length == 0 { return {}, !negative } // NSDecimal encodes NaN as negative zero length.
	if length > 8 { return {}, false }

	coefficient := u128(v.first >> 32) | (u128(v.second) << 32) | (u128(v.last) << 96)
	if length < 8 { coefficient &= (u128(1) << (16 * length)) - 1 }
	if coefficient == 0 { return {}, true }
	exponent := i16(i8(u8(v.first)))
	for coefficient % 10 == 0 {
		coefficient /= 10
		exponent += 1
	}
	return {coefficient, exponent, negative}, true
}
