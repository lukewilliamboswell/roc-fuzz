import cli.Path
import deflate.Deflate
import deflate.Gzip
import tar.Tar
import zip.Zip
import AutomationIO
import Files
import Script

## Read and write tar and ZIP archives in memory, with the tar and ZIP packages.
## Only regular files and directories with portable, relative names are
## accepted: a link, a device or anything else refuses the whole archive. Every
## member is read and checked before anything is written, and the scripts write
## each file themselves, so no archive ever creates a path, a link or a device.
Archive := [].{
	Format := [Tar, Zip].{}
	Entry : { name : Str, size : U64, directory : Bool }
	Member : { entry : Entry, bytes : List(U8) }

	validate : List(Entry), U64 -> Try(List(Entry), _)
	validate = |entries, limit| {
		var $seen = []
		var $total = 0
		for entry in entries {
			name = if (Script.ends_with(entry.name, "/")) Str.from_utf8_lossy(entry.name.to_utf8().drop_last(1)) else entry.name
			if !Files.safe_name(name) or $seen.contains(name) {
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

	## The members of an archive under `within`, a directory name ending in `/`
	## (or empty for all of them), named relative to it, with the bytes of each
	## file when `collect` is set. A member outside `within` is skipped unread
	## and unchecked. `limit` bounds the archive, decompressed, and the members
	## together.
	members : Format, List(U8), Str, U64, Bool -> Try(List(Member), _)
	members = |format, archive, within, limit, collect| {
		found = match format {
			Tar => read_tar(gunzipped(archive, limit)?, within, limit, collect)?
			Zip => read_zip(archive, within, limit, collect)?
		}
		_ = Archive.validate(found.map(|member| member.entry), limit)?
		for member in found {
			if !member.entry.directory and collect and member.bytes.len() != member.entry.size {
				return Err(ArchiveSizeMismatch(member.entry.name))
			}
		}
		Ok(found)
	}

	## An archive of `files`, each a regular file with mode 0644, owned by user
	## and group 0 with no names, modified at 1980-01-01 00:00 UTC, in the order
	## given. The same files always give the same bytes: a tar archive is ustar,
	## and a ZIP archive is DEFLATE compressed and records no extra fields.
	packed : Format, List({ name : Str, bytes : List(U8) }) -> Try(List(U8), _)
	packed = |format, files| {
		for file in files {
			if !Files.safe_name(file.name) {
				return Err(UnsafeArchiveName(file.name))
			}
		}
		match format {
			Tar => Tar.create(files.map(|file| { ..Tar.file(file.name, file.bytes), mtime: epoch_1980 })).map_err(|err| UnwritableTarMember(Tar.write_err_to_str(err)))
			Zip => {
				items : List(Zip.Item)
				items = files.map(|file| File({ path: file.name, content: file.bytes, mode: Unix(0o644) }))
				Zip.create_items(items, Balanced).map_err(|err| UnwritableZipMember(err))
			}
		}
	}

	entries! : Format, Path, U64 => Try(List(Entry), _)
	entries! = |format, archive, limit| Ok(Archive.members(format, Path.read_bytes!(archive)?, "", limit, Bool.False)?.map(|member| member.entry))

	extract! : Format, Path, Path, U64 => Try(List(Entry), _)
	extract! = |format, archive, destination, limit| Archive.extract_under!(format, archive, "", destination, limit)

	## Extract the members inside `directory` of the archive, named relative to
	## it, into the fresh `destination`. An empty `directory` is the whole
	## archive.
	extract_under! : Format, Path, Str, Path, U64 => Try(List(Entry), _)
	extract_under! = |format, archive, directory, destination, limit| {
		within = if (directory.is_empty() or Script.ends_with(directory, "/")) directory else "${directory}/"
		found = Archive.members(format, Path.read_bytes!(archive)?, within, limit, Bool.True)?
		if Path.exists!(destination)? {
			return Err(ArchiveDestinationExists(Path.display(destination)))
		}
		Path.create_all!(destination)?
		for member in found {
			if !member.entry.directory {
				AutomationIO.write!(Path.join(destination, member.entry.name), member.bytes)?
			}
		}
		Ok(found.map(|member| member.entry))
	}

	pack! : Format, Path, List(Str), Path => Try({}, _)
	pack! = |format, source, names, output| {
		var $files = []
		for name in names {
			if !Files.safe_name(name) or Path.type!(Path.join(source, name))? != IsFile {
				return Err(UnsafeArchiveName(name))
			}
			$files = $files.append({ name, bytes: Path.read_bytes!(Path.join(source, name))? })
		}
		AutomationIO.write!(output, Archive.packed(format, $files)?)
	}
}

## 1980-01-01 00:00:00 UTC, the earliest time a ZIP header can record.
epoch_1980 : U64
epoch_1980 = 315532800

## A gzip file, such as a `.tar.gz` or a `.crate`, holds a tar archive: every
## member's CRC-32 and size are checked, and nothing may follow the last one.
## Anything else is taken as it is.
gunzipped : List(U8), U64 -> Try(List(U8), _)
gunzipped = |archive, limit|
	if archive.starts_with([0x1f, 0x8b]) {
		Gzip.decompress(archive, Deflate.Bounds.{ max_output: limit }).map_err(|err| InvalidGzipFile(err))
	} else {
		Ok(archive)
	}

## The part of `name` after `within`, when it names a member inside it.
inside : Str, Str -> Try(Str, [Outside])
inside = |name, within|
	if within.is_empty() {
		Ok(name)
	} else if Script.starts_with(name, within) and name != within {
		Ok(Str.from_utf8_lossy(name.to_utf8().drop_first(within.to_utf8().len())))
	} else {
		Err(Outside)
	}

read_tar : List(U8), Str, U64, Bool -> Try(List(Archive.Member), _)
read_tar = |archive, within, limit, collect| {
	choose = |entry| if (collect and entry.kind == File and inside(entry.path, within).is_ok()) Collect(limit) else Skip
	invalid = |err| InvalidTarArchive(Tar.err_to_str(err))
	(reader, events) = Tar.new(Tar.Limits.{ max_total_size: limit, max_collect_bytes: limit }).push(archive, choose).map_err(invalid)?
	summary = reader.finish().map_err(invalid)?
	if summary.end != TwoZeroBlocks {
		return Err(TarArchiveHasNoEnd)
	}
	var $found = []
	for event in events {
		match event {
			Entry(entry) =>
				match inside(entry.path, within) {
					Ok(name) => {
						directory = match entry.kind {
							# Type `7`, a contiguous file, is a file to some readers and not to others.
							File if entry.type_byte != '7' => Bool.False
							Dir => Bool.True
							Symlink | HardLink => return Err(ArchiveLinksForbidden(entry.path))
							_ => return Err(ArchiveMemberNotFileOrDirectory(entry.path))
						}
						# A collected file arrives with its content.
						if directory or !collect {
							$found = $found.append({ entry: { name, size: entry.size, directory }, bytes: [] })
						}
					}
					Err(Outside) => {}
				}
			Content(entry, bytes) =>
				match inside(entry.path, within) {
					Ok(name) => {
						$found = $found.append({ entry: { name, size: entry.size, directory: Bool.False }, bytes })
					}
					Err(Outside) => {}
				}
		}
	}
	Ok($found)
}

read_zip : List(U8), Str, U64, Bool -> Try(List(Archive.Member), _)
read_zip = |archive, within, limit, collect| {
	listed = Zip.entries(archive).map_err(|err| InvalidZipArchive(err))?
	var $found = []
	var $total = 0
	for item in listed {
		match inside(item.path, within) {
			Ok(name) => {
				# The kind follows the entry's Unix mode when it has one and its
				# name otherwise, as unzip and bsdtar decide; a mode and a name
				# that disagree are `Other`.
				directory = match Zip.kind(item) {
					File => Bool.False
					Directory => Bool.True
					SymbolicLink => return Err(ArchiveLinksForbidden(item.path))
					Other => return Err(ArchiveMemberNotFileOrDirectory(item.path))
				}
				if item.uncompressed_size > limit - $total {
					return Err(ArchiveTooLarge)
				}
				$total = $total + item.uncompressed_size
				bytes = if (collect and !directory) Zip.extract_entry(archive, item, Zip.EntryLimits.{ max_bytes: item.uncompressed_size }).map_err(|err| InvalidZipArchive(err))? else []
				$found = $found.append({ entry: { name, size: item.uncompressed_size, directory }, bytes })
			}
			Err(Outside) => {}
		}
	}
	Ok($found)
}

## The value of `next` for an `Ok`; an `Err` as it is.
then = |result, next|
	match result {
		Ok(value) => next(value)
		Err(err) => Err(err)
	}

files = [{ name: "a.txt", bytes: "hello\n".to_utf8() }, { name: "dir/b.bin", bytes: [0, 1, 255, 0] }]

listing = |format, archive, limit| Archive.members(format, archive, "", limit, Bool.False).map_ok(|found| found.map(|member| member.entry))

contents = |format, archive, limit| Archive.members(format, archive, "", limit, Bool.True).map_ok(|found| found.map(|member| { name: member.entry.name, bytes: member.bytes }))

# Both formats give back exactly what they were given, in order.
expect Archive.packed(Tar, files) |> then(|archive| contents(Tar, archive, 100)) == Ok(files)
expect Archive.packed(Zip, files) |> then(|archive| contents(Zip, archive, 100)) == Ok(files)
expect Archive.packed(Tar, files) |> then(|archive| listing(Tar, archive, 100)) == Ok([{ name: "a.txt", size: 6, directory: Bool.False }, { name: "dir/b.bin", size: 4, directory: Bool.False }])
expect Archive.packed(Zip, files) |> then(|archive| listing(Zip, archive, 100)) == Ok([{ name: "a.txt", size: 6, directory: Bool.False }, { name: "dir/b.bin", size: 4, directory: Bool.False }])
expect Archive.packed(Tar, files) == Archive.packed(Tar, files)
expect Archive.packed(Zip, files) == Archive.packed(Zip, files)

# The limit bounds the members together.
expect Archive.packed(Tar, files) |> then(|archive| listing(Tar, archive, 9)) |> Try.is_err
expect Archive.packed(Zip, files) |> then(|archive| listing(Zip, archive, 9)) |> Try.is_err
expect Archive.packed(Zip, files) |> then(|archive| contents(Zip, archive, 9)) |> Try.is_err
expect Archive.packed(Tar, files) |> then(|archive| listing(Tar, archive, 10)) |> Try.is_ok

# Names must be portable and relative, on the way in and on the way out.
expect Archive.packed(Tar, [{ name: "../outside", bytes: [] }]).is_err()
expect Archive.packed(Zip, [{ name: "a b", bytes: [] }]).is_err()
expect Zip.create([{ path: "../outside", content: [] }], None) |> then(|archive| listing(Zip, archive, 100)) |> Try.is_err
expect Tar.create([Tar.file("a b", [])]).map_err(|_| Unwritable) |> then(|archive| listing(Tar, archive, 100)) |> Try.is_err
expect Tar.create([Tar.file("dir/.git/config", [])]).map_err(|_| Unwritable) |> then(|archive| listing(Tar, archive, 100)) |> Try.is_err

# Directories are listed and never written as files.
expect Tar.create([Tar.dir("dir/"), Tar.file("dir/a", [1])]).map_err(|_| Unwritable) |> then(|archive| listing(Tar, archive, 100)) == Ok([{ name: "dir/", size: 0, directory: Bool.True }, { name: "dir/a", size: 1, directory: Bool.False }])
expect Zip.create_items([Directory({ path: "dir/" })], None).map_err(|_| Unwritable) |> then(|archive| listing(Zip, archive, 100)) == Ok([{ name: "dir/", size: 0, directory: Bool.True }])

# Links of every kind refuse the archive, as do devices.
expect Tar.create([Tar.file("a", []), Tar.symlink("link", "missing")]).map_err(|_| Unwritable) |> then(|archive| listing(Tar, archive, 100)) == Err(ArchiveLinksForbidden("link"))
expect Tar.create([Tar.file("a", []), Tar.hard_link("link", "a")]).map_err(|_| Unwritable) |> then(|archive| listing(Tar, archive, 100)) == Err(ArchiveLinksForbidden("link"))
expect Zip.create_items([SymbolicLink({ path: "link", target: "missing" })], None).map_err(|_| Unwritable) |> then(|archive| listing(Zip, archive, 100)) == Err(ArchiveLinksForbidden("link"))
expect Tar.create([Tar.file("device", [])]).map_err(|_| Unwritable).map_ok(|archive| with_type(archive, '3')) |> then(|archive| listing(Tar, archive, 100)) == Err(ArchiveMemberNotFileOrDirectory("device"))
expect Tar.create([Tar.file("contiguous", [])]).map_err(|_| Unwritable).map_ok(|archive| with_type(archive, '7')) |> then(|archive| listing(Tar, archive, 100)) == Err(ArchiveMemberNotFileOrDirectory("contiguous"))

# A member may appear once, and an archive must be whole.
expect Tar.create([Tar.file("a", [1])]).map_err(|_| Unwritable) |> then(|one| listing(Tar, one.drop_last(1024).concat(one), 100)) == Err(UnsafeArchiveName("a"))
expect Archive.packed(Tar, files) |> then(|archive| listing(Tar, archive.take_first(2048), 100)) == Err(TarArchiveHasNoEnd)
expect Archive.packed(Tar, files) |> then(|archive| listing(Tar, archive.take_first(1536), 100)) |> Try.is_err
expect Archive.packed(Tar, files) |> then(|archive| listing(Tar, archive.take_first(1000), 100)) |> Try.is_err
expect Archive.packed(Zip, files) |> then(|archive| listing(Zip, archive.drop_last(1), 100)) |> Try.is_err

# A gzip file holds a tar archive, and a damaged one is refused.
expect Archive.packed(Tar, files).map_ok(|archive| Gzip.compress(archive, 6)) |> then(|archive| contents(Tar, archive, 100000)) == Ok(files)
expect Archive.packed(Tar, files).map_ok(|archive| Gzip.compress(archive, 6)) |> then(|archive| contents(Tar, archive, 100)) |> Try.is_err
expect Archive.packed(Tar, files).map_ok(|archive| Gzip.compress(archive, 6).drop_last(8).concat([0, 0, 0, 0, 0, 0, 0, 0])) |> then(|archive| contents(Tar, archive, 100000)) |> Try.is_err
expect Archive.packed(Tar, files).map_ok(|archive| Gzip.compress(archive, 6).concat([0])) |> then(|archive| contents(Tar, archive, 100000)) |> Try.is_err

# Extracting part of an archive reads nothing outside it.
expect Tar.create([Tar.file("root/keep/a", [1]), Tar.symlink("root/link", "x"), Tar.file("root/keep", [2])]).map_err(|_| Unwritable) |> then(|archive| Archive.members(Tar, archive, "root/keep/", 100, Bool.True)) == Ok([{ entry: { name: "a", size: 1, directory: Bool.False }, bytes: [1] }])
expect Zip.create_items([File({ path: "root/keep/a", content: [1] }), SymbolicLink({ path: "root/link", target: "x" })], None).map_err(|_| Unwritable) |> then(|archive| Archive.members(Zip, archive, "root/keep/", 100, Bool.True)) == Ok([{ entry: { name: "a", size: 1, directory: Bool.False }, bytes: [1] }])

# Archives made by GNU tar 1.35 (`tar --format=ustar --owner=0 --group=0
# --numeric-owner`) and by Info-ZIP zip 3.0 (`zip -X -q -y`), from a file `a.txt`
# holding "hello\n" and a symbolic link `link` to `missing`, both modified at
# 1980-01-01 00:00 UTC. The tar headers are written out field by field.
gnu_file_header = ustar_header([(0, "a.txt"), (100, "0000644"), (108, "0000000"), (116, "0000000"), (124, "00000000006"), (136, "02263523000"), (148, "006751"), (155, " "), (156, "0"), (257, "ustar"), (263, "00")])

gnu_link_header = ustar_header([(0, "link"), (100, "0000755"), (108, "0000000"), (116, "0000000"), (124, "00000000000"), (136, "02263523000"), (148, "010241"), (155, " "), (156, "2"), (157, "missing"), (257, "ustar"), (263, "00")])

gnu_file_data = "hello\n".to_utf8().concat(List.repeat(0, 506))

gnu_plain = gnu_file_header.concat(gnu_file_data).concat(List.repeat(0, 9216))

gnu_linked = gnu_file_header.concat(gnu_file_data).concat(gnu_link_header).concat(List.repeat(0, 8704))

info_zip_plain = hex("504b03040a00000000000000210020303a36060000000600000005000000612e74787468656c6c6f0a504b01021e030a00000000000000210020303a360600000006000000050000000000000001000000a48100000000612e747874504b0506000000000100010033000000290000000000")

info_zip_linked = hex("504b03040a00000000000000210020303a36060000000600000005000000612e74787468656c6c6f0a504b03040a000000000000002100d97ba0f00700000007000000040000006c696e6b6d697373696e67504b01021e030a00000000000000210020303a360600000006000000050000000000000001000000a48100000000612e747874504b01021e030a000000000000002100d97ba0f00700000007000000040000000000000000000000eda1290000006c696e6b504b0506000000000200020065000000520000000000")

# What the programs wrote reads back byte for byte, and their links are refused.
expect contents(Tar, gnu_plain, 100) == Ok([{ name: "a.txt", bytes: "hello\n".to_utf8() }])
expect contents(Zip, info_zip_plain, 100) == Ok([{ name: "a.txt", bytes: "hello\n".to_utf8() }])
expect listing(Tar, gnu_linked, 100) == Err(ArchiveLinksForbidden("link"))
expect listing(Zip, info_zip_linked, 100) == Err(ArchiveLinksForbidden("link"))
expect Archive.members(Zip, info_zip_linked, "a.txt/", 100, Bool.True) == Ok([])

## A ustar header of the given ASCII fields, with every other byte NUL.
ustar_header : List((U64, Str)) -> List(U8)
ustar_header = |fields| {
	var $header = List.repeat(0, 512)
	for (offset, text) in fields {
		var $at = offset
		for byte in text.to_utf8() {
			$header = $header.set($at, byte) ?? $header
			$at = $at + 1
		}
	}
	$header
}

## The archive with its first header's type byte replaced and its checksum
## computed again.
with_type : List(U8), U8 -> List(U8)
with_type = |archive, type|
	{
		header = archive.take_first(512).set(156, type) ?? archive
		blank = header.take_first(148).concat(List.repeat(' ', 8)).concat(header.drop_first(156))
		sum = blank.fold(0, |total, byte| total + byte.to_u64())
		digits = Str.repeat("0", 6 - octal(sum).to_utf8().len()).concat(octal(sum)).to_utf8()
		blank.take_first(148).concat(digits).concat([0, ' ']).concat(blank.drop_first(156)).concat(archive.drop_first(512))
	}

octal : U64 -> Str
octal = |value| if (value < 8) value.to_str() else octal(value // 8).concat((value % 8).to_str())

hex : Str -> List(U8)
hex = |text| {
	digits = text.to_utf8().map(|byte| if (byte >= 'a') byte - 'a' + 10 else byte - '0')
	var $bytes = []
	var $index = 0
	while $index + 1 < digits.len() {
		$bytes = $bytes.append((digits.get($index) ?? 0) * 16 + (digits.get($index + 1) ?? 0))
		$index = $index + 2
	}
	$bytes
}
