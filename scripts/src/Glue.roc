import Integrity
import Script

## Pure parts of `scripts/check_glue.roc`: which compiler is running, and
## where that compiler's glue specification is published.
Glue := [].{

	## The nightly release tag in the output of `roc version`, such as
	## `nightly-2026-10-09-258ab27`. A compiler built from source reports
	## none, and names its glue source with `--roc-source` instead.
	nightly_tag = |version_output| {
		words = Str.split_on(Str.replace_each(version_output, "\n", " "), " ")
		match words.keep_if(|word| Script.starts_with(word, "nightly-") and Str.split_on(word, "-").len() == 5) {
			[tag, ..] => Ok(tag)
			_ => Err(NotANightly)
		}
	}

	## The source archive a nightly release attaches. Its only top-level
	## directory has the same name without the extension.
	source_directory = |tag| "roc_nightly-source-${Str.replace_each(tag, "nightly-", "")}"
	source_asset = |tag| "${Glue.source_directory(tag)}.tar.gz"
	source_url = |tag| "https://github.com/roc-lang/nightlies/releases/download/${tag}/${Glue.source_asset(tag)}"

	## The lowercase hexadecimal SHA-256 in a release asset digest, which
	## GitHub writes as `sha256:<hex>`.
	sha256_of_digest = |digest| {
		text = Script.trim(digest)
		hex = Str.from_utf8_lossy(text.to_utf8().drop_first(7))
		if Script.starts_with(text, "sha256:") and Integrity.is_hex(hex, 64) {
			Ok(hex)
		} else {
			Err(NotSha256)
		}
	}
}

expect Glue.nightly_tag("Roc compiler version nightly-2026-10-09-258ab27\n") == Ok("nightly-2026-10-09-258ab27")
expect Glue.nightly_tag("Roc compiler version debug-b759efd1") == Err(NotANightly)
expect Glue.nightly_tag("nightly-build") == Err(NotANightly)
expect Glue.source_asset("nightly-2026-10-09-258ab27") == "roc_nightly-source-2026-10-09-258ab27.tar.gz"
expect Glue.source_url("nightly-2026-10-09-258ab27") == "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-09-258ab27/roc_nightly-source-2026-10-09-258ab27.tar.gz"
expect Glue.sha256_of_digest("sha256:a3407158152293bd1bf7183655374502d8da5f06192aa930ed8d240a979d2679\n") == Ok("a3407158152293bd1bf7183655374502d8da5f06192aa930ed8d240a979d2679")
expect Glue.sha256_of_digest("sha512:a3") == Err(NotSha256)
