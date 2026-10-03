'use strict';
/*
 * Headless harness for extension.js: mocks the `vscode` module, then drives
 * the real extension code paths (compile, run, clean, diagnostics).
 */
const Module = require('module');
const path = require('path');
const fs = require('fs');
const os = require('os');

// ---------------------------------------------------------------- mock vscode
const created = { diagnostics: [], statusBar: [], terminals: [], output: [] };

function Range(a, b, c, d) { this.a = a; this.b = b; this.c = c; this.d = d; }
function Position(l, c) { this.line = l; this.character = c; }
function Diagnostic(r, m, s) { this.range = r; this.message = m; this.severity = s; }
function Uri(p) { this.fsPath = p; this._s = 'file://' + p; }
Uri.file = (p) => new Uri(p);
Uri.prototype.toString = function () { return this._s; };

const messages = [];
const vscodeMock = {
    DiagnosticSeverity: { Error: 0, Warning: 1, Information: 2, Hint: 3 },
    StatusBarAlignment: { Left: 1, Right: 2 },
    Range, Position, Diagnostic, Uri,
    EventEmitter: class { constructor() { this.event = () => { }; } fire() { } },
    ThemeColor: class { constructor(id) { this.id = id; } },
    languages: {
        createDiagnosticCollection(name) {
            const store = new Map();
            return {
                name,
                set(uri, diags) {
                    store.set(uri.fsPath, diags);
                    created.diagnostics = store;
                },
                delete(uri) { store.delete(uri.fsPath); created.diagnostics = store; },
                dispose() { },
            };
        },
        registerFoldingRangeProvider() { return { dispose() { } }; },
    },
    window: {
        activeTextEditor: null,
        visibleTextEditors: [],
        createOutputChannel() {
            return {
                append() { }, appendLine() { }, show() { }, dispose() { }, clear() { },
            };
        },
        createStatusBarItem() {
            const item = { show() { }, hide() { }, dispose() { }, command: '' };
            created.statusBar.push(item);
            return item;
        },
        createTerminal(opts) {
            const t = {
                opts,
                sent: [],
                shown: 0,
                disposed: false,
                get exitStatus() { return this.disposed ? { code: 0 } : undefined; },
                show() { this.shown++; },
                sendText(s) { this.sent.push(s); },
                dispose() { this.disposed = true; },
            };
            created.terminals.push(t);
            return t;
        },
        showErrorMessage(m) { messages.push(['error', m]); return Promise.resolve(undefined); },
        showWarningMessage(m) { messages.push(['warn', m]); return Promise.resolve(undefined); },
        showInformationMessage(m) { messages.push(['info', m]); return Promise.resolve(undefined); },
        onDidChangeActiveTextEditor() { return { dispose() { } }; },
    },
    workspace: {
        workspaceFolders: null,
        getConfiguration() {
            const settings = harnessSettings;
            return {
                get: (k, d) => (k in settings ? settings[k] : d),
                update: () => Promise.resolve(),
            };
        },
        onDidSaveTextDocument() { return { dispose() { } }; },
    },
    commands: {
        registerCommand(id, fn) { harnessCommands[id] = fn; return { dispose() { } }; },
        executeCommand(id, arg) { messages.push(['cmd', id + ' ' + (arg || '')]); return Promise.resolve(); },
    },
};

let harnessSettings = {
    compilerPath: '', checkOnSave: true, showOutputChannel: false,
    runInTerminal: true, clearTerminalBeforeRun: true, outputDirectory: '',
    keepObjectFile: false,
};
const harnessCommands = {};

// ------------------------------------------------------------------- install
const origResolve = Module._resolveFilename;
Module._resolveFilename = function (request, ...rest) {
    if (request === 'vscode') return 'vscode';
    return origResolve.call(this, request, ...rest);
};
require.cache.vscode = { id: 'vscode', filename: 'vscode', loaded: true, exports: vscodeMock };

const ext = require(process.env.EXT_PATH || path.join(__dirname, 'extension.js'));
const BPC = process.env.BPC || path.join(__dirname, 'bin', 'bpc.exe');

// ---------------------------------------------------------------------- util
let pass = 0, fail = 0;
function check(name, cond, extra) {
    if (cond) { pass++; console.log('  ok   ' + name); }
    else { fail++; console.log('  FAIL ' + name + (extra ? '  -> ' + extra : '')); }
}

function diagsFor(f) {
    const m = created.diagnostics instanceof Map ? created.diagnostics : new Map();
    return m.get(path.resolve(f)) || [];
}
function dumpDiag(f) {
    return JSON.stringify(diagsFor(f).map((d) => [d.range.a, d.message]));
}

function makeDoc(file) {
    const doc = {
        languageId: 'bplus',
        uri: Uri.file(file),
        saved: true,
        save() { this.saved = true; return Promise.resolve(true); },
        getText() { return fs.readFileSync(file, 'utf8'); },
    };
    vscodeMock.window.activeTextEditor = { document: doc };
    vscodeMock.window.visibleTextEditors = [vscodeMock.window.activeTextEditor];
    return doc;
}

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'bplus-ext-'));
process.stdout.write('workspace: ' + work + '\n\n');

