import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/result
import gleam/string
import repl/project as host
import repl/state.{type Project}
import simplifile

pub fn reload(project: Project, generation: Int) -> Result(Nil, String) {
  use _ <- result.try(reload_beam(
    host.beam_path(project, generation),
    state.module_name(generation),
  ))
  reload_host_modules(project)
}

pub fn should_reload_beam(filename: String) -> Bool {
  case string.ends_with(filename, ".beam") {
    False -> False
    True -> {
      let module = string.drop_end(filename, 5)
      case state.is_scratch_module(module) {
        True -> False
        False -> !is_harness_module(module) && !is_runner_module(module)
      }
    }
  }
}

fn is_harness_module(module: String) -> Bool {
  module == "repl" || string.starts_with(module, "repl@")
}

fn is_runner_module(module: String) -> Bool {
  string.contains(module, "@@")
}

fn reload_host_modules(project: Project) -> Result(Nil, String) {
  let dir = host.ebin_dir(project)
  case simplifile.read_directory(dir) {
    Error(_) -> Ok(Nil)
    Ok(names) ->
      list.try_each(names, fn(name) {
        case should_reload_beam(name) {
          False -> Ok(Nil)
          True -> reload_beam(host.join(dir, name), string.drop_end(name, 5))
        }
      })
  }
}

fn reload_beam(path: String, module: String) -> Result(Nil, String) {
  use bits <- result.try(
    simplifile.read_bits(path)
    |> result.map_error(fn(e) {
      "Could not read " <> path <> ": " <> string.inspect(e)
    }),
  )
  load_binary(atom.create(module), path, bits)
  |> result.map_error(fn(reason) {
    "Hot-load failed (" <> module <> "): " <> string.inspect(reason)
  })
}

pub fn apply(
  generation: Int,
  function: String,
  args: List(Dynamic),
) -> Result(Dynamic, String) {
  safe_apply(
    atom.create(state.module_name(generation)),
    atom.create(function),
    args,
  )
  |> result.map_error(fn(reason) { format_runtime(reason) })
}

pub fn tuple_element(value: Dynamic, index: Int) -> Dynamic {
  do_tuple_element(value, index)
}

fn format_runtime(reason: Dynamic) -> String {
  case format_exception(reason) {
    "" -> "Runtime error: " <> string.inspect(reason)
    message -> "Runtime error: " <> message
  }
}

@external(erlang, "repl_ffi", "tuple_element")
fn do_tuple_element(value: Dynamic, index: Int) -> Dynamic

@external(erlang, "repl_ffi", "format_exception")
fn format_exception(reason: Dynamic) -> String

@external(erlang, "repl_ffi", "load_binary")
fn load_binary(
  module: Atom,
  filename: String,
  binary: BitArray,
) -> Result(Nil, Dynamic)

@external(erlang, "repl_ffi", "safe_apply")
fn safe_apply(
  module: Atom,
  function: Atom,
  args: List(Dynamic),
) -> Result(Dynamic, Dynamic)
