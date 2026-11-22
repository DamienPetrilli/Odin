#+build darwin arm64
#+vet tabs style semicolon
package darwin_StoreKit

import swift "core:sys/darwin/Swift"
foreign import api "swift:StoreKit"

when AVAILABLE {
	Subscription_Status             :: api.Product_SubscriptionInfo_Status
	Subscription_Status_transaction :: api.Product_SubscriptionInfo_Status_transaction
	subscription_statuses           :: api.Product_SubscriptionInfo_status_for_
	subscription_statuses_destroy   :: api.Array_Product_SubscriptionInfo_Status_destroy

	// The caller owns the returned string.
	@(require_results)
	subscription_group_id :: proc(product: Product) -> (id: string, ok: bool) #optional_ok {
		if product == nil { return "", false }
		info := api.Product_subscription(product) or_return
		defer api.Optional_Product_SubscriptionInfo_destroy(info)
		value := info.? or_return
		return api.Product_SubscriptionInfo_subscription_group_id(value)
	}

	Subscription_State :: enum {
		Unknown, Subscribed, Expired, Billing_Retry, Grace_Period, Revoked,
	}

	Subscription_Period :: struct {
		transaction_id: u64,
		original_id:    u64,
		state:          Subscription_State,
		will_renew:     bool,
		starts_at:      swift.Date,
		paid_until:     swift.Date,
		access_until:   Maybe(swift.Date),
	}

	@(private)
	renewal_state :: proc(status: Subscription_Status) -> (state: Subscription_State, ok: bool) #optional_ok {
		native := api.Product_SubscriptionInfo_Status_state(status) or_return
		defer api.Product_SubscriptionInfo_RenewalState_destroy(native)
		raw := api.Product_SubscriptionInfo_RenewalState_raw_value(native)
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
			known := get() or_return
			defer api.Product_SubscriptionInfo_RenewalState_destroy(known)
			if raw == api.Product_SubscriptionInfo_RenewalState_raw_value(known) { return kind, true }
		}
		return .Unknown, true
	}

	// Borrow a status and verify both signed values. The result owns no storage.
	@(require_results)
	subscription_period :: proc(status: Subscription_Status) -> (period: Subscription_Period, ok: bool) #optional_ok {
		if status == nil { return {}, false }
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
			transaction_id = Transaction_id(tx.value),
			original_id    = api.Transaction_original_id(tx.value),
			state          = state,
			will_renew     = api.Product_SubscriptionInfo_RenewalInfo_will_auto_renew(renewal.value),
			starts_at      = starts_at,
			paid_until     = paid_until,
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
