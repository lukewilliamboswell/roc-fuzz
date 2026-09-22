import cli.Env
import cli.OsStr
import cli.Path
import Identity
import Integrity
import Project
import Script

## Packaging, validation, and provenance for independently released native
## libraries. `libhost.a` is deliberately never part of this inventory.
NativeLibraries := [].{
	max_file_bytes : U64
	max_file_bytes = 134217728
	metadata_names = ["LICENSE", "SHA256SUMS", "THIRD_PARTY_LICENSES.md", "build.json"]

	BuildMetadata := {
		libfuzzer_sha256 : Identity.Sha256,
		libfuzzer_version : Str,
		release : Identity.NativeRelease,
		schema : U64,
		source_revision : Identity.GitRevision,
		target : Project.Target,
		zig_target : Str,
		zig_version : Str,
	}
	RawBuildMetadata : {
		libfuzzer_sha256 : Str,
		libfuzzer_version : Str,
		release : Str,
		schema : U64,
		source_revision : Str,
		target : Str,
		zig_target : Str,
		zig_version : Str,
	}

	LockTarget := { archive : Str, sha256 : Identity.Sha256 }
	LockTargets := { arm64mac : LockTarget, x64musl : LockTarget }
	Lock := { pins : LockTargets, release : Identity.NativeRelease, repository : Identity.Repository, schema : U64, source_revision : Identity.GitRevision }
	RawLock : { pins : { arm64mac : { archive : Str, sha256 : Str }, x64musl : { archive : Str, sha256 : Str } }, release : Str, repository : Str, schema : U64, source_revision : Str }
	Provenance := { archive : Str, release : Identity.NativeRelease, repository : Identity.Repository, sha256 : Identity.Sha256, source_revision : Identity.GitRevision, target : Project.Target }
	RawProvenance : { archive : Str, release : Str, repository : Str, sha256 : Str, source_revision : Str, target : Str }

	library_names = |spec| Project.library_names(spec)
	expected_names = |spec| NativeLibraries.library_names(spec).concat(NativeLibraries.metadata_names)

	read_lock! = |path, repository| {
		# `targets` is reserved Roc syntax, so rename exactly the one JSON key
		# before decoding it into the otherwise identical typed record.
		source = match Str.split_on(Path.read_utf8!(path)?, "\"targets\"") {
			[before, after] => "${before}\"pins\"${after}"
			_ => return Err(InvalidNativeLibraryLockTargetsKey)
		}
		raw : RawLock
		raw = Json.parse(source).map_err(|_| NativeLibrariesNotBootstrapped)?
		release = parse_or!(Identity.NativeRelease.parse(raw.release), InvalidNativeLibraryLock)?
		lock_repository = parse_or!(Identity.Repository.parse(raw.repository), InvalidNativeLibraryLock)?
		source_revision = parse_or!(Identity.GitRevision.parse(raw.source_revision), InvalidSourceRevision)?
		arm64_sha256 = parse_or!(Identity.Sha256.parse(raw.pins.arm64mac.sha256), InvalidNativeLibraryPin("arm64mac"))?
		x64_sha256 = parse_or!(Identity.Sha256.parse(raw.pins.x64musl.sha256), InvalidNativeLibraryPin("x64musl"))?
		lock = Lock.{ pins: LockTargets.{ arm64mac: LockTarget.{ archive: raw.pins.arm64mac.archive, sha256: arm64_sha256 }, x64musl: LockTarget.{ archive: raw.pins.x64musl.archive, sha256: x64_sha256 } }, release, repository: lock_repository, schema: raw.schema, source_revision }
		if lock.schema != 1 or lock.repository != repository {
			return Err(InvalidNativeLibraryLock)
		}
		for (name, entry) in [("arm64mac", lock.pins.arm64mac), ("x64musl", lock.pins.x64musl)] {
			if entry.archive != "${lock.release.to_str()}-${name}.tar.gz" {
				return Err(InvalidNativeLibraryPin(name))
			}
		}
		Ok(lock)
	}

	lock_target = |lock, target| match target {
		Arm64Mac => lock.pins.arm64mac
		X64Musl => lock.pins.x64musl
	}

	## Validate into a temporary directory, and copy into destination only after
	## every archive and metadata check succeeds.
	extract! = |archive, destination, spec| {
		Script.require_file!(archive)?
		if Path.is_file!(destination)? {
			return Err(NativeLibraryDestinationIsFile(Path.display(destination)))
		}
		if Path.is_dir!(destination)? and !Path.list!(destination)?.is_empty() {
			return Err(NativeLibraryDestinationNotEmpty(Path.display(destination)))
		}
		Env.with_temp_dir!(
			|temporary| {
				expected = NativeLibraries.expected_names(spec)
				extract_archive_members!(archive, temporary, expected)?
				verify_library_checksums!(temporary, NativeLibraries.library_names(spec))?
				metadata = read_build_metadata!(temporary, spec)?
				Path.create_all!(destination)?
				for name in expected {
					Path.copy!(Path.join(temporary, name), Path.join(destination, name))?
				}
				Ok(metadata)
			},
		)
	}

	provenance_json = |value|
		"{\n  \"target\": ${Json.to_str(value.target.name())},\n  \"repository\": ${Json.to_str(value.repository.to_str())},\n  \"release\": ${Json.to_str(value.release.to_str())},\n  \"source_revision\": ${Json.to_str(value.source_revision.to_str())},\n  \"archive\": ${Json.to_str(value.archive)},\n  \"sha256\": ${Json.to_str(value.sha256.to_str())}\n}\n"

	parse_provenance = |source| {
		raw : RawProvenance
		raw = Json.parse(source).map_err(|err| InvalidNativeLibraryProvenance(err))?
		target = match Project.Target.parse(raw.target) {
			Ok(value) => value
			Err(_) => return Err(InvalidNativeLibraryProvenanceTarget(raw.target))
		}
		release = parse_or!(Identity.NativeRelease.parse(raw.release), InvalidNativeLibraryProvenanceRelease)?
		repository = parse_or!(Identity.Repository.parse(raw.repository), InvalidNativeLibraryProvenanceRepository)?
		sha256 = parse_or!(Identity.Sha256.parse(raw.sha256), InvalidNativeLibraryProvenanceSha256)?
		source_revision = parse_or!(Identity.GitRevision.parse(raw.source_revision), InvalidNativeLibraryProvenanceRevision)?
		Ok(Provenance.{ archive: raw.archive, release, repository, sha256, source_revision, target })
	}

	provenance_matches = |left, right|
		left.archive == right.archive and left.release == right.release and left.repository == right.repository and left.sha256 == right.sha256 and left.source_revision == right.source_revision and left.target == right.target

	lock_json = |lock|
		"{\n  \"schema\": 1,\n  \"repository\": ${Json.to_str(lock.repository.to_str())},\n  \"release\": ${Json.to_str(lock.release.to_str())},\n  \"source_revision\": ${Json.to_str(lock.source_revision.to_str())},\n  \"targets\": {\n    \"x64musl\": {\n      \"archive\": ${Json.to_str(lock.pins.x64musl.archive)},\n      \"sha256\": ${Json.to_str(lock.pins.x64musl.sha256.to_str())}\n    },\n    \"arm64mac\": {\n      \"archive\": ${Json.to_str(lock.pins.arm64mac.archive)},\n      \"sha256\": ${Json.to_str(lock.pins.arm64mac.sha256.to_str())}\n    }\n  }\n}\n"

	metadata_json = |value|
		"{\n  \"schema\": 1,\n  \"release\": ${Json.to_str(value.release.to_str())},\n  \"source_revision\": ${Json.to_str(value.source_revision.to_str())},\n  \"target\": ${Json.to_str(value.target.name())},\n  \"zig_target\": ${Json.to_str(value.zig_target)},\n  \"zig_version\": ${Json.to_str(value.zig_version)},\n  \"libfuzzer_version\": ${Json.to_str(value.libfuzzer_version)},\n  \"libfuzzer_sha256\": ${Json.to_str(value.libfuzzer_sha256.to_str())}\n}\n"
}

