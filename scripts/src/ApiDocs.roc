import cli.Path
import Project
import Script

## Validate that generated documentation covers every public platform module and entry.
ApiDocs := [].{
	validate! = |root| {
		Script.require_file!(Path.join(root, "index.html"))?
		for module_name in Project.public_modules {
			path = Path.join(Path.join(root, module_name), "index.html")
			Script.require_file!(path)?
			html = Path.read_utf8!(path)?
			if !html.contains("<div class=\"module-doc\">") {
				return Err(MissingModuleDocs(module_name, Path.display(path)))
			}
			sections = Str.split_on(html, "<article class=\"entry ").drop_first(1)
			if sections.is_empty() {
				return Err(NoPublicEntries(module_name, Path.display(path)))
			}
			for section in sections {
				body = Str.split_on(section, "</article>").first().map_err(|_| MalformedEntry(module_name, Path.display(path)))?
				if !body.contains("class=\"entry-doc\"") {
					return Err(UndocumentedPublicEntry(module_name, Path.display(path)))
				}
			}
		}
		Ok({})
	}
}
