import OdinExportFixture

precondition(String(reflecting: Reading.self) == "OdinExportFixture.Reading")
precondition(MemoryLayout<Reading>.size == 16 && MemoryLayout<Reading>.alignment == 8)
precondition(MemoryLayout<LargeValue>.size == 40 && MemoryLayout<LargeValue>.stride == 40)
let keyword = updateAny(OdinExportFixture.`Any`(first: 10, second: 20))
precondition(keyword.first == 11 && keyword.second == 22)
checkInitialized()
precondition(addNumbers(17, 9) == 26)
precondition(negate(false) && !negate(true))
let reading = updateReading(Reading(page: 17, progress: 0.5))
precondition(reading.page == 18 && reading.progress == 0.75)
let large = updateLarge(LargeValue(a: 10, b: 20, c: 30, d: 40, e: 50))
precondition(large.a == 11 && large.b == 22 && large.c == 33 && large.d == 44 && large.e == 55)
var values: [UInt64] = [10, 20, 30]
values.withUnsafeMutableBufferPointer {
	precondition(modifyValues($0, 7) == 3)
}
precondition(values == [17, 27, 37])
precondition(modifyValues(UnsafeMutableBufferPointer(start: nil, count: 0), 1) == 0)
var guarded: [UInt64] = [0x12345678, 10, 20, 30, 0x87654321]
guarded.withUnsafeMutableBufferPointer { buffer in
	let middle = UnsafeMutableBufferPointer(start: buffer.baseAddress!.advanced(by: 1), count: 3)
	precondition(modifyValues(middle, 7) == 3)
}
precondition(guarded == [0x12345678, 17, 27, 37, 0x87654321])
var signed: [Int64] = [-1, 0, 20]
signed.withUnsafeMutableBufferPointer { modifySigned($0) }
precondition(signed == [-3, -2, 18])
var floats: [Double] = [0.5, -2, 4]
floats.withUnsafeMutableBufferPointer { modifyFloats($0) }
precondition(floats == [0.75, -3, 6])
precondition(callPrivate(41) == 42)
for index in 0..<1000 {
	precondition(roundTrip(UInt64(index)) == UInt64(index + 1))
	precondition(addNumbers(UInt64(index), 1) == UInt64(index + 1))
}
print("Swift export tests passed")

// Swift case tags are not Odin raw values. Test semantic identity and mutation.
precondition(String(reflecting: Mode.self) == "OdinExportFixture.Mode")
precondition(MemoryLayout<Mode>.size == 1 && MemoryLayout<SingleCase>.size == 0)
precondition(MemoryLayout<WideCode>.size == 2)
precondition(Mode.idle.rawValue == 10 && Mode.running.rawValue == 20)
precondition(Mode(rawValue: 11) == nil)
precondition(toggleMode(.idle) == .running && toggleMode(.running) == .idle)
precondition(modeRaw(.idle) == 10 && modeRaw(.running) == 20)
precondition(makeMode() == .running && localMode() == .idle)
precondition(echoSingle(.only) == .only && SingleCase.only.rawValue == -17)
precondition(singleArguments(.only, 73, .only, 0.25, .only) == 73.25)
for value in [SignedCode.low, .middle, .high] { precondition(echoSigned(value) == value) }
precondition(SignedCode.low.rawValue == Int64.min && SignedCode.high.rawValue == Int64.max)
for value in [UnsignedCode.high, .low, .middle] { precondition(echoUnsigned(value) == value) }
precondition(UnsignedCode.high.rawValue == UInt64.max && UnsignedCode.middle.rawValue == 1 << 63)
precondition(echoSmall(.low).rawValue == -128 && echoSmall(.high).rawValue == 127)
for value in [MediumCode.first, .second, .third] { precondition(echoMedium(value) == value) }
precondition(echoDefault(.first).rawValue == -1 && echoDefault(.second).rawValue == 42)
precondition(echoKeyword(.default) == .default && echoKeyword(.switch) == .switch && echoKeyword(.any) == .any)
for index in 0..<257 {
	let raw = UInt64(1000 + 3 * index)
	let value = WideCode(rawValue: raw)!
	precondition(echoWide(value) == value && wideRaw(value) == raw)
}
precondition(WideCode(rawValue: 1001) == nil)
var enumGuarded: [UInt64] = [0x12345678, 1, 2, 0x87654321]
enumGuarded.withUnsafeMutableBufferPointer { buffer in
	let middle = UnsafeMutableBufferPointer(start: buffer.baseAddress!.advanced(by: 1), count: 2)
	precondition(modifyWithMode(.running, middle, .only, 7) == .idle)
}
precondition(enumGuarded == [0x12345678, 28, 29, 0x87654321])
let enumReading = modeAndRecord(Reading(page: 42, progress: 0.25), .running)
precondition(enumReading.page == 62 && enumReading.progress == 0.75)
let enumLarge = modeAndLarge(.idle, LargeValue(a: 1, b: 2, c: 3, d: 4, e: 5))
precondition(enumLarge.a == 1 && enumLarge.e == 15)
for _ in 0..<1000 {
	precondition(toggleMode(toggleMode(.idle)) == .idle)
	precondition(echoSingle(.only) == .only)
}
precondition(echoShort(.low).rawValue == Int16.min && echoShort(.high).rawValue == Int16.max)
precondition(echoInt(.low).rawValue == Int32.min && echoInt(.high).rawValue == Int32.max)
precondition(echoNativeUnsigned(.low).rawValue == 0 && echoNativeUnsigned(.high).rawValue == UInt.max)
print("Native Swift enum export round trips passed")

