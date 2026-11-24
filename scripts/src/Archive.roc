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
			name = if (Script.ends_with(entry.name, "/")) Str.from_utf8_lossy(entry.name.to_utf8().drop_last(1)) else entry.name
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
		listing = match format {
			Tar => AutomationIO.text!("tar", ["-tvf", file], root)?
			Zip => AutomationIO.text!("unzip", ["-Z", "-l", file], root)?
		}
		layout = match format {
			Tar => tar_flavor!()?
			Zip => Zipinfo
		}
		Archive.validate(Archive.listed(layout, listing)?, limit)
	}

	## Parse a verbose listing. GNU tar prints `mode owner/group size date time
	## name`, bsdtar prints `mode links owner group size date time name`, and
	## zipinfo adds header and summary lines around `mode version os size ...`.
	listed : [GnuTar, BsdTar, Zipinfo], Str -> Try(List(Entry), _)
	listed = |layout, listing| {
		var $entries = []
		for line in AutomationIO.lines(listing) {
			is_entry = match layout {
				Zipinfo => ["-", "d", "l", "c", "b", "p", "s"].any(|kind| Script.starts_with(line, kind))
				_ => Bool.True
			}
			if is_entry {
				fields = AutomationIO.words(line)
				mode = fields.first().map_err(|_| InvalidArchiveListing)?
				if !Script.starts_with(mode, "-") and !Script.starts_with(mode, "d") {
					return Err(ArchiveLinksForbidden)
				}
				index = match layout {
					Zipinfo => 3
					GnuTar => 2
					BsdTar => 4
				}
				size = U64.from_str(fields.get(index).map_err(|_| InvalidArchiveListing)?).map_err(|_| InvalidArchiveListing)?
				name = fields.last().map_err(|_| InvalidArchiveListing)?
				$entries = $entries.append({ name, size, directory: Script.starts_with(mode, "d") })
			}
		}
		Ok($entries)
	}

	## The options that make a tar archive independent of who packed it.
	ownership_options : [GnuTar, BsdTar] -> List(Str)
	ownership_options = |tar|
		match tar {
			GnuTar => ["--owner=0", "--group=0", "--numeric-owner"]
			BsdTar => ["--uid", "0", "--gid", "0", "--uname", "", "--gname", ""]
		}

	## Which tar a `tar --version` banner names.
	flavor : Str -> [GnuTar, BsdTar]
	flavor = |banner| if (banner.contains("GNU tar")) GnuTar else BsdTar

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
				ownership = Archive.ownership_options(tar_flavor!()?)
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

expect Archive.flavor("tar (GNU tar) 1.35\nCopyright (C) 2023 Free Software Foundation, Inc.\n") == GnuTar
expect Archive.flavor("bsdtar 3.5.3 - libarchive 3.7.4 zlib/1.2.12 liblzma/5.4.3 bz2lib/1.0.8 \n") == BsdTar
expect Archive.listed(GnuTar, "-rw-r--r-- 0/0               6 2026-11-24 10:54 a.txt\ndrwxr-xr-x 0/0               0 2026-11-24 10:54 dir/\n") == Ok([{ name: "a.txt", size: 6, directory: Bool.False }, { name: "dir/", size: 0, directory: Bool.True }])
expect Archive.listed(BsdTar, "-rw-r--r--  0 0      0           6 24 Nov 10:54 a.txt\n") == Ok([{ name: "a.txt", size: 6, directory: Bool.False }])
# The layouts are not interchangeable: GNU's time column is not a size.
expect Archive.listed(BsdTar, "-rw-r--r-- 0/0               6 2026-11-24 10:54 a.txt\n") |> Try.is_err
expect Archive.listed(GnuTar, "lrwxr-xr-x 0/0               0 2026-11-24 10:54 link -> missing\n") |> Try.is_err
expect Archive.listed(Zipinfo, "Archive:  x.zip\nZip file size: 1 bytes, number of entries: 1\n-rw-r--r--  3.0 unx        6 tx defX 26-Nov-24 10:54 a.txt\n1 file, 6 bytes uncompressed\n") == Ok([{ name: "a.txt", size: 6, directory: Bool.False }])

## The archiver on PATH decides the listing layout and the ownership options,
## not the operating system: a Nix environment on macOS provides GNU tar.
tar_flavor! = || AutomationIO.text!("tar", ["--version"], Env.cwd!()?).map_ok(Archive.flavor)
