#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	ascii: "https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	roc: "nightly-2026-09-18-1d982dc",
}

import cli.Path
import src/ReleaseCandidate
import src/Script
import src/Version

ReleaseBundle : { artifact_file : Str, name : Str, source_path : Str }

main! = |_args| {
	version = Script.env_str!("RELEASE_VERSION")?
	notes_path = Script.env_path!("RELEASE_NOTES_PATH")?
	bundles_path = Script.env_path!("RELEASE_BUNDLES_PATH")?
	repository = Script.env_str!("GITHUB_REPOSITORY")?

	if !valid_release_version(version) {
		return Err(InvalidReleaseVersion(version))
	}

	source_path = Path.utf8("docs/releases/${version}.adoc")
	Script.require_file!(source_path)?
	source = Path.read_utf8!(source_path)?
	expected_title = "= roc-fuzz ${version}"
	if Str.split_on(source, "\n").first().map_err(|_| EmptyReleaseNotes(version))? != expected_title {
		return Err(InvalidReleaseNoteTitle(expected_title))
	}

	bundles : List(ReleaseBundle)
	bundles = Json.parse(Path.read_utf8!(bundles_path)?).map_err(|err| InvalidReleaseBundles(err))?
	bundle = match bundles {
		[single] => single
		_ => return Err(ExpectedOneReleaseBundle(bundles.len()))
	}

	release_root = "https://github.com/${repository}/releases/download/${version}"
	platform_url = "${release_root}/${bundle.artifact_file}"
	manual_url = "${release_root}/roc-fuzz-${version}.pdf"
	rendered = render(source, platform_url, manual_url)?
	Path.write_utf8!(notes_path, rendered)?
	Script.pass!("Release notes written to ${Path.display(notes_path)}")
}

valid_release_version = |value| Version.semantic(value) or (ReleaseCandidate.parse(value) |> Try.is_ok)

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
