import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/result
import gleam/string
import repl/state.{type Project}
import simplifile

pub fn reload(project: Project) -> Result(Nil, String) {
  use bits <- result.try(
    simplifile.read_bits(project.beam_path)
    |> result.map_error(fn(e) {
      "Could not read " <> project.beam_path <> ": " <> string.inspect(e)
    }),
  )
  load_binary(atom.create(state.scratch_module_name), project.beam_path, bits)
  |> result.map_error(fn(reason) {
    "Hot-load failed: " <> string.inspect(reason)
  })
}

pub fn apply(function: String, args: List(Dynamic)) -> Result(Dynamic, String) {
  safe_apply(
    atom.create(state.scratch_module_name),
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
