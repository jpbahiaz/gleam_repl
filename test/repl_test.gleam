import gleam/dict
import gleam/option.{Some}
import gleam/package_interface
import gleam/string
import gleeunit
import repl/classify.{
  ClassifyEmpty, ClassifyError, ClassifyIncomplete, DefinitionItem, FnDef,
  ImportItem, Items, TypeDef, ValueItem,
}
import repl/codegen
import repl/command
import repl/editor
import repl/history
import repl/hotload
import repl/source
import repl/state.{ImportSpec}
import repl/types

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn module_name_test() {
  assert state.module_name(1) == "repl_session_1"
  assert state.module_name(12) == "repl_session_12"
  assert state.is_scratch_module("repl_session_3")
  assert state.is_scratch_filename("repl_session_3.gleam")
  assert state.is_scratch_filename("repl_session.gleam")
  assert !state.is_scratch_filename("repl.gleam")
}

pub fn should_reload_host_modules_test() {
  assert hotload.should_reload_beam("demo.beam")
  assert hotload.should_reload_beam("demo@internal.beam")
  assert !hotload.should_reload_beam("repl.beam")
  assert !hotload.should_reload_beam("repl@eval.beam")
  assert !hotload.should_reload_beam("repl@@main.beam")
  assert !hotload.should_reload_beam("cultivation@@main.beam")
  assert !hotload.should_reload_beam("repl_session_3.beam")
  assert !hotload.should_reload_beam("README")
}

pub fn classify_expression_test() {
  let assert Items([ValueItem(names: [], rhs: "1 + 2", ..)]) =
    classify.classify("1 + 2", classify.empty_env())
}

pub fn classify_let_test() {
  let assert Items([
    ValueItem(names: ["x"], rhs: "5", simple: True, is_assert: False, ..),
  ]) = classify.classify("let x = 5", classify.empty_env())
}

pub fn classify_pattern_let_test() {
  let assert Items([ValueItem(names: ["a", "b"], simple: False, pattern:, ..)]) =
    classify.classify("let #(a, b) = #(1, 2)", classify.empty_env())
  assert pattern == "#(a, b)"
}

pub fn classify_function_test() {
  let assert Items([
    DefinitionItem(name: "double", kind: FnDef, captured_values: [], ..),
  ]) = classify.classify("fn double(n) { n * 2 }", classify.empty_env())
}

pub fn classify_type_test() {
  let assert Items([DefinitionItem(name: "Box", kind: TypeDef, ..)]) =
    classify.classify("type Box { Box(Int) }", classify.empty_env())
}

pub fn classify_import_test() {
  let assert Items([ImportItem(spec:, ..)]) =
    classify.classify("import gleam/io", classify.empty_env())
  assert spec.module == "gleam/io"
}

pub fn classify_empty_test() {
  let assert ClassifyEmpty = classify.classify("  \n", classify.empty_env())
}

pub fn classify_incomplete_test() {
  let assert ClassifyIncomplete =
    classify.classify("fn foo() {", classify.empty_env())
}

pub fn classify_syntax_error_test() {
  let assert ClassifyError(_) =
    classify.classify("1 + + 2", classify.empty_env())
}

pub fn classify_multiline_function_test() {
  let src = "fn double(n) {\n  n * 2\n}"
  let assert Items([DefinitionItem(name: "double", kind: FnDef, ..)]) =
    classify.classify(src, classify.empty_env())
}

pub fn classify_mixed_paste_test() {
  let src = "fn double(n) { n * 2 }\nlet x = 5\ndouble(x)"
  let assert Items([
    DefinitionItem(name: "double", ..),
    ValueItem(names: ["x"], ..),
    ValueItem(names: [], ..),
  ]) = classify.classify(src, classify.empty_env())
}

pub fn classify_free_value_params_test() {
  let env =
    classify.Env(value_names: ["x"], definition_names: [], import_names: [])
  let assert Items([ValueItem(params: ["x"], ..)]) =
    classify.classify("x + 10", env)
}

pub fn classify_prelude_not_param_test() {
  let assert Items([ValueItem(params: [], ..)]) =
    classify.classify("Ok(1)", classify.empty_env())
}

pub fn classify_import_alias_not_param_test() {
  let env =
    classify.Env(value_names: [], definition_names: [], import_names: ["list"])
  let assert Items([ValueItem(params: [], ..)]) =
    classify.classify("list.map([1], fn(x) { x })", env)
}

