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

main :: proc() {
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
