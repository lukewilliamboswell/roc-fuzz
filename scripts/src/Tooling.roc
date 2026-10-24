## What Blueprint.roc says about the tooling environment, read as text. The
## check script holds every script header to these values, so Blueprint.roc
## stays the one place where the tooling compiler and its bundles are chosen.
Tooling := [].{

	## The release tag in `Command("roc-stable", "nix#rocpkgs.<tag>")`.
	stable_tag = |blueprint|
		match Str.split_on(blueprint, "Command(\"roc-stable\", \"nix#rocpkgs.") {
			[_, rest] => match Str.split_on(rest, "\"") {
				[tag, ..] if !tag.is_empty() => Ok(tag)
				_ => Err(MissingToolingCompiler)
			}
			_ => Err(MissingToolingCompiler)
		}

	## Every bundle URL listed under `RocPackages([...])`.
	roc_packages = |blueprint|
		match Str.split_on(blueprint, "RocPackages([") {
			[_, rest] => match Str.split_on(rest, "])") {
				[listed, ..] => {
					var $urls = []
					for line in Str.split_on(listed, "\n") {
						match Str.split_on(line, "\"") {
							[indent, url, ..] if !indent.contains("#") and !url.is_empty() => {
								$urls = $urls.append(url)
							}
							_ => {}
						}
					}
					Ok($urls)
				}
				_ => Err(MissingRocPackages)
			}
			_ => Err(MissingRocPackages)
		}

	## The bundle URLs an application header names, in order.
	header_urls = |source|
		match Str.split_on(source, "}") {
			[header, ..] => Str.split_on(header, "\"").keep_if(|part| Str.split_on(part, "https://").len() == 2 and Str.split_on(part, "\n").len() == 1)
			_ => []
		}
}

sample = "app [config] { pf: platform \"https://example.org/blueprint.tar.zst\" }\nconfig = [\n\tEnvironment(\"dev\", [\n\t\tCommand(\"roc-stable\", \"nix#rocpkgs.nightly-2026-09-29-7f11a82\"),\n\t\t# A comment that mentions \"https://example.org/ignored.tar.zst\".\n\t\tRocPackages([\n\t\t\t\"https://example.org/one.tar.zst\",\n\t\t\t# \"https://example.org/commented.tar.zst\",\n\t\t\t\"https://example.org/two.tar.zst\",\n\t\t]),\n\t]),\n]\n"

expect Tooling.stable_tag(sample) == Ok("nightly-2026-09-29-7f11a82")
expect Tooling.stable_tag("config = []") == Err(MissingToolingCompiler)
expect Tooling.roc_packages(sample) == Ok(["https://example.org/one.tar.zst", "https://example.org/two.tar.zst"])
expect Tooling.roc_packages("config = []") == Err(MissingRocPackages)
expect Tooling.header_urls("app [main!] {\n\tcli: platform \"https://example.org/one.tar.zst\",\n\troc: \"nightly-2026-09-29-7f11a82\",\n}\nvalue = \"https://example.org/body\"\n") == ["https://example.org/one.tar.zst"]
