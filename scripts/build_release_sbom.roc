#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	ascii: "https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	roc: "nightly-2026-09-19-d025939",
}

import cli.Path
import cli.Utc
import weaver.Cli
import weaver.Opt
import src/CliValues
import src/Identity
import src/Integrity
import src/Project
import src/ReleaseCandidate
import src/Script
import src/WeaverCli
import src/WorkspaceDeps

Package := { checksum : [Checksum(Str), NoChecksum], download : Str, identifier : Str, license : Str, name : Str, version : Str }.{}

LibraryManifest : { archive : Str, release : Str, repository : Str, sha256 : Str, target : Str }

NativeManifest := { path : Path, target : Project.Target }.{}

main! = |raw_args| {
	options = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(parsed) => parsed
		Exit => return Ok({})
	}
	bundle = Path.absolute!(options.bundle)?
	output = match options.output {
		Ok(path) => Path.absolute!(path)?
		Err(NoValue) => Path.utf8("${Path.display(bundle)}.spdx.json")
	}
	document = generate!(bundle, ReleaseCandidate.to_str(options.release_version), options.native_manifests, options.library_manifests, WorkspaceDeps.current)?
	Path.write_utf8!(output, document)?
	Script.pass!("SPDX release SBOM written to ${Path.display(output)}")
}

cli_parser = Cli.assert_valid(
	Cli.finish(
		{
			bundle: Opt.single({ short: "", long: "bundle", help: "Release .tar.zst bundle.", type: "path", default: NoDefault, parser: CliValues.path }),
			library_manifests: Opt.list({ short: "", long: "library-manifest", help: "Native library release manifest; repeat as needed.", type: "path", parser: CliValues.path }),
			native_manifests: Opt.list({ short: "", long: "native-manifest", help: "TARGET=PATH checksum manifest; repeat for both targets.", type: "manifest", parser: parse_native_manifest }),
			output: Opt.maybe({ short: "o", long: "output", help: "Output SPDX JSON path; defaults beside the bundle.", type: "path", parser: CliValues.path }),
			release_version: Opt.single({ short: "", long: "release-version", help: "Release-candidate version, for example 1.2.3-rc4.", type: "version", default: NoDefault, parser: parse_release_version }),
		}.Cli,
		{
			name: "build-release-sbom",
			version: "development",
			authors: [],
			description: "Generate and validate the SPDX 2.3 release SBOM.",
			text_style: Plain,
		},
	),
)

parse_native_manifest : _ -> Try(NativeManifest, [InvalidNumStr, InvalidValue(Str), InvalidUtf8])
parse_native_manifest = |argument|
	match CliValues.text(argument) {
		Ok(value) => match parse_native_manifest_value(value) {
			Ok(manifest) => Ok(manifest)
			Err(_) => Err(InvalidValue("expected TARGET=PATH with a supported target"))
		}
		Err(_) => Err(InvalidUtf8)
	}

parse_release_version : _ -> Try(ReleaseCandidate, [InvalidNumStr, InvalidValue(Str), InvalidUtf8])
parse_release_version = |argument|
	match CliValues.text(argument) {
		Ok(value) => match ReleaseCandidate.parse(value) {
			Ok(version) => Ok(version)
			Err(_) => Err(InvalidValue("expected a release candidate such as 1.2.3-rc4"))
		}
		Err(_) => Err(InvalidUtf8)
	}

generate! = |bundle, release, native_manifests, library_manifest_paths, dependencies| {
	if !Path.is_file!(bundle)? or !Script.ends_with(Path.display(bundle), ".tar.zst") {
		return Err(InvalidReleaseBundle(Path.display(bundle)))
	}
	bundle_digest = Integrity.digest!(bundle)?
	bundle_name = Path.display(Path.filename(bundle).map_err(|_| InvalidReleaseBundle(Path.display(bundle)))?)
	repository = dependencies.repository.to_str()
	base = base_packages(bundle_name, release, bundle_digest, dependencies, repository)
	native = native_packages!(native_manifests, release, dependencies)?
	libraries = library_packages!(library_manifest_paths, release, repository)?
	components = base.concat(native).concat(libraries)
	if !unique(components.map(|item| item.identifier)) {
		return Err(DuplicateSbomIdentifier)
	}
	created = Utc.to_iso_8601(Utc.now!())
	Ok(render_document(bundle_name, release, bundle_digest, created, repository, components))
}

