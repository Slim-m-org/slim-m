# Modules

slim runs community-authored modules: small, sandboxed WebAssembly programs that extend a deployment through bounded contracts.

- **[building-modules.md](building-modules.md)** - the developer guide: the ABI, the manifest, extension points, the command protocol, the scene contract (including interactive scenes), host capabilities, resource limits, the security model, publishing, and testing.
- **[reactive-modules.md](reactive-modules.md)** - the module platform guide: events (`@event`), the `data.store` database, durable `log.read`, settings and secrets, slots (`@slot`, `slot/1`), per-run call budgets and a worked example.
- **[../decisions/0021-modules-and-the-dock.md](../decisions/0021-modules-and-the-dock.md)** - why the module system is shaped this way.
- **[../decisions/0022-module-extensibility-and-evolution.md](../decisions/0022-module-extensibility-and-evolution.md)** - the versioned contracts and how each grows.
- **Reference modules** - [slim-addons](https://github.com/Slim-m-org/slim-addons) ships worked examples (dice, code blocks, hash/JSON/markdown tools, Game of Life) and a copyable starter under `modules/_template/`.

The one-sentence version: a module is a pure `{command, input} -> {ok, output}` function that can reach nothing but its own memory, and everything it offers - a command, a chat runner, a slash command, a launchable app, an interactive scene - is declared in its manifest and rendered by slim without either side knowing the other's internals.
