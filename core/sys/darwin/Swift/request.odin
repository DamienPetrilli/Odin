#+build darwin, arm64
package darwin_Swift

import "base:intrinsics"

// Identifies a completion. It does not retain a task or control cancellation.
Request_Id :: distinct u64

@(private)
last_request_id: u64

// Used by imported procedures when the caller omits user data. IDs are unique
// within this linked copy of the package; zero denotes a failed start.
// Exhaustion fails instead of wrapping and reusing a previous ID.
@(require_results)
request_id_generate :: proc() -> Request_Id {
	previous := intrinsics.atomic_load_explicit(&last_request_id, .Relaxed)
	for previous != max(u64) {
		next := previous + 1
		observed, exchanged := intrinsics.atomic_compare_exchange_weak_explicit(&last_request_id, previous, next, .Relaxed, .Relaxed)
		if exchanged {
			return Request_Id(next)
		}
		previous = observed
	}
	return 0
}