parse_native_manifest_value = |value|
	match Str.split_on(value, "=") {
		[target_text, path_text] if target_text != "" and path_text != "" => Ok(NativeManifest.{ path: Path.utf8(path_text), target: Project.Target.parse(target_text)? })
		_ => Err(InvalidNativeManifestArgument(value))
	}

safe_identifier = |value| Str.from_utf8_lossy(
	value.to_utf8().map(
		|byte| if (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '.' or byte == '-' {
			byte
		} else {
			'-'
		},
	),
)

unique = |values| {
	var $seen = []
	for value in values {
		if $seen.contains(value) {
			return Bool.False
		}
		$seen = $seen.append(value)
	}
	Bool.True
}

base_packages = |bundle_name, release, bundle_digest, dependencies, repository| [
	component("SPDXRef-Package-roc-fuzz", "roc-fuzz", release, "MIT", "https://github.com/${repository}/releases/download/${release}/${bundle_name}", Checksum(bundle_digest)),
	component("SPDXRef-Package-libFuzzer", "LLVM libFuzzer from libfuzzer-sys", dependencies.libfuzzer.version, "Apache-2.0 WITH LLVM-exception", dependencies.libfuzzer.url, Checksum(dependencies.libfuzzer.sha256.to_str())),
	component("SPDXRef-Package-Zig-runtime", "Zig runtime and compiler runtime", dependencies.zig_version, "MIT", "https://ziglang.org/download/${dependencies.zig_version}/", NoChecksum),
	component("SPDXRef-Package-musl", "musl libc bundled by Zig", dependencies.zig_version, "MIT", "https://github.com/ziglang/zig/tree/${dependencies.zig_version}/lib/libc/musl", NoChecksum),
	component("SPDXRef-Package-LLVM-runtime", "LLVM libc++, libc++abi, libunwind, and compiler-rt bundled by Zig", dependencies.zig_version, "Apache-2.0 WITH LLVM-exception", "https://github.com/ziglang/zig/tree/${dependencies.zig_version}/lib", NoChecksum),
]

component = |identifier, name, version, license, download, checksum| Package.{ identifier, name, version, license, download, checksum }

native_packages! = |manifests, release, dependencies| {
	var $found = []
	var $found_targets = []
	for manifest in manifests {
		target_name = manifest.target.name()
		if $found_targets.contains(manifest.target) {
			return Err(DuplicateNativeTarget(target_name))
		}
		entries = match Integrity.parse_manifest(Path.read_utf8!(manifest.path)?) {
			Ok(parsed) => parsed
			Err(err) => return Err(InvalidNativeManifest(Path.display(manifest.path), err))
		}
		expected = manifest.target.spec().input_names
		names = entries.map(|entry| entry.name)
		if names.len() != expected.len() or expected.any(|name| !names.contains(name)) {
			return Err(NativeManifestInventoryMismatch(target_name, Path.display(manifest.path)))
		}
		for entry in entries {
			$found = $found.append(
				component(
					"SPDXRef-Native-${target_name}-${safe_identifier(entry.name)}",
					"roc-fuzz native input ${target_name}/${entry.name}",
					native_version(entry.name, release, dependencies),
					native_license(entry.name),
					"NOASSERTION",
					Checksum(entry.digest),
				),
			)
		}
		$found_targets = $found_targets.append(manifest.target)
	}
	if $found_targets.len() != Project.all_targets.len() or !Project.all_targets.all(|target| $found_targets.contains(target)) {
		return Err(IncompleteNativeTargets)
	}
	Ok($found)
}

library_packages! = |paths, release, repository| {
	var $found = []
	var $found_targets = []
	for path in paths {
		raw : LibraryManifest
		raw = Json.parse(Path.read_utf8!(path)?).map_err(|err| InvalidLibraryManifest(Path.display(path), err))?
		target = Project.Target.parse(raw.target)?
		target_name = target.name()
		if $found_targets.contains(target) {
			return Err(DuplicateLibraryManifestTarget(target_name))
		}
		if raw.release != release or raw.repository != repository {
			return Err(LibraryManifestIdentityMismatch(Path.display(path), release, repository, raw.release, raw.repository))
		}
		if !Integrity.is_hex(raw.sha256, 64) {
			return Err(InvalidLibraryDigest(Path.display(path)))
		}
		$found = $found.append(component("SPDXRef-NativeRelease-${safe_identifier(target_name)}", "roc-fuzz native-library archive ${target_name}", raw.release, "NOASSERTION", "https://github.com/${raw.repository}/releases/download/${raw.release}/${raw.archive}", Checksum(raw.sha256)))
		$found_targets = $found_targets.append(target)
	}
	if !$found_targets.is_empty() and ($found_targets.len() != Project.all_targets.len() or !Project.all_targets.all(|target| $found_targets.contains(target))) {
		return Err(IncompleteLibraryManifestTargets)
	}
	Ok($found)
}

native_license = |name| match name {
	"libhost.a" | "crt1.o" | "libc.a" | "libzigc.a" => "MIT"
	"libfuzzer.a" | "libc++.a" | "libc++abi.a" | "libunwind.a" => "Apache-2.0 WITH LLVM-exception"
	"libcompiler_rt.a" => "(Apache-2.0 WITH LLVM-exception) AND MIT"
	_ => "NOASSERTION"
}

native_version = |name, release, dependencies| match name {
	"libhost.a" => release
	"libfuzzer.a" => dependencies.libfuzzer.version
	_ => dependencies.zig_version
}

render_document = |bundle_name, release, digest, created, repository, components| {
	package_json = Str.join_with(components.map(render_package), ",\n")
	relations = components.drop_first(1).map(|item| "    {\"spdxElementId\":\"SPDXRef-Package-roc-fuzz\",\"relationshipType\":\"${if Script.starts_with(item.identifier, "SPDXRef-NativeRelease-") "DEPENDS_ON" else "CONTAINS"}\",\"relatedSpdxElement\":${Json.to_str(item.identifier)}}")
	relation_json = Str.join_with(["    {\"spdxElementId\":\"SPDXRef-DOCUMENT\",\"relationshipType\":\"DESCRIBES\",\"relatedSpdxElement\":\"SPDXRef-Package-roc-fuzz\"}"].concat(relations), ",\n")
	"{\n  \"SPDXID\": \"SPDXRef-DOCUMENT\",\n  \"creationInfo\": {\"created\": ${Json.to_str(created)}, \"creators\": [\"Tool: roc-fuzz/scripts/build_release_sbom.roc\"], \"licenseListVersion\": \"3.27.0\"},\n  \"dataLicense\": \"CC0-1.0\",\n  \"documentDescribes\": [\"SPDXRef-Package-roc-fuzz\"],\n  \"documentNamespace\": ${Json.to_str("https://github.com/${repository}/sbom/${release}/${digest}")},\n  \"name\": ${Json.to_str("${bundle_name} release SBOM")},\n  \"packages\": [\n${package_json}\n  ],\n  \"relationships\": [\n${relation_json}\n  ],\n  \"spdxVersion\": \"SPDX-2.3\"\n}\n"
}

render_package = |item| {
	checksum = match item.checksum {
		Checksum(value) => ",\"checksums\":[{\"algorithm\":\"SHA256\",\"checksumValue\":${Json.to_str(value)}}]"
		NoChecksum => ""
	}
	"    {\"SPDXID\":${Json.to_str(item.identifier)},\"name\":${Json.to_str(item.name)},\"versionInfo\":${Json.to_str(item.version)},\"downloadLocation\":${Json.to_str(item.download)},\"filesAnalyzed\":false,\"licenseConcluded\":${Json.to_str(item.license)},\"licenseDeclared\":${Json.to_str(item.license)},\"copyrightText\":\"NOASSERTION\"${checksum}}"
}

expect native_license("libfuzzer.a") == "Apache-2.0 WITH LLVM-exception"
expect safe_identifier("x/y a") == "x-y-a"
