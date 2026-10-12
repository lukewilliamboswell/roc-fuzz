import cli.Env
import cli.Path
import AutomationIO
import Script

## Validate inventories before invoking system archivers. Only regular files and
## directories with portable, relative names are accepted
## Links are forbidden.
Archive := [].{
	Format := [Tar, Zip].{}
	Entry : { name : Str, size : U64, directory : Bool }
	safe_name = |name| {
		parts = Str.split_on(name, "/")
		!name.is_empty() and !Script.starts_with(name, "/") and !Script.starts_with(name, "-")
			and !parts.any(|part| part.is_empty() or part == ".." or part == "." or part == ".git")
				and name.to_utf8().all(|b| (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or [43, 45, 46, 47, 95].contains(b))
	}
	validate : List(Entry), U64 -> Try(List(Entry), _)
	validate = |entries, limit| {
		var $seen = []
		var $total = 0
		for entry in entries {
			name = if Script.ends_with(entry.name, "/") Str.from_utf8_lossy(entry.name.to_utf8().drop_last(1)) else entry.name
			if !Archive.safe_name(name) or $seen.contains(name) {
				return Err(UnsafeArchiveName(entry.name))
			}
			if entry.size > limit - $total {
				return Err(ArchiveTooLarge)
			}
			$total = $total + entry.size
			$seen = $seen.append(name)
		}
		Ok(entries)
	}
	entries! : Format, Path, U64 => Try(List(Entry), _)
	entries! = |format, archive, limit| {
		root = Env.cwd!()?
		file = Path.display(Path.absolute!(archive)?)
		is_mac = Env.platform!().os == MACOS
		listing = match format {
			Tar => AutomationIO.text!("tar", ["-tvf", file], root)?
			Zip => AutomationIO.text!("unzip", ["-Z", "-l", file], root)?
		}
		lines = AutomationIO.lines(listing)
		var $entries = []
		for line in lines {
			# Zipinfo has summary/header lines
			# Tar lists only entries.
			if (match format {
				Tar => Bool.True
				Zip => Bool.False
			}) or Script.starts_with(line, "-") or Script.starts_with(line, "d") or Script.starts_with(line, "l") or Script.starts_with(line, "c") or Script.starts_with(line, "b") or Script.starts_with(line, "p") or Script.starts_with(line, "s") {
				fields = AutomationIO.words(line)
				mode = fields.first().map_err(|_| InvalidArchiveListing)?
				if !Script.starts_with(mode, "-") and !Script.starts_with(mode, "d") {
					return Err(ArchiveLinksForbidden)
				}
				index = match format {
					Zip => 3
					Tar => if is_mac 4 else 2
				}
				size = U64.from_str(fields.get(index).map_err(|_| InvalidArchiveListing)?).map_err(|_| InvalidArchiveListing)?
				name = fields.last().map_err(|_| InvalidArchiveListing)?
				$entries = $entries.append({ name, size, directory: Script.starts_with(mode, "d") })
			}
		}
		Archive.validate($entries, limit)
	}
	extract! : Format, Path, Path, U64 => Try(List(Entry), _)
	extract! = |format, archive, destination, limit| {
		entries = Archive.entries!(format, archive, limit)?
		if Path.exists!(destination)? {
			return Err(ArchiveDestinationExists(Path.display(destination)))
		}
		Path.create_all!(destination)?
		# Read each regular member to stdout and write its validated destination.
		# Never let an archiver create paths, links, devices or overwrite files.
		for entry in entries {
			if !entry.directory {
				bytes = match format {
					Tar => AutomationIO.bytes!("tar", ["-xOf", Path.display(archive), entry.name], Env.cwd!()?)?
					Zip => AutomationIO.bytes!("unzip", ["-p", Path.display(archive), entry.name], Env.cwd!()?)?
				}
				if bytes.len() != entry.size {
					return Err(ArchiveSizeMismatch(entry.name))
				}
				AutomationIO.write!(Path.join(destination, entry.name), bytes)?
			}
		}
		Ok(entries)
	}
	pack! = |format, source, names, output| {
		output_absolute = Path.absolute!(output)?
		Path.create_all!(AutomationIO.parent(output_absolute))?
		if Path.exists!(output_absolute)? {
			Path.delete!(output_absolute)?
		}
		for name in names {
			if !Archive.safe_name(name) or Path.type!(Path.join(source, name))? != IsFile {
				return Err(UnsafeArchiveName(name))
			}
			AutomationIO.run!("chmod", ["0644", name], source)?
			AutomationIO.run!("touch", ["-t", "198001010000", name], source)?
		}
		match format {
			Zip => AutomationIO.run!("zip", ["-X", "-q", Path.display(output_absolute)].concat(names), source)
			Tar => {
				ownership = if Env.platform!().os == MACOS ["--uid", "0", "--gid", "0", "--uname", "", "--gname", ""] else ["--owner=0", "--group=0", "--numeric-owner"]
				AutomationIO.run!("tar", ["--format=ustar"].concat(ownership).concat(["-cf", Path.display(output_absolute)]).concat(names), source)
			}
		}
	}
}

expect !Archive.safe_name("../outside")
expect !Archive.safe_name("/absolute")
expect !Archive.safe_name("examples/*.roc")
expect Archive.safe_name("examples/stack/main.roc")
expect Archive.validate([{ name: "a", size: 1, directory: Bool.False }, { name: "a", size: 1, directory: Bool.False }], 100) |> Try.is_err
expect Archive.validate([{ name: "a", size: 101, directory: Bool.False }], 100) |> Try.is_err
