// Link-only consumer. The test does not initiate a payment.
package storekit_import_test

import sk "vendor:darwin/StoreKit"

loaded :: proc(task: sk.Task, products: []sk.Product, err: sk.Error) {
	defer sk.Error_destroy(err)
	defer sk.products_destroy(products)
	if purchase_err, ok := err.(sk.Purchase_Error); ok {
		_, _ = purchase_err.(sk.Purchase_Error_Product_Unavailable)
	}
	for product in products {
		_ = sk.Product_is_family_shareable(product)
		kind := sk.Product_type(product) or_continue
		if kind == .Auto_Renewable_Subscription {
			interval := sk.Product_subscription_period(product) or_continue
			assert(interval.count > 0)
			terms := sk.Product_introductory_offer(product) or_continue
			if offer, present := terms.?; present {
				defer delete(offer.display_price)
				assert(offer.period_count > 0)
				group := sk.subscription_group_id(product) or_continue
				defer delete(group)
				eligibility := sk.eligible_for_intro_offer(group, eligibility_received) or_continue
				sk.task_release(eligibility)
			}
		}
		if kind == .Consumable {
			option := sk.purchase_quantity(2) or_continue
			sk.Purchase_Option_destroy(option)
		}
		name := sk.Product_display_name(product) or_continue
		defer delete(name)
		description := sk.Product_description(product) or_continue
		defer delete(description)
		_, currency := sk.price_and_currency(product) or_continue
		defer delete(currency)
	}
}

eligibility_received :: proc(_: sk.Task, _: bool) {}

refund_completed :: proc(_: sk.Task, result: sk.Refund_Result, err: sk.Error) {
	defer sk.Refund_Result_destroy(result)
	defer sk.Error_destroy(err)
}

scan_item :: proc(_: ^sk.Transaction_Scan, item: sk.Verification) {
	if tx, ok := item.(sk.Verified); ok {
		code, converted := sk.Transaction_ownership(tx.value)
		if !converted { return }
		defer delete(string(code))
	}
}

scan_closed :: proc(_: ^sk.Transaction_Scan, _: sk.Listener_End) {}

store_changed :: proc(_: ^sk.Storefront_Watch, store: sk.Storefront) {
	id, country, ok := sk.storefront_details(store)
	if !ok { return }
	defer delete(id)
	defer delete(country)
}

watch_closed :: proc(_: ^sk.Storefront_Watch, _: sk.Listener_End) {}

subscription_changed :: proc(_: ^sk.Subscription_Watch, status: sk.Subscription_Status) {
	_, _ = sk.subscription_period(status)
}

subscription_closed :: proc(_: ^sk.Subscription_Watch, _: sk.Listener_End) {}

main :: proc() {
	kind, classified := sk.Product_type(nil)
	assert(!classified && kind == .Unknown)
	kind, classified = sk.Transaction_product_type(nil)
	assert(!classified && kind == .Unknown)
	when (ODIN_PLATFORM_SUBTARGET == .Default && ODIN_MINIMUM_OS_VERSION >= 15_02_00) ||
	     (ODIN_PLATFORM_SUBTARGET != .Default && ODIN_MINIMUM_OS_VERSION >= 18_02_00) {
		callback :: proc(_: sk.Task, _: sk.Purchase_Result, _: sk.Error) {
			panic("A failed purchase start cannot complete")
		}
		purchase, confirmed := sk.purchase_confirm_in(nil, nil, callback)
		assert(!confirmed && purchase == nil)
		purchase, confirmed = sk.purchase_confirm_in(nil, nil, nil, callback)
		assert(!confirmed && purchase == nil)
	}
	watch: sk.Storefront_Watch
	assert(!sk.watch_storefront(nil, store_changed, watch_closed))
	assert(!sk.watch_storefront(&watch, nil, watch_closed))
	sk.stop_storefront_watch(&watch)
	subscriptions: sk.Subscription_Watch
	assert(!sk.watch_subscriptions(nil, subscription_changed, subscription_closed))
	assert(!sk.watch_subscriptions(&subscriptions, nil, subscription_closed))
	assert(!sk.watch_subscriptions(&subscriptions, subscription_changed, nil))
	sk.stop_subscription_watch(&subscriptions)
	_, verified := sk.subscription_period(nil)
	assert(!verified)
	offer, read := sk.Product_introductory_offer(nil)
	assert(!read && offer == nil)
	id, country, has_store := sk.storefront_details(nil)
	assert(!has_store && id == "" && country == "")
	_, code, priced := sk.price_and_currency(nil)
	assert(!priced && code == "")
	scan: sk.Transaction_Scan
	assert(!sk.scan_transactions(nil, .History, "sample", scan_item, scan_closed))
	sk.stop_scan(&scan)
	_, refund_started := sk.request_refund(0, nil, refund_completed)
	assert(!refund_started)
	reason, converted := sk.Transaction_revocation_reason(nil)
	assert(!converted && reason == nil)
	current, renewal, ok := sk.subscription_products(nil)
	assert(!ok && current == "" && renewal == nil)
	period := sk.Non_Renewing_Period{starts_at = 10, expires_at = 20}
	assert(sk.non_renewing_active(period, 10))
	assert(!sk.non_renewing_active(period, 20))
	assert(!sk.non_renewing_active({}))
	p := sk.Subscription_Period{will_renew = false, starts_at = 10, access_until = 20}
	assert(!sk.subscription_active(p, 9))
	assert(sk.subscription_active(p, 10))
	assert(sk.subscription_active(p, 19))
	assert(!sk.subscription_active(p, 20))
	if sk.can_make_payments() {
		if task, started := sk.products(nil, loaded); started {
			sk.task_release(task)
		}
	}
}