(async () => {
    ext.activate({ subscriptions: [] });

    console.log('== command registration ==');
    for (const id of ['bplus.run', 'bplus.build', 'bplus.runExe', 'bplus.clean',
        'bplus.check', 'bplus.doctor', 'bplus.selectCompiler', 'bplus.showOutput']) {
        check('registered ' + id, typeof harnessCommands[id] === 'function');
    }

    console.log('\n== bplus.run: valid program ==');
    const hello = path.join(work, 'hello.b+');
    fs.writeFileSync(hello, 'fn main()\n{\n    x = 6\n    y = 7\n    print(x * y)\n}\n', 'utf8');
    makeDoc(hello);
    created.diagnostics = new Map();
    await harnessCommands['bplus.run']();
    check('exe produced', fs.existsSync(path.join(work, 'hello.exe')));
    check('no diagnostics', (created.diagnostics.size === 0),
        dumpDiag(hello));
    const term = created.terminals[created.terminals.length - 1];
    check('terminal got the exe path', !!term && term.sent.some((s) => s.includes('hello.exe')),
        term ? JSON.stringify(term.sent) : 'no terminal');
    check('terminal ran exactly one program', !!term &&
        term.sent.filter((s) => s.includes('hello.exe')).length === 1,
        term ? JSON.stringify(term.sent) : '');

    console.log('\n== bplus.build: no terminal launch ==');
    const before = created.terminals.length;
    await harnessCommands['bplus.build']();
    check('build did not open a terminal', created.terminals.length === before);
    check('build reported success', messages.some((m) => m[0] === 'info' && m[1].includes('built')),
        JSON.stringify(messages.slice(-2)));

    console.log('\n== bplus.run: program with an error ==');
    const bad = path.join(work, 'bad.b+');
    fs.writeFileSync(bad, 'fn main()\n{\n    print(unknown_variable)\n}\n', 'utf8');
    makeDoc(bad);
    created.diagnostics = new Map();
    const beforeBad = created.terminals.length;
    await harnessCommands['bplus.run']();
    check('error diagnostic published', (created.diagnostics.size > 0));
    check('diagnostic points at line 3', [...diagsFor(bad)].some((d) => d.range.a === 2),
        JSON.stringify([...diagsFor(bad)].map((d) => [d.range.a, d.message])));
    check('message mentions the variable',
        [...diagsFor(bad)].some((d) => d.message.includes('unknown_variable')),
        JSON.stringify([...diagsFor(bad)].map((d) => d.message)));
    check('no exe built', !fs.existsSync(path.join(work, 'bad.exe')));
    check('no terminal opened', created.terminals.length === beforeBad);

    console.log('\n== bplus.run: type error without line info ==');
    const bad2 = path.join(work, 'bad2.b+');
    fs.writeFileSync(bad2, 'fn main()\n{\n    a: i32 = "text"\n}\n', 'utf8');
    makeDoc(bad2);
    created.diagnostics = new Map();
    await harnessCommands['bplus.run']();
    check('still produced a diagnostic', (created.diagnostics.size > 0),
        'compiler said: ' + require('child_process')
            .spawnSync(BPC, ['run', bad2], { encoding: 'utf8' }).stderr);

    console.log('\n== bplus.check: diagnostics only, no artifacts ==');
    const ok = path.join(work, 'ok.b+');
    fs.writeFileSync(ok, 'fn main()\n{\n    print(1)\n}\n', 'utf8');
    makeDoc(ok);
    created.diagnostics = new Map();
    const termsBefore = created.terminals.length;
    await harnessCommands['bplus.check']();
    check('no diagnostics for valid file', diagsFor(ok).length === 0,
        dumpDiag(ok));
    check('no .obj left behind',
        fs.readdirSync(work).filter((f) => f.endsWith('.obj')).length === 0,
        fs.readdirSync(work).join(','));
    check('no exe produced', !fs.existsSync(path.join(work, 'ok.exe')));
    check('check opened no terminal', created.terminals.length === termsBefore);

    console.log('\n== bplus.runExe / bplus.clean ==');
    makeDoc(hello);
    await harnessCommands['bplus.runExe']();
    check('runExe launched existing exe',
        created.terminals[created.terminals.length - 1].sent.some((s) => s.includes('hello.exe')));
    await harnessCommands['bplus.clean']();
    check('clean removed the exe', !fs.existsSync(path.join(work, 'hello.exe')));

    console.log('\n== outputDirectory setting ==');
    harnessSettings.outputDirectory = 'out';
    makeDoc(ok);
    await harnessCommands['bplus.build']();
    check('exe written into out/', fs.existsSync(path.join(work, 'out', 'ok.exe')),
        fs.readdirSync(work).join(','));
    harnessSettings.outputDirectory = '';

    console.log('\n== compilerPath setting ==');
    harnessSettings.compilerPath = 'C:/definitely/missing/bpc.exe';
    harnessSettings.checkOnSave = false;
    makeDoc(ok);
    const terms2 = created.terminals.length;
    await harnessCommands['bplus.run']();
    check('missing compilerPath falls back to bundled compiler and still builds',
        messages.some((m) => m[1] && m[1].includes('built')),
        JSON.stringify(messages.slice(-1)));
    harnessSettings.compilerPath = '';

    console.log('\n== bplus.doctor ==');
    await harnessCommands['bplus.doctor']();
    check('doctor finished', messages.some((m) => m[1] && m[1].includes('doctor finished')),
        JSON.stringify(messages.slice(-1)));

    ext.deactivate();

    fs.rmSync(work, { recursive: true, force: true });
    console.log(`\n${pass} passed, ${fail} failed`);
    process.exit(fail === 0 ? 0 : 1);
})().catch((e) => { console.error(e); process.exit(1); });
