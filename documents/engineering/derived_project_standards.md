---
name: engineering-derived-project-standards
description: The five rules every derived project follows. The doctrine tying base_image / warm_store / code_check / linking together.
type: standard
---

# Derived project standards

This is the single page a derived project's author reads before writing their
`docker/Dockerfile` and `cabal.project`. It is the union of the doctrine docs
under [`engineering/`](.), in the form of five rules with one-line explanations
and a link to the authoritative source.

## The five rules

1. **Inherit `FROM ${BASE_IMAGE}` and follow the Dockerfile rules.** POSIX
   `/bin/sh`, no pipes, no buildx, no `--platform`. See
   [base_image.md](base_image.md#dockerfile-rules).
2. **Use the warm-store cabal.project template AND import the warm-store
   freeze.** Set `with-compiler: ghc-9.12.4`, `tests: True`, `benchmarks:
   True`, `shared: True`, `optimization: 2`, and add
   `import: /opt/basecontainer/haskell-deps/cabal.project.freeze` in
   `cabal.project`. Derived projects ship **zero** `cabal.project.freeze`
   files of their own — the freeze lives only in the base image and is
   referenced at build time so version drift cannot happen. Without the
   import, the resolver picks different transitive versions than the warm
   store and rebuilds. See
   [warm_store.md](warm_store.md#required-import-the-freeze-file).
3. **Add `RUN <project> check-code` and a tini-wrapped `ENTRYPOINT` to the
   Dockerfile.** The check runs after the project's CLI is installed and before
   any expensive backend work; the entrypoint makes `hostbootstrap run [args...]`
   pass args to the project command consistently across execution models. See
   [code_check_doctrine.md](code_check_doctrine.md#derived-images).
4. **Link executables statically; build libraries with `shared: True`.** Do
   not pass `--enable-executable-dynamic` or `--enable-executable-static`. See
   [linking_and_optimization.md](linking_and_optimization.md#recommended-policy).
5. **Don't rebuild what the warm store already builds.** Check
   `cabal build --dry-run --enable-tests --enable-benchmarks all` inside the
   container. If a third-party package shows up in the plan, fix your project's
   flags first; if it's a genuine miss, add it to
   [`support/haskell-deps/basecontainer-haskell-deps.cabal`](../../support/haskell-deps/basecontainer-haskell-deps.cabal).
   See [warm_store.md](warm_store.md#how-to-verify-your-project-hits-the-cache).

A project that follows all five rules has a Dockerfile that is small, a build
that hits the cache, and an image that cannot exist with code-check
violations.

## Worked compliant example

The MCTS project at `/Users/matthewnowak/MCTS` is the reference derived
project. Its `docker/Dockerfile` is the canonical shape:

```dockerfile
# check=skip=InvalidDefaultArgInFrom

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

WORKDIR /workspace/MCTS

COPY . /workspace/MCTS

RUN cabal build --enable-tests --enable-benchmarks all \
    && cabal build --enable-tests --enable-benchmarks \
        test:mcts-haskell-style \
        test:mcts-unit \
        # ...other tests...
        bench:mcts-criterion \
    && install -m 0755 "$(cabal list-bin --enable-tests --enable-benchmarks exe:mcts)" /usr/local/bin/mcts \
    # ...other installs...

RUN mcts check-code

RUN mcts build cpp-legacy \
    && mcts build cpp-imperative \
    && mcts build cpp-functional \
    && mcts build rust

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/mcts"]
```

The `# check=skip=InvalidDefaultArgInFrom` parser directive on line 1
silences a BuildKit lint warning. The linter evaluates `FROM ${BASE_IMAGE}`
against the static `ARG` default; since the default is empty (the value is
supplied by `hostbootstrap --build-arg`), the linter reports an "invalid
base image name." The directive is required boilerplate for every derived
project that follows the `FROM ${BASE_IMAGE}` pattern.

Its `cabal.project`:

```cabal
packages: .

with-compiler: ghc-9.12.4

import: /opt/basecontainer/haskell-deps/cabal.project.freeze

tests: True
benchmarks: True
shared: True
optimization: 2

-- Sprint 7.4: relax the upper bounds on `config-ini`'s `containers`
-- and `base` so `brick` 2.12 + `vty` 6.5 can resolve.
allow-newer: config-ini:containers, config-ini:base
```

No `cabal.project.freeze` is committed in MCTS — the warm-store freeze is
imported from the base image at build time. `ls MCTS/cabal.project.freeze`
intentionally returns "No such file or directory."

Three signals that this project complies:

1. `mcts check-code` between install and backend builds, with the final image
   using a tini-wrapped `ENTRYPOINT` for `hostbootstrap run` (rule 3,
   code-check; runtime-entrypoint rule).
2. `cabal.project` matches the template, including the freeze `import:` line
   (rule 2, warm store).
3. `mcts.cabal`'s library and exe stanzas carry `-O2` in `ghc-options` (rule 4,
   linking + optimisation).

## Migration checklist for legacy projects

The four projects scheduled to migrate to hostbootstrap. For each, the work is
the same: drop the project Dockerfile, write the compliant shape above, and
adjust the `*.cabal` file's GHC compatibility.

| Project | GHC today | Notes for migration |
|---|---|---|
| [mattandjames](https://example.invalid/mattandjames) | 9.14.1 | Narrow the `allow-newer` block in `cabal.project` once on 9.12; all deps already covered by the warm store. |
| [prodbox](https://example.invalid/prodbox) | 9.14.1 | Dual `base` constraint (`^>=4.22 \|\| ^>=4.18`) already supports the downgrade; all deps already covered. |
| [infernix](https://example.invalid/infernix) | 9.14.1 | `proto-lens-setup` custom build is already in the warm store; allow-newer block tightens after migration. |
| [jitML](https://example.invalid/jitML) | 9.14.1 | **Blocker:** relax `base >=4.22 && <4.23` in `jitml.cabal` to `>=4.18 && <4.23` so the project compiles under GHC 9.12.4 (`base-4.21.x`). Vendored `lens-family` and `lens-family-core` under `third_party/haskell/` are fine — they get rebuilt against the warm-store closure. |

After migration, each project follows the same five rules above.

## See also

* [base_image.md](base_image.md) — what the base image ships
* [warm_store.md](warm_store.md) — the Cabal store contract
* [code_check_doctrine.md](code_check_doctrine.md) — build-time code-check
* [linking_and_optimization.md](linking_and_optimization.md) — linking and
  optimisation defaults
* [harbor.md](harbor.md) — pushing the project image (out of scope for
  hostbootstrap itself)
