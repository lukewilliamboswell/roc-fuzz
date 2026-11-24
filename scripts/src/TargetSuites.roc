import cli.Path
import Files

## Shared executable members used by repository and archived-example checks.
TargetSuites := [].{
	Member : { name : Str, expected_failure : Bool }
	Suite : { name : Str, members : List(Member) }

	load! = |path| {
		source = Path.read_utf8!(path)?
		parsed : Try({ suites : List(Suite) }, _)
		parsed = Json.parse(source)
		match parsed {
			Ok(inventory) => {
				cases : { cases : List({ name : Str }) }
				cases = Json.parse(source)?
				var $names = []
				for suite in inventory.suites {
					if $names.contains(suite.name) or !cases.cases.any(|item| item.name == suite.name) or suite.members.is_empty() {
						return Err(InvalidSuiteInventory(suite.name))
					}
					$names = $names.append(suite.name)
					var $members = []
					for member in suite.members {
						if !Files.safe_name(member.name) or member.name.contains("/") or $members.contains(member.name) {
							return Err(InvalidSuiteMember(suite.name, member.name))
						}
						$members = $members.append(member.name)
					}
				}
				Ok(inventory.suites)
			}
			# Published single-target inventories have no suites field.
			Err(_) => Ok([])
		}
	}

	members = |suites, name| match suites.keep_if(|suite| suite.name == name) {
		[suite] => suite.members
		_ => []
	}
}
