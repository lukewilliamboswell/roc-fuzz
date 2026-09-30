import cli.Env
import cli.Path
import Archive
import AutomationIO
import Files
import Integrity
import RocSource
import Script
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
			if !Archive.safe_name(item.path) or !Script.starts_with(item.path, "examples/") or !Script.ends_with(item.path, ".roc") or !Archive.safe_name(item.name) or item.name.contains("/") or $names.contains(item.name) {
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
				if RocSource.value_for(source, header, "platform")? != manifest.platform_url or RocSource.value_for(source, header, "roc")? != manifest.compiler {
					return Err(ExampleDisagreesWithManifest(Path.display(path)))
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
		names = AutomationIO.tracked!(root, ["examples", "tests/set-model", "tests/targets.json"])?
		Env.with_temp_dir!(
			|staging| {
				for name in names {
					path = Path.join(root, name)
					if !Archive.safe_name(name) or Path.type!(path)? != IsFile {
						return Err(UnsafeExampleFile(name))
					}
					AutomationIO.write!(Path.join(staging, name), Path.read_bytes!(path)?)?
				}
				ReleaseExamples.rewrite!(staging, "platform", manifest.platform_url)?
				ReleaseExamples.rewrite!(staging, "roc", manifest.compiler)?
				AutomationIO.json!(Path.join(staging, "release.json"), manifest)?
				Path.write_utf8!(Path.join(staging, "README.md"), "# roc-fuzz ${manifest.version} examples\n\nTested with Roc `${manifest.compiler}`. Each app selects the published platform.\n\n```sh\nroc build --fuzz examples/jsonRoundTrip.roc\n./examples/jsonRoundTrip run\n```\n")?
				_ = ReleaseExamples.validate_release!(staging)?
				Archive.pack!(Archive.Format.Zip, staging, names.concat(["release.json", "README.md"]), output)
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
	resolve! : Str, Str => Try(Selection, _)
	resolve! = |repository, compiler| {
		if !Archive.safe_name(repository) or Str.split_on(repository, "/").len() != 2 or !Version.nightly(compiler) {
			return Err(InvalidReleaseSelection)
		}
		releases = releases!(repository, 1, [])?
		release = ReleaseExamples.select_release(releases)?
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
	unpack! = |archive, destination| {
		_ = Archive.extract!(Archive.Format.Zip, archive, destination, ReleaseExamples.limit)?
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
				ReleaseExamples.rewrite!(destination, "roc", selection.compiler)?
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
	if batch.len() < 100 Ok(all) else releases!(repository, page + 1, all)
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

valid_version = |version| match Str.split_on(version, "-rc") {
	[base] => semantic(base) |> Try.is_ok
	[base, rc] => (semantic(base) |> Try.is_ok) and (U64.from_str(rc) |> Try.is_ok)
	_ => Bool.False
}

expect legacy("0.4.1")
expect !legacy("0.4.2")
expect !valid_version("1.02.3")

fixture_release : Str, Bool, Bool -> ReleaseExamples.Release
fixture_release = |version, draft, prerelease| { id: 1, tag_name: version, draft, prerelease, assets: [{ name: "hash.tar.zst", browser_download_url: "https://github.com/owner/repo/releases/download/1.0.0/hash.tar.zst", digest: "sha256:${Str.repeat("a", 64)}" }] }
expect ReleaseExamples.select_release([fixture_release("1.2.0", Bool.False, Bool.False), fixture_release("1.10.0", Bool.False, Bool.False), fixture_release("9.0.0", Bool.True, Bool.False), fixture_release("2.0.0-rc1", Bool.False, Bool.True), fixture_release("linker-inputs-sha256-abc", Bool.False, Bool.False)]).map_ok(|release| release.tag_name) == Ok("1.10.0")
