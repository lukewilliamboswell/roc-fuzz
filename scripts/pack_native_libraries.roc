#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	ascii: "https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	roc: "nightly-2026-09-19-d025939",
}

import cli.Env
import cli.OsStr
import cli.Path
import weaver.Cli
import weaver.Opt
import src/CliValues
import src/Identity
import src/Integrity
import src/NativeLibraries
import src/Project
import src/Script
import src/WeaverCli
import src/WorkspaceDeps

main! = |raw_args| {
	options = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(value) => value
		Exit => return Ok({})
	}
	root = Project.root!()?
	deps = WorkspaceDeps.current
	release = match options.release {
		Ok(value) => value
		Err(NoValue) => deps.native_release_default
	}
	output = Path.absolute!(options.directory)?
	Script.info!("PACK", "Validating built libraries and release metadata")?
	release_name = release.to_str()
	repository = deps.repository.to_str()
	spec = options.target.spec()
	zig = Script.trim(Str.from_utf8_lossy(Script.command("zig").capture!(["version"], root, [])?))
	if zig != deps.zig_version {
		return Err(UnsupportedZigVersion(zig))
	}
	revision = match Identity.GitRevision.parse(git_value!(root, ["rev-parse", "HEAD"])?) {
		Ok(value) => value
		Err(_) => return Err(InvalidSourceRevision)
	}
	metadata = NativeLibraries.BuildMetadata.{
		libfuzzer_sha256: deps.libfuzzer.sha256,
		libfuzzer_version: deps.libfuzzer.version,
		release,
		schema: 1,
		source_revision: revision,
		target: options.target,
		zig_target: spec.zig_target,
		zig_version: zig,
	}
	Path.create_all!(output)?
	archive_name = "${release_name}-${options.target.name()}.tar.gz"
	archive = Path.join(output, archive_name)
	checksum_output = Path.utf8("${Path.display(archive)}.sha256")
	sbom_output = Path.utf8("${Path.display(archive)}.spdx.json")
	if Path.is_file!(archive)? or Path.is_file!(checksum_output)? or Path.is_file!(sbom_output)? {
		return Err(NativeLibraryReleaseAlreadyExists(Path.display(archive)))
	}
	# Stage every output away from the publication directory. Sidecars are copied
	# first; the archive itself is the completion marker.
	Env.with_temp_dir!(
		|temporary| {
			staging = Path.join(temporary, "contents")
			Path.create_all!(staging)?
			candidate = Path.join(temporary, archive_name)
			stage_archive!(root, staging, candidate, spec, metadata)?
			digest = Integrity.digest!(candidate)?
			checksum = Path.join(temporary, "${archive_name}.sha256")
			Path.write_utf8!(checksum, "${digest}  ${archive_name}\n")?
			created = git_value!(root, ["show", "-s", "--format=%cI", "HEAD"])?
			sbom_path = Path.join(temporary, "${archive_name}.spdx.json")
			Path.write_utf8!(sbom_path, sbom(archive_name, release_name, options.target.name(), digest, created, repository))?
			Path.copy!(checksum, checksum_output)?
			Path.copy!(sbom_path, sbom_output)?
			Path.copy!(candidate, archive)
		},
	)?
	Script.pass!("Created ${Path.display(archive)}")
}

git_value! = |root, args| Script.command("git").capture!(args, root, []).map_ok(|bytes| Script.trim(Str.from_utf8_lossy(bytes)))

stage_archive! = |root, staging, archive, spec, metadata| {
	for name in NativeLibraries.library_names(spec) {
		source = Path.join(spec.target.dir(root), name)
		Script.require_file!(source)?
		Path.copy!(source, Path.join(staging, name))?
	}
	for name in ["LICENSE", "THIRD_PARTY_LICENSES.md"] {
		Path.copy!(Path.join(root, name), Path.join(staging, name))?
	}
	Path.write_utf8!(Path.join(staging, "build.json"), NativeLibraries.metadata_json(metadata))?
	var $entries = []
	for name in NativeLibraries.library_names(spec) {
		digest = Integrity.digest!(Path.join(staging, name))?
		$entries = $entries.append(Integrity.ManifestEntry.{ digest, name })
	}
	Path.write_utf8!(Path.join(staging, "SHA256SUMS"), Integrity.render_manifest($entries))?
	names = NativeLibraries.expected_names(spec)
	Script.command("tar").cmd(["-czf", Path.to_os_str(archive), "--"].concat(names.map(OsStr.from_str))).cwd(staging).exec_cmd!()
}

sbom = |archive, release, target, digest, created, repository|
	"{\n  \"spdxVersion\": \"SPDX-2.3\",\n  \"dataLicense\": \"CC0-1.0\",\n  \"SPDXID\": \"SPDXRef-DOCUMENT\",\n  \"name\": ${Json.to_str(archive)},\n  \"documentNamespace\": ${Json.to_str("https://github.com/${repository}/sbom/${digest}")},\n  \"creationInfo\": {\"created\":${Json.to_str(created)},\"creators\":[\"Tool: roc-fuzz/scripts/pack_native_libraries.roc\"]},\n  \"packages\": [{\"SPDXID\":\"SPDXRef-NativeLibraries\",\"name\":${Json.to_str("roc-fuzz native libraries ${target}")},\"versionInfo\":${Json.to_str(release)},\"downloadLocation\":${Json.to_str("https://github.com/${repository}/releases/download/${release}/${archive}")},\"filesAnalyzed\":false,\"checksums\":[{\"algorithm\":\"SHA256\",\"checksumValue\":${Json.to_str(digest)}}],\"licenseConcluded\":\"NOASSERTION\",\"licenseDeclared\":\"NOASSERTION\",\"copyrightText\":\"NOASSERTION\"}],\n  \"documentDescribes\": [\"SPDXRef-NativeLibraries\"]\n}\n"

cli_parser = Cli.assert_valid(
	Cli.finish(
		{
			directory: Opt.single({ short: "", long: "directory", help: "Output directory. [default: dist/native]", type: "path", default: Value(Path.utf8("dist/native")), parser: CliValues.path }),
			release: release_option,
			target: target_option,
		}.Cli,
		{ name: "pack-native-libraries", version: "development", authors: [], description: "Package native libraries, checksums, provenance, and an SPDX SBOM.", text_style: Plain },
	),
)

release_option = Opt.maybe({ short: "", long: "release", help: "Immutable native-libs-vX.Y.Z release tag; defaults to workspace configuration.", type: "release", parser: parse_release })

target_option = Opt.single({ short: "", long: "target", help: "Native target name.", type: "target", default: NoDefault, parser: parse_target })

parse_release = |arg| parse_text(arg, Identity.NativeRelease.parse, "expected native-libs-vX.Y.Z")

parse_target = |arg| parse_text(arg, Project.Target.parse, "expected x64musl or arm64mac")

parse_text = |arg, parse, message| match CliValues.text(arg) {
	Ok(value) => match parse(value) {
		Ok(parsed) => Ok(parsed)
		Err(_) => Err(InvalidValue(message))
	}
	Err(_) => Err(InvalidUtf8)
}
