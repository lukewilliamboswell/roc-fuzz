#!/usr/bin/env roc-stable
app [main!] {
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
}

import cli.Path
import src/Files
import src/ReleaseCandidate
import src/Script
import src/Version

ReleaseBundle : { artifact_file : Str, name : Str, source_path : Str }

## Render the notes a release publishes as its body, from the AsciiDoc source in
## docs/releases/. The source cannot name its own bundle, whose URL holds a
## content hash that does not exist until the release builds it, so it writes
## `{platform-url}` and this script fills it in.
##
## A release renders `docs/releases/<version>.adoc`. A dry run has no version of
## its own, so it renders the highest version under docs/releases/, which fails
## a mistake in the notes being written on the pull request that makes it. When
## that version is the latest release there is nothing unreleased to render.
main! = |_args| {
	version = Script.env_str!("RELEASE_VERSION")?
	notes_path = Script.env_path!("RELEASE_NOTES_PATH")?
	bundles_path = Script.env_path!("RELEASE_BUNDLES_PATH")?
	repository = Script.env_str!("GITHUB_REPOSITORY")?
	previous = Script.env_str_or!("PREVIOUS_RELEASE_VERSION", "")?

	bundles : List(ReleaseBundle)
	bundles = Json.parse(Path.read_utf8!(bundles_path)?).map_err(|err| InvalidReleaseBundles(err))?
	bundle = match bundles {
		[single] => single
		_ => return Err(ExpectedOneReleaseBundle(bundles.len()))
	}
	compilers = compilers!()?

	if version == Version.dry_run {
		var $highest = Err(NoReleaseNotes)
		for path in Files.direct_files!("docs/releases")? {
			name = Path.filename(path).map_ok(Path.display).map_err(|_| InvalidReleaseNotePath(Path.display(path)))?
			if Script.ends_with(name, ".adoc") {
				candidate = Str.replace_each(name, ".adoc", "")
				key = order_key(candidate)?
				$highest = match $highest {
					Ok((_, best)) if !later(key, best) => $highest
					_ => Ok((candidate, key))
				}
			}
		}
		(highest, _) = $highest?
		if highest == previous {
			Path.write_utf8!(notes_path, "Dry run: ${highest} is the highest version under docs/releases/ and is already released, so there are no notes to render.\n")?
			return Script.pass!("Release notes dry run: ${highest} is already released")
		}
		rendered = render_release!(highest, repository, bundle.artifact_file, compilers)?
		Path.write_utf8!(notes_path, "Dry run: the notes for ${highest}, as a release of it would publish them.\n\n${rendered}")?
		Script.pass!("Release notes dry run: rendered ${highest}")
	} else {
		if !valid_release_version(version) {
			return Err(InvalidReleaseVersion(version))
		}
		Path.write_utf8!(notes_path, render_release!(version, repository, bundle.artifact_file, compilers)?)?
		Script.pass!("Release notes written to ${Path.display(notes_path)}")
	}
}

render_release! = |version, repository, artifact_file, compilers| {
	source_path = Path.utf8("docs/releases/${version}.adoc")
	Script.require_file!(source_path)?
	source = Path.read_utf8!(source_path)?
	expected_title = "= roc-fuzz ${version}"
	if Str.split_on(source, "\n").first().map_err(|_| EmptyReleaseNotes(version))? != expected_title {
		return Err(InvalidReleaseNoteTitle(expected_title))
	}
	# A reader meets a release through the URL they paste into a header.
	if !contains(source, "{platform-url}") {
		return Err(ReleaseNotesMustUsePlatformUrl(version))
	}
	release_root = "https://github.com/${repository}/releases/download/${version}"
	rendered = render(source, "${release_root}/${artifact_file}", "${release_root}/roc-fuzz-${version}.pdf")?
	bundle_url = "${release_root}/${artifact_file}"
	Ok("${rendered}\n\n[Download the complete release examples](${release_root}/roc-fuzz-examples-${version}.zip).\n\n${sbom_section(bundle_url)}\n${compilers}")
}

## The record of what a release was built and tested with. No header pin makes
## this statement, so the notes do.
compilers! = || {
	package_compiler = Script.trim(Str.from_utf8_lossy((Script.roc!()?).capture!(["version"], ".", [])?))
	tooling_compiler = Script.trim(Str.from_utf8_lossy((Script.roc_stable!()?).capture!(["version"], ".", [])?))
	Ok("## Compilers\n\n- Platform, examples and bundle: `${package_compiler}`\n- Repository tooling: `${tooling_compiler}`\n")
}

## Where the bundle's SBOM is, what it is, and what it does not establish.
sbom_section = |bundle_url|
	"## Software bill of materials\n\nThe bundle's SBOM sits beside it, bound to its SHA-256 and attested with it: [SPDX 3.0.1](${bundle_url}.spdx.json), [CycloneDX 1.7](${bundle_url}.cdx.json) and the [evidence manifest](${bundle_url}.sbom-manifest.json). It lists every member of the archive by digest, and the platform, libFuzzer, Zig runtime, musl and LLVM runtimes as components; Zig is a build dependency. It marks as incomplete which upstream sources each object file holds, and the compiler that ran `roc bundle`, which is named under Compilers.\n"

