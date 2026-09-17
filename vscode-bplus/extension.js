const vscode = require('vscode');
const { spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');

/** @type {vscode.OutputChannel} */
let outputChannel = null;

// Common Windows locations for bpc.exe and the B+ toolchain.
const DEFAULT_CANDIDATES = [
    process.env.BPC_PATH ? path.join(process.env.BPC_PATH, 'bpc.exe') : null,
    'C:\\B-Plus\\zig\\zig-out\\bin\\bpc.exe',
    'D:\\B-Plus\\zig\\zig-out\\bin\\bpc.exe',
    'C:\\B-Plus\\bpc.exe',
];

/**
 * Resolve the bpc.exe absolute path:
 * 1. user setting `bplus.compilerPath`
 * 2. PATH search
 * 3. well-known candidates
 */
function findCompiler() {
    const cfg = vscode.workspace.getConfiguration('bplus');
    const explicit = cfg.get('compilerPath', '');
    if (explicit) {
        return path.isAbsolute(explicit) ? explicit : path.resolve(vscode.workspace.rootPath || '', explicit);
    }

    // PATH search via `where` on Windows, `which` elsewhere.
    const whereCmd = spawnSync(process.platform === 'win32' ? 'where' : 'which', ['bpc'], { encoding: 'utf-8' });
    if (whereCmd.status === 0 && whereCmd.stdout) {
        const first = whereCmd.stdout.split(/\r?\n/).find((l) => l.trim().length > 0);
        if (first && first.trim().toLowerCase().endsWith('bpc.exe')) {
            return first.trim();
        }
    }

    for (const cand of DEFAULT_CANDIDATES) {
        if (!cand) continue;
        if (fs.existsSync(cand)) return cand;
    }
    return null;
}

function buildCommandLine(bin, file) {
    return {
        bin,
        args: ['run', file],
    };
}

/** Kill any running instance of the target exe and remove a stale copy so linking can overwrite it. */
function clearRunningExe(exePath) {
    try {
        const { spawnSync } = require('child_process');
        const img = path.basename(exePath);
        spawnSync('taskkill', ['/F', '/IM', img, '/T'], { encoding: 'utf-8' });
        if (fs.existsSync(exePath)) {
            try {
                fs.unlinkSync(exePath);
            } catch (_) {
                // still locked; linker will report it, but we tried.
            }
        }
    } catch (_) {
        // ignore
    }
}

function runCompiler(bin, args) {
    const result = spawnSync(bin, args, {
        encoding: 'utf-8',
        cwd: path.dirname(args[1]),
        windowsHide: false,
        maxBuffer: 64 * 1024 * 1024,
    });
    return result;
}

async function doBuildFile(runExe) {
    const doc = vscode.window.activeTextEditor;
    if (!doc || doc.document.languageId !== 'bplus') {
        vscode.window.showWarningMessage('B+: open a .b+ file first.');
        return false;
    }

    const file = doc.document.uri.fsPath;
    const bin = findCompiler();
    if (!bin) {
        const pick = await vscode.window.showErrorMessage(
            'B+: cannot locate bpc.exe. Set "bplus.compilerPath" in settings.',
            { title: 'Open Settings', action: 'openSettings' },
            { title: 'OK' }
        );
        if (pick && pick.action === 'openSettings') {
            vscode.commands.executeCommand('workbench.action.openSettings', 'bplus.compilerPath');
        }
        return false;
    }

    const cfg = vscode.workspace.getConfiguration('bplus');
    if (cfg.get('showOutputChannel', true)) {
        outputChannel = outputChannel || vscode.window.createOutputChannel('B+');
        outputChannel.show(true);
        outputChannel.appendLine(`> ${bin} run ${file}`);
    }

    clearRunningExe(file.replace(/\.b\+$/, '.exe'));

    const { args } = buildCommandLine(bin, file);
    const result = runCompiler(bin, args);

    if (outputChannel) {
        if (result.stdout && result.stdout.trim()) outputChannel.append(result.stdout);
        if (result.stderr && result.stderr.trim()) outputChannel.appendLine('[stderr] ' + result.stderr.trim());
    }

    if (result.status === 0) {
        if (outputChannel) outputChannel.appendLine('Build OK.');
        if (runExe) {
            const exe = file.replace(/\.b\+$/, '.exe');
            if (fs.existsSync(exe)) {
                if (cfg.get('runInTerminal', true)) {
                    clearRunningExe(exe);
                    await runExeInTerminal(exe, path.dirname(file));
                } else {
                    const r = spawnSync(exe, [], { encoding: 'utf-8', cwd: path.dirname(file) });
                    if (outputChannel) {
                        outputChannel.appendLine('--- program output ---');
                        if (r.stdout) outputChannel.appendLine(r.stdout);
                        if (r.stderr) outputChannel.appendLine(r.stderr);
                    }
                }
            } else {
                vscode.window.showWarningMessage('B+: built OK but .exe not found: ' + exe);
            }
        }
        return true;
    }

    const errLines = (result.stderr || result.stdout || 'compilation failed').split(/\r?\n/);
    const firstErr = errLines.find((l) => l.includes('error:') || l.includes('Error')) || errLines[0];
    vscode.window.showErrorMessage('B+: compilation failed. ' + firstErr.trim());
    return false;
}

function runExeInTerminal(exe, cwd) {
    return new Promise((resolve) => {
        const term = vscode.window.createTerminal({
            name: 'B+ Run',
            cwd,
        });
        term.show(true);
        term.sendText(`& '${exe}'`);
        resolve();
    });
}

function activate(context) {
    context.subscriptions.push(
        vscode.commands.registerCommand('bplus.run', async () => doBuildFile(true)),
        vscode.commands.registerCommand('bplus.build', async () => doBuildFile(false)),
        vscode.languages.registerFoldingRangeProvider('bplus', {
            provideFoldingRanges(document) {
                const ranges = [];
                const stack = [];
                const lines = document.getText().split('\n');
                for (let i = 0; i < lines.length; i++) {
                    const line = lines[i];
                    const open = (line.match(/{/g) || []).length;
                    const close = (line.match(/}/g) || []).length;
                    if (open > 0) stack.push({ line: i, open });
                    if (close > 0) {
                        while (stack.length > 0 && close > 0) {
                            const top = stack.pop();
                            ranges.push(new vscode.FoldingRange(top.line, i));
                            close--;
                        }
                    }
                }
                return ranges;
            },
        })
    );
}

function deactivate() {
    if (outputChannel) outputChannel.dispose();
}

module.exports = { activate, deactivate };