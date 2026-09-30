import cli.Env
import cli.Path
import Archive
import AutomationIO
import Integrity
import Project
import Script
import WorkspaceDeps

## Immutable native-input packaging, lock validation and installation.
LinkInputs := [].{
	Asset : { asset : Str, sha256 : Str, size : U64 }
	Source : { repository : Str, sha : Str, ref : Str, workflow : Str, input_fingerprint : Str }
	Targets : { arm64mac : Asset, x64musl : Asset }
	Manifest : { schema_version : U64, kind : Str, source : Source, assets : Targets }
	Lock : { schema_version : U64, kind : Str, repository : Str, release : Str, manifest : { asset : Str, sha256 : Str }, source : Source, artifacts : Targets }
	Metadata : { schema_version : U64, kind : Str, target : Str, input_fingerprint : Str, files : List(Str), licenses : List(Str) }
	Provenance : { target : Str, repository : Str, release : Str, source_revision : Str, archive : Str, sha256 : Str }
	licenses = ["LICENSE", "THIRD_PARTY_LICENSES.md"]
	limit : U64
	limit = 512 * 1024 * 1024
	files = |target| Project.library_names(target.spec())
	asset : Targets, Project.Target -> Asset
	asset = |artifacts, target| if target.name() == "x64musl" artifacts.x64musl else artifacts.arm64mac
	fingerprint! = |root| {
		names = AutomationIO.tracked!(root, [".github/workflows/native-libraries.yml", ".github/actions/setup-workspace-roc", "scripts/build_platform.roc", "scripts/link_input_artifacts.roc", "scripts/src", "scripts/workspace-deps.json", "src/macos_fuzzer_ext_functions.cpp", "LICENSE", "THIRD_PARTY_LICENSES.md"])?
		var $entries = []
		for name in names {
			path = Path.join(root, name)
			bytes = if name == "scripts/workspace-deps.json" WorkspaceDeps.fingerprint_source(Path.read_utf8!(path)?)?.to_utf8() else Path.read_bytes!(path)?
			$entries = $entries.append({ path: name, sha256: Integrity.digest_bytes(bytes) })
		}
		Ok(Integrity.digest_bytes(Json.to_str($entries).to_utf8()))
	}
	metadata : Project.Target, Str -> Metadata
	metadata = |target, fingerprint| { schema_version: 1, kind: "link-inputs", target: target.name(), input_fingerprint: fingerprint, files: LinkInputs.files(target), licenses: LinkInputs.licenses }
	package! = |root, output, source| {
		fingerprint = LinkInputs.fingerprint!(root)?
		actual_source = { ..source, input_fingerprint: fingerprint }
		arm64mac = package_target!(root, output, Project.Target.Arm64Mac, fingerprint)?
		x64musl = package_target!(root, output, Project.Target.X64Musl, fingerprint)?
		manifest : Manifest
		manifest = { schema_version: 1, kind: "link-inputs", source: actual_source, assets: { arm64mac, x64musl } }
		AutomationIO.json!(Path.join(output, "build-input-release.json"), manifest)
	}
	validate_lock : Lock, Str -> Try(Lock, _)
	validate_lock = |lock, fingerprint| {
		if lock.schema_version != 1 or lock.kind != "link-inputs" {
			return Err(UnsupportedLinkInputLock)
		}
		if !valid_repository(lock.repository) or lock.manifest.asset != "build-input-release.json" or !Integrity.is_hex(lock.manifest.sha256, 64) {
			return Err(InvalidLinkInputManifest)
		}
		if lock.release != "linker-inputs-sha256-${lock.manifest.sha256}" {
			return Err(ReleaseMustIdentifyManifest)
		}
		source = lock.source
		if source.repository != lock.repository or !Integrity.is_hex(source.sha, 40) or !Script.starts_with(source.ref, "refs/heads/") or !Archive.safe_name(source.ref) or source.workflow != "${lock.repository}/.github/workflows/native-libraries.yml" or !Integrity.is_hex(source.input_fingerprint, 64) {
			return Err(InvalidLinkInputSource)
		}
		for target in Project.all_targets {
			item = LinkInputs.asset(lock.artifacts, target)
			if item.asset != "link-inputs-${target.name()}.tar" or !Integrity.is_hex(item.sha256, 64) or item.size == 0 or item.size > LinkInputs.limit {
				return Err(InvalidLinkInputAsset(target.name()))
			}
		}
		if source.input_fingerprint != fingerprint {
			return Err(StaleLinkInputLockPublishReviewedInputs)
		}
		Ok(lock)
	}
	read_lock! = |root| {
		# `targets` is a Roc keyword. Adapt the publisher's literal JSON key only
		# at this boundary; never accept the internal alias in a published lock.
		encoded = Path.read_utf8!(Path.join(root, "native-libraries.lock.json"))?
		if encoded.contains("\"artifacts\"") {
			return Err(InvalidLinkInputLockKey)
		}
		lock : Lock
		lock = Json.parse(Str.replace_each(encoded, "\"targets\"", "\"artifacts\""))?
		LinkInputs.validate_lock(lock, LinkInputs.fingerprint!(root)?)
	}
	cache_identity! = |root, target| {
		lock = LinkInputs.read_lock!(root)?
		item = LinkInputs.asset(lock.artifacts, target)
		Ok("${lock.manifest.sha256}-${item.sha256}-${item.size.to_str()}")
	}
	verify_archive! = |root, target, cache| {
		lock = LinkInputs.read_lock!(root)?
		base = "https://github.com/${lock.repository}/releases/download/${lock.release}"
		manifest_path = Path.join(cache, lock.manifest.asset)
		AutomationIO.verified_download!("${base}/${lock.manifest.asset}", manifest_path, lock.manifest.sha256)?
		manifest : Manifest
		manifest = Json.parse(Path.read_utf8!(manifest_path)?)?
		if manifest != { schema_version: 1, kind: lock.kind, source: lock.source, assets: lock.artifacts } {
			return Err(ManifestDisagreesWithLock)
		}
		item = LinkInputs.asset(lock.artifacts, target)
		archive = Path.join(cache, item.asset)
		AutomationIO.verified_download!("${base}/${item.asset}", archive, item.sha256)?
		if Path.read_bytes!(archive)?.len() != item.size {
			return Err(ArchiveSizeDisagreesWithLock)
		}
		Ok((archive, lock))
	}
	extract! = |target, archive, destination, fingerprint| {
		entries = Archive.entries!(Archive.Format.Tar, archive, LinkInputs.limit)?
		expected = ["link-inputs.json"].concat(LinkInputs.files(target)).concat(LinkInputs.licenses)
		if entries.len() != expected.len() or entries.any(|entry| entry.directory or !expected.contains(entry.name)) {
			return Err(LinkInputInventoryMismatch)
		}
		_ = Archive.extract!(Archive.Format.Tar, archive, destination, LinkInputs.limit)?
		actual_metadata : Metadata
		actual_metadata = Json.parse(Path.read_utf8!(Path.join(destination, "link-inputs.json"))?)?
		if actual_metadata != LinkInputs.metadata(target, fingerprint) {
			return Err(LinkInputMetadataMismatch)
		}
		Ok({})
	}
	install! = |root, target, cache| {
		(archive, lock) = LinkInputs.verify_archive!(root, target, cache)?
		destination = target.dir(root)
		provenance_path = Path.join(destination, "NATIVE_LIBRARIES.json")
		Env.with_temp_dir!(
			|temp| {
				staging = Path.join(temp, "inputs")
				LinkInputs.extract!(target, archive, staging, lock.source.input_fingerprint)?
				if Path.exists!(provenance_path)? {
					Path.delete!(provenance_path)?
				}
				for name in LinkInputs.files(target) {
					Path.copy!(Path.join(staging, name), Path.join(destination, name))?
				}
				AutomationIO.json!(provenance_path, provenance(lock, target))
			},
		)
	}
	check_installed! = |root| {
		lock = LinkInputs.read_lock!(root)?
		for target in Project.all_targets {
			actual : Provenance
			actual = Json.parse(Path.read_utf8!(Path.join(target.dir(root), "NATIVE_LIBRARIES.json"))?)?
			if actual != provenance(lock, target) {
				return Err(InstalledProvenanceMismatch(target.name()))
			}
		}
		Ok({})
	}
}