valid_release_version = |value| Version.semantic(value) or (ReleaseCandidate.parse(value) |> Try.is_ok)

## How release versions order: by major, minor and patch, and a release after
## its own candidates.
order_key : Str -> Try((U64, U64, U64, U64, U64), _)
order_key = |version| {
	(major, minor, patch) = base(version)?
	match Str.split_on(version, "-rc") {
		[_, number] => Ok((major, minor, patch, 0, U64.from_str(number)?))
		_ => Ok((major, minor, patch, 1, 0))
	}
}

later : (U64, U64, U64, U64, U64), (U64, U64, U64, U64, U64) -> Bool
later = |(a, b, c, d, e), (v, w, x, y, z)| a > v or (a == v and (b > w or (b == w and (c > x or (c == x and (d > y or (d == y and e > z)))))))

base = |version|
	match Str.split_on(Str.split_on(version, "-").first().map_err(|_| InvalidReleaseVersion(version))?, ".") {
		[major, minor, patch] => Ok((U64.from_str(major)?, U64.from_str(minor)?, U64.from_str(patch)?))
		_ => Err(InvalidReleaseVersion(version))
	}

expect later(order_key("0.5.0") ?? (0, 0, 0, 0, 0), order_key("0.4.3") ?? (0, 0, 0, 0, 0))
expect later(order_key("0.5.0") ?? (0, 0, 0, 0, 0), order_key("0.5.0-rc2") ?? (0, 0, 0, 0, 0))
expect later(order_key("0.5.0-rc10") ?? (0, 0, 0, 0, 0), order_key("0.5.0-rc2") ?? (0, 0, 0, 0, 0))
expect !later(order_key("0.4.3") ?? (0, 0, 0, 0, 0), order_key("0.4.3") ?? (0, 0, 0, 0, 0))
expect !later(order_key("0.4.10") ?? (0, 0, 0, 0, 0), order_key("0.5.0") ?? (0, 0, 0, 0, 0))

render = |source, platform_url, manual_url| {
	lines = Str.split_on(source, "\n")
	converted = render_lines(lines, platform_url, manual_url, Normal, [])?
	result = Str.join_with(converted, "\n")
	if contains(result, "{platform-url}") or contains(result, "{manual-url}") {
		Err(UnresolvedReleaseUrl)
	} else {
		Ok(result)
	}
}

render_lines = |lines, platform_url, manual_url, state, output|
	match lines {
		[] => if (state == SourceBlock) Err(UnclosedSourceBlock) else Ok(output)
		[line, .. as rest] => {
			resolved = resolve_urls(line, platform_url, manual_url)
			match state {
				SourceBlock if line == "----" => render_lines(rest, platform_url, manual_url, Normal, output.append("```"))
				SourceBlock => render_lines(rest, platform_url, manual_url, SourceBlock, output.append(resolved))
				Normal =>
					match heading(resolved) {
						Ok(markdown) => render_lines(rest, platform_url, manual_url, Normal, output.append(markdown))
						Err(NotHeading) =>
							match source_language(line) {
								Ok(language) => match rest {
									["----", .. as body] => render_lines(body, platform_url, manual_url, SourceBlock, output.append("```${language}"))
									_ => Err(MissingSourceBlockDelimiter)
								}
								Err(NotSourceDeclaration) => render_lines(rest, platform_url, manual_url, Normal, output.append(resolved))
							}
					}
			}
		}
	}

heading = |line|
	match Str.split_on(line, "== ") {
		["", title] => Ok("## ${title}")
		_ => match Str.split_on(line, "= ") {
			["", title] => Ok("# ${title}")
			_ => Err(NotHeading)
		}
	}

source_language = |line|
	match Str.split_on(line, "[source,") {
		["", remainder] => match Str.split_on(remainder, "]") {
			[language, ""] if language != "" => Ok(language)
			_ => Err(NotSourceDeclaration)
		}
		_ => Err(NotSourceDeclaration)
	}

resolve_urls = |line, platform_url, manual_url|
	Str.replace_each(Str.replace_each(line, "{platform-url}", platform_url), "{manual-url}", manual_url)

contains = |value, needle| Str.split_on(value, needle).len() > 1

expect render(
	"= roc-fuzz 1.2.3\n\n== Use this release\n\n[source,roc]\n----\napp [target] { fuzz: platform \"{platform-url}\" }\n----\n\nManual: {manual-url}\n",
	"https://example.test/1.2.3/hash.tar.zst",
	"https://example.test/1.2.3/manual.pdf",
) == Ok(
	"# roc-fuzz 1.2.3\n\n## Use this release\n\n```roc\napp [target] { fuzz: platform \"https://example.test/1.2.3/hash.tar.zst\" }\n```\n\nManual: https://example.test/1.2.3/manual.pdf\n",
)

expect render("= roc-fuzz 1.2.3\n\n[source,roc]\nnot-a-delimiter\n", "platform", "manual") == Err(MissingSourceBlockDelimiter)
expect render("= roc-fuzz 1.2.3\n\n[source,roc]\n----\nbody", "platform", "manual") == Err(UnclosedSourceBlock)
expect render("= roc-fuzz 1.2.3\n{platform-url}\n", "{platform-url}", "manual") == Err(UnresolvedReleaseUrl)
