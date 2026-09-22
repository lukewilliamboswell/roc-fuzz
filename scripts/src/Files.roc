import ascii.Ascii
import cli.Path

## Deterministic repository file discovery.
Files := [].{
	sort_paths : List(Path) -> Try(List(Path), _)
	sort_paths = |paths| {
		keyed = paths.map_try(|path| Ascii.from_str(Path.display(path)).map_ok(|key| (key, path)).map_err(|_| NonAsciiPath(Path.display(path))))?
		Ok(List.sort_with(keyed, |(a, _), (b, _)| Ascii.order_relative_to(a, b)).map(|(_, path)| path))
	}

	direct_files! = |directory| {
		entries = Path.list!(directory)?
		files = keep_direct_files!(entries, [])?
		sort_paths(files)
	}

	files! = |directory| find_files!(Path.list!(directory)?, [])

	roc_files! = |directory| Ok(Files.files!(directory)?.keep_if(|path| Path.ext(path).map_ok(Path.display) == Ok("roc")))

	stem = |filename|
		match Str.split_on(filename, ".") {
			[first, ..] => first
			[] => filename
		}
}

keep_direct_files! = |entries, found|
	match entries {
		[path, .. as rest] =>
			match Path.type!(path)? {
				IsFile => keep_direct_files!(rest, found.append(path))
				_ => keep_direct_files!(rest, found)
			}
		[] => Ok(found)
	}

find_files! = |entries, found|
	match entries {
		[path, .. as rest] =>
			match Path.type!(path)? {
				IsDir => find_files!(rest.concat(Path.list!(path)?), found)
				IsFile => find_files!(rest, found.append(path))
				_ => find_files!(rest, found)
			}
		[] => Files.sort_paths(found)
	}
