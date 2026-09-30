# B+ Language Support for Visual Studio Code

Extension for the **B+** programming language: syntax highlighting, snippets,
and one-click **Run/Build** via `bpc.exe`.

> **v0.2.0 bundles the compiler** — the `bpc.exe` compiler is shipped inside
> the extension, so a fresh user only installs the `.vsix` and writes code.
> Nothing else to setup: **write a `.b+` file → press `F8` (or the ▶ button) → done.**

## Features

- Syntax highlighting for `.b+`, `.bplus`, `.bp` files (keywords, types, strings,
  numbers, comments `//` and `/* */`, functions, operators)
- Snippets: `fn`, `main`, `for`, `while`, `struct`, `enum`, `if`
- Bracket matching / auto-closing, indentation rules
- Code folding for `{}` blocks
- **Bundled `bpc.exe` compiler** — run code right away, no separate install
- Commands:
  - `B+: Run Current File` — `bpc run <file>` then launches the `.exe`
    (default key: `Ctrl+Alt+B` or `F8`)
  - `B+: Build Current File (no run)` — compiles only
- Run button in the editor title bar for `.b+` files

## Install (no build needed)

The ready `.vsix` ships with the compiler inside. Download
`vscode-bplus-<version>.vsix` from the
[B-Plus repository](https://github.com/bylka2W/B-Plus) and run:

```powershell
code --install-extension vscode-bplus-0.2.0.vsix
```

Then: create `hello.b+`

```rust
fn main() {
    print("Hello, B+!\n")
}
```

…press `F8` (or the ▶ button in the editor title bar) and the program runs.

## Requirements

- Visual Studio Code 1.85+.
- The extension ships its own `bpc.exe` (bundled in `bin/bpc.exe`). To use a
  different build set `bplus.compilerPath` or `bpc` on `PATH`.

The compiler is located, in order:
1. the `bplus.compilerPath` setting,
2. the bundled `bin/bpc.exe` inside the extension,
3. `bpc` on `PATH`,
4. well-known default locations.

## How it works

```
.b+ file in VS Code
        │
        ▼
   [Ctrl+Alt+B / F8 / ▶ button]
        │
        ▼
  bpc.exe run <file>  ────►  <file>.exe
        │
        ▼
   integrated terminal runs the .exe
```

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `bplus.compilerPath` | `""` | Full path to `bpc.exe`. Empty = bundled compiler + auto-detect. |
| `bplus.runInTerminal` | `true` | Run the built `.exe` in the integrated terminal. |
| `bplus.showOutputChannel` | `true` | Show compiler diagnostics in the **B+** output channel. |

## Snippets

| Prefix | Expands to |
|---|---|
| `fn` | function declaration |
| `main` | `fn main() { print(…) }` entry point |
| `for` | C-style `for` loop |
| `while` | `while` loop |
| `struct` | struct declaration |
| `enum` | enum declaration |
| `if` | `if` statement |

## Install from source / rebuild the `.vsix`

```powershell
cd C:\B-Plus\vscode-bplus
npx @vscode/vsce package              # produces vscode-bplus-0.2.0.vsix
code --install-extension vscode-bplus-0.2.0.vsix
```

> `bin/bpc.exe` is the current B+ compiler build. To bundle a newer compiler
> copy `zig\zig-out\bin\bpc.exe` into `bin\` and repackage.

## Custom compiler location

Add to `.vscode/settings.json` in your workspace:

```json
{
  "bplus.compilerPath": "C:\\B-Plus\\zig\\zig-out\\bin\\bpc.exe"
}
```

## License

MIT