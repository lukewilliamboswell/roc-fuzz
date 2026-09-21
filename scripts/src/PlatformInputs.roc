import cli.Path
import Integrity
import Project

## Validate and record generated platform inputs.
PlatformInputs := [].{
	manifest_name = "SHA256SUMS"

	write_manifest! = |root, spec| {
		directory = Project.Target.dir(spec.target, root)
		entries = manifest_entries!(directory, Project.Target.name(spec.target), spec.input_names, [])?
		manifest = Path.join(directory, manifest_name)
		Path.write_utf8!(manifest, Integrity.render_manifest(entries))?
		Ok(manifest)
	}

	validate! : Path, List(Project.TargetSpec) => Try(List(Path), _)
	validate! = |root, specs| validate_specs!(root, specs, [])
}

validate_specs! : Path, List(Project.TargetSpec), List(Path) => Try(List(Path), _)
validate_specs! = |root, specs, found|
	match specs {
		[spec, .. as rest] => {
			target_name = Project.Target.name(spec.target)
			directory = Project.Target.dir(spec.target, root)
			manifest = Path.join(directory, PlatformInputs.manifest_name)
			if !Path.is_file!(manifest)? {
				return Err(MissingPlatformManifest(target_name, Path.display(manifest)))
			}
			entries = Integrity.parse_manifest(Path.read_utf8!(manifest)?)?
			names = entries.map(|entry| entry.name)
			if names.len() != spec.input_names.len() or !spec.input_names.all(|name| names.contains(name)) {
				return Err(PlatformManifestInventoryMismatch(target_name, names))
			}
			paths = validate_names!(directory, target_name, spec.input_names, entries, [])?
			validate_specs!(root, rest, found.concat(paths))
		}
		[] => Ok(found)
	}

manifest_entries! = |directory, target_name, names, found|
	match names {
		[name, .. as rest] => {
			path = Path.join(directory, name)
			if !Path.is_file!(path)? {
				return Err(MissingPlatformInput(target_name, name))
			}
			digest = Integrity.digest!(path)?
			manifest_entries!(directory, target_name, rest, found.append(Integrity.ManifestEntry.{ digest, name }))
		}
		[] => Ok(found)
	}

validate_names! = |directory, target_name, names, entries, found|
	match names {
		[name, .. as rest] => {
			path = Path.join(directory, name)
			if !Path.is_file!(path)? {
				return Err(MissingPlatformInput(target_name, name))
			}
			entry = entries.find_first(|candidate| candidate.name == name).map_err(|_| MissingPlatformManifestEntry(target_name, name))?
			actual = Integrity.digest!(path)?
			if actual != entry.digest {
				return Err(PlatformInputChecksumMismatch(target_name, name, actual))
			}
			validate_names!(directory, target_name, rest, entries, found.append(path))
		}
		[] => Ok(found)
	}
