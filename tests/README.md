# Tests layout

`tests/integration/` holds the full-stack suites that exercise the provider/plan
pipeline or real environment builds (`drupal*/`, `provider-*.nix`,
`public-env-json.nix`, `socket-contract.nix`, `hostname.nix`). These typically use `makeHostenv` and
import multi-module stacks.

`tests/unit/` contains fast, focused checks for individual modules (`restic.nix`,
`users-slices.nix`, `hostenv-assertions.nix`) and lean on the stubs in
`tests/support`.

Shared helpers live in `tests/support/`:

- `stubs/` – minimal root option stubs so we can call `lib.evalModules` without pulling a full NixOS config.
- `provider-view.nix` – builds provider-style environment views for tests.
- `sample-envs.nix` – tiny constructors for provider-style env attrsets used by multiple suites.
- `assert.nix` – small assertion helpers; tests prefer Nix-side assertions (`assertTrue`) to reduce shell/JQ boilerplate.

Guidelines for adding tests:

- Reuse fixtures from `tests/environments.nix` where possible.
- Use the helpers above instead of re-declaring option stubs or reshaping envs by hand.
- Evaluate only the modules you need for the branch under test (keep imports minimal).
- Assert on resulting config values, not implementation details.

The `systemd-service-path` and `postgresql-socket-permissions` checks run in ordinary CI. The more expensive
`systemd-services-vm-test` exercises real user services and is available as a
package for manual runs on hosts with KVM:

```sh
nix build .#systemd-services-vm-test -L
```
