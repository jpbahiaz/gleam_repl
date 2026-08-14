import gleam/dict
import gleam/io
import gleam/list
import repl/command
import repl/eval
import repl/project
import repl/source
import repl/state.{
  type EvalError, type HarnessState, type Outcome, type Project, CompileError,
  Defined, Definition, Imported, Incomplete, NoOutcome, ParseError, Printed,
  ProjectError, RuntimeError, Value,
}

pub fn main() -> Nil {
  case project.discover(".") {
    Error(message) -> {
      io.println_error(message)
      exit(1)
    }
    Ok(host) -> {
      project.clear_scratch_files(host)
      banner()
      loop(host, state.new_state(), "")
    }
  }
}

fn banner() -> Nil {
  io.println("gleam repl  (Erlang target)")
  io.println("Type Gleam at the prompt. :help for commands, :quit to exit.")
  io.println("")
}

fn loop(host: Project, state: HarnessState, buffer: String) -> Nil {
  let prompt = case buffer {
    "" -> "> "
    _ -> "... "
  }
  case get_line(prompt) {
    Eof -> {
      io.println("")
      project.clear_scratch_files(host)
      Nil
    }
    Read(raw) -> {
      let line = source.strip_newline(raw)
      case buffer, command.parse(line) {
        "", Ok(cmd) ->
          case handle_command(host, state, cmd) {
            Continue(state) -> loop(host, state, "")
            Stop -> Nil
          }
        _, _ -> {
          let next = source.join_line(buffer, line)
          case eval.eval_snippet(host, state, next) {
            #(state, Error(Incomplete)) -> loop(host, state, next)
            #(state, result) -> {
              print_result(result)
              loop(host, state, "")
            }
          }
        }
      }
    }
  }
}

type AfterCommand {
  Continue(HarnessState)
  Stop
}

fn handle_command(
  host: Project,
  state: HarnessState,
  cmd: command.Command,
) -> AfterCommand {
  case cmd {
    command.Quit -> {
      project.clear_scratch_files(host)
      Stop
    }
    command.Help -> {
      io.println(command.help_text)
      Continue(state)
    }
    command.Reset -> {
      project.clear_scratch_files(host)
      io.println("REPL state cleared.")
      Continue(state.new_state())
    }
    command.TypeOf(name) -> {
      case dict.get(state.symbol_table, name) {
        Ok(Value(_, gleam_type)) | Ok(Definition(_, gleam_type)) ->
          io.println(command.type_of(name, gleam_type))
        Error(_) -> io.println_error("unknown name: " <> name)
      }
      Continue(state)
    }
    command.Unknown(name) -> {
      io.println_error("Unknown command :" <> name <> "  (try :help)")
      Continue(state)
    }
  }
}

fn print_result(result: Result(List(Outcome), EvalError)) -> Nil {
  case result {
    Error(error) -> io.println_error(format_error(error))
    Ok(outcomes) ->
      list.each(outcomes, fn(outcome) {
        case outcome {
          Printed(text, _) -> io.println(text)
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

type Input {
  Read(String)
  Eof
}

@external(erlang, "repl_ffi", "get_line")
fn get_line(prompt: String) -> Input

@external(erlang, "erlang", "halt")
fn exit(status: Int) -> Nil