pub fn classify_captured_fn_test() {
  let env =
    classify.Env(value_names: ["x"], definition_names: [], import_names: [])
  let assert Items([DefinitionItem(name: "add_x", captured_values: ["x"], ..)]) =
    classify.classify("fn add_x(n) { n + x }", env)
}

pub fn classify_pattern_assignment_names_test() {
  let assert Items([ValueItem(names:, ..)]) =
    classify.classify("let #(a, _) as pair = #(1, 2)", classify.empty_env())
  assert names == ["a", "pair"] || names == ["pair", "a"]
}

pub fn unmatched_delimiters_test() {
  assert source.unmatched_delimiters("fn foo() {")
  assert !source.unmatched_delimiters("fn foo() { 1 }")
  assert !source.unmatched_delimiters("\"(\"")
}

pub fn command_parse_test() {
  let assert Ok(command.Quit) = command.parse(":quit")
  let assert Ok(command.Quit) = command.parse(":q")
  let assert Ok(command.Help) = command.parse(":help")
  let assert Ok(command.Reset) = command.parse(":reset")
  let assert Ok(command.TypeOf("x")) = command.parse(":type x")
  let assert Ok(command.Bindings) = command.parse(":bindings")
  let assert Ok(command.Bindings) = command.parse(":ls")
  let assert Ok(command.History) = command.parse(":history")
  let assert Ok(command.Unknown("nope")) = command.parse(":nope")
  let assert Error(Nil) = command.parse("1 + 2")
}

pub fn history_skips_quit_and_duplicates_test() {
  let entries = history.add([], "1 + 2")
  let entries = history.add(entries, "1 + 2")
  let entries = history.add(entries, ":quit")
  let entries = history.add(entries, "")
  let entries = history.add(entries, "let x = 1")
  assert entries == ["1 + 2", "let x = 1"]
}

