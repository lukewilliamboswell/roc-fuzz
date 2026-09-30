import cli.Env
import cli.OsStr
import cli.Path
import Script
import Integrity

## Small process and file helpers shared by release tooling. No shell evaluation.
AutomationIO := [].{
	parent = |path| {
		name = Str.join_with(Str.split_on(Path.display(path), "/").drop_last(1), "/")
		Path.utf8(if name.is_empty() "." else name)
	}
	bytes! = |program, args, cwd| Script.command(OsStr.from_str(program)).capture!(args.map(OsStr.from_str), cwd, [])
	text! = |program, args, cwd| AutomationIO.bytes!(program, args, cwd).map_ok(Str.from_utf8_lossy)
	run! = |program, args, cwd| {
		_ = AutomationIO.bytes!(program, args, cwd)?
		Ok({})
	}
	write! = |path, bytes| {
		Path.create_all!(AutomationIO.parent(path))?
		Path.write_bytes!(path, bytes)
	}
	json! = |path, value| AutomationIO.write!(path, "${Json.to_str(value)}\n".to_utf8())
	lines = |text| Str.split_on(text, "\n").keep_if(|line| !line.is_empty())
	words = |text| Str.split_on(Str.replace_each(text, "\t", " "), " ").keep_if(|word| !word.is_empty())
	tracked! = |root, paths| AutomationIO.text!("git", ["ls-files", "-z", "--"].concat(paths), root).map_ok(|text| Str.split_on(text, Str.from_utf8_lossy([0])).keep_if(|name| !name.is_empty()))
	download! = |url, path| {
		if !Script.starts_with(url, "https://github.com/") {
			return Err(ExpectedGitHubUrl(url))
		}
		Env.with_temp_dir!(
			|temp| {
				file = Path.join(temp, "download")
				AutomationIO.run!("curl", ["--fail", "--silent", "--show-error", "--location", "--retry", "3", "--max-time", "120", "--output", Path.display(file), url], temp)?
				AutomationIO.write!(path, Path.read_bytes!(file)?)
			},
		)
	}
	verified_download! = |url, path, sha| {
		if Path.exists!(path)? {
			if Integrity.digest!(path)? == sha {
				return Ok({})
			}
			Path.delete!(path)?
		}
		AutomationIO.download!(url, path)?
		if Integrity.digest!(path)? != sha {
			Path.delete!(path)?
			return Err(DownloadDigestMismatch(url))
		}
		Ok({})
	}
}
