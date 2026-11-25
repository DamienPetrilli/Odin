#+build darwin arm64
#+vet tabs style semicolon
package darwin_StoreKit

import swift "core:sys/darwin/Swift"
foreign import api "swift:StoreKit"

when AVAILABLE {
	Task         :: swift.Task
	task_retain  :: swift.task_retain
	task_release :: swift.task_release
	task_cancel  :: swift.task_cancel

	Error                    :: api.Call_Error
	Error_copy               :: api.Call_Error_copy
	Error_destroy            :: api.Call_Error_destroy
	Unknown_Error            :: swift.Unknown_Error
	Error_Conversion_Failed  :: swift.Error_Conversion_Failed
	Result_Conversion_Failed :: swift.Result_Conversion_Failed
	error_type_name          :: swift.error_type_name
	error_description        :: swift.error_description

	Product               :: api.Product
	Product_is_family_shareable :: api.Product_is_family_shareable
	Product_copy          :: api.Product_copy
	Product_destroy       :: api.Product_destroy
	// Each successful string getter returns an Odin string owned by the caller.
	Product_id            :: api.Product_id
	Product_display_name  :: api.Product_display_name
	Product_description   :: api.Product_description
	Product_display_price :: api.Product_display_price

	// StoreKit uses an open, string-backed type. Unknown includes product types
	// introduced by newer SDKs. A failed getter returns ok = false.
	Product_Type :: enum {
		Unknown,
		Consumable,
		Non_Consumable,
		Non_Renewing_Subscription,
		Auto_Renewable_Subscription,
	}

	@(private)
	take_product_type :: proc(native: api.Product_ProductType) -> (kind: Product_Type, ok: bool) {
		defer api.Product_ProductType_destroy(native)
		raw := api.Product_ProductType_raw_value(native) or_return
		defer delete(raw)
		switch raw {
		case "Consumable":                  return .Consumable, true
		case "Non-Consumable":              return .Non_Consumable, true
		case "Non-Renewing Subscription":   return .Non_Renewing_Subscription, true
		case "Auto-Renewable Subscription": return .Auto_Renewable_Subscription, true
		}
		return .Unknown, true
	}

	@(require_results)
	Product_type :: proc(product: Product) -> (kind: Product_Type, ok: bool) #optional_ok {
		native := api.Product_type(product) or_return
		return take_product_type(native)
	}

	// The callback owns the product slice and its elements. Free the slice on its
	// own when transferring its elements elsewhere, or use products_destroy.
	products :: api.Product_products

	products_destroy :: proc(items: []Product, allocator := context.allocator) {
		api.Array_Product_destroy(items, allocator)
	}

	Purchase_Option         :: api.Product_PurchaseOption
	Purchase_Option_destroy :: api.Product_PurchaseOption_destroy
	app_account_token       :: api.Product_PurchaseOption_app_account_token

	// StoreKit accepts 1 through 10 units per purchase. The caller owns the option.
	@(require_results)
	purchase_quantity :: proc(units: int) -> (option: Purchase_Option, ok: bool) #optional_ok {
		if units < 1 || units > 10 { return nil, false }
		return api.Product_PurchaseOption_quantity(units)
	}

	Purchase_Error                          :: api.Product_PurchaseError
	Purchase_Error_Invalid_Quantity         :: api.Product_PurchaseError_InvalidQuantity
	Purchase_Error_Product_Unavailable      :: api.Product_PurchaseError_ProductUnavailable
	Purchase_Error_Purchase_Not_Allowed     :: api.Product_PurchaseError_PurchaseNotAllowed
	Purchase_Error_Ineligible_For_Offer     :: api.Product_PurchaseError_IneligibleForOffer
	Purchase_Error_Invalid_Offer_Identifier :: api.Product_PurchaseError_InvalidOfferIdentifier
	Purchase_Error_Invalid_Offer_Price      :: api.Product_PurchaseError_InvalidOfferPrice
	Purchase_Error_Invalid_Offer_Signature  :: api.Product_PurchaseError_InvalidOfferSignature
	Purchase_Error_Missing_Offer_Parameters :: api.Product_PurchaseError_MissingOfferParameters
	Purchase_Error_Unknown                  :: api.Product_PurchaseError_Unknown

	Purchase_Result         :: api.Product_PurchaseResult
	Purchase_Result_destroy :: api.Product_PurchaseResult_destroy
	Purchase_Success        :: api.Product_PurchaseResult_Success
	Purchase_Pending        :: api.Product_PurchaseResult_Pending
	Purchase_Cancelled      :: api.Product_PurchaseResult_UserCancelled
	Purchase_Unknown        :: api.Product_PurchaseResult_Unknown

	// The presentation argument is the window scene on iOS and the view
	// controller on macOS. A submitted request awaits the App Store's decision.
	request_refund        :: api.Transaction_begin_refund_request_for__in_
	Refund_Result         :: api.Transaction_RefundRequestStatus
	Refund_Result_destroy :: api.Transaction_RefundRequestStatus_destroy
	Refund_Submitted      :: api.Transaction_RefundRequestStatus_Success
	Refund_Cancelled      :: api.Transaction_RefundRequestStatus_UserCancelled
	Refund_Unknown        :: api.Transaction_RefundRequestStatus_Unknown

	Refund_Error         :: api.Transaction_RefundRequestError
	Refund_Duplicate     :: api.Transaction_RefundRequestError_DuplicateRequest
	Refund_Failed        :: api.Transaction_RefundRequestError_Failed
	Refund_Error_Unknown :: api.Transaction_RefundRequestError_Unknown

	can_make_payments :: api.AppStore_can_make_payments
	restore           :: api.AppStore_sync

	Verification         :: api.VerificationResult_Transaction
	// The caller owns the compact signed text and releases it with delete.
	Verification_jws     :: api.VerificationResult_Transaction_jws_representation
	Verification_copy    :: api.VerificationResult_Transaction_copy
	Verification_destroy :: api.VerificationResult_Transaction_destroy
	Verified             :: api.VerificationResult_Transaction_Verified
	Unverified           :: api.VerificationResult_Transaction_Unverified

	Verification_Error                     :: api.VerificationResult_Transaction_VerificationError
	Verification_RevokedCertificate        :: api.VerificationResult_Transaction_VerificationError_RevokedCertificate
	Verification_InvalidCertificateChain   :: api.VerificationResult_Transaction_VerificationError_InvalidCertificateChain
	Verification_InvalidDeviceVerification :: api.VerificationResult_Transaction_VerificationError_InvalidDeviceVerification
	Verification_InvalidEncoding           :: api.VerificationResult_Transaction_VerificationError_InvalidEncoding
	Verification_InvalidSignature          :: api.VerificationResult_Transaction_VerificationError_InvalidSignature
	Verification_MissingRequiredProperties :: api.VerificationResult_Transaction_VerificationError_MissingRequiredProperties
	Verification_Unknown                   :: api.VerificationResult_Transaction_VerificationError_Unknown

	// Both fields borrow their storage from the verification.
	unverified_details :: proc(item: Unverified) -> (transaction: Transaction, reason: Verification_Error) {
		return item.value_0, item.value_1
	}

	Transaction                        :: api.Transaction
	Transaction_copy                   :: api.Transaction_copy
	Transaction_destroy                :: api.Transaction_destroy
	Transaction_id                     :: api.Transaction_id
	Transaction_product_id             :: api.Transaction_product_id
	Transaction_app_account_token      :: api.Transaction_app_account_token
	Transaction_purchase_date          :: api.Transaction_purchase_date
	Transaction_original_purchase_date :: api.Transaction_original_purchase_date
	Transaction_expiration_date        :: api.Transaction_expiration_date
	Transaction_revocation_date        :: api.Transaction_revocation_date
	Transaction_purchased_quantity     :: api.Transaction_purchased_quantity
	finish                             :: api.Transaction_finish

	// StoreKit uses an open integer code. Preserve new reasons from later OS releases.
	Revocation_Reason :: distinct int
	REVOCATION_OTHER           :: Revocation_Reason(0)
	REVOCATION_DEVELOPER_ISSUE :: Revocation_Reason(1)

	@(require_results)
	Transaction_revocation_reason :: proc(tx: Transaction) -> (reason: Maybe(Revocation_Reason), ok: bool) #optional_ok {
		if tx == nil { return nil, false }
		native := api.Transaction_revocation_reason(tx) or_return
		defer api.Optional_Transaction_RevocationReason_destroy(native)
		if value, present := native.?; present {
			return Revocation_Reason(api.Transaction_RevocationReason_raw_value(value)), true
		}
		return nil, true
	}

	// The caller owns the returned raw code, including values added by later systems.
	Ownership_Type :: distinct string
	OWNERSHIP_PURCHASED     :: Ownership_Type("PURCHASED")
	OWNERSHIP_FAMILY_SHARED :: Ownership_Type("FAMILY_SHARED")

	@(require_results)
	Transaction_ownership :: proc(tx: Transaction) -> (ownership: Ownership_Type, ok: bool) #optional_ok {
		if tx == nil { return "", false }
		native := api.Transaction_ownership_type(tx) or_return
		defer api.Transaction_OwnershipType_destroy(native)
		code := api.Transaction_OwnershipType_raw_value(native) or_return
		return Ownership_Type(code), true
	}

	// Classify a delivered or replayed transaction without fetching its product.
	@(require_results)
	Transaction_product_type :: proc(tx: Transaction) -> (kind: Product_Type, ok: bool) #optional_ok {
		native := api.Transaction_product_type(tx) or_return
		return take_product_type(native)
	}
}