extract_archive_members! = |archive, temporary, expected| {
	listed = Script.command("tar").capture!(["-tzf", Path.to_os_str(archive)], temporary, [])?
	names = Str.split_on(Str.from_utf8_lossy(listed), "\n").keep_if(|name| name != "")
	if names.len() != expected.len() or !expected.all(|name| names.contains(name)) or names.any(|name| name.contains("/") or name == "." or name == "..") {
		return Err(NativeLibraryArchiveInventoryMismatch)
	}
	verbose = Script.command("tar").capture!(["-tvzf", Path.to_os_str(archive)], temporary, [])?
	member_lines = Str.split_on(Str.from_utf8_lossy(verbose), "\n").keep_if(|line| line != "")
	if member_lines.len() != expected.len() or member_lines.any(|line| !Script.starts_with(line, "-")) {
		return Err(NativeLibraryArchiveContainsNonRegularFile)
	}
	# Explicit names prevent archive-selected paths from being written.
	args = ["-xzf", Path.to_os_str(archive), "--no-same-owner", "--no-same-permissions", "-C", Path.to_os_str(temporary), "--"].concat(names.map(OsStr.from_str))
	Script.command("tar").cmd(args).exec_cmd!()?
	for name in names {
		path = Path.join(temporary, name)
		if !Path.is_file!(path)? or Path.size_in_bytes!(path)? > NativeLibraries.max_file_bytes {
			return Err(InvalidNativeLibraryArchiveFile(name))
		}
	}
	Ok({})
}

