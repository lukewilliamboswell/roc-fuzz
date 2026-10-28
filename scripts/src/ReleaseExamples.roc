import cli.Env
import cli.Path
import Archive
import AutomationIO
import Files
import Integrity
import RocSource
import Script
import SkipNotes
import Version

## Freeze release examples and acquire the exact published compatibility suite.
ReleaseExamples := [].{
	Asset : { name : Str, url : Str, digest : Str }
	GitHubAsset : { name : Str, browser_download_url : Str, digest : Str }
	Release : { id : U64, tag_name : Str, draft : Bool, prerelease : Bool, assets : List(GitHubAsset) }
	Selection : { schema : U64, repository : Str, release_id : U64, version : Str, source_sha : Str, compiler : Str, bundle : Asset, examples : List(Asset) }
	Manifest : { schema : U64, version : Str, source_sha : Str, platform_url : Str, compiler : Str }
	Case : { name : Str, path : Str, seed_hex : Str, expected_failure : Bool, skip_seed : Bool, skip_fuzz : Bool }
	Inventory : { schema : U64, cases : List(Case) }
	ArchivedInventory : { schema : U64, cases : List(Case), skips : List(SkipNotes.Note) }
	SharedCase : { name : Str, args : List(Str), stdin : Str, stdout : Str, stderr : Str, stderr_match : Str, exit_code : I32, skip : Try({ reason : Str, issue : Str }, [Missing]) }
	SharedApp : { path : Str, build_args : List(Str), cases : List(SharedCase) }
	SharedSuite : { schema_version : U64, release : Str, dependencies : List(Str), apps : List(SharedApp) }
	limit : U64
	limit = 100 * 1024 * 1024
	validate_suite! = |root| {
		inventory : Inventory
		inventory = Json.parse(Path.read_utf8!(Path.join(root, "tests/targets.json"))?)?
		if inventory.schema != 1 or inventory.cases.is_empty() {
			return Err(InvalidTargetInventory)
		}
		var $names = []
		for item in inventory.cases {
			if !Archive.safe_name(item.path) or !(Script.starts_with(item.path, "examples/") or Script.starts_with(item.path, "tests/targets/")) or !Script.ends_with(item.path, ".roc") or !Archive.safe_name(item.name) or item.name.contains("/") or $names.contains(item.name) {
				return Err(InvalidTargetInventory)
			}
			if item.seed_hex.to_utf8().len() % 2 != 0 or !Integrity.is_hex(item.seed_hex, item.seed_hex.to_utf8().len()) {
				return Err(InvalidTargetSeed)
			}
			$names = $names.append(item.name)
			match RocSource.app_header(Path.read_utf8!(Path.join(root, item.path))?)? {
				[_] => {}
				_ => return Err(TargetMustBeApp(item.path))
			}
		}
		Ok({})
	}
	validate_release! = |root| {
		manifest : Manifest
		manifest = Json.parse(Path.read_utf8!(Path.join(root, "release.json"))?)?
		if manifest.schema != 1 or !valid_version(manifest.version) or !Integrity.is_hex(manifest.source_sha, 40) or !Version.nightly(manifest.compiler) or !Script.starts_with(manifest.platform_url, "https://github.com/") or !manifest.platform_url.contains("/releases/download/${manifest.version}/") or !Script.ends_with(manifest.platform_url, ".tar.zst") {
			return Err(InvalidReleaseExamplesManifest)
		}
		ReleaseExamples.validate_suite!(root)?
		for path in Files.roc_files!(Path.join(root, "examples"))? {
			source = Path.read_utf8!(path)?
			for header in RocSource.app_header(source)? {
				if RocSource.value_for(source, header, "platform")? != manifest.platform_url {
					return Err(ExampleDisagreesWithManifest(Path.display(path)))
				}
				# An archived example carries no compiler pin. Archives published
				# up to 0.4.3 pinned every example to the manifest's compiler.
				match RocSource.value_for(source, header, "roc") {
					Ok(pinned) if pinned == manifest.compiler => {}
					Err(MissingAppField(_)) => {}
					_ => return Err(ExampleDisagreesWithManifest(Path.display(path)))
				}
			}
		}
		Ok(manifest)
	}
	rewrite! = |root, name, value| {
		if name == "roc" and !Version.nightly(value) {
			return Err(InvalidCompilerTag(value))
		}
		for path in Files.roc_files!(Path.join(root, "examples"))? {
			Path.write_utf8!(path, RocSource.rewrite(Path.read_utf8!(path)?, name, value)?)?
		}
		Ok({})
	}
	package! : Path, Path, Manifest => Try({}, _)
	package! = |root, output, manifest| {
		ReleaseExamples.validate_suite!(root)?
		# The archive holds the examples and the cases that describe them. The
		# regression targets under tests/targets stay in the repository.
		inventory : Inventory
		inventory = Json.parse(Path.read_utf8!(Path.join(root, "tests/targets.json"))?)?
		cases = inventory.cases.keep_if(|item| Script.starts_with(item.path, "examples/"))
		notes = SkipNotes.load!(Path.join(root, "tests/targets.json"))?
		archived : ArchivedInventory
		archived = { schema: inventory.schema, cases, skips: notes.keep_if(|note| cases.any(|item| item.name == note.name)) }
		names = AutomationIO.tracked!(root, ["examples"])?.concat(["tests/targets.json"])
		Env.with_temp_dir!(
			|temporary| {
				archive_root = "roc-fuzz-examples-${manifest.version}"
				staging = Path.join(temporary, archive_root)
				for name in names {
					path = Path.join(root, name)
					if !Archive.safe_name(name) or Path.type!(path)? != IsFile {
						return Err(UnsafeExampleFile(name))
					}
					AutomationIO.write!(Path.join(staging, name), Path.read_bytes!(path)?)?
				}
				AutomationIO.json!(Path.join(staging, "tests/targets.json"), archived)?
				ReleaseExamples.rewrite!(staging, "platform", manifest.platform_url)?
				# Application sources differ only in their platform dependency.
				for name in names.keep_if(|item| Script.ends_with(item, ".roc")) {
					original = Path.read_utf8!(Path.join(root, name))?
					for header in RocSource.app_header(original)? {
						local = RocSource.value_for(original, header, "platform")?
						if RocSource.rewrite(Path.read_utf8!(Path.join(staging, name))?, "platform", local)? != original {
							return Err(ArchivedExampleDiffersBeyondPlatform(name))
						}
					}
				}
				AutomationIO.json!(Path.join(staging, "release.json"), manifest)?
				Path.write_utf8!(Path.join(staging, "README.md"), "# roc-fuzz ${manifest.version} examples\n\nThese are the repository's examples at the commit of release ${manifest.version}. Each application depends on that release's platform bundle:\n\n    ${manifest.platform_url}\n\nApplication sources differ only in that dependency, and no example pins a compiler. The archive adds the shared test specification, seeds, and local harness metadata. The release was built and tested with Roc `${manifest.compiler}`.\n\n```sh\nroc build --fuzz examples/jsonRoundTrip.roc\n./examples/jsonRoundTrip run\n```\n")?
				_ = ReleaseExamples.validate_release!(staging)?
				# Retain the local harness metadata inside the canonical examples tree.
				metadata = "examples/.roc-fuzz"
				AutomationIO.json!(Path.join(staging, "${metadata}/release.json"), manifest)?
				AutomationIO.json!(Path.join(staging, "${metadata}/targets.json"), archived)?
				var $apps = []
				var $seeds = []
				for item in cases {
					seed = "${metadata}/corpus/${item.name}/seed"
					AutomationIO.write!(Path.join(staging, seed), seed_bytes(item.seed_hex)?)?
					$seeds = $seeds.append(seed)
					parent_depth = Str.split_on(item.path, "/").len() - 2
					corpus = "${Str.repeat("../", parent_depth)}.roc-fuzz/corpus/${item.name}"
					code = if (item.expected_failure) 1 else 0
					$apps = $apps.append({
						path: item.path,
						build_args: ["--fuzz"],
						cases: [
							{ name: "replay", args: ["replay", "${corpus}/seed"], stdin: "", stdout: "", stderr: "", stderr_match: "ignore", exit_code: code, skip: shared_skip(item.skip_seed, item.name, "seed", notes)? },
							{ name: "smoke", args: ["run", corpus, "--time=1", "--seed=1"], stdin: "", stdout: "", stderr: "", stderr_match: "ignore", exit_code: code, skip: shared_skip(item.skip_fuzz, item.name, "fuzz", notes)? },
						],
					})
				}
				suite : SharedSuite
				suite = { schema_version: 1, release: manifest.version, dependencies: [manifest.platform_url], apps: $apps }
				AutomationIO.json!(Path.join(staging, "spec.json"), suite)?
				archived_names = names.keep_if(|name| Script.starts_with(name, "examples/")).concat(["README.md", "spec.json", "${metadata}/release.json", "${metadata}/targets.json"]).concat($seeds)
				Archive.pack!(Archive.Format.Zip, temporary, archived_names.map(|name| "${archive_root}/${name}"), output)
			},
		)
	}
	select_release : List(Release) -> Try(Release, _)
	select_release = |releases| {
		var $selected = []
		var $version = (0, 0, 0)
		for release in releases {
			if !release.draft and !release.prerelease and release.assets.any(|item| Script.ends_with(item.name, ".tar.zst")) {
				match semantic(release.tag_name) {
					Ok(version) if $selected.is_empty() or newer(version, $version) => {
						$selected = [release]
						$version = version
					}
					_ => {}
				}
			}
		}
		match $selected {
			[release] => Ok(release)
			_ => Err(NoStablePlatformRelease)
		}
	}

	## Select the release to test: the one tagged `wanted`, or the latest
	## stable platform release when `wanted` is empty.
	resolve! : Str, Str, Str => Try(Selection, _)
	resolve! = |repository, compiler, wanted| {
		if !Archive.safe_name(repository) or Str.split_on(repository, "/").len() != 2 or !Version.nightly(compiler) {
			return Err(InvalidReleaseSelection)
		}
		releases = releases!(repository, 1, [])?
		release = if wanted.is_empty() {
			ReleaseExamples.select_release(releases)?
		} else {
			match releases.keep_if(|item| item.tag_name == wanted and !item.draft) {
				[item] => item
				_ => return Err(NoSuchPlatformRelease(wanted))
			}
		}
		bundle = match release.assets.keep_if(|item| Script.ends_with(item.name, ".tar.zst")) {
			[item] => asset_identity(item)?
			_ => return Err(ExpectedOnePlatformBundle)
		}
		kits = release.assets.keep_if(|item| item.name == "roc-fuzz-examples-${release.tag_name}.zip")
		if kits.len() > 1 or (kits.is_empty() and !legacy(release.tag_name)) {
			return Err(ExpectedReleaseExamplesArchive)
		}
		ref : { object : { type : Str, sha : Str } }
		ref = Json.parse(api!("repos/${repository}/git/ref/tags/${release.tag_name}")?)?
		sha = resolve_tag!(repository, ref.object, 0)?
		examples = kits.map_try(asset_identity)?
		Ok({ schema: 1, repository, release_id: release.id, version: release.tag_name, source_sha: sha, compiler, bundle, examples })
	}

	## The documentation archive of the latest stable platform release, which
	## is what a visitor to the site has installed.
	latest_docs! = |repository| {
		if !Archive.safe_name(repository) or Str.split_on(repository, "/").len() != 2 {
			return Err(InvalidReleaseSelection)
		}
		release = ReleaseExamples.select_release(releases!(repository, 1, [])?)?
		match release.assets.keep_if(|item| item.name == "roc-fuzz-docs-${release.tag_name}.zip") {
			[item] => Ok(Published({ version: release.tag_name, archive: asset_identity(item)? }))
			_ => Ok(NoDocsArchive(release.tag_name))
		}
	}

	## Download a release's documentation archive, check it against the digest
	## GitHub records, and unpack it into a fresh directory.
	fetch_docs! = |archive, destination|
		Env.with_temp_dir!(
			|temp| {
				downloaded = Path.join(temp, "docs.zip")
				download!(archive, downloaded)?
				_ = Archive.extract!(Archive.Format.Zip, downloaded, destination, ReleaseExamples.limit)?
				Ok({})
			},
		)

	unpack! = |archive, destination| {
		entries = Archive.extract!(Archive.Format.Zip, archive, destination, ReleaseExamples.limit)?
		# Historical archives were flat; canonical archives have one named root.
		if !Path.exists!(Path.join(destination, "release.json"))? {
			prefix = Str.split_on(entries.first()?.name, "/").first()?
			if entries.any(|entry| !Script.starts_with(entry.name, "${prefix}/")) {
				return Err(InvalidReleaseArchiveRoot)
			}
			canonical = Path.join(destination, prefix)
			metadata : Manifest
			metadata = Json.parse(Path.read_utf8!(Path.join(canonical, "examples/.roc-fuzz/release.json"))?)?
			if prefix != "roc-fuzz-examples-${metadata.version}" {
				return Err(InvalidReleaseArchiveRoot)
			}
			Path.copy_dir!(Path.join(canonical, "examples"), Path.join(destination, "examples"))?
			AutomationIO.write!(Path.join(destination, "release.json"), Path.read_bytes!(Path.join(canonical, "examples/.roc-fuzz/release.json"))?)?
			AutomationIO.write!(Path.join(destination, "tests/targets.json"), Path.read_bytes!(Path.join(canonical, "examples/.roc-fuzz/targets.json"))?)?
		}
		ReleaseExamples.validate_release!(destination)
	}
	fetch! : Selection, Path => Try({}, _)
	fetch! = |selection, destination| {
		if Path.exists!(destination)? {
			return Err(SuiteDestinationMustBeFresh)
		}
		if selection.schema != 1 or !Integrity.is_hex(selection.source_sha, 40) or !Version.nightly(selection.compiler) {
			return Err(InvalidReleaseSelection)
		}
		Env.with_temp_dir!(
			|temp| {
				match selection.examples {
					[item] => {
						archive = Path.join(temp, "examples.zip")
						download!(item, archive)?
						manifest = ReleaseExamples.unpack!(archive, destination)?
						if manifest.version != selection.version or manifest.source_sha != selection.source_sha or manifest.platform_url != selection.bundle.url {
							return Err(ExamplesDisagreeWithSelectedRelease)
						}
					}
					[] if legacy(selection.version) => legacy_suite!(selection, destination, temp)?
					_ => return Err(ExpectedReleaseExamplesArchive)
				}
				# Check the platform's digest too; Roc checks its content address on use.
				download!(selection.bundle, Path.join(temp, "platform.tar.zst"))?
				AutomationIO.json!(Path.join(destination, "compatibility.json"), selection)
			},
		)
	}
}

