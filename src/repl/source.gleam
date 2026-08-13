import gleam/bit_array
import gleam/int
import gleam/string

pub fn slice_bytes(src: String, start: Int, end: Int) -> String {
  let length = int.max(0, end - start)
  case bit_array.slice(<<src:utf8>>, start, length) {
    Ok(bits) ->
      case bit_array.to_string(bits) {
        Ok(text) -> text
        Error(_) -> ""
      }
    Error(_) -> ""
  }
}

pub fn strip_newline(line: String) -> String {
  case string.ends_with(line, "\r\n") {
    True -> string.drop_end(line, 2)
    False ->
      case string.ends_with(line, "\n") || string.ends_with(line, "\r") {
        True -> string.drop_end(line, 1)
        False -> line
      }
  }
}

pub fn join_line(acc: String, line: String) -> String {
  case acc {
    "" -> line
    _ -> acc <> "\n" <> line
  }
}

pub fn unmatched_delimiters(src: String) -> Bool {
  walk(src, 0, 0, 0, Normal) != #(0, 0, 0)
}

type Mode {
  Normal
  InString
  InStringEscape
  LineComment
}

fn walk(
  src: String,
  parens: Int,
  brackets: Int,
  braces: Int,
  mode: Mode,
) -> #(Int, Int, Int) {
  case src {
    "" -> #(parens, brackets, braces)
    _ ->
      case mode, src {
        LineComment, "\n" <> rest ->
          walk(rest, parens, brackets, braces, Normal)
        LineComment, _ ->
          walk(drop1(src), parens, brackets, braces, LineComment)

        InStringEscape, _ ->
          walk(drop1(src), parens, brackets, braces, InString)

        InString, "\\" <> rest ->
          walk(rest, parens, brackets, braces, InStringEscape)
        InString, "\"" <> rest -> walk(rest, parens, brackets, braces, Normal)
        InString, _ -> walk(drop1(src), parens, brackets, braces, InString)

        Normal, "\"" <> rest -> walk(rest, parens, brackets, braces, InString)
        Normal, "//" <> rest ->
          walk(rest, parens, brackets, braces, LineComment)
        Normal, "(" <> rest -> walk(rest, parens + 1, brackets, braces, Normal)
        Normal, ")" <> rest ->
          walk(rest, int.max(0, parens - 1), brackets, braces, Normal)
        Normal, "[" <> rest -> walk(rest, parens, brackets + 1, braces, Normal)
        Normal, "]" <> rest ->
          walk(rest, parens, int.max(0, brackets - 1), braces, Normal)
        Normal, "{" <> rest -> walk(rest, parens, brackets, braces + 1, Normal)
        Normal, "}" <> rest ->
          walk(rest, parens, brackets, int.max(0, braces - 1), Normal)
        Normal, _ -> walk(drop1(src), parens, brackets, braces, Normal)
      }
  }
}

fn drop1(src: String) -> String {
  string.drop_start(src, 1)
}
