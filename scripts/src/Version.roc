Version := [].{
	semantic = |value|
		match Str.split_on(value, ".") {
			[major, minor, patch] => [major, minor, patch].all(nonempty_digits)
			_ => Bool.False
		}

	nightly = |value|
		match Str.split_on(value, "-") {
			["nightly", year, month, day, revision] =>
				year.to_utf8().len() == 4
					and month.to_utf8().len() == 2
						and day.to_utf8().len() == 2
							and [year, month, day].all(nonempty_digits)
								and revision.to_utf8().len() >= 7
									and revision.to_utf8().len() <= 40
										and revision.to_utf8().all(lower_hex_digit)
			_ => Bool.False
		}

	native_release = |value| {
		prefix = "native-libs-v"
		starts_with(value, prefix) and Version.semantic(Str.from_utf8_lossy(value.to_utf8().drop_first(prefix.to_utf8().len())))
	}
}

nonempty_digits = |value| !value.is_empty() and value.to_utf8().all(|byte| byte >= '0' and byte <= '9')

lower_hex_digit = |byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f')

starts_with = |value, prefix| value.to_utf8().take_first(prefix.to_utf8().len()) == prefix.to_utf8()

expect !Version.semantic("1.2")
expect !Version.nightly("nightly-main")
expect Version.native_release("native-libs-v1.2.3")