api! = |endpoint| AutomationIO.text!("gh", ["api", endpoint], Env.cwd!()?)

releases! : Str, U64, List(ReleaseExamples.Release) => Try(List(ReleaseExamples.Release), _)
releases! = |repository, page, found| {
	batch : List(ReleaseExamples.Release)
	batch = Json.parse(api!("repos/${repository}/releases?per_page=100&page=${page.to_str()}")?)?
	all = found.concat(batch)
	if (batch.len() < 100) Ok(all) else releases!(repository, page + 1, all)
}

resolve_tag! : Str, { type : Str, sha : Str }, U64 => Try(Str, _)
resolve_tag! = |repository, object, depth| {
	if !Integrity.is_hex(object.sha, 40) or depth > 8 {
		return Err(InvalidReleaseTag)
	}
	if object.type == "commit" {
		return Ok(object.sha)
	}
	if object.type != "tag" {
		return Err(InvalidReleaseTag)
	}
	next : { object : { type : Str, sha : Str } }
	next = Json.parse(api!("repos/${repository}/git/tags/${object.sha}")?)?
	resolve_tag!(repository, next.object, depth + 1)
}

asset_identity : ReleaseExamples.GitHubAsset -> Try(ReleaseExamples.Asset, _)
asset_identity = |asset| {
	if !Script.starts_with(asset.digest, "sha256:") or !Integrity.is_hex(Str.from_utf8_lossy(asset.digest.to_utf8().drop_first(7)), 64) {
		return Err(AssetDigestRequired)
	}
	Ok({ name: asset.name, url: asset.browser_download_url, digest: asset.digest })
}

