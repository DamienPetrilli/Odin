import SwiftABIFixture

// Declare the test exports with Swift's native calling convention.
@_silgen_name("odin_swift_abi_check_imports")
func checkImports() -> Int64

@_silgen_name("odin_swift_abi_add_scalar")
func addOdinScalar(_ whole: Int64, _ fraction: Double) -> Double

@_silgen_name("odin_swift_abi_advance")
func advanceOdin(_ pages: Int64, _ reading: Reading, _ fraction: Double) -> Reading

@_silgen_name("odin_swift_abi_change_in_place")
func changeInPlaceInOdin(_ reading: UnsafeMutablePointer<Reading>, _ pages: Int64, _ fraction: Double) -> UnsafeMutablePointer<Reading>

@_silgen_name("odin_swift_abi_fill_bytes")
func fillBytesInOdin(_ output: UnsafeMutablePointer<UInt8>, _ capacity: Int64) -> Int64

precondition(MemoryLayout<Reading>.size == 16)
precondition(MemoryLayout<Reading>.stride == 16)
precondition(MemoryLayout<Reading>.alignment == 8)
precondition(MemoryLayout<Reading>.offset(of: \.page) == 0)
precondition(MemoryLayout<Reading>.offset(of: \.progress) == 8)

let failure = checkImports()
precondition(failure == 0, "Odin call to Swift failed at check \(failure)")
precondition(addOdinScalar(42, 0.25) == 42.25, "Swift call to Odin failed")

let original = Reading(page: 41, progress: 0.25)
let reading = advanceOdin(5, original, 0.125)
precondition(reading == Reading(page: 46, progress: 0.375))
precondition(original == Reading(page: 41, progress: 0.25))

let before = Reading(page: 111, progress: 0.75)
let after = Reading(page: 222, progress: 1.25)
var records = [before, original, after]
records.withUnsafeMutableBufferPointer { buffer in
	let middle = buffer.baseAddress!.advanced(by: 1)
	precondition(changeInPlaceInOdin(middle, 5, 0.125) == middle)
}
precondition(records == [before, reading, after])

var data: [UInt8] = [0xa5, 255, 255, 255, 255, 0x5a]
data.withUnsafeMutableBufferPointer { bytes in
	let start = bytes.baseAddress!.advanced(by: 1)
	precondition(fillBytesInOdin(start, 0) == 0)
	precondition(fillBytesInOdin(start, 2) == 0)
	precondition(bytes.elementsEqual([0xa5, 255, 255, 255, 255, 0x5a]))
	precondition(fillBytesInOdin(start, Int64(bytes.count - 2)) == 3)
}
precondition(data == [0xa5, 13, 29, 61, 255, 0x5a])
