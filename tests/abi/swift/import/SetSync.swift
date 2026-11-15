// A synchronous-only module must import everything its Set conversion needs.
public func uniqueCount(_ values: Set<UInt64>) -> UInt64 { UInt64(values.count) }
