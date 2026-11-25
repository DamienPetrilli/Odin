#+build darwin arm64
#+vet tabs style semicolon
package darwin_StoreKit

import "core:mem"
import "core:sync"
import swift "core:sys/darwin/Swift"
foreign import api "swift:StoreKit"

when AVAILABLE {
	Subscription_Status             :: api.Product_SubscriptionInfo_Status
	Subscription_Status_transaction :: api.Product_SubscriptionInfo_Status_transaction
	subscription_statuses           :: api.Product_SubscriptionInfo_status_for_
	subscription_statuses_destroy   :: api.Array_Product_SubscriptionInfo_Status_destroy

	// Zero-initialize and keep at a stable address through on_closed.
	Subscription_Watch :: struct {
		iterator:  api.Product_SubscriptionInfo_Status_Statuses_AsyncIterator,
		task:      Task,
		next:      ^Subscription_Watch,
		on_change: proc(^Subscription_Watch, Subscription_Status),
		on_closed: proc(^Subscription_Watch, Listener_End),
		stopping:  bool,
	}

	@(private)
	pending_subscriptions: ^Subscription_Watch

	// Start on the main executor. Each change borrows a status until on_change
	// returns. Query subscription_statuses separately for the initial group state.
	@(require_results)
	watch_subscriptions :: proc(
		watch: ^Subscription_Watch, on_change: proc(^Subscription_Watch, Subscription_Status),
		on_closed: proc(^Subscription_Watch, Listener_End),
	) -> bool {
		if watch == nil || watch.iterator != nil || on_change == nil || on_closed == nil { return false }
		updates := api.Product_SubscriptionInfo_Status_updates() or_return
		defer api.Product_SubscriptionInfo_Status_Statuses_destroy(updates)
		iter := api.Product_SubscriptionInfo_Status_Statuses_make_async_iterator(updates) or_return
		watch^ = {iterator = iter, on_change = on_change, on_closed = on_closed}
		if read_subscription(watch) { return true }
		api.Product_SubscriptionInfo_Status_Statuses_AsyncIterator_destroy(iter)
		watch^ = {}
		return false
	}

	// Safe inside on_change. A successful start delivers on_closed once.
	stop_subscription_watch :: proc(watch: ^Subscription_Watch) {
		stop_watch(watch)
	}

	@(private)
	read_subscription :: proc(watch: ^Subscription_Watch) -> bool {
		watch.task = api.Product_SubscriptionInfo_Status_Statuses_AsyncIterator_next(watch.iterator, subscription_changed) or_return
		watch.next = pending_subscriptions
		pending_subscriptions = watch
		return true
	}

	@(private)
	subscription_changed :: proc(task: Task, result: Maybe(Subscription_Status), converted: bool) {
		watch := take_pending_read(&pending_subscriptions, task)
		deliver_watch_update(
			watch, result, converted, api.Product_SubscriptionInfo_Status_destroy,
			read_subscription, api.Product_SubscriptionInfo_Status_Statuses_AsyncIterator_destroy,
		)
	}

	// The caller owns the returned string.
	@(require_results)
	subscription_group_id :: proc(product: Product) -> (id: string, ok: bool) #optional_ok {
		if product == nil { return "", false }
		info := api.Product_subscription(product) or_return
		defer api.Optional_Product_SubscriptionInfo_destroy(info)
		value := info.? or_return
		return api.Product_SubscriptionInfo_subscription_group_id(value)
	}

	Subscription_Unit :: enum { Unknown, Day, Week, Month, Year }

	Billing_Interval :: struct {
		count: int,
		unit:  Subscription_Unit,
	}

	// The catalog's calendar interval. Returns false for products without
	// subscription information. The returned value owns no Swift storage.
	@(require_results)
	Product_subscription_period :: proc(product: Product) -> (interval: Billing_Interval, ok: bool) #optional_ok {
		if product == nil { return {}, false }
		info := api.Product_subscription(product) or_return
		defer api.Optional_Product_SubscriptionInfo_destroy(info)
		subscription := info.? or_return
		period := api.Product_SubscriptionInfo_subscription_period(subscription) or_return
		defer api.Product_SubscriptionPeriod_destroy(period)
		unit := api.Product_SubscriptionPeriod_unit(period) or_return
		defer api.Product_SubscriptionPeriod_Unit_destroy(unit)
		interval.count = api.Product_SubscriptionPeriod_value(period)
		switch _ in unit {
		case api.Product_SubscriptionPeriod_Unit_Day:     interval.unit = .Day
		case api.Product_SubscriptionPeriod_Unit_Week:    interval.unit = .Week
		case api.Product_SubscriptionPeriod_Unit_Month:   interval.unit = .Month
		case api.Product_SubscriptionPeriod_Unit_Year:    interval.unit = .Year
		case api.Product_SubscriptionPeriod_Unit_Unknown: interval.unit = .Unknown
		}
		return interval, true
	}

	Subscription_State :: enum {
		Unknown, Subscribed, Expired, Billing_Retry, Grace_Period, Revoked,
	}

	Subscription_Period :: struct {
		transaction_id:   u64,
		original_id:      u64,
		state:            Subscription_State,
		will_renew:       bool,
		in_billing_retry: bool,
		starts_at:        swift.Date,
		paid_until:       swift.Date,
		access_until:     Maybe(swift.Date),
	}

	@(private)
	renewal_state :: proc(status: Subscription_Status) -> (state: Subscription_State, ok: bool) #optional_ok {
		native := api.Product_SubscriptionInfo_Status_state(status) or_return
		defer api.Product_SubscriptionInfo_RenewalState_destroy(native)
		raw := api.Product_SubscriptionInfo_RenewalState_raw_value(native)
		// Cache only the integer from each immutable Swift constant. Zero is
		// read again if it is a valid raw value on a future runtime.
		@(static) raw_values: [Subscription_State]int
		getters := [Subscription_State]type_of(api.Product_SubscriptionInfo_RenewalState_subscribed) {
			.Unknown       = nil,
			.Subscribed    = api.Product_SubscriptionInfo_RenewalState_subscribed,
			.Expired       = api.Product_SubscriptionInfo_RenewalState_expired,
			.Billing_Retry = api.Product_SubscriptionInfo_RenewalState_in_billing_retry_period,
			.Grace_Period  = api.Product_SubscriptionInfo_RenewalState_in_grace_period,
			.Revoked       = api.Product_SubscriptionInfo_RenewalState_revoked,
		}
		for get, kind in getters {
			if get == nil { continue }
			code := sync.atomic_load_explicit(&raw_values[kind], .Relaxed)
			if code == 0 {
				known := get() or_return
				defer api.Product_SubscriptionInfo_RenewalState_destroy(known)
				code = api.Product_SubscriptionInfo_RenewalState_raw_value(known)
				sync.atomic_store_explicit(&raw_values[kind], code, .Relaxed)
			}
			if raw == code { return kind, true }
		}
		return .Unknown, true
	}

	// Read the current product and renewal preference from signed renewal info.
	// The caller owns each returned string. A nil preference means no renewal.
	@(require_results)
	subscription_products :: proc(status: Subscription_Status) -> (current: string, renewal: Maybe(string), ok: bool) {
		if status == nil { return "", nil, false }
		result := api.Product_SubscriptionInfo_Status_renewal_info(status) or_return
		defer api.VerificationResult_Product_SubscriptionInfo_RenewalInfo_destroy(result)
		info := result.(api.VerificationResult_Product_SubscriptionInfo_RenewalInfo_Verified) or_return
		id := api.Product_SubscriptionInfo_RenewalInfo_current_product_id(info.value) or_return
		preference, converted := api.Product_SubscriptionInfo_RenewalInfo_auto_renew_preference(info.value)
		if !converted {
			delete(id)
			return "", nil, false
		}
		return id, preference, true
	}

	// Borrow a status and verify both signed values. The result owns no storage.
	@(require_results)
	subscription_period :: proc(status: Subscription_Status) -> (period: Subscription_Period, ok: bool) #optional_ok {
		if status == nil { return {}, false }
		// Both signed values are consumed before returning the scalar snapshot.
		// Swift supplies their layouts. Larger layouts use the caller's allocator.
		{
			buffer: [3 * 1024]byte = ---
			arena := mem.Arena{data = buffer[:]}
			context.allocator = mem.arena_allocator(&arena)
			period, ok = read_subscription_period(status)
			if ok { return }
		}
		return read_subscription_period(status)
	}

	@(private)
	read_subscription_period :: proc(status: Subscription_Status) -> (period: Subscription_Period, ok: bool) #optional_ok {
		tx_result := api.Product_SubscriptionInfo_Status_transaction(status) or_return
		defer Verification_destroy(tx_result)
		tx := tx_result.(Verified) or_return
		renewal_result := api.Product_SubscriptionInfo_Status_renewal_info(status) or_return
		defer api.VerificationResult_Product_SubscriptionInfo_RenewalInfo_destroy(renewal_result)
		renewal := renewal_result.(api.VerificationResult_Product_SubscriptionInfo_RenewalInfo_Verified) or_return
		expiry := Transaction_expiration_date(tx.value) or_return
		paid_until := expiry.? or_return
		starts_at := Transaction_purchase_date(tx.value) or_return
		state := renewal_state(status) or_return
		revoked := Transaction_revocation_date(tx.value) or_return
		period = {
			transaction_id   = Transaction_id(tx.value),
			original_id      = api.Transaction_original_id(tx.value),
			state            = state,
			will_renew       = api.Product_SubscriptionInfo_RenewalInfo_will_auto_renew(renewal.value),
			in_billing_retry = api.Product_SubscriptionInfo_RenewalInfo_is_in_billing_retry(renewal.value),
			starts_at        = starts_at,
			paid_until       = paid_until,
		}
		if revoked == nil && !api.Transaction_is_upgraded(tx.value) {
			#partial switch state {
			case .Subscribed:   period.access_until = paid_until
			case .Grace_Period: period.access_until = api.Product_SubscriptionInfo_RenewalInfo_grace_period_expiration_date(renewal.value) or_return
			}
		}
		return period, true
	}

	// Check on each access and refresh StoreKit at the deadline. Disabling
	// auto-renewal affects the next charge and preserves the current paid term.
	subscription_active :: proc{subscription_active_now, subscription_active_at}

	@(private)
	subscription_active_now :: proc(period: Subscription_Period) -> bool {
		return subscription_active_at(period, current_store_date())
	}

	@(private)
	subscription_active_at :: proc(period: Subscription_Period, now: swift.Date) -> bool {
		end := period.access_until.? or_return
		return period.starts_at <= now && now < end
	}
}
