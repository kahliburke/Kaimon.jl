# Registering KaimonGate

`KaimonGate` is a subpackage of the [Kaimon.jl](https://github.com/kahliburke/Kaimon.jl)
monorepo — it lives in `lib/KaimonGate/` and is registered in the Julia **General**
registry as its own package, separate from `Kaimon`. One repo, two registered packages.

## Prerequisites
- The repository is public.
- `lib/KaimonGate/Project.toml` has a unique `name`/`uuid`, a `version`, and `[compat]`
  entries for every dependency plus `julia`.
- Tests pass: `julia --project=lib/KaimonGate -e 'using Pkg; Pkg.test()'`
  (CI runs them via the `test-kaimongate` job).

## First registration
1. Merge the work to `main`.
2. Trigger Registrator with the **subdir** argument (comment on the release commit, or
   use the JuliaRegistrator GitHub App):

       @JuliaRegistrator register subdir=lib/KaimonGate

   `subdir` tells Registrator the package lives in `lib/KaimonGate`, not the repo root.
3. Registrator opens a PR against General. Once it merges, `]add KaimonGate` works.

## Subsequent releases
- Bump `version` in `lib/KaimonGate/Project.toml`, then register again with the same
  `@JuliaRegistrator register subdir=lib/KaimonGate` comment.
- TagBot (`.github/workflows/TagBot.yml`) creates the GitHub tag/release — it has a
  dedicated step with `subdir: lib/KaimonGate`.

## After KaimonGate is registered (cleanup)
- Remove the path `[sources]` entries that exist only for unregistered development:
  - root `Project.toml`: `KaimonGate = {path = "lib/KaimonGate"}`
  - `test/GateToolTest.jl/Project.toml`: same
  Pkg will then resolve KaimonGate from the registry.
- Keep the root `Kaimon` `[compat]` pin `KaimonGate = "0.1"`; bump it when you release a
  breaking KaimonGate version.
- The CLI's global install (`_install_gate_global`) already prefers `Pkg.add("KaimonGate")`
  and only falls back to the bundled path, so it works before and after registration.

## Note
Register and tag `KaimonGate` **before** announcing it publicly, so `]add KaimonGate`
resolves for users from day one.
