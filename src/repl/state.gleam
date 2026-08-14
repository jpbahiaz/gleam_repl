import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub const scratch_prefix = "repl_session"

pub const empty_scratch = "//// REPL scratch — generated, do not edit\n"

pub type BindingKind {
  Value(entry_fn: String, gleam_type: String)
  Definition(real_name: String, gleam_type: String)
}

pub type Unqualified {
  Unqualified(name: String, alias: Option(String))
}

pub type ImportSpec {
  ImportSpec(
    module: String,
    alias: Option(String),
    types: List(Unqualified),
    values: List(Unqualified),
  )
}

pub type Project {
  Project(name: String, root: String, interface_path: String)
}

pub type HarnessState {
  HarnessState(
    module_source: String,
    body: String,
    symbol_table: Dict(String, BindingKind),
    runtime_store: Dict(String, Dynamic),
    imports: List(ImportSpec),
    next_entry_id: Int,
    generation: Int,
    seen_warnings: List(String),
  )
}

pub type Outcome {
  Printed(text: String, gleam_type: String)
  Defined(name: String, gleam_type: String)
  Imported(module: String)
  Warned(String)
  NoOutcome
}

pub type EvalError {
  ParseError(message: String)
  Incomplete
  CompileError(message: String)
  RuntimeError(message: String)
  ProjectError(message: String)
}

pub fn new_state() -> HarnessState {
  HarnessState(
    module_source: empty_scratch,
    body: "",
    symbol_table: dict.new(),
    runtime_store: dict.new(),
    imports: [],
    next_entry_id: 1,
    generation: 0,
    seen_warnings: [],
  )
}

pub fn entry_name(id: Int) -> String {
  "entry_" <> int.to_string(id)
}

pub fn module_name(generation: Int) -> String {
  scratch_prefix <> "_" <> int.to_string(generation)
}

pub fn is_scratch_module(module: String) -> Bool {
  string.starts_with(module, scratch_prefix)
}

pub fn is_scratch_filename(name: String) -> Bool {
  string.starts_with(name, scratch_prefix) && string.ends_with(name, ".gleam")
}

pub fn import_alias(spec: ImportSpec) -> String {
  case spec.alias {
    Some(name) -> name
    None -> last_segment(spec.module)
  }
}

pub fn last_segment(module: String) -> String {
  case list.last(string.split(module, "/")) {
    Ok(segment) -> segment
    Error(_) -> module
  }
}
