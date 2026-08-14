import gleam/int
import gleam/list
import gleam/string
import repl/codegen
import repl/state

pub type Span {
  Span(file: String, line: Int)
}

pub type Warning {
  Warning(text: String, spans: List(Span), fingerprint: String)
}

pub type BuildReport {
  BuildReport(warnings: List(Warning), errors: List(Warning))
}

pub fn parse(output: String) -> List(Warning) {
  parse_build(output).warnings
}

pub fn parse_build(output: String) -> BuildReport {
  let blocks =
    output
    |> strip_ansi
    |> string.replace("\r\n", "\n")
    |> string.replace("\r", "\n")
    |> string.split("\n")
    |> split_blocks([])
    |> list.reverse
  let warnings =
    list.filter_map(blocks, fn(block) {
      case block {
        #(WarningBlock, lines) -> from_block(lines)
        #(ErrorBlock, _) -> Error(Nil)
      }
    })
  let errors =
    list.filter_map(blocks, fn(block) {
      case block {
        #(ErrorBlock, lines) -> from_block(lines)
        #(WarningBlock, _) -> Error(Nil)
      }
    })
  BuildReport(warnings:, errors:)
}

pub fn select(
  warnings: List(Warning),
  dirty: List(#(Int, Int)),
  seen: List(String),
  scratch_path: String,
) -> List(Warning) {
  let current = state.last_segment(scratch_path)
  warnings
  |> list.filter(fn(warning) { belongs(warning.spans, current) })
  |> list.filter(fn(warning) {
    in_dirty(warning.spans, dirty, current)
    || !list.contains(seen, warning.fingerprint)
  })
}

pub fn select_errors(
  errors: List(Warning),
  dirty: List(#(Int, Int)),
  scratch_path: String,
) -> List(Warning) {
  let current = state.last_segment(scratch_path)
  let related =
    list.filter(errors, fn(error) {
      belongs(error.spans, current)
      && {
        in_dirty(error.spans, dirty, current)
        || !on_current_scratch(error.spans, current)
      }
    })
  case related {
    [] -> list.filter(errors, fn(error) { belongs(error.spans, current) })
    _ -> related
  }
}

pub fn fingerprints(warnings: List(Warning)) -> List(String) {
  list.map(warnings, fn(warning) { warning.fingerprint })
}

pub fn polish(text: String, scratch_path: String) -> String {
  codegen.polish_compiler_error(text, scratch_path)
}

type BlockKind {
  WarningBlock
  ErrorBlock
}

fn split_blocks(
  lines: List(String),
  acc: List(#(BlockKind, List(String))),
) -> List(#(BlockKind, List(String))) {
  case lines {
    [] -> acc
    [line, ..rest] ->
      case block_kind(line) {
        Ok(kind) -> split_blocks(rest, [#(kind, [line]), ..acc])
        Error(_) ->
          case acc {
            [#(kind, current), ..blocks] ->
              split_blocks(rest, [
                #(kind, list.append(current, [line])),
                ..blocks
              ])
            [] -> split_blocks(rest, acc)
          }
      }
  }
}

fn block_kind(line: String) -> Result(BlockKind, Nil) {
  let trimmed = string.trim_start(line)
  case string.starts_with(trimmed, "warning:") {
    True -> Ok(WarningBlock)
    False ->
      case string.starts_with(trimmed, "error:") {
        True -> Ok(ErrorBlock)
        False -> Error(Nil)
      }
  }
}

fn on_current_scratch(spans: List(Span), current: String) -> Bool {
  list.any(spans, fn(span) { state.last_segment(span.file) == current })
}

fn from_block(lines: List(String)) -> Result(Warning, Nil) {
  let lines = trim_trailing_empty(lines)
  case lines {
    [] -> Error(Nil)
    _ -> {
      let text = string.join(lines, "\n")
      Ok(Warning(
        text:,
        spans: list.filter_map(lines, span_from_line),
        fingerprint: fingerprint(lines),
      ))
    }
  }
}

fn trim_trailing_empty(lines: List(String)) -> List(String) {
  lines
  |> list.reverse
  |> list.drop_while(fn(line) { string.trim(line) == "" })
  |> list.reverse
}

fn span_from_line(line: String) -> Result(Span, Nil) {
  case location_spec(string.trim(line)) {
    Error(_) -> Error(Nil)
    Ok(spec) -> parse_file_line(string.trim(spec))
  }
}

fn location_spec(line: String) -> Result(String, Nil) {
  case string.split_once(line, "┌─") {
    Ok(#(_, rest)) -> Ok(rest)
    Error(_) ->
      case string.split_once(line, "╭─") {
        Ok(#(_, rest)) -> Ok(rest)
        Error(_) -> Error(Nil)
      }
  }
}

fn parse_file_line(spec: String) -> Result(Span, Nil) {
  case rsplit_int(spec) {
    Error(_) -> Error(Nil)
    Ok(#(left, last)) ->
      case rsplit_int(left) {
        Ok(#(file, line)) -> Ok(Span(file: string.trim(file), line:))
        Error(_) -> Ok(Span(file: string.trim(left), line: last))
      }
  }
}

fn rsplit_int(spec: String) -> Result(#(String, Int), Nil) {
  case list.reverse(string.split(spec, ":")) {
    [last, ..rest] ->
      case int.parse(last), rest {
        Ok(n), [_, ..] -> Ok(#(string.join(list.reverse(rest), ":"), n))
        _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn fingerprint(lines: List(String)) -> String {
  lines
  |> list.map(normalize_line)
  |> string.join("\n")
}

fn normalize_line(line: String) -> String {
  case location_spec(string.trim(line)) {
    Ok(_) -> "┌─ <loc>"
    Error(_) -> strip_gutter_number(line)
  }
}

fn strip_gutter_number(line: String) -> String {
  case string.split_once(line, "│") {
    Error(_) -> line
    Ok(#(left, right)) ->
      case string.trim(left) {
        "" -> "│" <> right
        trimmed ->
          case int.parse(trimmed) {
            Ok(_) -> "│" <> right
            Error(_) -> line
          }
      }
  }
}

fn belongs(spans: List(Span), current: String) -> Bool {
  case spans {
    [] -> True
    _ ->
      list.any(spans, fn(span) {
        let file = state.last_segment(span.file)
        !state.is_scratch_filename(file) || file == current
      })
  }
}

fn in_dirty(
  spans: List(Span),
  dirty: List(#(Int, Int)),
  current: String,
) -> Bool {
  list.any(spans, fn(span) {
    state.last_segment(span.file) == current
    && list.any(dirty, fn(range) {
      let #(start, end) = range
      span.line >= start && span.line <= end
    })
  })
}

fn strip_ansi(text: String) -> String {
  case string.split_once(text, "\u{001b}[") {
    Error(_) -> text
    Ok(#(before, rest)) -> before <> strip_ansi(drop_csi(rest))
  }
}

fn drop_csi(text: String) -> String {
  case string.pop_grapheme(text) {
    Error(_) -> ""
    Ok(#(g, rest)) ->
      case is_csi_param(g) {
        True -> drop_csi(rest)
        False -> rest
      }
  }
}

fn is_csi_param(g: String) -> Bool {
  case g {
    "0"
    | "1"
    | "2"
    | "3"
    | "4"
    | "5"
    | "6"
    | "7"
    | "8"
    | "9"
    | ";"
    | ":"
    | "?"
    | " " -> True
    _ -> False
  }
}
