#!/usr/bin/env roc-stable
app [main!] {
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.3/BioPdu7WjVhTB2j1HaomKMi8htxsuwqwr79GbXY5nAUf.tar.zst",
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	deflate: "https://github.com/lukewilliamboswell/roc-deflate/releases/download/0.6.0-rc2/CQoQh2ycoMgMbrkSnQJdsEhWjp67fYrT7hWwgQXynEBy.tar.zst",
	roc: "nightly-2026-11-23-b5c77fc",
	tar: "https://github.com/lukewilliamboswell/roc-tar/releases/download/0.0.3-rc1/8egXmMy7h6TTkRzUmxWygp2GnPe4mBSNGy5Q2ZZYkppu.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc6/CxK9QaRb2VBQn2hKHAmSQ1zFYW2AGNC6XLuDXeHDamZY.tar.zst",
}

import cli.Env
import cli.Path
import tar.Tar
import zip.Zip
import src/Archive
import src/AutomationIO
import src/Integrity
import src/LinkInputs
import src/Project
import src/ReleaseExamples
import src/Script
import src/TargetSuites

main! = |_args| {
	root = Project.root!()?
	Env.with_temp_dir!(
		|temp| {
			source = Path.join(temp, "source")
			AutomationIO.write!(Path.join(source, "examples/nested/main.roc"), "app [target] { pf: platform \"../../platform/main.roc\", model: \"../shared/main.roc\" }\nvalue = {roc: \"body\"}\n".to_utf8())?
			AutomationIO.write!(Path.join(source, "examples/shared/main.roc"), "package [] {}\n".to_utf8())?
			AutomationIO.write!(Path.join(source, "examples/nested/Other.roc"), "answer = 42\n".to_utf8())?
			AutomationIO.write!(Path.join(source, "examples/nested/witnesses/regression.bin"), [0, 1, 255, 0, 82, 70, 90])?
			AutomationIO.write!(Path.join(source, "tests/targets/internal.roc"), "internal test target must remain outside example packaging\n".to_utf8())?
			inventory : ReleaseExamples.Inventory
			inventory = { schema: 1, cases: [{ name: "nested", path: "examples/nested/main.roc", seed_hex: "00", expected_failure: Bool.False, skip_seed: Bool.False, skip_fuzz: Bool.False }] }
			AutomationIO.json!(Path.join(source, "tests/targets.json"), inventory)?
			AutomationIO.write!(Path.join(source, "scripts/native-deps.json"), Path.read_bytes!(Path.join(root, "scripts/native-deps.json"))?)?
			for name in ["src/macos_fuzzer_ext_functions.cpp", "src/macos_compat/sys/syscall.h"] {
				AutomationIO.write!(Path.join(source, name), Path.read_bytes!(Path.join(root, name))?)?
			}
			AutomationIO.write!(Path.join(source, "Blueprint.lock"), "locked tools\n".to_utf8())?
			AutomationIO.write!(Path.join(source, "README.md"), "unrelated\n".to_utf8())?
			AutomationIO.run!("git", ["init", "-q"], source)?
			AutomationIO.run!("git", ["add", "."], source)?
			manifest : ReleaseExamples.Manifest
			manifest = { schema: 1, version: "1.2.3", source_sha: Str.repeat("a", 40), platform_url: "https://github.com/owner/repo/releases/download/1.2.3/hash.tar.zst", compiler: "nightly-2026-09-26-d6267b4" }
			first = Path.join(temp, "one.zip")
			second = Path.join(temp, "two.zip")
			original = Path.read_utf8!(Path.join(source, "examples/nested/main.roc"))?
			ReleaseExamples.package!(source, first, manifest)?
			ReleaseExamples.package!(source, second, manifest)?
			Script.require!(Integrity.digest!(first)? == Integrity.digest!(second)?, "Examples packaging must be deterministic")?
			Script.require!(Path.read_utf8!(Path.join(source, "examples/nested/main.roc"))? == original, "Packaging must preserve source examples")?
			suite = Path.join(temp, "suite")
			actual = ReleaseExamples.unpack!(first, suite)?
			canonical = Path.join(suite, "roc-fuzz-examples-1.2.3")
			shared : ReleaseExamples.SharedSuite
			shared = Json.parse(Path.read_utf8!(Path.join(canonical, "spec.json"))?)?
			Script.require!(shared.release == manifest.version and shared.dependencies == [manifest.platform_url], "Shared suite must name the exact released bundle")?
			example = shared.apps.first()?
			Script.require!(example.build_args == ["--fuzz"] and example.cases.len() == 2, "Every example must replay and smoke a fuzz build")?
			Script.require!(example.cases.first()?.args == ["replay", "../.roc-fuzz/corpus/nested/seed"], "Nested examples resolve seeds from their own directory")?
			Script.require!(Path.read_bytes!(Path.join(canonical, "examples/.roc-fuzz/corpus/nested/seed"))? == [0], "Archive must carry decoded seed bytes")?
			Script.require!(Path.read_bytes!(Path.join(canonical, "examples/nested/witnesses/regression.bin"))? == [0, 1, 255, 0, 82, 70, 90], "Archive must preserve original witness bytes and relative paths")?
			entries = Archive.entries!(Archive.Format.Zip, first, ReleaseExamples.limit)?
			Script.require!(entries.all(|entry| Script.starts_with(entry.name, "roc-fuzz-examples-1.2.3/")), "Archive must have one canonical root")?
			Script.require!(!entries.any(|entry| entry.name.contains("tests/targets/")), "Internal test targets must remain outside example packaging and URL rewrites")?
			# Suite metadata survives packaging and selects every member from one build.
			members = [{ name: "passing", expected_failure: Bool.False }, { name: "finding", expected_failure: Bool.True }]
			suites = [{ name: "nested", members }]
			AutomationIO.json!(Path.join(source, "tests/targets.json"), { schema: inventory.schema, cases: inventory.cases, suites })?
			multi = Path.join(temp, "multi.zip")
			ReleaseExamples.package!(source, multi, manifest)?
			multi_root = Path.join(temp, "multi-suite")
			_ = ReleaseExamples.unpack!(multi, multi_root)?
			Script.require!(TargetSuites.load!(Path.join(multi_root, "tests/targets.json"))? == suites, "Archived suites must retain member identities")?
			multi_spec : ReleaseExamples.SharedSuite
			multi_spec = Json.parse(Path.read_utf8!(Path.join(multi_root, "roc-fuzz-examples-1.2.3/spec.json"))?)?
			checks = multi_spec.apps.first()?.cases
			Script.require!(multi_spec.apps.len() == 1 and checks.len() == 4, "One suite build must exercise every member")?
			Script.require!(checks.take_first(2).all(|check| check.args.first() == Ok("--target=passing") and check.exit_code == 0), "Passing member selection must survive packaging")?
			Script.require!(checks.drop_first(2).all(|check| check.args.first() == Ok("--target=finding") and check.exit_code == 1), "Finding member selection must retain its exit code")?
			Script.require!(checks.first()?.args == ["--target=passing", "replay", "../.roc-fuzz/corpus/nested/passing/seed"], "Each suite member must have its own corpus")?
			Script.require!(checks.get(2)?.args == ["--target=finding", "replay", "../.roc-fuzz/corpus/nested/finding/seed"], "Distinct member encodings must not share a corpus")?
			for name in ["passing", "finding"] {
				Script.require!(Path.read_bytes!(Path.join(multi_root, "examples/.roc-fuzz/corpus/nested/${name}/seed"))? == [0], "Each archived member must retain its seed")?
			}
			AutomationIO.json!(Path.join(source, "tests/targets.json"), inventory)?
			flat = Path.join(temp, "legacy.zip")
			Archive.pack!(Archive.Format.Zip, suite, ["release.json", "tests/targets.json", "examples/nested/main.roc", "examples/nested/Other.roc", "examples/shared/main.roc"], flat)?
			Script.require!(ReleaseExamples.unpack!(flat, Path.join(temp, "legacy-suite"))? == manifest, "Historical flat archives must remain readable")?
			Script.require!(actual == manifest, "Manifest must survive packaging")?
			Script.require!(ReleaseExamples.unpack!(first, suite) |> Try.is_err, "Unpacking must require a fresh destination")?
			Script.require!(Path.is_file!(Path.join(suite, "examples/shared/main.roc"))?, "Package must include the helper packages beside the examples")?
			Script.require!(!Path.read_utf8!(Path.join(suite, "examples/nested/main.roc"))?.contains("roc: \"nightly"), "An archived example must not pin a compiler")?
			ReleaseExamples.rewrite!(suite, "roc", "nightly-2026-09-29-7f11a82")?
			Script.require!(ReleaseExamples.validate_release!(suite) |> Try.is_err, "Reject modified publication compiler")?
			ReleaseExamples.rewrite!(suite, "roc", manifest.compiler)?
			ReleaseExamples.rewrite!(suite, "platform", "https://github.com/owner/repo/releases/download/1.2.2/hash.tar.zst")?
			Script.require!(ReleaseExamples.validate_release!(suite) |> Try.is_err, "Reject modified publication URL")?
			Script.require!(Path.read_utf8!(Path.join(suite, "examples/nested/Other.roc"))? == "answer = 42\n", "Rewrites must preserve non-app modules")?
			# Both archive formats must reject links before any extraction.
			linked_zip = Path.join(temp, "linked.zip")
			linked_tar = Path.join(temp, "linked.tar")
			AutomationIO.write!(linked_zip, Zip.create_items([File({ path: "a", content: [1] }), SymbolicLink({ path: "link", target: "missing" })], None)?)?
			AutomationIO.write!(linked_tar, Tar.create([Tar.file("a", [1]), Tar.symlink("link", "missing")]).map_err(|err| UnwritableTar(Tar.write_err_to_str(err)))?)?
			for (format, archive) in [(Archive.Format.Zip, linked_zip), (Archive.Format.Tar, linked_tar)] {
				Script.require!(Archive.entries!(format, archive, 1000) |> Try.is_err, "Links must refuse the listing")?
				Script.require!(Archive.extract!(format, archive, Path.join(temp, "linked"), 1000) |> Try.is_err, "Links must refuse extraction")?
				Script.require!(!Path.exists!(Path.join(temp, "linked"))?, "A refused archive must write nothing")?
			}
			# What a pack writes extracts byte for byte, in both formats, and
			# extraction needs a fresh destination.
			packed_source = Path.join(suite, "examples")
			packed_names = ["nested/main.roc", "nested/Other.roc", "shared/main.roc"]
			for (format, name) in [(Archive.Format.Zip, "round.zip"), (Archive.Format.Tar, "round.tar")] {
				archive = Path.join(temp, name)
				Archive.pack!(format, packed_source, packed_names, archive)?
				unpacked = Path.join(temp, "${name}-unpacked")
				listed = Archive.extract!(format, archive, unpacked, 1000000)?
				Script.require!(listed.map(|entry| entry.name) == packed_names, "Pack keeps the order it is given")?
				for packed_name in packed_names {
					Script.require!(Path.read_bytes!(Path.join(unpacked, packed_name))? == Path.read_bytes!(Path.join(packed_source, packed_name))?, "Extraction must give the packed bytes")?
				}
				Script.require!(Archive.extract!(format, archive, unpacked, 1000000) |> Try.is_err, "Extraction must require a fresh destination")?
				Script.require!(Archive.entries!(format, archive, 10) |> Try.is_err, "Listing must enforce the size limit")?
				under = Path.join(temp, "${name}-nested")
				Script.require!(Archive.extract_under!(format, archive, "nested", under, 1000000)?.map(|entry| entry.name) == ["main.roc", "Other.roc"], "A part of an archive is named relative to it")?
				Script.require!(Path.read_bytes!(Path.join(under, "Other.roc"))? == Path.read_bytes!(Path.join(packed_source, "nested/Other.roc"))?, "A part extracts byte for byte")?
			}
			# A documentation site packs whole, named relative to its root.
			site = Path.join(temp, "site")
			AutomationIO.write!(Path.join(site, "index.html"), "<p>home</p>\n".to_utf8())?
			AutomationIO.write!(Path.join(site, "api/fonts/a.ttf"), [0, 1, 2, 255])?
			docs_archive = Path.join(temp, "docs.zip")
			ReleaseExamples.package_docs!(site, docs_archive)?
			docs_unpacked = Path.join(temp, "docs-unpacked")
			Script.require!(Archive.extract!(Archive.Format.Zip, docs_archive, docs_unpacked, 1000)?.map(|entry| entry.name) == ["api/fonts/a.ttf", "index.html"], "A packed site lists its files in byte order")?
			Script.require!(Path.read_bytes!(Path.join(docs_unpacked, "api/fonts/a.ttf"))? == [0, 1, 2, 255], "A packed site extracts byte for byte")?
			cached = Path.join(temp, "cached")
			Path.write_utf8!(cached, "good")?
			AutomationIO.verified_download!("not-a-network-url", cached, Integrity.digest_bytes("good".to_utf8()))?
			Path.write_utf8!(cached, "corrupt")?
			Script.require!(AutomationIO.verified_download!("not-a-network-url", cached, Integrity.digest_bytes("good".to_utf8())) |> Try.is_err, "Corrupt cache must require a fresh download")?
			Script.require!(!Path.exists!(cached)?, "Corrupt cache must be removed")?
			native_tests!(root, source, temp)?
			Script.pass!("Roc release and native-input integration tests passed.")
		},
	)
}

