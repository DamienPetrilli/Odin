#+vet tabs style semicolon
package test_core_text_i18n

import "core:testing"
import "core:text/i18n"

@(test)
test_mo_contextual_plurals :: proc(t: ^testing.T) {
	catalog, err := i18n.parse_mo(#load("../../assets/I18N/contextual_plurals.mo"))
	defer i18n.destroy(catalog)

	if !testing.expect_value(t, err, i18n.Error.None) {
		return
	}

	cases := [?]Test{
		{"A", "item", "A item", 1},
		{"A", "item", "A items", 2},
		{"A", "items", "A item", 1},
		{"A", "items", "A items", 2},
		{"B", "item", "B item", 1},
		{"B", "item", "B items", 2},
		{"B", "items", "B item", 1},
		{"B", "items", "B items", 2},
		{"", "item", "item", 2},
		{"", "items", "items", 2},
	}

	for c in cases {
		value := i18n.get_n(c.section, c.key, c.n, catalog)
		testing.expect_value(t, value, c.val)
	}

	testing.expect_value(t, i18n.get("plain", catalog), "Plain translation")
}

@(test)
test_mo_contextual_plurals_merge_sections :: proc(t: ^testing.T) {
	catalog, err := i18n.parse_mo(
		#load("../../assets/I18N/contextual_plurals.mo"),
		options = {merge_sections = true},
	)
	defer i18n.destroy(catalog)

	testing.expect_value(t, err, i18n.Error.Duplicate_Key)
}
