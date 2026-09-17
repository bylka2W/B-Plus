# B+ Language Support for Visual Studio Code

Extension for the **B+** programming language: syntax highlighting, snippets,
and one-click **Run/Build** via `bpc.exe`.

## Features

- Syntax highlighting for `.b+`, `.bplus`, `.bp` files
- Bracket matching / auto-closing, indentation rules
- Code folding for `{}` blocks
- Commands:
  - `B+: Run Current File` — `bpc run <file>` then launches the `.exe`
    (default key: `Ctrl+Alt+B` or `F8`)
  - `B+: Build Current File (no run)` — compiles only
- Run button in the editor title bar for `.b+` files

## Requirements

- **B+ compiler** `bpc.exe` (from `C:\B-Plus\zig\zig-out\bin\bpc.exe`).
  The extension searches, in order:
  1. the `bplus.compilerPath` setting,
  2. `bpc` on `PATH`,
  3. well-known default locations.
- Visual Studio Code 1.85+.

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
| `bplus.compilerPath` | `""` | Full path to `bpc.exe`. Empty = auto-detect. |
| `bplus.runInTerminal` | `true` | Run the built `.exe` in the integrated terminal. |
| `bplus.showOutputChannel` | `true` | Show compiler diagnostics in the **B+** output channel. |

## Install from source

```powershell
cd C:\B-Plus\vscode-bplus
npm install          # only if you need vsce packaging
code --install-extension .   # load as a folder, or:
npx @vscode/vsce package --allow-missing-repository
code --install-extension vscode-bplus-0.1.0.vsix
```

Or press `F5` in this folder with the VS Code extension host started with the
"Extension Development Host" profile.

## Custom compiler location

Add to `.vscode/settings.json` in your workspace:

```json
{
  "bplus.compilerPath": "C:\\B-Plus\\zig\\zig-out\\bin\\bpc.exe"
}
```

## License

MIT