verify_library_checksums! = |directory, libraries| {
	entries = match Integrity.parse_manifest(Path.read_utf8!(Path.join(directory, "SHA256SUMS"))?) {
		Ok(value) => value
		Err(err) => return Err(InvalidNativeLibraryManifest(err))
	}
	manifest_names = entries.map(|entry| entry.name)
	if manifest_names.len() != libraries.len() or !libraries.all(|name| manifest_names.contains(name)) {
		return Err(NativeLibraryManifestInventoryMismatch)
	}
	for entry in entries {
		actual = Integrity.digest!(Path.join(directory, entry.name))?
		if actual != entry.digest {
			return Err(NativeLibraryChecksumMismatch(entry.name))
		}
	}
	Ok({})
}

read_build_metadata! = |directory, spec| {
	raw : NativeLibraries.RawBuildMetadata
	raw = Json.parse(Path.read_utf8!(Path.join(directory, "build.json"))?).map_err(|err| InvalidNativeLibraryMetadata(err))?
	target = match Project.Target.parse(raw.target) {
		Ok(value) => value
		Err(_) => return Err(NativeLibraryTargetMismatch)
	}
	libfuzzer_sha256 = parse_or!(Identity.Sha256.parse(raw.libfuzzer_sha256), InvalidNativeLibraryMetadataSha256)?
	release = parse_or!(Identity.NativeRelease.parse(raw.release), InvalidNativeLibraryMetadataRelease)?
	source_revision = parse_or!(Identity.GitRevision.parse(raw.source_revision), InvalidNativeLibraryMetadataRevision)?
	metadata = NativeLibraries.BuildMetadata.{ libfuzzer_sha256, libfuzzer_version: raw.libfuzzer_version, release, schema: raw.schema, source_revision, target, zig_target: raw.zig_target, zig_version: raw.zig_version }
	if metadata.schema != 1 or metadata.target != spec.target or metadata.zig_target != spec.zig_target {
		return Err(NativeLibraryTargetMismatch)
	}
	Ok(metadata)
}

parse_or! = |result, error| match result {
	Ok(value) => Ok(value)
	Err(_) => Err(error)
}

expect Project.target_specs.all(|spec| !NativeLibraries.library_names(spec).contains("libhost.a"))
