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
}

expect LibrarySource.parse("release") == Ok(Release)
expect match LibrarySource.parse("local") {
	Err(_) => Bool.True
	Ok(_) => Bool.False
}
