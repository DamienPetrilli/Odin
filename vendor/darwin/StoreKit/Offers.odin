#+build darwin arm64
#+vet tabs style semicolon
package darwin_StoreKit

import "core:mem"
import swift "core:sys/darwin/Swift"
foreign import api "swift:StoreKit"

when AVAILABLE {
	// These are signed transaction fields. A regular purchase has no offer.
	Redeemed_Offer_Kind :: enum u8 { Unknown, Introductory, Promotional, Code, Win_Back }
	Redeemed_Offer_Mode :: enum u8 { Unknown, Free_Trial, Pay_As_You_Go, Pay_Up_Front, One_Time }
	Redeemed_Offer :: struct {
		kind: Redeemed_Offer_Kind,
		mode: Maybe(Redeemed_Offer_Mode),
		id:   Maybe(string),
	}

	@(private)
	redeemed_kind :: proc(value: api.Transaction_OfferType) -> Redeemed_Offer_Kind {
		switch api.Transaction_OfferType_raw_value(value) {
		case 1: return .Introductory
		case 2: return .Promotional
		case 3: return .Code
		case 4: return .Win_Back
		}
		return .Unknown
	}

	@(private)
	redeemed_mode :: proc(code: string) -> Redeemed_Offer_Mode {
		switch code {
		case "FREE_TRIAL":    return .Free_Trial
		case "PAY_AS_YOU_GO": return .Pay_As_You_Go
		case "PAY_UP_FRONT":  return .Pay_Up_Front
		case "ONE_TIME":      return .One_Time
		}
		return .Unknown
	}

	// Returns the offer that StoreKit recorded for this transaction. The caller
	// owns a present id. A successful empty result means no offer was applied.
	@(require_results)
	Transaction_offer :: proc(tx: Transaction) -> (offer: Maybe(Redeemed_Offer), ok: bool) #optional_ok {
		if tx == nil { return nil, false }
		caller := context.allocator
		buffer: [512]byte = ---
		arena := mem.Arena{data = buffer[:]}
		allocators := [2]mem.Allocator{swift.value_arena_allocator(&arena), caller}
		for scratch, attempt in allocators {
			context.allocator = scratch
			terms: Redeemed_Offer
			when #defined(api.Transaction_offer) {
				item := api.Transaction_offer(tx) or_continue
				defer api.Optional_Transaction_Offer_destroy(item)
				value, present := item.?
				if !present { return nil, true }
				kind := api.Transaction_Offer_type(value) or_continue
				defer api.Transaction_OfferType_destroy(kind)
				mode := api.Transaction_Offer_payment_mode(value) or_continue
				defer api.Optional_Transaction_Offer_PaymentMode_destroy(mode)
				if payment, provided := mode.?; provided {
					code := api.Transaction_Offer_PaymentMode_raw_value(payment) or_continue
					defer if attempt != 0 { delete(code) }
					terms.mode = redeemed_mode(code)
				}
				terms.kind = redeemed_kind(kind)
				{
					context.allocator = caller
					terms.id = api.Transaction_Offer_id(value) or_return
				}
			} else {
				item := api.Transaction_offer_type(tx) or_continue
				defer api.Optional_Transaction_OfferType_destroy(item)
				kind, present := item.?
				if !present { return nil, true }
				mode := api.Transaction_offer_payment_mode_string_representation(tx) or_continue
				if code, provided := mode.?; provided {
					defer if attempt != 0 { delete(code) }
					terms.mode = redeemed_mode(code)
				}
				terms.kind = redeemed_kind(kind)
				{
					context.allocator = caller
					terms.id = api.Transaction_offer_id(tx) or_return
				}
			}
			return terms, true
		}
		return nil, false
	}
}
