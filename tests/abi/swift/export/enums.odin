package export_fixture

Mode :: enum u32 {
	Idle    = 10,
	Running = 20,
}

Single_Case :: enum i64 { Only = -17 }
Signed_Code :: enum i64 { Low = min(i64), Middle = -37, High = max(i64) }
Unsigned_Code :: enum u64 { High = max(u64), Low = 0, Middle = 1 << 63 }
Small_Code :: enum i8 { Low = -128, High = 127 }
Medium_Code :: enum u16 { First = 511, Second = 17, Third = 65535 }
Signed_Short :: enum i16 { Low = -32768, High = 32767 }
Signed_Int :: enum i32 { Low = min(i32), High = max(i32) }
Native_Unsigned :: enum uint { Low = 0, High = max(uint) }
Default_Code :: enum { First = -1, Second = 42 }
Keyword_Code :: enum u8 { Default = 7, Switch = 11, Any = 12 }

@(export)
toggle_mode :: proc "swift" (value: Mode) -> Mode {
	if value == .Idle { return .Running }
	return .Idle
}

@(export)
mode_raw :: proc "swift" (value: Mode) -> u64 { return u64(value) }

@(export)
make_mode :: proc "swift" () -> Mode { return .Running }

@(export)
local_mode :: proc "swift" () -> Mode {
	// Calling the original procedure from Odin uses Odin's raw values.
	return toggle_mode(.Running)
}

@(export)
echo_single :: proc "swift" (value: Single_Case) -> Single_Case { return value }

@(export)
single_arguments :: proc "swift" (_: Single_Case, a: u64, _: Single_Case, b: f64, _: Single_Case) -> f64 {
	return f64(a) + b
}

@(export)
echo_signed :: proc "swift" (value: Signed_Code) -> Signed_Code { return value }

@(export)
echo_unsigned :: proc "swift" (value: Unsigned_Code) -> Unsigned_Code { return value }

@(export)
echo_small :: proc "swift" (value: Small_Code) -> Small_Code { return value }

@(export)
echo_medium :: proc "swift" (value: Medium_Code) -> Medium_Code { return value }

@(export)
echo_default :: proc "swift" (value: Default_Code) -> Default_Code { return value }

@(export)
echo_keyword :: proc "swift" (value: Keyword_Code) -> Keyword_Code { return value }

@(export)
modify_with_mode :: proc "swift" (mode: Mode, values: []u64, _: Single_Case, delta: u64) -> Mode {
	for &value in values { value += delta + u64(mode) }
	return toggle_mode(mode)
}

@(export)
mode_and_record :: proc "swift" (value: Reading, mode: Mode) -> Reading {
	return Reading{value.page + i64(mode), value.progress + 0.5}
}

@(export)
mode_and_large :: proc "swift" (mode: Mode, value: Large_Value) -> Large_Value {
	result := value
	result.e += u64(mode)
	return result
}

@(export)
invalid_mode :: proc "swift" () -> Mode { return Mode(11) }

@(export)
invalid_single :: proc "swift" () -> Single_Case { return Single_Case(0) }

