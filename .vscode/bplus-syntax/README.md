# B+ Syntax Highlighting for VS Code

Установка:

```powershell
# Вариант 1 — скопировать в extensions
cp -r .vscode/bplus-syntax $env:USERPROFILE\.vscode\extensions\bplus-syntax

# Вариант 2 — установить как VSIX (нужен vsce)
cd .vscode/bplus-syntax
npx vsce package
code --install-extension bplus-syntax-*.vsix
```

После установки переоткрой VS Code — `.b+` файлы будут с подсветкой.