valid_repository = |value| match Str.split_on(value, "/") {
	[owner, name] => Archive.safe_name(owner) and Archive.safe_name(name)
	_ => Bool.False
}

provenance = |lock, target| {
	item = LinkInputs.asset(lock.artifacts, target)
	{ target: target.name(), repository: lock.repository, release: lock.release, source_revision: lock.source.sha, archive: item.asset, sha256: item.sha256 }
}

package_target! = |root, output, target, fingerprint| Env.with_temp_dir!(
	|staging| {
		for name in LinkInputs.files(target) {
			Path.copy!(Path.join(target.dir(root), name), Path.join(staging, name))?
		}
		for name in LinkInputs.licenses {
			Path.copy!(Path.join(root, name), Path.join(staging, name))?
		}
		AutomationIO.json!(Path.join(staging, "link-inputs.json"), LinkInputs.metadata(target, fingerprint))?
		asset = "link-inputs-${target.name()}.tar"
		archive = Path.join(output, asset)
		Archive.pack!(Archive.Format.Tar, staging, ["link-inputs.json"].concat(LinkInputs.files(target)).concat(LinkInputs.licenses), archive)?
		Ok({ asset, sha256: Integrity.digest!(archive)?, size: Path.read_bytes!(archive)?.len() })
	},
)