for value in [Int.min, -73, -1, 0, Int.max] { precondition(identityNativeInt(value) == value) }
for value in [UInt(0), 1, 73, 1 << 63, UInt.max] { precondition(identityNativeUint(value) == value) }
precondition(identityBool(false) == false && identityBool(true) == true)
let words = identityWords(NativeWords(signed: Int.min, unsigned: UInt.max))
precondition(words.signed == Int.min && words.unsigned == UInt.max)
var nativeSigned: [Int] = [Int.min, 0, Int.max]
var nativeUnsigned: [UInt] = [0, 1 << 63, UInt.max]
nativeSigned.withUnsafeMutableBufferPointer { signed in
	nativeUnsigned.withUnsafeMutableBufferPointer { unsigned in
		modifyNativeWords(signed, unsigned)
	}
}
precondition(nativeSigned == [-73, -73, -73] && nativeUnsigned == [UInt.max, UInt.max, UInt.max])
modifyNativeWords(UnsafeMutableBufferPointer(start: nil, count: 0), UnsafeMutableBufferPointer(start: nil, count: 0))
print("Native Bool/Int/UInt export-import round trips passed")

// Mixed frozen records preserve field values and Swift size versus stride.
precondition(MemoryLayout<BoolTriple>.size == 3 && MemoryLayout<BoolTriple>.stride == 3)
precondition(MemoryLayout<BoolTail>.size == 9 && MemoryLayout<BoolTail>.stride == 16)
precondition(MemoryLayout<BoolMixed>.size == 25 && MemoryLayout<BoolMixed>.stride == 32)
precondition(MemoryLayout<BoolWide>.size == 41 && MemoryLayout<BoolWide>.stride == 48)
for flag in [false, true] {
	let valueBoolOnly = BoolOnly(flag: flag)
	let resultBoolOnly = echoBoolOnly(valueBoolOnly)
	precondition(resultBoolOnly.flag == valueBoolOnly.flag)
	let valueBoolTriple = BoolTriple(a: flag, b: !flag, c: flag)
	let resultBoolTriple = echoBoolTriple(valueBoolTriple)
	precondition(resultBoolTriple.a == valueBoolTriple.a)
	precondition(resultBoolTriple.b == valueBoolTriple.b)
	precondition(resultBoolTriple.c == valueBoolTriple.c)
	let valueBoolRun = BoolRun(a: flag, b: !flag, c: flag, d: !flag, e: flag, f: !flag, g: flag, h: !flag, i: flag)
	let resultBoolRun = echoBoolRun(valueBoolRun)
	precondition(resultBoolRun.a == valueBoolRun.a)
	precondition(resultBoolRun.b == valueBoolRun.b)
	precondition(resultBoolRun.c == valueBoolRun.c)
	precondition(resultBoolRun.d == valueBoolRun.d)
	precondition(resultBoolRun.e == valueBoolRun.e)
	precondition(resultBoolRun.f == valueBoolRun.f)
	precondition(resultBoolRun.g == valueBoolRun.g)
	precondition(resultBoolRun.h == valueBoolRun.h)
	precondition(resultBoolRun.i == valueBoolRun.i)
	let valueBoolHead = BoolHead(flag: flag, count: -73)
	let resultBoolHead = echoBoolHead(valueBoolHead)
	precondition(resultBoolHead.flag == valueBoolHead.flag)
	precondition(resultBoolHead.count == valueBoolHead.count)
	let valueBoolTail = BoolTail(count: -73, flag: !flag)
	let resultBoolTail = echoBoolTail(valueBoolTail)
	precondition(resultBoolTail.count == valueBoolTail.count)
	precondition(resultBoolTail.flag == valueBoolTail.flag)
	let valueBoolMixed = BoolMixed(a: flag, b: !flag, count: -73, fraction: 0.5, c: flag)
	let resultBoolMixed = echoBoolMixed(valueBoolMixed)
	precondition(resultBoolMixed.a == valueBoolMixed.a)
	precondition(resultBoolMixed.b == valueBoolMixed.b)
	precondition(resultBoolMixed.count == valueBoolMixed.count)
	precondition(resultBoolMixed.fraction == valueBoolMixed.fraction)
	precondition(resultBoolMixed.c == valueBoolMixed.c)
	let valueBoolWide = BoolWide(flag: flag, a: -73, b: UInt.max, c: 0.5, d: -73, end: !flag)
	let resultBoolWide = echoBoolWide(valueBoolWide)
	precondition(resultBoolWide.flag == valueBoolWide.flag)
	precondition(resultBoolWide.a == valueBoolWide.a)
	precondition(resultBoolWide.b == valueBoolWide.b)
	precondition(resultBoolWide.c == valueBoolWide.c)
	precondition(resultBoolWide.d == valueBoolWide.d)
	precondition(resultBoolWide.end == valueBoolWide.end)
	let changed = flipBoolMixed(valueBoolMixed)
	precondition(changed.a == !valueBoolMixed.a && changed.b == !valueBoolMixed.b && changed.c == !valueBoolMixed.c)
	precondition(changed.count == -72 && changed.fraction == 0.75)
	precondition(returnBoolWideCall(valueBoolWide).end == valueBoolWide.end)
	precondition(returnBoolWideLocal(valueBoolWide).d == valueBoolWide.d)
}
print("Mixed Bool record exports passed")

// Swift may reuse tail padding in a surrounding value. A native result writes
// only its stored fields, never Odin's larger rounded size.
@inline(never) func checkBoolWideStorage(_ value: BoolWide) {
	let size = MemoryLayout<BoolWide>.size
	let storage = UnsafeMutableRawPointer.allocate(byteCount: 48, alignment: 8)
	defer { storage.deallocate() }
	storage.initializeMemory(as: UInt8.self, repeating: 0xa5, count: 48)
	let destination = storage.bindMemory(to: BoolWide.self, capacity: 1)
	destination.initialize(to: returnBoolWideCall(value))
	precondition(destination.pointee.a == value.a && destination.pointee.end == value.end)
	for index in size..<48 { precondition(storage.load(fromByteOffset: index, as: UInt8.self) == 0xa5) }
	destination.deinitialize(count: 1)
}
checkBoolWideStorage(BoolWide(flag: true, a: -73, b: UInt.max, c: 0.5, d: 41, end: false))
print("Mixed Bool record tail padding preserved")
