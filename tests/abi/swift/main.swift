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

@_silgen_name("odin_swift_abi_call_callback")
func callCallbackInOdin(_ callback: ReadingCallback, _ userData: UnsafeMutableRawPointer, _ reading: Reading) -> Reading

// Odin resolves the Swift symbol as a thin procedure value.
@_silgen_name("odin_swift_abi_swift_callback")
func swiftCallback() -> ReadingCallback

@_silgen_name("odin_swift_abi_retain_callback_state")
func retainCallbackStateInOdin(_ state: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer

@_silgen_name("odin_swift_abi_release_callback_state")
func releaseCallbackStateInOdin(_ state: UnsafeMutableRawPointer)

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

var deinitCount: Int64 = 0
withUnsafeMutablePointer(to: &deinitCount) { count in
	let initial = makeCallbackState(count)
	let retained = retainCallbackStateInOdin(initial)
	precondition(retained == initial)
	releaseCallbackState(initial)
	precondition(count.pointee == 0)

	let callback = swiftCallback()
	let first = callCallbackInOdin(callback, retained, original)
	let second = callCallbackInOdin(callback, retained, original)
	precondition(first == Reading(page: 42, progress: 0.375))
	precondition(second == Reading(page: 43, progress: 0.375))
	precondition(count.pointee == 0)

	releaseCallbackStateInOdin(retained)
	precondition(count.pointee == 1)
}

@_silgen_name("odin_swift_abi_check_records")
func checkRecordImports() -> Int64

@_silgen_name("odin_swift_abi_next_id")
func nextIDInOdin(_ id: TransactionID) -> TransactionID

@_silgen_name("odin_swift_abi_drop_prefix")
func dropPrefixInOdin(_ text: TextView, _ prefix: UInt64) -> TextView

@_silgen_name("odin_swift_abi_update_key")
func updateKeyInOdin(_ status: UInt64, _ key: TransactionKey, _ seconds: Double) -> TransactionKey

@_silgen_name("odin_swift_abi_update_transaction")
func updateTransactionInOdin(_ status: UInt64, _ transaction: TransactionInfo, _ seconds: Double) -> TransactionInfo

@_silgen_name("odin_swift_abi_update_transaction_in_place")
func updateTransactionInPlaceInOdin(_ transaction: UnsafeMutablePointer<TransactionInfo>, _ status: UInt64, _ seconds: Double) -> UnsafeMutablePointer<TransactionInfo>

precondition(MemoryLayout<TransactionID>.size == 8)
precondition(MemoryLayout<TextView>.size == 16)
precondition(MemoryLayout<TextView>.offset(of: \.count) == 8)
precondition(MemoryLayout<TransactionKey>.size == 32)
precondition(MemoryLayout<TransactionKey>.offset(of: \.purchasedAt) == 16)
precondition(MemoryLayout<TransactionInfo>.size == 48)
precondition(MemoryLayout<TransactionInfo>.stride == 48)
precondition(MemoryLayout<TransactionInfo>.alignment == 8)
precondition(MemoryLayout<TransactionInfo>.offset(of: \.id) == 0)
precondition(MemoryLayout<TransactionInfo>.offset(of: \.originalID) == 8)
precondition(MemoryLayout<TransactionInfo>.offset(of: \.purchasedAt) == 16)
precondition(MemoryLayout<TransactionInfo>.offset(of: \.status) == 24)
precondition(MemoryLayout<TransactionInfo>.offset(of: \.productOffset) == 32)
precondition(MemoryLayout<TransactionInfo>.offset(of: \.productCount) == 40)

let recordFailure = checkRecordImports()
precondition(recordFailure == 0, "Odin record call to Swift failed at check \(recordFailure)")

let id: UInt64 = 0x8000_0000_0000_0041
precondition(nextIDInOdin(TransactionID(value: id)) == TransactionID(value: id + 1))

let textBytes: [UInt8] = [0xa5, 0x24, 0x33, 0x5a]
textBytes.withUnsafeBufferPointer { bytes in
	let start = bytes.baseAddress!.advanced(by: 1)
	let text = TextView(bytes: start, count: 2)
	let empty = TextView(bytes: start.advanced(by: 2), count: 0)
	let view = dropPrefixInOdin(text, 0x24)
	precondition(view.bytes == start.advanced(by: 1) && view.count == 1 && view.bytes.pointee == 0x33)
	precondition(dropPrefixInOdin(text, 0x25) == text)
	precondition(dropPrefixInOdin(empty, 0x5a) == empty)
	precondition(bytes.elementsEqual([0xa5, 0x24, 0x33, 0x5a]))
}

let key = TransactionKey(id: id, originalID: 99, purchasedAt: 42.25, status: 0)
precondition(updateKeyInOdin(3, key, 0.5) == TransactionKey(id: id + 1, originalID: 99, purchasedAt: 42.75, status: 3))

let transaction = TransactionInfo(id: id, originalID: 99, purchasedAt: 42.25, status: 0, productOffset: 16, productCount: 7)
let updated = TransactionInfo(id: id + 1, originalID: 99, purchasedAt: 42.75, status: 3, productOffset: 17, productCount: 6)
precondition(updateTransactionInOdin(3, transaction, 0.5) == updated)
precondition(transaction == TransactionInfo(id: id, originalID: 99, purchasedAt: 42.25, status: 0, productOffset: 16, productCount: 7))

let beforeTransaction = TransactionInfo(id: 111, originalID: 0, purchasedAt: 0, status: 12, productOffset: 0, productCount: 14)
let afterTransaction = TransactionInfo(id: 222, originalID: 0, purchasedAt: 0, status: 15, productOffset: 0, productCount: 17)
var transactions = [beforeTransaction, transaction, afterTransaction]
transactions.withUnsafeMutableBufferPointer { buffer in
	let middle = buffer.baseAddress!.advanced(by: 1)
	precondition(updateTransactionInPlaceInOdin(middle, 3, 0.5) == middle)
}
precondition(transactions == [beforeTransaction, updated, afterTransaction])

@_silgen_name("odin_swift_abi_invert_flag")
func invertFlagRoundTrip(_ value: Bool) -> Bool
precondition(invertFlagRoundTrip(false))
precondition(!invertFlagRoundTrip(true))