download! = |asset, destination| {
	if !Script.starts_with(asset.digest, "sha256:") {
		return Err(AssetDigestRequired)
	}
	AutomationIO.verified_download!(asset.url, destination, Str.from_utf8_lossy(asset.digest.to_utf8().drop_first(7)))
}

legacy_suite! = |selection, destination, temp| {
	archive = Path.join(temp, "legacy.tar.gz")
	AutomationIO.write!(archive, AutomationIO.bytes!("gh", ["api", "repos/${selection.repository}/tarball/${selection.source_sha}"], temp)?)?
	extracted = Path.join(temp, "legacy")
	entries = Archive.extract!(Archive.Format.Tar, archive, extracted, ReleaseExamples.limit)?
	prefix = Str.split_on(entries.first().map_err(|_| EmptyLegacyArchive)?.name, "/").first().map_err(|_| EmptyLegacyArchive)?
	if entries.any(|entry| !Script.starts_with(entry.name, "${prefix}/")) {
		return Err(InvalidLegacyArchiveRoot)
	}
	Path.create_all!(destination)?
	for name in ["examples", "tests"] {
		Path.copy_dir!(Path.join(extracted, "${prefix}/${name}"), Path.join(destination, name))?
	}
	ReleaseExamples.rewrite!(destination, "platform", selection.bundle.url)?
	ReleaseExamples.validate_suite!(destination)
}

