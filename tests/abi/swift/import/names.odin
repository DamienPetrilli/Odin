package swift_names_test

foreign import fixture "swift:fixture/SwiftNamesFixture"

main :: proc() {
	assert(fixture.len_(40) == 42)
	assert(fixture.f64_(12.0) == 12.5)
	item := fixture.Item_init(31) or_else panic("Named helper alias")
	defer fixture.Item_destroy(item)
	assert(fixture.Item_copy_amount(item, 11) == 42)
	copied := fixture.Item_copy(item) or_else panic("Owned copy")
	defer fixture.Item_destroy(copied)
	assert(fixture.Item_value(copied) == 31)
	assert(fixture.actual_scalar(41) == 42)
	value := fixture.named_value(73) or_else panic("Named UInt64")
	defer fixture.UInt64_destroy(value)
	assert(fixture.UInt64_value(value) == 73)
	outcome := fixture.named_outcome(91) or_else panic("Named outcome")
	defer fixture.Outcome_destroy(outcome)
	assert(fixture.Outcome_case(outcome) == .Value)
	payload := fixture.Outcome_get_value(outcome) or_else panic("Named payload")
	defer fixture.UInt64_destroy(payload)
	assert(fixture.UInt64_value(payload) == 91)
	values := fixture.scalar_words([]u64{10, 20, 30}) or_else panic("Scalar array")
	defer delete(values)
	assert(len(values) == 3 && values[0] == 11 && values[2] == 31)
}
