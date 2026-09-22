import Version

## Validated identities used across repository automation. Raw strings should be
## converted at JSON/CLI boundaries and unwrapped only for serialization or a
## subprocess argument.
Identity := [].{
	Sha256 :: Str.{
		parse = |value| if is_lower_hex(value, 64) Ok(Sha256.(value)) else Err(InvalidSha256(value))
		to_str = |Sha256.(value)| value
		is_eq = |Sha256.(left), Sha256.(right)| left == right
	}

	GitRevision :: Str.{
		parse = |value| if is_lower_hex(value, 40) Ok(GitRevision.(value)) else Err(InvalidGitRevision(value))
		to_str = |GitRevision.(value)| value
		is_eq = |GitRevision.(left), GitRevision.(right)| left == right
	}

	NativeRelease :: Str.{
		parse = |value| if Version.native_release(value) Ok(NativeRelease.(value)) else Err(InvalidNativeRelease(value))
		to_str = |NativeRelease.(value)| value
		is_eq = |NativeRelease.(left), NativeRelease.(right)| left == right
	}

	Repository :: Str.{
		parse = |value|
			match Str.split_on(value, "/") {
				[owner, name] if !owner.is_empty() and !name.is_empty() => Ok(Repository.(value))
				_ => Err(InvalidRepository(value))
			}
		to_str = |Repository.(value)| value
		is_eq = |Repository.(left), Repository.(right)| left == right
	}
}

is_lower_hex = |value, length| {
	bytes = value.to_utf8()
	bytes.len() == length and bytes.all(|byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))
}

expect Identity.Sha256.parse("xyz") |> Try.is_err
expect Identity.GitRevision.parse("0123456789012345678901234567890123456789") |> Try.is_ok
expect Identity.Repository.parse("owner/project/extra") |> Try.is_err
