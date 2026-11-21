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
	Product_copy          :: api.Product_copy
	Product_destroy       :: api.Product_destroy
	// Each successful string getter returns an Odin string owned by the caller.
	Product_id            :: api.Product_id
	Product_display_name  :: api.Product_display_name
	Product_description   :: api.Product_description
	Product_display_price :: api.Product_display_price

	// The callback owns the product slice and its elements. Free the slice on its
	// own when transferring its elements elsewhere, or use products_destroy.
	products :: api.Product_products

	products_destroy :: proc(items: []Product, allocator := context.allocator) {
		for item in items { Product_destroy(item) }
		delete(items, allocator)
	}

	Purchase_Option         :: api.Product_PurchaseOption
	Purchase_Option_destroy :: api.Product_PurchaseOption_destroy
	app_account_token       :: api.Product_PurchaseOption_app_account_token

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

	can_make_payments :: api.AppStore_can_make_payments
	restore           :: api.AppStore_sync

	Verification         :: api.VerificationResult_Transaction
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
	finish                             :: api.Transaction_finish
}
