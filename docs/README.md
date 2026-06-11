# dotfiler Documentation

## Get set up

| Document | What it covers |
|----------|----------------|
| [Project README](../README.md) | Why dotfiler, quick start, installation topologies, new-machine setup |
| [zdot Integration](zdot-integration.md) | Pairing with zdot: topologies, the hook symlink chain, bootstrap |

## Use it

| Document | What it covers |
|----------|----------------|
| [CLI Reference](commands.md) | Every command and flag |
| [Configuration Reference](configuration.md) | zstyle keys, the exclusions file, environment variables |
| [How Updates Work](how-updates-work.md) | Update modes, frequency, release channels, branch overrides, the login check |

## Extend it

| Document | What it covers |
|----------|----------------|
| [Authoring Install Files](authoring-install-files.md) | Writing install modules; the two helper layers |
| [Install Helpers Reference](../example_install/README.md) | The example install-dir helper library |
| [Update Hooks](update-hooks.md) | Hooking your own component into the update cycle; the `_update_core_*` API |

## Internals

| Document | What it covers |
|----------|----------------|
| [Update Internals](update-internals.md) | Topologies, branch resolution, hint resolution, pointer bookkeeping, file discovery |
