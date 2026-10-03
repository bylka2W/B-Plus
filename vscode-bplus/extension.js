'use strict';

const vscode = require('vscode');
const { spawn, spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const IS_WIN = process.platform === 'win32';
const BUNDLED_BIN = path.join(__dirname, 'bin', 'bpc.exe');

let outputChannel = null;
let diagnostics = null;
let statusBar = null;
let runTerminal = null;
const pendingChecks = new Map();

/* ------------------------------------------------------------------ *
 * compiler discovery
 * ------------------------------------------------------------------ */

function wellKnownPaths() {
    if (!IS_WIN) return [];
    const list = [
        'C:\\B-Plus\\zig\\zig-out\\bin\\bpc.exe',
        'D:\\B-Plus\\zig\\zig-out\\bin\\bpc.exe',
        path.join(process.env.LOCALAPPDATA || '', 'Programs', 'B+', 'bpc.exe'),
    ];
    if (process.env.BPC_PATH) list.unshift(path.join(process.env.BPC_PATH, 'bpc.exe'));
    return list.filter(Boolean);
}

function firstExisting(cands) {
    for (const c of cands) {
        if (c && fs.existsSync(c)) return c;
    }
    return null;
}

function whichBpc() {
    try {
        const r = spawnSync(IS_WIN ? 'where' : 'which', ['bpc'], { encoding: 'utf-8' });
        if (r.status !== 0 || !r.stdout) return null;
        const hit = r.stdout.split(/\r?\n/).map((l) => l.trim()).find((l) => l && /bpc(\.exe)?$/i.test(l));
        return hit || null;
    } catch (_) {
        return null;
    }
}

/**
 * Resolution order guarantees "install the extension and it just works":
 *   1. bplus.compilerPath setting
 *   2. BPC_PATH environment variable
 *   3. compiler bundled inside the extension (bin/bpc.exe)
 *   4. bpc on PATH
 *   5. well-known local build folders
 */
function findCompiler() {
    const cfg = vscode.workspace.getConfiguration('bplus');
    const explicit = (cfg.get('compilerPath') || '').trim();
    if (explicit) {
        const abs = path.isAbsolute(explicit)
            ? explicit
            : path.resolve(workspaceRoot(), explicit);
        if (fs.existsSync(abs)) return abs;
        log(`configured bplus.compilerPath does not exist: ${abs}`);
    }

    return firstExisting([
        process.env.BPC_PATH ? path.join(process.env.BPC_PATH, 'bpc.exe') : null,
        IS_WIN ? BUNDLED_BIN : path.join(__dirname, 'bin', 'bpc'),
        whichBpc(),
        ...wellKnownPaths(),
    ]);
}

function workspaceRoot() {
    const folders = vscode.workspace.workspaceFolders;
    if (folders && folders.length) return folders[0].uri.fsPath;
    return process.cwd();
}

/* ------------------------------------------------------------------ *
 * process helper
 * ------------------------------------------------------------------ */

function log(line) {
    outputChannel = outputChannel || vscode.window.createOutputChannel('B+');
    outputChannel.appendLine(line);
}

function reveal() {
    outputChannel = outputChannel || vscode.window.createOutputChannel('B+');
    if (vscode.workspace.getConfiguration('bplus').get('showOutputChannel', true)) {
        outputChannel.show(true);
    }
    return outputChannel;
}

function runBpc(bin, args, cwd) {
    return new Promise((resolve) => {
        log(`> ${bin} ${args.join(' ')}   (cwd: ${cwd})`);
        let child;
        try {
            child = spawn(bin, args, { cwd, windowsHide: true });
        } catch (err) {
            resolve({ code: -1, stdout: '', stderr: String(err) });
            return;
        }
        let stdout = '';
        let stderr = '';
        child.stdout.on('data', (d) => { stdout += d.toString(); });
        child.stderr.on('data', (d) => { stderr += d.toString(); });
        child.on('error', (err) => resolve({ code: -1, stdout, stderr: stderr + String(err) }));
        child.on('close', (code) => resolve({ code: code === null ? -1 : code, stdout, stderr }));
    });
}

function showOutput(res) {
    const out = reveal();
    if (res.stdout && res.stdout.trim()) out.append(res.stdout);
    if (res.stderr && res.stderr.trim()) out.appendLine('[stderr] ' + res.stderr.trim());
}

/* ------------------------------------------------------------------ *
 * diagnostics
 * ------------------------------------------------------------------ */

// Lines that only restate a failure already reported with a better message.
const NOISE = [
    /compilation failed/i,
    /semantic analysis failed/i,
    /BIR verification\/optimization pipeline failed/i,
    /^error:\s*(UnexpectedToken|UnknownExpression|VerificationFailed|DuplicateStruct|ImportNotFound)\b/,
    /no functions found in/i,
    /^error:\s*$/,
];

const PANIC_NOISE = [
    /\.zig:\d+:\d+: 0x[0-9a-f]+ in /i,
    /^\s*\^+\s*$/,
    /reached unreachable code/i,
    /stack overflow/i,
    /returned from function without returning a value/i,
];

function isNoise(line) {
    const t = line.trim();
    if (!t) return true;
    if (PANIC_NOISE.some((r) => r.test(t))) return true;
    return NOISE.some((r) => r.test(t));
}

function stripPrefixes(msg) {
    let m = msg.trim();
    let prev;
    do {
        prev = m;
        m = m.replace(/^error:\s*/, '');
    } while (m !== prev);
    return m.replace(/^error\.[A-Za-z]+:\s*/, '');
}

// A diagnostic looks like:  <path>:<line>[:<col>]: error: <message>
// The compiler often prefixes the whole line with another "error: ", so the
// prefix is removed before looking for the location.
const LOC_RE = /^(.+?\.[A-Za-z0-9_+-]+):(\d+)(?::(\d+))?:\s*(?:error|note)\s*:\s*(.*)$/;
const VERIFY_RE = /VERIFY:\s*\[([a-z_]+)\]\s*(.*)$/;
const LEAD_RE = /^\s*(?:error|note)\s*:\s*/i;

/**
 * Turns raw bpc output into VS Code diagnostics.
 * Every message without a usable location is anchored to line 1 so it stays
 * visible instead of silently disappearing.
 */
function parseDiagnostics(file, stdout, stderr) {
    const raw = `${stdout || ''}\n${stderr || ''}`.split(/\r?\n/);
    const dir = path.dirname(file);
    const found = [];
    const seen = new Set();
    let inlineSeen = false;

    for (const rawLine of raw) {
        const line = rawLine.replace(/\s+$/, '');
        if (isNoise(line)) continue;

        let loc = null;
        let message = null;

        const verify = line.trim().match(VERIFY_RE);
        if (verify) {
            message = `[${verify[1]}] ${verify[2].trim()}`;
            inlineSeen = true;
        } else {
            const body = line.replace(LEAD_RE, '');
            const m = body.match(LOC_RE);
            if (m) {
                const abs = path.resolve(dir, m[1]);
                if (path.resolve(abs) === path.resolve(file)) {
                    loc = { line: parseInt(m[2], 10), col: m[3] ? parseInt(m[3], 10) : null };
                    message = stripPrefixes(m[4]);
                    inlineSeen = true;
                }
            } else if (LEAD_RE.test(line)) {
                message = stripPrefixes(body);
                inlineSeen = true;
            }
        }

        if (!message) continue;
        message = message.trim();
        if (!message) continue;

        const target = loc || { line: 1, col: null };
        const key = `${target.line}:${target.col}:${message}`;
        if (seen.has(key)) continue;
        seen.add(key);

        found.push({ target, message, severity: vscode.DiagnosticSeverity.Error });
    }

    // The compiler failed but produced nothing we could map: report it anyway.
    if (!inlineSeen && found.length === 0) {
        const last = raw.map((l) => l.trim()).filter((l) => l && !PANIC_NOISE.some((r) => r.test(l)));
        const tail = last.length ? last[last.length - 1] : 'compilation failed';
        found.push({ target: { line: 1, col: null }, message: stripPrefixes(tail), severity: vscode.DiagnosticSeverity.Error });
    }

    return found;
}

function publishDiagnostics(file, res) {
    diagnostics = diagnostics || vscode.languages.createDiagnosticCollection('bplus');
    if (res.code === 0) {
        diagnostics.delete(vscode.Uri.file(file));
        return [];
    }
    const list = parseDiagnostics(file, res.stdout, res.stderr);
    const items = list.map((d) => {
        const line = Math.max(0, d.target.line - 1);
        const range = d.target.col
            ? new vscode.Range(line, Math.max(0, d.target.col - 1), line, Math.max(0, d.target.col - 1))
            : new vscode.Range(line, 0, line, Number.MAX_SAFE_INTEGER);
        const diag = new vscode.Diagnostic(range, d.message, d.severity);
        diag.source = 'bpc';
        return diag;
    });
    diagnostics.set(vscode.Uri.file(file), items);
    return items;
}

function firstMessage(items) {
    if (!items || items.length === 0) return 'compilation failed';
    const d = items[0];
    return d.message.length > 220 ? d.message.slice(0, 217) + '...' : d.message;
}

/* ------------------------------------------------------------------ *
 * build pipeline
 * ------------------------------------------------------------------ */

function sourceOf() {
    const active = vscode.window.activeTextEditor;
    if (active && isBplus(active.document)) return active.document;
    const visible = vscode.window.visibleTextEditors.find((e) => isBplus(e.document));
    return visible ? visible.document : null;
}

function isBplus(doc) {
    if (!doc) return false;
    if (doc.languageId === 'bplus') return true;
    return /\.(b\+|bplus|bp)$/i.test(doc.uri.fsPath);
}

function outputExePath(file) {
    const cfg = vscode.workspace.getConfiguration('bplus');
    const dir = (cfg.get('outputDirectory') || '').trim();
    const base = path.basename(file).replace(/\.[^.]+$/, '');
    if (dir) {
        const abs = path.isAbsolute(dir) ? dir : path.resolve(path.dirname(file), dir);
        try {
            fs.mkdirSync(abs, { recursive: true });
        } catch (err) {
            vscode.window.showErrorMessage(`B+: cannot create output directory ${abs} (${err.message})`);
            return null;
        }
        return path.join(abs, base + '.exe');
    }
    return path.join(path.dirname(file), base + '.exe');
}

/**
 * Compile-only pipeline: `bpc mir` (source -> COFF .obj) then `bpc link`
 * (.obj -> .exe). Unlike `bpc run` this never executes the program, so the
 * same routine can be used for diagnostics, build and run.
 */
async function compileFile(file, { wantExe }) {
    const bin = findCompiler();
    if (!bin) {
        vscode.window.showErrorMessage(
            'B+: compiler not found. Reinstall the extension (it ships bin/bpc.exe) or set "bplus.compilerPath".'
        );
        vscode.commands.executeCommand('workbench.action.openSettings', 'bplus.compilerPath');
        return { ok: false, bin: null };
    }

    const dir = path.dirname(file);
    const exe = outputExePath(file);
    if (!exe) return { ok: false, bin };

    const obj = exe.replace(/\.exe$/i, '.obj');

    log('');
    log(`--- compiling ${file}`);

    const res1 = await runBpc(bin, ['mir', file, '-o', obj], dir);
    showOutput(res1);
    let items = publishDiagnostics(file, res1);
    if (res1.code !== 0) return { ok: false, bin, exe, items };

    if (wantExe) {
        const res2 = await runBpc(bin, ['link', obj, '-o', exe], dir);
        showOutput(res2);
        items = publishDiagnostics(file, res2);
        if (res2.code !== 0) return { ok: false, bin, exe, items };
    }

    if (!vscode.workspace.getConfiguration('bplus').get('keepObjectFile', false)) {
        try { fs.unlinkSync(obj); } catch (_) { /* keep a locked object file */ }
    }

    log('Build OK.');
    return { ok: true, bin, exe, items: [] };
}

/** Compile to a throwaway .obj purely to refresh diagnostics (no artifacts). */
async function checkFile(file) {
    const bin = findCompiler();
    if (!bin) return;
    const tmp = path.join(os.tmpdir(), `bpc-check-${process.pid}-${Date.now()}.obj`);
    const res = await runBpc(bin, ['mir', file, '-o', tmp], path.dirname(file));
    publishDiagnostics(file, res);
    try { fs.unlinkSync(tmp); } catch (_) { /* ignore */ }
}

/* ------------------------------------------------------------------ *
 * running
 * ------------------------------------------------------------------ */

function killRunningExe(exe) {
    if (!exe || !IS_WIN) return;
    const target = exe.replace(/'/g, "''");
    const name = path.basename(exe).replace(/'/g, "''");
    const ps = [
        `$ErrorActionPreference='SilentlyContinue'`,
        `Get-CimInstance Win32_Process -Filter "Name='${name}'"`,
        ` | Where-Object { $_.ExecutablePath -eq '${target}' }`,
        ` | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }`,
    ].join('');
    try {
        spawnSync('powershell', ['-NoProfile', '-NonInteractive', '-Command', ps], { windowsHide: true });
    } catch (_) { /* ignore */ }
}

function launchInTerminal(exe, cwd) {
    const cfg = vscode.workspace.getConfiguration('bplus');
    if (cfg.get('runInTerminal', true)) {
        const opts = { name: 'B+ Run', cwd };
        if (IS_WIN) {
            opts.shellPath = 'powershell.exe';
            opts.shellArgs = ['-NoProfile'];
        }
        if (!runTerminal || runTerminal.exitStatus) {
            runTerminal = vscode.window.createTerminal(opts);
        }
        if (cfg.get('clearTerminalBeforeRun', true)) runTerminal.sendText('cls');
        runTerminal.show(true);
        runTerminal.sendText(IS_WIN ? `& '${exe}'; $LASTEXITCODE` : `'${exe}'; echo "exit=$?"`);
        return;
    }

    // headless: capture into the output channel
    const res = spawnSync(exe, [], { cwd, encoding: 'utf-8', windowsHide: true });
    const out = reveal();
    out.appendLine(`--- program output (exit ${res.status}) ---`);
    if (res.stdout) out.append(res.stdout);
    if (res.stderr) out.appendLine('[stderr] ' + res.stderr.trim());
}

/* ------------------------------------------------------------------ *
 * status bar
 * ------------------------------------------------------------------ */

function updateStatusBar(state) {
    if (!statusBar) return;
    if (state === 'error') {
        statusBar.text = '$(error) B+';
        statusBar.tooltip = 'B+: last build failed — click to open the output channel';
        statusBar.backgroundColor = new vscode.ThemeColor('statusBarItem.errorBackground');
    } else if (state === 'ok') {
        statusBar.text = '$(check) B+';
        statusBar.tooltip = 'B+: last build succeeded — click to run the current file';
        statusBar.backgroundColor = undefined;
    } else {
        statusBar.text = '$(zap) B+';
        statusBar.tooltip = 'B+: ready — click to run the current file';
        statusBar.backgroundColor = undefined;
    }
}

/* ------------------------------------------------------------------ *
 * commands
 * ------------------------------------------------------------------ */

async function cmdRun() {
    const doc = sourceOf();
    if (!doc) {
        vscode.window.showWarningMessage('B+: open a .b+ file first.');
        return;
    }
    const file = doc.uri.fsPath;
    const dir = path.dirname(file);
    const saved = await doc.save();

    const result = await compileFile(file, { wantExe: true });
    if (!result.ok) {
        updateStatusBar('error');
        vscode.window.showErrorMessage('B+: ' + firstMessage(result.items));
        return;
    }
    updateStatusBar('ok');
    killRunningExe(result.exe);
    launchInTerminal(result.exe, dir);
    log(`running ${result.exe}`);
    if (!saved) vscode.window.showWarningMessage('B+: save the file before running (compilation used the version on disk).');
}

async function cmdBuild() {
    const doc = sourceOf();
    if (!doc) {
        vscode.window.showWarningMessage('B+: open a .b+ file first.');
        return;
    }
    await doc.save();
    const result = await compileFile(doc.uri.fsPath, { wantExe: true });
    if (!result.ok) {
        updateStatusBar('error');
        vscode.window.showErrorMessage('B+: ' + firstMessage(result.items));
        return;
    }
    updateStatusBar('ok');
    vscode.window.showInformationMessage('B+: built ' + path.basename(result.exe));
}

function cmdRunExe() {
    const doc = sourceOf();
    if (!doc) {
        vscode.window.showWarningMessage('B+: open a .b+ file first.');
        return;
    }
    const exe = outputExePath(doc.uri.fsPath);
    if (!exe || !fs.existsSync(exe)) {
        vscode.window.showWarningMessage('B+: no built .exe found. Press F8 to build and run.');
        return;
    }
    killRunningExe(exe);
    launchInTerminal(exe, path.dirname(exe));
}

async function cmdClean() {
    const doc = sourceOf();
    if (!doc) return;
    const file = doc.uri.fsPath;
    const exe = outputExePath(file);
    if (exe) {
        killRunningExe(exe);
        try {
            if (fs.existsSync(exe)) {
                fs.unlinkSync(exe);
                vscode.window.showInformationMessage('B+: removed ' + path.basename(exe));
            } else {
                vscode.window.showInformationMessage('B+: nothing to clean.');
            }
        } catch (err) {
            vscode.window.showErrorMessage(`B+: cannot delete ${path.basename(exe)} (${err.message})`);
        }
    }
    const obj = file.replace(/\.[^.]+$/, '.obj');
    try { if (fs.existsSync(obj)) fs.unlinkSync(obj); } catch (_) { /* ignore */ }
}

async function cmdCheck() {
    const doc = sourceOf();
    if (!doc) {
        vscode.window.showWarningMessage('B+: open a .b+ file first.');
        return;
    }
    const file = doc.uri.fsPath;
    const bin = findCompiler();
    if (!bin) {
        vscode.window.showErrorMessage('B+: compiler not found.');
        return;
    }
    const tmp = path.join(os.tmpdir(), `bpc-check-${process.pid}-${Date.now()}.obj`);
    reveal();
    const res = await runBpc(bin, ['mir', file, '-o', tmp], path.dirname(file));
    publishDiagnostics(file, res);
    try { fs.unlinkSync(tmp); } catch (_) { /* ignore */ }
    if (res.code === 0) {
        updateStatusBar('ok');
        vscode.window.showInformationMessage('B+: check OK — no problems found.');
    } else {
        updateStatusBar('error');
    }
}

async function cmdDoctor() {
    const bin = findCompiler();
    if (!bin) {
        vscode.window.showErrorMessage('B+: compiler not found.');
        return;
    }
    const out = reveal();
    out.appendLine('');
    out.appendLine(`compiler: ${bin}`);
    const res = await runBpc(bin, ['doctor'], workspaceRoot());
    out.append(res.stdout || '');
    if (res.stderr) out.appendLine('[stderr] ' + res.stderr.trim());
    vscode.window.showInformationMessage(`B+: doctor finished (exit ${res.code}) — see the B+ output channel.`);
}

function cmdSelectCompiler() {
    vscode.commands.executeCommand('workbench.action.openSettings', 'bplus.compilerPath');
}

function cmdShowOutput() {
    reveal();
}

/* ------------------------------------------------------------------ *
 * save hooks
 * ------------------------------------------------------------------ */

function scheduleCheck(doc) {
    if (!isBplus(doc)) return;
    if (doc.uri.scheme !== 'file') return;
    if (!vscode.workspace.getConfiguration('bplus').get('checkOnSave', true)) return;

    const key = doc.uri.toString();
    clearTimeout(pendingChecks.get(key));
    const timer = setTimeout(() => {
        pendingChecks.delete(key);
        checkFile(doc.uri.fsPath).catch(() => { /* never break the editor */ });
    }, 400);
    pendingChecks.set(key, timer);
}

/* ------------------------------------------------------------------ *
 * activation
 * ------------------------------------------------------------------ */

function activate(context) {
    outputChannel = vscode.window.createOutputChannel('B+');
    context.subscriptions.push(outputChannel);
    diagnostics = vscode.languages.createDiagnosticCollection('bplus');
    context.subscriptions.push(diagnostics);

    statusBar = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
    statusBar.command = 'bplus.run';
    context.subscriptions.push(statusBar);
    updateStatusBar('idle');
    statusBar.show();

    context.subscriptions.push(
        vscode.commands.registerCommand('bplus.run', cmdRun),
        vscode.commands.registerCommand('bplus.build', cmdBuild),
        vscode.commands.registerCommand('bplus.runExe', cmdRunExe),
        vscode.commands.registerCommand('bplus.clean', cmdClean),
        vscode.commands.registerCommand('bplus.check', cmdCheck),
        vscode.commands.registerCommand('bplus.doctor', cmdDoctor),
        vscode.commands.registerCommand('bplus.selectCompiler', cmdSelectCompiler),
        vscode.commands.registerCommand('bplus.showOutput', cmdShowOutput),

        vscode.workspace.onDidSaveTextDocument(scheduleCheck),

        vscode.window.onDidChangeActiveTextEditor(() => {
            const doc = vscode.window.activeTextEditor && vscode.window.activeTextEditor.document;
            statusBar.text = isBplus(doc) ? statusBar.text : '$(zap) B+';
        }),

        vscode.languages.registerFoldingRangeProvider('bplus', {
            provideFoldingRanges(document) {
                const ranges = [];
                const stack = [];
                const lines = document.getText().split('\n');
                for (let i = 0; i < lines.length; i++) {
                    const line = lines[i];
                    const open = (line.match(/{/g) || []).length;
                    let close = (line.match(/}/g) || []).length;
                    if (open > 0) stack.push({ line: i, open });
                    while (stack.length > 0 && close > 0) {
                        ranges.push(new vscode.FoldingRange(stack.pop().line, i));
                        close--;
                    }
                }
                return ranges;
            },
        })
    );

    const bin = findCompiler();
    if (bin) {
        log(`B+ extension activated. Compiler: ${bin}`);
        const version = spawnSync(bin, ['doctor'], { encoding: 'utf-8', windowsHide: true, timeout: 20000 });
        if (version && version.status === 0) {
            log('bpc doctor: OK');
        } else {
            log('bpc doctor: FAILED - run "B+: Compiler Health Check" for details');
        }
    } else {
        log('bpc.exe NOT FOUND. The extension should ship bin/bpc.exe.');
        vscode.window.showErrorMessage(
            'B+: bundled compiler (bin/bpc.exe) is missing. Reinstall the extension or set "bplus.compilerPath".'
        );
    }
}

function deactivate() {
    for (const timer of pendingChecks.values()) clearTimeout(timer);
    pendingChecks.clear();
    if (runTerminal) runTerminal.dispose();
    if (outputChannel) outputChannel.dispose();
    if (diagnostics) diagnostics.dispose();
    if (statusBar) statusBar.dispose();
}

module.exports = { activate, deactivate };
