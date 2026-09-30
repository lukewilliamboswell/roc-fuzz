#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0/GNN5tt2gKdX4dhawg4915C4YB193woHFdcCkz31fhGxv.tar.zst",
	ascii: "https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	roc: "nightly-2026-09-29-7f11a82",
}

import cli.Env
import cli.Path
import src/Archive
import src/AutomationIO
import src/Integrity
import src/LinkInputs
import src/Project
import src/ReleaseExamples
import src/Script

main! = |_args| {
	root = Project.root!()?
	Env.with_temp_dir!(
		|temp| {
			source = Path.join(temp, "source")
			AutomationIO.write!(Path.join(source, "examples/nested/main.roc"), "app [target] { pf: platform \"../../platform/main.roc\", model: \"../../tests/set-model/main.roc\" }\nvalue = {roc: \"body\"}\n".to_utf8())?
			AutomationIO.write!(Path.join(source, "tests/set-model/main.roc"), "package [] {}\n".to_utf8())?
			AutomationIO.write!(Path.join(source, "examples/nested/Other.roc"), "answer = 42\n".to_utf8())?
			inventory : ReleaseExamples.Inventory
			inventory = { schema: 1, cases: [{ name: "nested", path: "examples/nested/main.roc", seed_hex: "00", expected_failure: Bool.False, skip_seed: Bool.False, skip_fuzz: Bool.False }] }
			AutomationIO.json!(Path.join(source, "tests/targets.json"), inventory)?
			AutomationIO.write!(Path.join(source, "scripts/workspace-deps.json"), Path.read_bytes!(Path.join(root, "scripts/workspace-deps.json"))?)?
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
			Script.require!(actual == manifest, "Manifest must survive packaging")?
			Script.require!(ReleaseExamples.unpack!(first, suite) |> Try.is_err, "Unpacking must require a fresh destination")?
			Script.require!(Path.is_file!(Path.join(suite, "tests/set-model/main.roc"))?, "Package must include local model imports")?
			ReleaseExamples.rewrite!(suite, "roc", "nightly-2026-09-29-7f11a82")?
			Script.require!(ReleaseExamples.validate_release!(suite) |> Try.is_err, "Reject modified publication compiler")?
			ReleaseExamples.rewrite!(suite, "roc", manifest.compiler)?
			ReleaseExamples.rewrite!(suite, "platform", "https://github.com/owner/repo/releases/download/1.2.2/hash.tar.zst")?
			Script.require!(ReleaseExamples.validate_release!(suite) |> Try.is_err, "Reject modified publication URL")?
			Script.require!(Path.read_utf8!(Path.join(suite, "examples/nested/Other.roc"))? == "answer = 42\n", "Rewrites must preserve non-app modules")?
			# Both archive formats must reject symlinks before any extraction.
			AutomationIO.run!("ln", ["-s", "missing", "link"], temp)?
			AutomationIO.run!("zip", ["-q", "-y", "linked.zip", "link"], temp)?
			AutomationIO.run!("tar", ["-cf", "linked.tar", "link"], temp)?
			Script.require!(Archive.entries!(Archive.Format.Zip, Path.join(temp, "linked.zip"), 1000) |> Try.is_err, "ZIP links must fail")?
			Script.require!(Archive.entries!(Archive.Format.Tar, Path.join(temp, "linked.tar"), 1000) |> Try.is_err, "TAR links must fail")?
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
	metadata = Path.join(source, "scripts/workspace-deps.json")
	original = Path.read_utf8!(metadata)?
	fingerprint = LinkInputs.fingerprint!(source)?
	Path.write_utf8!(metadata, Str.replace_each(original, "nightly-2026-09-26-d6267b4", "nightly-2026-09-29-7f11a82"))?
	Script.require!(LinkInputs.fingerprint!(source)? == fingerprint, "Project nightly must not invalidate native inputs")?
	Path.write_utf8!(metadata, Str.replace_each(original, "nightly-2026-09-29-7f11a82", "nightly-2026-09-18-1d982dc"))?
	Script.require!(LinkInputs.fingerprint!(source)? != fingerprint, "Tooling compiler must invalidate native inputs")?
	Path.write_utf8!(metadata, original)?
	cache = Path.join(temp, "native")
	producer : LinkInputs.Source
	producer = { repository: "owner/repo", sha: Str.repeat("b", 40), ref: "refs/heads/test", workflow: "owner/repo/.github/workflows/native-libraries.yml", input_fingerprint: "" }
	LinkInputs.package!(source, cache, producer)?
	manifest_path = Path.join(cache, "build-input-release.json")
	manifest : LinkInputs.Manifest
	manifest = Json.parse(Path.read_utf8!(manifest_path)?)?
	digest = Integrity.digest!(manifest_path)?
	lock : LinkInputs.Lock
	lock = { schema_version: 1, kind: "link-inputs", repository: "owner/repo", release: "linker-inputs-sha256-${digest}", manifest: { asset: "build-input-release.json", sha256: digest }, source: manifest.source, artifacts: manifest.assets }
	Path.write_utf8!(Path.join(source, "native-libraries.lock.json"), Str.replace_each(Json.to_str(lock), "\"artifacts\"", "\"targets\""))?
	Script.require!(LinkInputs.validate_lock(lock, "different") |> Try.is_err, "Reject stale native locks")?
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
