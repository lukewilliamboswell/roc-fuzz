#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
	ascii: "https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	roc: "nightly-2026-09-29-7f11a82",
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
## its own, so it renders every notes file newer than the latest release, which
## fails a mistake in unreleased notes on the pull request that makes it.
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
		var $rendered = []
		for path in Files.direct_files!("docs/releases")? {
			name = Path.filename(path).map_ok(Path.display).map_err(|_| InvalidReleaseNotePath(Path.display(path)))?
			pending = Str.replace_each(name, ".adoc", "")
			if Script.ends_with(name, ".adoc") and newer(pending, previous)? {
				_ = render_release!(pending, repository, bundle.artifact_file, compilers)?
				$rendered = $rendered.append(pending)
			}
		}
		summary = if $rendered.is_empty() "no notes are newer than ${previous}" else "rendered ${Str.join_with($rendered, ", ")}"
		Path.write_utf8!(notes_path, "Dry run: ${summary}.\n")?
		Script.pass!("Release notes dry run: ${summary}")
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
	Ok("${rendered}\n\n[Download the complete release examples](${release_root}/roc-fuzz-examples-${version}.zip).\n\n${compilers}")
}

## The record of what a release was built and tested with. No header pin makes
## this statement, so the notes do.
compilers! = || {
	package_compiler = Script.trim(Str.from_utf8_lossy((Script.roc!()?).capture!(["version"], ".", [])?))
	tooling_compiler = Script.trim(Str.from_utf8_lossy((Script.roc_stable!()?).capture!(["version"], ".", [])?))
	Ok("## Built and tested with\n\n- Platform, examples and bundle: `${package_compiler}`\n- Repository tooling: `${tooling_compiler}`\n")
}

valid_release_version = |value| Version.semantic(value) or (ReleaseCandidate.parse(value) |> Try.is_ok)

## Whether the notes for `version` are newer than the release `previous`. A
## release candidate counts with the release it leads to.
newer = |version, previous| {
	if previous.is_empty() {
		return Ok(Bool.True)
	}
	(a, b, c) = base(version)?
	(x, y, z) = base(previous)?
	Ok(a > x or (a == x and (b > y or (b == y and c > z))))
}

base = |version|
	match Str.split_on(Str.split_on(version, "-").first().map_err(|_| InvalidReleaseVersion(version))?, ".") {
		[major, minor, patch] => Ok((U64.from_str(major)?, U64.from_str(minor)?, U64.from_str(patch)?))
		_ => Err(InvalidReleaseVersion(version))
	}

expect newer("0.5.0", "0.4.3") == Ok(Bool.True)
expect newer("0.5.0-rc1", "0.4.3") == Ok(Bool.True)
expect newer("0.4.3", "0.4.3") == Ok(Bool.False)
expect newer("0.4.2", "0.4.3") == Ok(Bool.False)
expect newer("0.4.3", "") == Ok(Bool.True)

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
		[] => if state == SourceBlock Err(UnclosedSourceBlock) else Ok(output)
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
