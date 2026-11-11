public func addScalar(_ whole: Int64, _ fraction: Double) -> Double {
	Double(whole) + fraction
}

@frozen public struct Reading: Equatable {
	public var page: Int64
	public var progress: Double

	public init(page: Int64, progress: Double) {
		self.page = page
		self.progress = progress
	}
}

public func advance(_ pages: Int64, _ reading: Reading, _ fraction: Double) -> Reading {
	Reading(page: reading.page + pages, progress: reading.progress + fraction)
}

public func changeInPlace(_ reading: UnsafeMutablePointer<Reading>, _ pages: Int64, _ fraction: Double) -> UnsafeMutablePointer<Reading> {
	reading.pointee = advance(pages, reading.pointee, fraction)
	return reading
}

public func fillBytes(_ output: UnsafeMutablePointer<UInt8>, _ capacity: Int64) -> Int64 {
	guard capacity >= 3 else { return 0 }
	let bytes = UnsafeMutableBufferPointer(start: output, count: 3)
	bytes[0] = 13
	bytes[1] = 29
	bytes[2] = 61
	return 3
}
