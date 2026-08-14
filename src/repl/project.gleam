import gleam/list
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
    interface_path: join(root, "build/repl_package_interface.json"),
  ))
}

pub fn scratch_relpath(generation: Int) -> String {
  "src/" <> state.module_name(generation) <> ".gleam"
}

pub fn scratch_path(project: Project, generation: Int) -> String {
  join(project.root, scratch_relpath(generation))
}

pub fn beam_path(project: Project, generation: Int) -> String {
  join(
    project.root,
    "build/dev/erlang/"
      <> project.name
      <> "/ebin/"
      <> state.module_name(generation)
      <> ".beam",
  )
}

pub fn clear_scratch_files(project: Project) -> Nil {
  let src = join(project.root, "src")
  case simplifile.read_directory(src) {
    Error(_) -> Nil
    Ok(names) ->
      list.each(names, fn(name) {
        case state.is_scratch_filename(name) {
          True -> {
            let _ = simplifile.delete(join(src, name))
            Nil
          }
          False -> Nil
        }
      })
  }
}

pub fn delete_scratch(project: Project, generation: Int) -> Nil {
  case generation > 0 {
    False -> Nil
    True -> {
      let _ = simplifile.delete(scratch_path(project, generation))
      Nil
    }
  }
}

pub fn join(left: String, right: String) -> String {
  case string.ends_with(left, "/"), string.starts_with(right, "/") {
    True, True -> left <> string.drop_start(right, 1)
    True, False -> left <> right
    False, True -> left <> right
    False, False -> left <> "/" <> right
  }
}
