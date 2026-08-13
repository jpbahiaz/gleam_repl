import gleam/string

pub type Command {
  Quit
  Help
  TypeOf(String)
  Reset
  Unknown(String)
}

pub fn parse(line: String) -> Result(Command, Nil) {
  let trimmed = string.trim(line)
  case trimmed {
    "" -> Error(Nil)
    _ ->
      case string.starts_with(trimmed, ":") {
        False -> Error(Nil)
        True -> Ok(parse_command(string.drop_start(trimmed, 1)))
      }
  }
}

fn parse_command(body: String) -> Command {
  let body = string.trim(body)
  case first_word(body) {
    #("quit", _) | #("q", _) -> Quit
    #("help", _) | #("h", _) -> Help
    #("reset", _) -> Reset
    #("type", rest) ->
      case string.trim(rest) {
        "" -> Unknown("type")
        name -> TypeOf(name)
      }
    #(other, _) -> Unknown(other)
  }
}

fn first_word(src: String) -> #(String, String) {
  case string.split_once(src, " ") {
    Ok(#(word, rest)) -> #(word, rest)
    Error(_) -> #(src, "")
  }
}

pub const help_text = "Commands:
  :quit, :q     Exit the REPL
  :help, :h     Show this help
  :type <name>  Show the inferred type of a binding
  :reset        Clear all bindings and the scratch module"

pub fn type_of(name: String, gleam_type: String) -> String {
  case gleam_type {
    "" -> name <> " : <unknown>"
    _ -> name <> " : " <> gleam_type
  }
}