Wide_Code :: enum u64 {
	Case_0 = 1000, Case_1 = 1003, Case_2 = 1006, Case_3 = 1009, Case_4 = 1012, Case_5 = 1015,
	Case_6 = 1018, Case_7 = 1021, Case_8 = 1024, Case_9 = 1027, Case_10 = 1030, Case_11 = 1033,
	Case_12 = 1036, Case_13 = 1039, Case_14 = 1042, Case_15 = 1045, Case_16 = 1048, Case_17 = 1051,
	Case_18 = 1054, Case_19 = 1057, Case_20 = 1060, Case_21 = 1063, Case_22 = 1066, Case_23 = 1069,
	Case_24 = 1072, Case_25 = 1075, Case_26 = 1078, Case_27 = 1081, Case_28 = 1084, Case_29 = 1087,
	Case_30 = 1090, Case_31 = 1093, Case_32 = 1096, Case_33 = 1099, Case_34 = 1102, Case_35 = 1105,
	Case_36 = 1108, Case_37 = 1111, Case_38 = 1114, Case_39 = 1117, Case_40 = 1120, Case_41 = 1123,
	Case_42 = 1126, Case_43 = 1129, Case_44 = 1132, Case_45 = 1135, Case_46 = 1138, Case_47 = 1141,
	Case_48 = 1144, Case_49 = 1147, Case_50 = 1150, Case_51 = 1153, Case_52 = 1156, Case_53 = 1159,
	Case_54 = 1162, Case_55 = 1165, Case_56 = 1168, Case_57 = 1171, Case_58 = 1174, Case_59 = 1177,
	Case_60 = 1180, Case_61 = 1183, Case_62 = 1186, Case_63 = 1189, Case_64 = 1192, Case_65 = 1195,
	Case_66 = 1198, Case_67 = 1201, Case_68 = 1204, Case_69 = 1207, Case_70 = 1210, Case_71 = 1213,
	Case_72 = 1216, Case_73 = 1219, Case_74 = 1222, Case_75 = 1225, Case_76 = 1228, Case_77 = 1231,
	Case_78 = 1234, Case_79 = 1237, Case_80 = 1240, Case_81 = 1243, Case_82 = 1246, Case_83 = 1249,
	Case_84 = 1252, Case_85 = 1255, Case_86 = 1258, Case_87 = 1261, Case_88 = 1264, Case_89 = 1267,
	Case_90 = 1270, Case_91 = 1273, Case_92 = 1276, Case_93 = 1279, Case_94 = 1282, Case_95 = 1285,
	Case_96 = 1288, Case_97 = 1291, Case_98 = 1294, Case_99 = 1297, Case_100 = 1300, Case_101 = 1303,
	Case_102 = 1306, Case_103 = 1309, Case_104 = 1312, Case_105 = 1315, Case_106 = 1318, Case_107 = 1321,
	Case_108 = 1324, Case_109 = 1327, Case_110 = 1330, Case_111 = 1333, Case_112 = 1336, Case_113 = 1339,
	Case_114 = 1342, Case_115 = 1345, Case_116 = 1348, Case_117 = 1351, Case_118 = 1354, Case_119 = 1357,
	Case_120 = 1360, Case_121 = 1363, Case_122 = 1366, Case_123 = 1369, Case_124 = 1372, Case_125 = 1375,
	Case_126 = 1378, Case_127 = 1381, Case_128 = 1384, Case_129 = 1387, Case_130 = 1390, Case_131 = 1393,
	Case_132 = 1396, Case_133 = 1399, Case_134 = 1402, Case_135 = 1405, Case_136 = 1408, Case_137 = 1411,
	Case_138 = 1414, Case_139 = 1417, Case_140 = 1420, Case_141 = 1423, Case_142 = 1426, Case_143 = 1429,
	Case_144 = 1432, Case_145 = 1435, Case_146 = 1438, Case_147 = 1441, Case_148 = 1444, Case_149 = 1447,
	Case_150 = 1450, Case_151 = 1453, Case_152 = 1456, Case_153 = 1459, Case_154 = 1462, Case_155 = 1465,
	Case_156 = 1468, Case_157 = 1471, Case_158 = 1474, Case_159 = 1477, Case_160 = 1480, Case_161 = 1483,
	Case_162 = 1486, Case_163 = 1489, Case_164 = 1492, Case_165 = 1495, Case_166 = 1498, Case_167 = 1501,
	Case_168 = 1504, Case_169 = 1507, Case_170 = 1510, Case_171 = 1513, Case_172 = 1516, Case_173 = 1519,
	Case_174 = 1522, Case_175 = 1525, Case_176 = 1528, Case_177 = 1531, Case_178 = 1534, Case_179 = 1537,
	Case_180 = 1540, Case_181 = 1543, Case_182 = 1546, Case_183 = 1549, Case_184 = 1552, Case_185 = 1555,
	Case_186 = 1558, Case_187 = 1561, Case_188 = 1564, Case_189 = 1567, Case_190 = 1570, Case_191 = 1573,
	Case_192 = 1576, Case_193 = 1579, Case_194 = 1582, Case_195 = 1585, Case_196 = 1588, Case_197 = 1591,
	Case_198 = 1594, Case_199 = 1597, Case_200 = 1600, Case_201 = 1603, Case_202 = 1606, Case_203 = 1609,
	Case_204 = 1612, Case_205 = 1615, Case_206 = 1618, Case_207 = 1621, Case_208 = 1624, Case_209 = 1627,
	Case_210 = 1630, Case_211 = 1633, Case_212 = 1636, Case_213 = 1639, Case_214 = 1642, Case_215 = 1645,
	Case_216 = 1648, Case_217 = 1651, Case_218 = 1654, Case_219 = 1657, Case_220 = 1660, Case_221 = 1663,
	Case_222 = 1666, Case_223 = 1669, Case_224 = 1672, Case_225 = 1675, Case_226 = 1678, Case_227 = 1681,
	Case_228 = 1684, Case_229 = 1687, Case_230 = 1690, Case_231 = 1693, Case_232 = 1696, Case_233 = 1699,
	Case_234 = 1702, Case_235 = 1705, Case_236 = 1708, Case_237 = 1711, Case_238 = 1714, Case_239 = 1717,
	Case_240 = 1720, Case_241 = 1723, Case_242 = 1726, Case_243 = 1729, Case_244 = 1732, Case_245 = 1735,
	Case_246 = 1738, Case_247 = 1741, Case_248 = 1744, Case_249 = 1747, Case_250 = 1750, Case_251 = 1753,
	Case_252 = 1756, Case_253 = 1759, Case_254 = 1762, Case_255 = 1765, Case_256 = 1768,
}

@(export)
echo_wide :: proc "swift" (value: Wide_Code) -> Wide_Code { return value }

@(export)
wide_raw :: proc "swift" (value: Wide_Code) -> u64 { return u64(value) }

@(export)
echo_short :: proc "swift" (value: Signed_Short) -> Signed_Short { return value }

@(export)
echo_int :: proc "swift" (value: Signed_Int) -> Signed_Int { return value }

@(export)
echo_native_unsigned :: proc "swift" (value: Native_Unsigned) -> Native_Unsigned { return value }
