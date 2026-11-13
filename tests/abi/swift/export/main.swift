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
for index in 0..<1000 {
	precondition(roundTrip(UInt64(index)) == UInt64(index + 1))
	precondition(addNumbers(UInt64(index), 1) == UInt64(index + 1))
}
print("Swift export tests passed")
