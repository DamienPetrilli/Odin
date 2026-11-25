import Foundation

// A synchronous-only module must import everything its Set conversion needs.
public func uniqueCount(_ values: Set<UInt64>) -> UInt64 { UInt64(values.count) }
public func wordCount(_ values: Set<String>) -> UInt64 { UInt64(values.count) }
public func datedIdentifiers(_ date: Date, _ ids: Set<UUID>) -> Date {
	date.addingTimeInterval(Double(ids.count))
}
public func echoIdentifier(_ id: UUID) -> UUID { id }
