import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/result
import gleam/string
import repl/project as host
import repl/state.{type Project}
import simplifile

pub fn reload(project: Project, generation: Int) -> Result(Nil, String) {
  let path = host.beam_path(project, generation)
  use bits <- result.try(
    simplifile.read_bits(path)
    |> result.map_error(fn(e) {
      "Could not read " <> path <> ": " <> string.inspect(e)
    }),
  )
  load_binary(atom.create(state.module_name(generation)), path, bits)
  |> result.map_error(fn(reason) {
    "Hot-load failed: " <> string.inspect(reason)
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
