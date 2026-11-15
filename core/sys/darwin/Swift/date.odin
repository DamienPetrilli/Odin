#+build darwin, arm64
package darwin_Swift

// Seconds since 2001-01-01 00:00:00 UTC, as in Foundation.Date. This is an Odin
// value, not Swift storage. Preserve its Double precision and range; converting
// automatically to core:time.Time would lose subnanoseconds and distant dates.
// The importer constructs and consumes native Date values through the Swift ABI.
Date :: distinct f64
