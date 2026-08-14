import gleam/dict
import gleam/list
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
import repl/eval
import repl/history
import repl/hotload
import repl/source
import repl/state.{type Project, CompileError, ImportSpec, Project, Warned}
import repl/types
import repl/warnings
import simplifile

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

pub fn codegen_dirty_covers_new_entry_test() {
  let state = state.new_state()
  let assert Items(items) =
    classify.classify("\"Kiss\" == \"kiss\"", classify.empty_env())
  let #(plan, _) = codegen.generate(state, items)
  let dirty = source_in_ranges(plan.source, plan.dirty)
  assert string_contains(dirty, "Kiss")
  assert string_contains(dirty, "kiss")
  assert string_contains(dirty, "entry_1")
}

pub fn codegen_dirty_skips_old_entry_test() {
  let state = state.new_state()
  let assert Items(first) =
    classify.classify("\"Kiss\" == \"kiss\"", classify.empty_env())
  let #(plan1, id1) = codegen.generate(state, first)
  let state = state.HarnessState(..state, body: plan1.body, next_entry_id: id1)
  let assert Items(second) = classify.classify("1 + 1", classify.empty_env())
  let #(plan2, _) = codegen.generate(state, second)
  let dirty = source_in_ranges(plan2.source, plan2.dirty)
  assert string_contains(dirty, "1 + 1")
  assert string_contains(dirty, "entry_2")
  assert !string_contains(dirty, "Kiss")
  assert string_contains(plan2.source, "Kiss")
}

pub fn codegen_dirty_covers_redefined_fn_test() {
  let state = state.new_state()
  let assert Items(first) =
    classify.classify("fn double(n) { n * 2 }", classify.empty_env())
  let #(plan1, id1) = codegen.generate(state, first)
  let state = state.HarnessState(..state, body: plan1.body, next_entry_id: id1)
  let assert Items(second) =
    classify.classify("fn double(n) { n * 3 }", classify.empty_env())
  let #(plan2, _) = codegen.generate(state, second)
  let dirty = source_in_ranges(plan2.source, plan2.dirty)
  assert string_contains(dirty, "n * 3")
  assert string_contains(dirty, "@repl-def double")
  assert !string_contains(dirty, "n * 2")
}

pub fn warning_parse_strips_ansi_test() {
  let output =
    "\u{001b}[0m\u{001b}[1m\u{001b}[38;5;11mwarning\u{001b}[0m\u{001b}[1m: Unused function argument\u{001b}[0m\n"
    <> "  \u{001b}[0m\u{001b}[36m┌─\u{001b}[0m src/repl_session_1.gleam:4:12\n"
    <> "\u{001b}[0m\u{001b}[36m4\u{001b}[0m \u{001b}[0m\u{001b}[36m│\u{001b}[0m pub fn foo(\u{001b}[0m\u{001b}[33mx\u{001b}[0m) { 1 }\n"
  let assert [warning] = warnings.parse(output)
  assert warning.spans == [warnings.Span("src/repl_session_1.gleam", 4)]
  assert string_contains(warning.text, "warning: Unused function argument")
  assert !string_contains(warning.text, "\u{001b}")
}

pub fn warning_parse_redundant_comparison_test() {
  let output =
    "warning: Redundant comparison\n"
    <> "  ┌─ src/repl_session_1.gleam:8:3\n"
    <> "  │\n"
    <> "8 │   \"Kiss\" == \"kiss\"\n"
    <> "  │   ^^^^^^^^^^^^^^^^ This is always `False`\n"
    <> "\n"
    <> "This comparison is redundant since it always fails.\n"
  let assert [warning] = warnings.parse(output)
  assert warning.spans == [warnings.Span("src/repl_session_1.gleam", 8)]
  assert string_contains(warning.text, "Redundant comparison")
  assert string_contains(warning.text, "Kiss")
}

pub fn warning_fingerprint_ignores_path_and_line_test() {
  let first =
    warnings.parse(
      "warning: Redundant comparison\n"
      <> "  ┌─ src/repl_session_1.gleam:8:3\n"
      <> "8 │   \"Kiss\" == \"kiss\"\n"
      <> "  │   ^^^^^^^^^^^^^^^^ This is always `False`\n",
    )
  let second =
    warnings.parse(
      "warning: Redundant comparison\n"
      <> "  ┌─ /tmp/proj/src/repl_session_4.gleam:20:3\n"
      <> "20 │   \"Kiss\" == \"kiss\"\n"
      <> "  │   ^^^^^^^^^^^^^^^^ This is always `False`\n",
    )
  let assert [a] = first
  let assert [b] = second
  assert a.fingerprint == b.fingerprint
}

