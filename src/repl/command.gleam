import gleam/string

pub type Command {
  Quit
  Help
  TypeOf(String)
  Bindings
  History
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
    #("bindings", _) | #("ls", _) -> Bindings
    #("history", _) -> History
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
  :quit, :q          Exit the REPL
  :help, :h          Show this help
  :type <name>       Show the inferred type of a binding
  :bindings, :ls     List names in the session
  :history           Show input history
  :reset             Clear bindings (keeps history)

Keys:
  Up/Down            History
  Ctrl+R             Reverse search
  Ctrl+A / Ctrl+E    Start / end of line
  Ctrl+U / Ctrl+K    Kill to start / end
  Ctrl+W             Kill previous word
  Ctrl+C             Clear the line
  Ctrl+L             Clear the screen
  Ctrl+D             Exit (empty line) or delete"

pub fn type_of(name: String, gleam_type: String) -> String {
  case gleam_type {
    "" -> name <> " : <unknown>"
    _ -> name <> " : " <> gleam_type
  }
}
