import gleam/dict
import gleam/io
import gleam/list
import gleam/string
import repl/command
import repl/eval
import repl/history
import repl/input
import repl/project
import repl/source
import repl/state.{
  type EvalError, type HarnessState, type Outcome, type Project, CompileError,
  Defined, Definition, Imported, Incomplete, NoOutcome, ParseError, Printed,
  ProjectError, RuntimeError, Value,
}
import repl/style

pub fn main() -> Nil {
  case project.discover(".") {
    Error(message) -> {
      io.println_error(message)
      exit(1)
    }
    Ok(host) -> {
      project.clear_scratch_files(host)
      banner()
      let entries = history.load(project.history_path(host))
      loop(host, state.new_state(), entries, "")
    }
  }
}

fn banner() -> Nil {
  let color = input.is_tty()
  io.println(style.dim_text("gleam repl  (Erlang target)", color))
  io.println(style.dim_text(
    "Up/Down history, Ctrl+R search, :help for commands.",
    color,
  ))
  io.println("")
}

fn loop(
  host: Project,
  state: HarnessState,
  entries: List(String),
  buffer: String,
) -> Nil {
  let color = input.is_tty()
  let prompt = case buffer {
    "" -> "> "
    _ -> "... "
  }
  case input.read_line(prompt, entries, color) {
    input.Eof -> {
      io.println("")
      project.clear_scratch_files(host)
      Nil
    }
    input.Read(line) -> {
      let entries = persist(host, entries, line)
      case buffer, command.parse(line) {
        "", Ok(cmd) ->
          case handle_command(host, state, entries, cmd, color) {
            Continue(state, entries) -> loop(host, state, entries, "")
            Stop -> Nil
          }
        _, _ -> {
          let next = source.join_line(buffer, line)
          case eval.eval_snippet(host, state, next) {
            #(state, Error(Incomplete)) -> loop(host, state, entries, next)
            #(state, result) -> {
              print_result(result, color)
              loop(host, state, entries, "")
            }
          }
        }
      }
    }
  }
}

fn persist(host: Project, entries: List(String), line: String) -> List(String) {
  let next = history.add(entries, line)
  case next == entries {
    True -> entries
    False -> {
      history.save(project.history_path(host), next)
      next
    }
  }
}

type AfterCommand {
  Continue(HarnessState, List(String))
  Stop
}

fn handle_command(
  host: Project,
  state: HarnessState,
  entries: List(String),
  cmd: command.Command,
  color: Bool,
) -> AfterCommand {
  case cmd {
    command.Quit -> {
      project.clear_scratch_files(host)
      Stop
    }
    command.Help -> {
      io.println(command.help_text)
      Continue(state, entries)
    }
    command.Reset -> {
      project.clear_scratch_files(host)
      io.println(style.dim_text("REPL state cleared.", color))
      Continue(state.new_state(), entries)
    }
    command.History -> {
      case entries {
        [] -> io.println(style.dim_text("(empty)", color))
        _ -> io.println(history.format(entries))
      }
      Continue(state, entries)
    }
    command.Bindings -> {
      io.println(format_bindings(state, color))
      Continue(state, entries)
    }
    command.TypeOf(name) -> {
      case dict.get(state.symbol_table, name) {
        Ok(Value(_, gleam_type)) | Ok(Definition(_, gleam_type)) ->
          io.println(command.type_of(name, gleam_type))
        Error(_) ->
          io.println_error(style.error("unknown name: " <> name, color))
      }
      Continue(state, entries)
    }
    command.Unknown(name) -> {
      io.println_error(style.error(
        "Unknown command :" <> name <> "  (try :help)",
        color,
      ))
      Continue(state, entries)
    }
  }
}

fn format_bindings(state: HarnessState, color: Bool) -> String {
  let rows =
    state.symbol_table
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.map(fn(pair) {
      let #(name, kind) = pair
      case kind {
        Value(_, gleam_type) ->
          name
          <> " : "
          <> display_type(gleam_type)
          <> style.dim_text("  value", color)
        Definition(_, gleam_type) ->
          name
          <> " : "
          <> display_type(gleam_type)
          <> style.dim_text("  def", color)
      }
    })
  case rows {
    [] -> style.dim_text("(no bindings)", color)
    _ -> string.join(rows, "\n")
  }
}

fn display_type(gleam_type: String) -> String {
  case gleam_type {
    "" -> "<unknown>"
    _ -> gleam_type
  }
}

fn print_result(result: Result(List(Outcome), EvalError), color: Bool) -> Nil {
  case result {
    Error(error) -> io.println_error(style.error(format_error(error), color))
    Ok(outcomes) ->
      list.each(outcomes, fn(outcome) {
        case outcome {
          Printed(text, gleam_type) -> {
            io.println(style.value(text, color))
            case gleam_type {
              "" -> Nil
              t -> io.println(style.type_note(": " <> t, color))
            }
          }
          Defined(_, _) | Imported(_) | NoOutcome -> Nil
        }
      })
  }
}

fn format_error(error: EvalError) -> String {
  case error {
    ParseError(message) -> message
    Incomplete -> "Incomplete input"
    CompileError(message) -> message
    RuntimeError(message) -> message
    ProjectError(message) -> message
  }
}

@external(erlang, "erlang", "halt")
fn exit(status: Int) -> Nil
