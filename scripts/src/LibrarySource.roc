## Where generated platform libraries come from.
LibrarySource := [Release, Source].{
	default : LibrarySource
	default = Release

	## Parse the user-facing CLI value once, before build orchestration begins.
	parse = |value|
		match value {
			"release" => Ok(Release)
			"source" => Ok(Source)
			other => Err(UnknownLibrarySource(other))
		}

	to_str = |self|
		match self {
			Release => "release"
			Source => "source"
		}

	is_eq = |left, right| match (left, right) {
		(Release, Release) | (Source, Source) => Bool.True
		_ => Bool.False
	}
}

expect LibrarySource.(Release) == LibrarySource.(Release)
expect LibrarySource.(Source) == LibrarySource.(Source)
expect LibrarySource.(Release) != LibrarySource.(Source)
expect LibrarySource.(Source) != LibrarySource.(Release)
expect LibrarySource.parse("release") == Ok(Release)
expect match LibrarySource.parse("local") {
	Err(_) => Bool.True
	Ok(_) => Bool.False
}