pub fn warning_select_hides_seen_outside_dirty_test() {
  let assert [warning] =
    warnings.parse(
      "warning: Redundant comparison\n"
      <> "  ┌─ src/repl_session_2.gleam:8:3\n"
      <> "8 │   \"Kiss\" == \"kiss\"\n",
    )
  assert warnings.select(
      [warning],
      [#(20, 24)],
      [warning.fingerprint],
      "src/repl_session_2.gleam",
    )
    == []
}

pub fn warning_select_shows_seen_in_dirty_test() {
  let assert [warning] =
    warnings.parse(
      "warning: Unused argument\n"
      <> "  ┌─ src/repl_session_3.gleam:12:12\n"
      <> "12 │ pub fn foo(x) { 2 }\n",
    )
  let assert [_] =
    warnings.select(
      [warning],
      [#(10, 14)],
      [warning.fingerprint],
      "src/repl_session_3.gleam",
    )
}

pub fn warning_select_shows_new_fingerprint_test() {
  let assert [warning] =
    warnings.parse(
      "warning: Unused imported module\n"
      <> "  ┌─ src/repl_session_3.gleam:2:1\n"
      <> "2 │ import gleam/io\n",
    )
  let assert [_] =
    warnings.select([warning], [#(20, 24)], [], "src/repl_session_3.gleam")
}

pub fn parse_build_splits_warnings_and_errors_test() {
  let output =
    "warning: Redundant comparison\n"
    <> "  ┌─ src/repl_session_2.gleam:12:3\n"
    <> "12 │   \"Kiss\" == \"kiss\"\n"
    <> "\n"
    <> "error: Unknown module\n"
    <> "  ┌─ src/repl_session_3.gleam:16:3\n"
    <> "16 │   io.println(90)\n"
    <> "\n"
    <> "No module has been found with the name io.\n"
  let report = warnings.parse_build(output)
  let assert [warning] = report.warnings
  let assert [error] = report.errors
  assert string_contains(warning.text, "Redundant comparison")
  assert string_contains(error.text, "Unknown module")
  assert string_contains(error.text, "io.println")
}

pub fn select_errors_keeps_dirty_drops_old_entry_test() {
  let report =
    warnings.parse_build(
      "error: Unknown variable\n"
      <> "  ┌─ src/repl_session_3.gleam:4:3\n"
      <> "4 │   leftover\n"
      <> "\n"
      <> "error: Unknown module\n"
      <> "  ┌─ src/repl_session_3.gleam:16:3\n"
      <> "16 │   io.println(90)\n",
    )
  let shown =
    warnings.select_errors(
      report.errors,
      [#(14, 18)],
      "src/repl_session_3.gleam",
    )
  let assert [error] = shown
  assert string_contains(error.text, "Unknown module")
}

pub fn warning_select_drops_other_generation_test() {
  let assert [stale, current] =
    warnings.parse(
      "warning: Unused function argument\n"
      <> "  ┌─ src/repl_session_3.gleam:4:12\n"
      <> "4 │ pub fn foo(x) { 1 }\n"
      <> "\n"
      <> "warning: Unused function argument\n"
      <> "  ┌─ src/repl_session_4.gleam:4:12\n"
      <> "4 │ pub fn foo(x) { 4 }\n",
    )
  let shown =
    warnings.select([stale, current], [#(3, 6)], [], "src/repl_session_4.gleam")
  assert shown == [current]
}

pub fn eval_shows_warning_once_then_hides_test() {
  let host = warning_host()
  let state = state.new_state()
  let #(state, first) = eval.eval_snippet(host, state, "\"Kiss\" == \"kiss\"")
  let assert Ok(first_outcomes) = first
  assert list.any(first_outcomes, is_warned)
  let #(_state, second) = eval.eval_snippet(host, state, "1 + 1")
  let assert Ok(second_outcomes) = second
  assert !list.any(second_outcomes, is_warned)
}

pub fn eval_reshows_warning_on_redefine_test() {
  let host = warning_host()
  let state = state.new_state()
  let #(state, first) = eval.eval_snippet(host, state, "fn foo(x) { 1 }")
  let assert Ok(first_outcomes) = first
  assert list.any(first_outcomes, is_warned)
  let #(state, second) = eval.eval_snippet(host, state, "1")
  let assert Ok(second_outcomes) = second
  assert !list.any(second_outcomes, is_warned)
  let #(_state, third) = eval.eval_snippet(host, state, "fn foo(x) { 2 }")
  let assert Ok(third_outcomes) = third
  let warned = list.filter(third_outcomes, is_warned)
  assert list.length(warned) == 1
  let assert [Warned(text)] = warned
  assert string_contains(text, "{ 2 }")
  assert !string_contains(text, "{ 1 }")
  assert string_contains(text, "<repl>")
  assert !string_contains(text, "repl_session")
}

pub fn eval_failed_compile_hides_old_warning_test() {
  let host = warning_host()
  let state = state.new_state()
  let #(state, first) = eval.eval_snippet(host, state, "\"Kiss\" == \"kiss\"")
  let assert Ok(first_outcomes) = first
  assert list.any(first_outcomes, is_warned)
  let #(_state, failed) = eval.eval_snippet(host, state, "io.println(90)")
  let assert Error(CompileError(warnings, message)) = failed
  assert warnings == []
  assert string_contains(message, "Unknown module")
  assert string_contains(message, "<repl>")
  assert !string_contains(message, "Kiss")
  assert !string_contains(message, "Redundant")
  assert !string_contains(message, "repl_session")
}

pub fn warning_polish_rewrites_scratch_path_test() {
  let text = "warning: Redundant comparison\n  ┌─ src/repl_session_2.gleam:8:3"
  let polished = warnings.polish(text, "src/repl_session_2.gleam")
  assert string_contains(polished, "<repl>")
  assert !string_contains(polished, "repl_session_2.gleam")
}

pub fn warning_polish_rewrites_absolute_and_stale_paths_test() {
  let text =
    "warning: Unused function argument\n"
    <> "  ┌─ /home/zica/workspace/gleam/repl/src/repl_session_3.gleam:4:12\n"
    <> "4 │ pub fn foo(x) { 1 }\n"
  let polished = warnings.polish(text, "src/repl_session_4.gleam")
  assert string_contains(polished, "┌─ <repl>:4:12")
  assert !string_contains(polished, "repl_session")
  assert !string_contains(polished, "/home/")
}

pub fn warning_polish_does_not_leave_directory_prefix_test() {
  let text =
    "error: Unknown variable\n"
    <> "  ┌─ /home/elias/Downloads/chess/chess_server/src/repl_session_2.gleam:12:3"
  let polished = warnings.polish(text, "src/repl_session_2.gleam")
  assert string_contains(polished, "┌─ <repl>:12:3")
  assert !string_contains(polished, "chess_server")
  assert !string_contains(polished, "repl_session")
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

fn warning_host() -> Project {
  let assert Ok(cwd) = simplifile.current_directory()
  let root = cwd <> "/build/repl_warn_fixture"
  let assert Ok(_) = simplifile.create_directory_all(root <> "/src")
  let assert Ok(_) =
    simplifile.write(
      to: root <> "/gleam.toml",
      contents: "name = \"warn_fixture\"\nversion = \"1.0.0\"\ntarget = \"erlang\"\n\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n",
    )
  let assert Ok(_) =
    simplifile.write(
      to: root <> "/src/warn_fixture.gleam",
      contents: "pub fn main() { Nil }\n",
    )
  let src = root <> "/src"
  case simplifile.read_directory(src) {
    Error(_) -> Nil
    Ok(names) ->
      list.each(names, fn(name) {
        case state.is_scratch_filename(name) {
          True -> {
            let _ = simplifile.delete(src <> "/" <> name)
            Nil
          }
          False -> Nil
        }
      })
  }
  Project(
    name: "warn_fixture",
    root:,
    interface_path: root <> "/build/repl_package_interface.json",
  )
}

fn is_warned(outcome: state.Outcome) -> Bool {
  case outcome {
    Warned(_) -> True
    _ -> False
  }
}

fn source_in_ranges(source: String, ranges: List(#(Int, Int))) -> String {
  let lines = string.split(source, "\n")
  ranges
  |> list.flat_map(fn(range) {
    let #(start, end) = range
    list.index_map(lines, fn(line, index) { #(index + 1, line) })
    |> list.filter_map(fn(pair) {
      let #(n, line) = pair
      case n >= start && n <= end {
        True -> Ok(line)
        False -> Error(Nil)
      }
    })
  })
  |> string.join("\n")
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
