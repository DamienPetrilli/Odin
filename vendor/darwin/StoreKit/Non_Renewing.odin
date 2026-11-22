#+build darwin arm64
#+vet tabs style semicolon
package darwin_StoreKit

import "core:time"
import swift "core:sys/darwin/Swift"

when AVAILABLE {
	// Absolute dates in the same units as Transaction_purchase_date.
	Non_Renewing_Period :: struct {
		starts_at:  swift.Date,
		expires_at: swift.Date,
	}

	// Compute a fixed elapsed term from the verified purchase. The app chooses
	// its product ID, duration and revocation policy. No transaction is retained.
	@(require_results)
	non_renewing_period :: proc(verified: Verified, duration: time.Duration) -> (period: Non_Renewing_Period, ok: bool) #optional_ok {
		if verified.value == nil || duration <= 0 { return {}, false }
		kind := Transaction_product_type(verified.value) or_return
		if kind != .Non_Renewing_Subscription { return {}, false }
		start := Transaction_purchase_date(verified.value) or_return
		end := start + swift.Date(time.duration_seconds(duration))
		if !(start < end) { return {}, false }
		return {start, end}, true
	}

	// The start is inclusive and the expiry is exclusive. Supply now to use
	// a trusted clock or to evaluate a specific instant.
	non_renewing_active :: proc{non_renewing_active_now, non_renewing_active_at}

	@(private)
	current_store_date :: proc() -> swift.Date {
		// Swift counts seconds from 2001-01-01 00:00:00 UTC.
		ns := time.to_unix_nanoseconds(time.now())
		return swift.Date(ns / 1_000_000_000 - 978_307_200) + swift.Date(ns % 1_000_000_000) / 1e9
	}

	@(private)
	non_renewing_active_now :: proc(period: Non_Renewing_Period) -> bool {
		return non_renewing_active_at(period, current_store_date())
	}

	@(private)
	non_renewing_active_at :: proc(period: Non_Renewing_Period, now: swift.Date) -> bool {
		return period.starts_at <= now && now < period.expires_at
	}
}