pub fn history_search_test() {
  let entries = ["let x = 1", "fn double(n) { n * 2 }", "double(x)"]
  let assert Ok(#("double(x)", 0)) = history.search(entries, "double", 0)
  let assert Ok(#("fn double(n) { n * 2 }", 1)) =
    history.search(entries, "double", 1)
  let assert Error(Nil) = history.search(entries, "nope", 0)
}

pub fn editor_up_recalls_history_test() {
  let ed = editor.new("> ", ["1 + 1", "2 + 2"])
  let assert editor.Continue(ed) = editor.apply(ed, editor.Up)
  assert ed.buffer == "2 + 2"
  let assert editor.Continue(ed) = editor.apply(ed, editor.Up)
  assert ed.buffer == "1 + 1"
  let assert editor.Continue(ed) = editor.apply(ed, editor.Down)
  assert ed.buffer == "2 + 2"
}

pub fn editor_ctrl_c_clears_line_test() {
  let ed = editor.new("> ", [])
  let assert editor.Continue(ed) = editor.apply(ed, editor.Char("x"))
  let assert editor.Continue(ed) = editor.apply(ed, editor.CtrlC)
  assert ed.buffer == ""
}

pub fn editor_ctrl_r_search_test() {
  let ed = editor.new("> ", ["let x = 1", "let y = 2"])
  let assert editor.Continue(ed) = editor.apply(ed, editor.CtrlR)
  let assert editor.Continue(ed) = editor.apply(ed, editor.Char("y"))
  assert ed.buffer == "let y = 2"
  let assert editor.Submit("let y = 2", _) = editor.apply(ed, editor.Enter)
}

pub fn editor_ctrl_r_enter_submits_match_not_query_test() {
  let ed = editor.new("> ", ["let a = 12"])
  let assert editor.Continue(ed) = editor.apply(ed, editor.CtrlR)
  let assert editor.Continue(ed) = editor.apply(ed, editor.Char("l"))
  let assert editor.Continue(ed) = editor.apply(ed, editor.Char("e"))
  let assert editor.Continue(ed) = editor.apply(ed, editor.Char("t"))
  let assert editor.Continue(ed) = editor.apply(ed, editor.Char(" "))
  let assert editor.Continue(ed) = editor.apply(ed, editor.Char("a"))
  assert ed.buffer == "let a = 12"
  let assert editor.Submit("let a = 12", _) = editor.apply(ed, editor.Enter)
}

pub fn codegen_simple_let_test() {
  let state = state.new_state()
  let assert Items(items) = classify.classify("let x = 5", classify.empty_env())
  let #(plan, next) = codegen.generate(state, items)
  assert next == 2
  assert string_contains(plan.source, "pub fn entry_1()")
  assert string_contains(plan.source, "5")
}

pub fn codegen_closure_is_anonymous_test() {
  let state = state.new_state()
  let env =
    classify.Env(value_names: ["x"], definition_names: [], import_names: [])
  let state =
    state.HarnessState(
      ..state,
      symbol_table: dict.from_list([#("x", state.Value("entry_1", "Int"))]),
    )
  let assert Items(items) = classify.classify("fn add_x(n) { n + x }", env)
  let #(plan, _) = codegen.generate(state, items)
  assert string_contains(plan.source, "fn(")
  assert !string_contains(plan.source, "pub fn add_x")
}

pub fn codegen_forces_pub_test() {
  let state = state.new_state()
  let assert Items(items) =
    classify.classify("fn double(n) { n * 2 }", classify.empty_env())
  let #(plan, _) = codegen.generate(state, items)
  assert string_contains(plan.source, "// @repl-def double")
  assert string_contains(plan.source, "pub fn double")
}

pub fn codegen_redefine_replaces_test() {
  let state = state.new_state()
  let assert Items(first) =
    classify.classify("fn double(n) { n * 2 }", classify.empty_env())
  let #(plan1, id1) = codegen.generate(state, first)
  let state = state.HarnessState(..state, body: plan1.body, next_entry_id: id1)
  let assert Items(second) =
    classify.classify("fn double(n) { n * 3 }", classify.empty_env())
  let #(plan2, _) = codegen.generate(state, second)
  assert string_contains(plan2.source, "n * 3")
  assert !string_contains(plan2.source, "n * 2")
}

pub fn import_merge_test() {
  let state = state.new_state()
  let assert Items(first) =
    classify.classify("import gleam/io.{println}", classify.empty_env())
  let #(plan1, id1) = codegen.generate(state, first)
  let state =
    state.HarnessState(..state, imports: plan1.imports, next_entry_id: id1)
  let assert Items(second) =
    classify.classify("import gleam/io.{debug}", classify.empty_env())
  let #(plan2, _) = codegen.generate(state, second)
  assert string_contains(plan2.source, "println")
  assert string_contains(plan2.source, "debug")
  assert count_substring(plan2.source, "import gleam/io") == 1
}

pub fn type_render_prelude_test() {
  let int_t =
    package_interface.Named(
      name: "Int",
      package: "",
      module: "gleam",
      parameters: [],
    )
  let #(text, extra) = types.render(int_t, "repl_session", [])
  assert text == "Int"
  assert extra == []
}

pub fn type_render_list_and_fn_test() {
  let int_t =
    package_interface.Named(
      name: "Int",
      package: "",
      module: "gleam",
      parameters: [],
    )
  let list_t =
    package_interface.Named(
      name: "List",
      package: "",
      module: "gleam",
      parameters: [int_t],
    )
  let fn_t = package_interface.Fn([int_t], list_t)
  let #(text, _) = types.render(fn_t, "repl_session", [])
  assert text == "fn(Int) -> List(Int)"
}

pub fn type_render_qualified_test() {
  let dict_t =
    package_interface.Named(
      name: "Dict",
      package: "gleam_stdlib",
      module: "gleam/dict",
      parameters: [
        package_interface.Variable(0),
        package_interface.Variable(1),
      ],
    )
  let #(text, extra) = types.render(dict_t, "repl_session", [])
  assert text == "dict.Dict(a, b)"
  let assert [ImportSpec(module: "gleam/dict", ..)] = extra
}

pub fn type_render_uses_existing_alias_test() {
  let imports = [
    ImportSpec(module: "gleam/dict", alias: Some("d"), types: [], values: []),
  ]
  let dict_t =
    package_interface.Named(
      name: "Dict",
      package: "gleam_stdlib",
      module: "gleam/dict",
      parameters: [],
    )
  let #(text, extra) = types.render(dict_t, "repl_session", imports)
  assert text == "d.Dict"
  assert extra == []
}

fn string_contains(haystack: String, needle: String) -> Bool {
  case string.split_once(haystack, needle) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn count_substring(haystack: String, needle: String) -> Int {
  count_loop(haystack, needle, 0)
}

fn count_loop(haystack: String, needle: String, acc: Int) -> Int {
  case string.split_once(haystack, needle) {
    Error(_) -> acc
    Ok(#(_, rest)) -> count_loop(rest, needle, acc + 1)
  }
}
