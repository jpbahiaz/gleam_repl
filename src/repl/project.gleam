import gleam/result
import gleam/string
import repl/state.{type Project, Project}
import simplifile
import tom

pub fn discover(root: String) -> Result(Project, String) {
  let toml_path = join(root, "gleam.toml")
  use contents <- result.try(
    simplifile.read(toml_path)
    |> result.map_error(fn(_) {
      "No gleam.toml in " <> root <> ". Run the REPL from a Gleam project root."
    }),
  )
  use parsed <- result.try(
    tom.parse(contents)
    |> result.map_error(fn(_) { "Could not parse gleam.toml" }),
  )
  use name <- result.try(
    tom.get_string(parsed, ["name"])
    |> result.map_error(fn(_) { "gleam.toml is missing a name" }),
  )
  Ok(Project(
    name:,
    root:,
    scratch_path: join(root, state.scratch_relpath),
    beam_path: join(
      root,
      "build/dev/erlang/" <> name <> "/ebin/repl_session.beam",
    ),
    interface_path: join(root, "build/repl_package_interface.json"),
  ))
}

pub fn join(left: String, right: String) -> String {
  case string.ends_with(left, "/"), string.starts_with(right, "/") {
    True, True -> left <> string.drop_start(right, 1)
    True, False -> left <> right
    False, True -> left <> right
    False, False -> left <> "/" <> right
  }
}
