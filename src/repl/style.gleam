import gleam/string

const reset = "\u{001b}[0m"

const red = "\u{001b}[31m"

const dim = "\u{001b}[2m"

const cyan = "\u{001b}[36m"

const yellow = "\u{001b}[33m"

pub fn prompt(text: String, color: Bool) -> String {
  paint(cyan, text, color)
}

pub fn value(text: String, _color: Bool) -> String {
  text
}

pub fn type_note(text: String, color: Bool) -> String {
  paint(dim, text, color)
}

pub fn error(text: String, color: Bool) -> String {
  paint(red, text, color)
}

pub fn warning(text: String, color: Bool) -> String {
  paint(yellow, text, color)
}

pub fn dim_text(text: String, color: Bool) -> String {
  paint(dim, text, color)
}

fn paint(code: String, text: String, color: Bool) -> String {
  case color {
    False -> text
    True -> code <> text <> reset
  }
}

pub fn strip(text: String) -> String {
  text
  |> string.replace("\u{001b}[0m", "")
  |> string.replace("\u{001b}[31m", "")
  |> string.replace("\u{001b}[2m", "")
  |> string.replace("\u{001b}[36m", "")
  |> string.replace("\u{001b}[33m", "")
}
