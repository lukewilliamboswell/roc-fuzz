Version := [].{
	semantic = |value|
		match Str.split_on(value, ".") {
			[major, minor, patch] => [major, minor, patch].all(nonempty_digits)
			_ => Bool.False
		}

	## The version a pull request's release dry run uses. Roc rejects `0.0.0`
	## in a package URL.
	dry_run = "0.0.1-dry-run"

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

}

nonempty_digits = |value| !value.is_empty() and value.to_utf8().all(|byte| byte >= '0' and byte <= '9')

lower_hex_digit = |byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f')

expect !Version.semantic("1.2")
expect !Version.nightly("nightly-main")
