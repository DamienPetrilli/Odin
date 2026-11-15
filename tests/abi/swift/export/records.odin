package export_fixture

BoolOnly :: struct {
	flag: bool,
}

@(export)
echo_bool_only :: proc "swift" (value: BoolOnly) -> BoolOnly { return value }

BoolTriple :: struct {
	a: bool,
	b: bool,
	c: bool,
}

@(export)
echo_bool_triple :: proc "swift" (value: BoolTriple) -> BoolTriple { return value }

BoolRun :: struct {
	a: bool,
	b: bool,
	c: bool,
	d: bool,
	e: bool,
	f: bool,
	g: bool,
	h: bool,
	i: bool,
}

@(export)
echo_bool_run :: proc "swift" (value: BoolRun) -> BoolRun { return value }

BoolHead :: struct {
	flag: bool,
	count: int,
}

@(export)
echo_bool_head :: proc "swift" (value: BoolHead) -> BoolHead { return value }

BoolTail :: struct {
	count: int,
	flag: bool,
}

@(export)
echo_bool_tail :: proc "swift" (value: BoolTail) -> BoolTail { return value }

BoolMixed :: struct {
	a: bool,
	b: bool,
	count: int,
	fraction: f64,
	c: bool,
}

@(export)
echo_bool_mixed :: proc "swift" (value: BoolMixed) -> BoolMixed { return value }

BoolWide :: struct {
	flag: bool,
	a: int,
	b: uint,
	c: f64,
	d: int,
	end: bool,
}

@(export)
echo_bool_wide :: proc "swift" (value: BoolWide) -> BoolWide { return value }

@(export)
flip_bool_mixed :: proc "swift" (value: BoolMixed) -> BoolMixed {
	return {!value.a, !value.b, value.count + 1, value.fraction + 0.25, !value.c}
}

// Exercise returning an ordinary Odin call through a smaller Swift result slot.
copy_bool_wide :: proc "contextless" (value: BoolWide) -> BoolWide { return value }

@(export)
return_bool_wide_call :: proc "swift" (value: BoolWide) -> BoolWide {
	return copy_bool_wide(value)
}

@(export)
return_bool_wide_local :: proc "swift" (value: BoolWide) -> BoolWide {
	result := copy_bool_wide(value)
	return result
}