semantic : Str -> Try((U64, U64, U64), _)
semantic = |version| match Str.split_on(version, ".") {
	[a, b, c] if [a, b, c].all(|part| part == "0" or (!Script.starts_with(part, "0") and !part.is_empty())) => Ok((U64.from_str(a)?, U64.from_str(b)?, U64.from_str(c)?))
	_ => Err(InvalidSemanticVersion)
}

newer = |(a, b, c), (x, y, z)| a > x or (a == x and (b > y or (b == y and c > z)))

legacy = |version| match semantic(version) {
	Ok(value) => !newer(value, (0, 4, 1))
	Err(_) => Bool.False
}

valid_version = |version| if (version == Version.dry_run) Bool.True else match Str.split_on(version, "-rc") {
	[base] => semantic(base) |> Try.is_ok
	[base, rc] => (semantic(base) |> Try.is_ok) and (U64.from_str(rc) |> Try.is_ok)
	_ => Bool.False
}

expect legacy("0.4.1")
expect !legacy("0.4.2")
expect !valid_version("1.02.3")
expect valid_version("0.0.1-dryrun")
expect !valid_version("0.0.1-dry")

fixture_release : Str, Bool, Bool -> ReleaseExamples.Release
fixture_release = |version, draft, prerelease| { id: 1, tag_name: version, draft, prerelease, assets: [{ name: "hash.tar.zst", browser_download_url: "https://github.com/owner/repo/releases/download/1.0.0/hash.tar.zst", digest: "sha256:${Str.repeat("a", 64)}" }] }
expect ReleaseExamples.select_release([fixture_release("1.2.0", Bool.False, Bool.False), fixture_release("1.10.0", Bool.False, Bool.False), fixture_release("9.0.0", Bool.True, Bool.False), fixture_release("2.0.0-rc1", Bool.False, Bool.True), fixture_release("linker-inputs-sha256-abc", Bool.False, Bool.False)]).map_ok(|release| release.tag_name) == Ok("1.10.0")

