#+test
#+build darwin arm64
#+vet tabs style semicolon
package darwin_StoreKit

import "core:testing"

when AVAILABLE {
	@(test)
	test_parse_offer_period :: proc(t: ^testing.T) {
		examples := [?]struct {text: string, period: Billing_Interval}{
			{"P3D", {3, .Day}},
			{"P1W", {1, .Week}},
			{"P2M", {2, .Month}},
			{"P12Y", {12, .Year}},
			{"P9223372036854775807D", {max(int), .Day}},
		}
		for example in examples {
			period, ok := parse_offer_period(example.text)
			testing.expect(t, ok && period == example.period)
		}
		invalid := [?]string{"", "P", "1M", "P0D", "P+1W", "P1_0D", "P2Q", "P1M2D", "PT1M", "P9223372036854775808D"}
		for text in invalid {
			_, ok := parse_offer_period(text)
			testing.expect(t, !ok)
		}
	}
}
