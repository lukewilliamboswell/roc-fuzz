import arg_path.Path as ArgumentPath
import cli.Path

## Adapters used at the Weaver boundary.
##
## Weaver deliberately preserves the operating system's raw argument path. The
## basic-cli platform uses its own Path type, so convert between the two without
## first squeezing filesystem arguments through Str.
CliValues := [].{
	path = |argument| Ok(Path.from_raw(ArgumentPath.to_raw(argument)))

	text = |argument|
		match ArgumentPath.to_str(argument) {
			Ok(value) => Ok(value)
			Err(_) => Err(InvalidUtf8)
		}

	## Parse a UTF-8 command-line value into a domain type while keeping domain
	## failures inside Weaver's normal invalid-usage reporting.
	parse = |argument, parser, message|
		match CliValues.text(argument) {
			Ok(value) => match parser(value) {
				Ok(parsed) => Ok(parsed)
				Err(_) => Err(InvalidValue(message))
			}
			Err(_) => Err(InvalidUtf8)
		}
}