shared_skip = |disabled, name, operation, notes| {
	if !disabled {
		return Ok(Err(Missing))
	}
	match notes.keep_if(|note| note.name == name and note.operation == operation) {
		[note] => Ok(Ok({ reason: note.reason, issue: note.issue }))
		_ => Err(MissingSharedSkipNote(name))
	}
}

seed_bytes = |hex| {
	var $bytes = []
	var $index = 0
	while $index < hex.to_utf8().len() {
		$bytes = $bytes.append(seed_nibble(hex.to_utf8().get($index)?)? * 16 + seed_nibble(hex.to_utf8().get($index + 1)?)?)
		$index = $index + 2
	}
	Ok($bytes)
}

seed_nibble = |byte| if (byte >= '0' and byte <= '9') Ok(byte - '0') else if (byte >= 'a' and byte <= 'f') Ok(byte - 'a' + 10) else Err(InvalidSeedHex)
expect seed_bytes("00ff10") == Ok([0, 255, 16])

expect shared_skip(Bool.False, "example", "seed", []) == Ok(Err(Missing))
expect shared_skip(Bool.True, "example", "seed", []) == Err(MissingSharedSkipNote("example"))
expect shared_skip(Bool.True, "example", "seed", [{ name: "example", operation: "seed", reason: "broken", issue: "https://github.com/o/r/issues/1" }]) == Ok(Ok({ reason: "broken", issue: "https://github.com/o/r/issues/1" }))
