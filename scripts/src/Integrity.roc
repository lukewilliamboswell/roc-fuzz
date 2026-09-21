import cli.Path

## Cryptographic digests and two-column checksum manifests.
Integrity := [].{
	digest_bytes = |bytes| Crypto.SHA256.hash(bytes).to_hex()
	digest! = |path| Path.read_bytes!(path).map_ok(digest_bytes)

	ManifestEntry := { digest : Str, name : Str }.{}

	parse_manifest = |source| parse_lines(Str.split_on(source, "\n"), 1, [])

	render_manifest = |entries|
		Str.join_with(entries.map(|entry| "${entry.digest}  ${entry.name}\n"), "")

	is_hex = |value, length| {
		bytes = value.to_utf8()
		bytes.len() == length and bytes.all(|byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))
	}
}

parse_lines = |lines, number, found|
	match lines {
		["", .. as rest] => parse_lines(rest, number + 1, found)
		[line, .. as rest] =>
			match Str.split_on(line, "  ") {
				[digest, name] if Integrity.is_hex(digest, 64) and name != "" => {
					if found.any(|entry| entry.name == name) {
						Err(DuplicateManifestEntry(name))
					} else {
						parse_lines(rest, number + 1, found.append(Integrity.ManifestEntry.{ digest, name }))
					}
				}
				_ => Err(InvalidManifestLine(number, line))
			}
		[] => Ok(found)
	}

expect Integrity.digest_bytes("abc".to_utf8()) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
expect match Integrity.parse_manifest("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  file\n") {
	Ok(_) => Bool.True
	Err(_) => Bool.False
}
expect match Integrity.parse_manifest("bad  file\n") {
	Err(_) => Bool.True
	Ok(_) => Bool.False
}