native_tests! = |_root, source, temp| {
	for target in Project.all_targets {
		for name in LinkInputs.files(target) {
			AutomationIO.write!(Path.join(target.dir(source), name), name.to_utf8())?
		}
	}
	for name in LinkInputs.licenses {
		AutomationIO.write!(Path.join(source, name), name.to_utf8())?
	}
	AutomationIO.run!("git", ["add", "."], source)?
	fingerprint = LinkInputs.fingerprint!(source)?
	library = Path.join(Project.Target.dir(Project.Target.X64Musl, source), "libc.a")
	# Tooling is not an input: editing it never demands a release.
	for name in ["README.md", "Blueprint.lock", "scripts/build_platform.roc"] {
		AutomationIO.write!(Path.join(source, name), "edited\n".to_utf8())?
		Script.require!(LinkInputs.fingerprint!(source)? == fingerprint, "${name} must not invalidate native inputs")?
	}
	for name in ["scripts/native-deps.json", "LICENSE", "src/macos_fuzzer_ext_functions.cpp"] {
		original = Path.read_bytes!(Path.join(source, name))?
		AutomationIO.write!(Path.join(source, name), original.concat("changed\n".to_utf8()))?
		Script.require!(LinkInputs.fingerprint!(source)? != fingerprint, "${name} must invalidate native inputs")?
		AutomationIO.write!(Path.join(source, name), original)?
	}
	Script.require!(LinkInputs.fingerprint!(source)? == fingerprint, "Restored inputs must restore the fingerprint")?
	cache = Path.join(temp, "native")
	producer : LinkInputs.Source
	producer = { repository: "owner/repo", sha: Str.repeat("b", 40), ref: "refs/heads/test", workflow: "owner/repo/.github/workflows/link-inputs.yml", input_fingerprint: "" }
	LinkInputs.package!(source, cache, producer)?
	manifest_path = Path.join(cache, "build-input-release.json")
	manifest : LinkInputs.Manifest
	manifest = Json.parse(Path.read_utf8!(manifest_path)?)?
	digest = Integrity.digest!(manifest_path)?
	lock : LinkInputs.Lock
	lock = { schema_version: 1, kind: "link-inputs", repository: "owner/repo", release: "linker-inputs-sha256-${digest}", manifest: { asset: "build-input-release.json", sha256: digest }, source: manifest.source, artifacts: manifest.assets }
	Path.write_utf8!(Path.join(source, "native-libraries.lock.json"), Str.replace_each(Json.to_str(lock), "\"artifacts\"", "\"targets\""))?
	Script.require!(LinkInputs.validate_lock(lock, "different") |> Try.is_err, "Reject stale native locks")?
	same = match LinkInputs.check_source!(source, cache)? {
		SameBytes(_) => Bool.True
		_ => Bool.False
	}
	Script.require!(same, "Libraries the lock was made from must compare equal")?
	AutomationIO.write!(library, "rebuilt differently".to_utf8())?
	named = match LinkInputs.check_source!(source, cache)? {
		DifferentBytes({ files, release: _ }) => files == ["x64musl/libc.a"]
		_ => Bool.False
	}
	Script.require!(named, "A library that differs from the locked one must be named")?
	AutomationIO.write!(library, "libc.a".to_utf8())?
	for target in Project.all_targets {
		_ = LinkInputs.verify_archive!(source, target, cache)?
		LinkInputs.install!(source, target, cache)?
		for name in LinkInputs.files(target) {
			Script.require!(Path.read_utf8!(Path.join(target.dir(source), name))? == name, "Native archive round trip")?
		}
	}
	LinkInputs.check_installed!(source)?
	bad_metadata = Path.join(Project.Target.dir(Project.Target.Arm64Mac, source), "NATIVE_LIBRARIES.json")
	Path.write_utf8!(bad_metadata, "{}")?
	Script.require!(LinkInputs.check_installed!(source) |> Try.is_err, "Reject incorrect installed provenance")?
	second_cache = Path.join(temp, "native-again")
	LinkInputs.package!(source, second_cache, producer)?
	Script.require!(Integrity.digest!(manifest_path)? == Integrity.digest!(Path.join(second_cache, "build-input-release.json"))?, "Native archives must be deterministic")?
	Ok({})
}
