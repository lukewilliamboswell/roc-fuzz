## Source-preserving rewrites for temporary copies of Roc applications.
RocSource := [].{
	replace_platform = |source, url|
		match Str.split_on(source, "platform \"") {
			[before, after] => match Str.split_on(after, "\"") {
				[_, .. as rest] => Ok("${before}platform \"${url}\"${Str.join_with(rest, "\"")}")
				_ => Err(MalformedPlatformDeclaration)
			}
			_ => Err(MissingPlatformDeclaration)
		}

	replace_platform_if_present = |source, url|
		if source.contains("platform \"") {
			match RocSource.replace_platform(source, url) {
				Ok(updated) => Ok(Updated(updated))
				Err(err) => Err(err)
			}
		} else {
			Ok(Unchanged)
		}
}

expect RocSource.replace_platform("app [x] { p: platform \"old\" }", "new") == Ok("app [x] { p: platform \"new\" }")
