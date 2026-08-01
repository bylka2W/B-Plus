import * as vscode from "vscode";
import * as cp from "child_process";

let lsp: BplusLspClient | undefined;
const diags = vscode.languages.createDiagnosticCollection("bplus");

export function activate(ctx: vscode.ExtensionContext): void {
    const cfg = vscode.workspace.getConfiguration("bplus");
    const bpc = cfg.get<string>("bpcPath", "C:\\B-Plus\\zig\\zig-out\\bin\\bpc.exe");

    ctx.subscriptions.push(vscode.commands.registerCommand("bplus.build", () => runInTerminal(bpc, "build")));
    ctx.subscriptions.push(vscode.commands.registerCommand("bplus.run", () => runInTerminal(bpc, "run")));
    ctx.subscriptions.push(vscode.commands.registerCommand("bplus.test", () => runInTerminal(bpc, "test")));
    ctx.subscriptions.push(vscode.commands.registerCommand("bplus.check", () => runInTerminal(bpc, "check")));

    ctx.subscriptions.push(vscode.languages.registerCodeLensProvider("bplus", {
        provideCodeLenses(doc) {
            const lenses: vscode.CodeLens[] = [];
            for (let i = 0; i < doc.lineCount; i++) {
                const line = doc.lineAt(i).text.trim();
                if (/^fn\s+\w+\s*\(/.test(line)) {
                    const r = new vscode.Range(i, 0, i, 0);
                    lenses.push(new vscode.CodeLens(r, { title: "▶ Run", command: "bplus.run", arguments: [] }));
                }
            }
            return lenses;
        },
    }));

    if (cfg.get<boolean>("diagnostics", true)) {
        startLsp(ctx, cfg.get<string>("lspPath", "C:\\B-Plus\\zig\\zig-out\\bin\\bplus-lsp.exe"));
    }

    ctx.subscriptions.push({ dispose: () => { lsp?.dispose(); diags.dispose(); } });
}

function runInTerminal(bpc: string, command: string): void {
    const doc = vscode.window.activeTextEditor?.document;
    if (!doc || doc.languageId !== "bplus") {
        vscode.window.showInformationMessage("Open a .b+ file first.");
        return;
    }
    const t = vscode.window.createTerminal("B+");
    t.show();
    t.sendText(`cmd /c ""${bpc}" ${command} "${doc.uri.fsPath}""`);
}

function startLsp(ctx: vscode.ExtensionContext, lspPath: string): void {
    try {
        lsp = new BplusLspClient(lspPath);
        for (const doc of vscode.workspace.textDocuments) {
            if (doc.languageId === "bplus") lsp.open(doc);
        }
        ctx.subscriptions.push(
            vscode.workspace.onDidOpenTextDocument(d => { if (d.languageId === "bplus") lsp?.open(d); }),
            vscode.workspace.onDidChangeTextDocument(e => { if (e.document.languageId === "bplus") lsp?.change(e.document); }),
            vscode.workspace.onDidCloseTextDocument(d => { if (d.languageId === "bplus") lsp?.close(d.uri.toString()); }),
        );
    } catch {
        vscode.window.showWarningMessage("B+ LSP server could not be started. Diagnostics disabled.");
    }
}

class BplusLspClient {
    private proc: cp.ChildProcess;
    private pending = new Map<number, { resolve: (v: unknown) => void }>();
    private id = 1;
    private buffer = Buffer.alloc(0);
    private uriToFs = new Map<string, string>();

    constructor(lspPath: string) {
        this.proc = cp.spawn(lspPath, [], { stdio: ["pipe", "pipe", "pipe"] });
        this.proc.stdout!.on("data", (d: Buffer) => this.onData(d));
        this.proc.stderr!.on("data", (d: Buffer) => console.error("[bplus-lsp]", d.toString()));
        this.proc.on("error", () => { /* server missing; surface via warning in startLsp */ });
        this.request("initialize", { processId: process.pid, rootUri: null, capabilities: {} })
            .then(() => this.notify("initialized", {}))
            .catch(() => {});
    }

    private onData(data: Buffer): void {
        this.buffer = Buffer.concat([this.buffer, data]);
        for (;;) {
            const headerEnd = this.buffer.indexOf("\r\n\r\n");
            if (headerEnd < 0) return;
            const header = this.buffer.slice(0, headerEnd).toString();
            const m = /Content-Length:\s*(\d+)/i.exec(header);
            if (!m) { this.buffer = this.buffer.slice(headerEnd + 4); continue; }
            const len = parseInt(m[1], 10);
            const bodyStart = headerEnd + 4;
            if (this.buffer.length < bodyStart + len) return;
            const body = this.buffer.slice(bodyStart, bodyStart + len).toString();
            this.buffer = this.buffer.slice(bodyStart + len);
            this.handleMessage(body);
        }
    }

    private handleMessage(body: string): void {
        const msg = JSON.parse(body);
        if (msg.id !== undefined && msg.result !== undefined) {
            const p = this.pending.get(msg.id);
            if (p) { p.resolve(msg.result); this.pending.delete(msg.id); }
            return;
        }
        if (msg.method === "textDocument/publishDiagnostics") {
            const p = msg.params as { uri: string; diagnostics: any[] };
            const fsPath = this.uriToFs.get(p.uri) ?? uriToPath(p.uri);
            const doc = vscode.workspace.textDocuments.find(d => d.uri.toString() === p.uri || d.uri.fsPath === fsPath);
            if (!doc) return;
            const list = p.diagnostics.map((d: any) => {
                const r = d.range as { start: { line: number; character: number }; end: { line: number; character: number } };
                return new vscode.Diagnostic(
                    new vscode.Range(r.start.line, r.start.character, r.end.line, r.end.character),
                    d.message,
                    d.severity === 2 ? vscode.DiagnosticSeverity.Warning : vscode.DiagnosticSeverity.Error,
                );
            });
            diags.set(doc.uri, list);
        }
    }

    private send(obj: unknown): void {
        const body = JSON.stringify(obj);
        this.proc.stdin!.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
    }

    private notify(method: string, params: unknown): void {
        this.send({ jsonrpc: "2.0", method, params });
    }

    private request(method: string, params: unknown): Promise<unknown> {
        const id = this.id++;
        return new Promise((resolve) => {
            this.pending.set(id, { resolve });
            this.send({ jsonrpc: "2.0", id, method, params });
        });
    }

    open(doc: vscode.TextDocument): void {
        this.uriToFs.set(doc.uri.toString(), doc.uri.fsPath);
        this.notify("textDocument/didOpen", {
            textDocument: { uri: doc.uri.toString(), languageId: doc.languageId, version: doc.version, text: doc.getText() },
        });
    }

    change(doc: vscode.TextDocument): void {
        this.notify("textDocument/didChange", {
            textDocument: { uri: doc.uri.toString(), version: doc.version },
            contentChanges: [{ text: doc.getText() }],
        });
    }

    close(uri: string): void {
        this.notify("textDocument/didClose", { textDocument: { uri } });
        diags.delete(uriToUri(uri));
    }

    dispose(): void {
        this.proc.kill();
    }
}

function uriToPath(uri: string): string {
    return uri.replace(/^file:\/\//, "");
}
function uriToUri(uri: string): vscode.Uri {
    return vscode.Uri.parse(uri);
}
