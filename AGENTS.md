# AGENTS — ztree-md

Operating rules for humans + AI.

## Workflow

- Never commit to `main`/`master`.
- Always start on a new branch.
- Only push after the user approves.
- Merge via PR.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/).

- fix → patch
- feat → minor
- feat! / BREAKING CHANGE → major
- chore, docs, refactor, test, ci, style, perf → no version change

## Releases

- Semantic versioning.
- Versions derived from Conventional Commits.
- Release performed locally via `/create-release` (no CI required).
- Manifest (if present) is source of truth.
- Tags: vX.Y.Z

## Repo map

- `LICENSE` — MIT licence
- `.gitignore` — Zig build artefacts exclusions
- `build.zig` — Zig build configuration
- `build.zig.zon` — Zig package manifest (depends on ztree)
- `CHANGELOG.md` — release history
- `src/` — library source
  - `root.zig` — public API: `render(node, writer)`

## Merge strategy

- Prefer squash merge.
- PR title must be a valid Conventional Commit.

## Definition of done

- Works locally.
- Tests updated if behaviour changed.
- CHANGELOG updated when user-facing.
- No secrets committed.

## Principles

- **Pure functions whenever possible.** No hidden state, no side effects. Data in, output out. Not always achievable — e.g. `render` takes a writer, which is inherently effectful — but the default posture is pure.
- **One way to do a thing.** No aliases, no convenience wrappers, no options. One function, one output style. Follows Zig's design philosophy.
- **`anytype` writer.** The renderer writes to any writer, not a concrete type. Matches idiomatic Zig (`std.fmt`, `std.json`). Callers choose the destination.

## Orientation

- **Entry point**: `src/root.zig` — public API.
- **Domain**: GFM (GitHub Flavoured Markdown) renderer for ztree. Walks a `Node` tree and writes Markdown to any writer. Uses the same HTML tag names as ztree-html.
- **Language**: Zig (0.15.x). Depends on `ztree` and `std`.
