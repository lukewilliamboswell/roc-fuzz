## A validated semantic version for an immutable release candidate.
ReleaseCandidate :: Str.{
	parse = |value|
		match Str.split_on(value, "-rc") {
			[base, rc] if valid_positive(rc) => if Str.split_on(base, ".").len() == 3 and Str.split_on(base, ".").all(valid_component) {
				Ok(ReleaseCandidate.(value))
			} else {
				Err(InvalidReleaseCandidateVersion(value))
			}
			_ => Err(InvalidReleaseCandidateVersion(value))
		}

	to_str = |ReleaseCandidate.(value)| value
}

valid_component = |value| value == "0" or (valid_positive(value) and !starts_with(value, "0"))

starts_with = |value, prefix| value.to_utf8().take_first(prefix.to_utf8().len()) == prefix.to_utf8()

valid_positive = |value| match U64.from_str(value) {
	Ok(number) => number > 0
	Err(_) => Bool.False
}

expect ReleaseCandidate.parse("1.2.3-rc4") |> Try.is_ok
expect ReleaseCandidate.parse("1.2.3") |> Try.is_err
