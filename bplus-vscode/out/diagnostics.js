"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.BplusDiagnostics = void 0;
const vscode = __importStar(require("vscode"));
const cp = __importStar(require("child_process"));
const BPC = "C:\\B-Plus\\zig\\zig-out\\bin\\bpc.exe";
const diagCollection = vscode.languages.createDiagnosticCollection("bplus");
class BplusDiagnostics {
    constructor() {
        this.pending = new Map();
    }
    clear(uri) {
        if (uri) {
            diagCollection.delete(uri);
        }
        else {
            diagCollection.clear();
        }
    }
    trackBuild(planUri, planPath, exePath) {
        const key = planPath;
        this.pending.set(key, { planUri, planPath, exePath });
        // Poll for .exe and parse build errors
        const interval = setInterval(() => {
            // Try running bpc build and capture stderr
            cp.exec(`"${BPC}" build "${planPath}" 2>&1`, (err, stdout, stderr) => {
                const output = stdout + stderr;
                this.parseErrors(planUri, output, planPath);
                this.pending.delete(key);
                clearInterval(interval);
            });
        }, 500);
    }
    parseErrors(uri, output, planPath) {
        const diagnostics = [];
        const lines = output.split("\n");
        for (const line of lines) {
            // Match patterns like: "error: Unknown state S_Foo" or "file.plan:5: error: ..."
            const errorMatch = line.match(/(?:error|Error|ERROR)\s*:\s*(.+)/);
            if (errorMatch) {
                let message = errorMatch[1].trim();
                let lineNum = 0;
                // Try to extract line number: "file.plan(5): error: ..."
                const lineMatch = line.match(/\((\d+)\)/);
                if (lineMatch) {
                    lineNum = parseInt(lineMatch[1]) - 1;
                }
                const range = new vscode.Range(Math.max(0, lineNum), 0, Math.max(0, lineNum), 1000);
                diagnostics.push(new vscode.Diagnostic(range, message, vscode.DiagnosticSeverity.Error));
            }
        }
        if (diagnostics.length > 0) {
            diagCollection.set(uri, diagnostics);
        }
    }
    dispose() {
        diagCollection.clear();
        diagCollection.dispose();
    }
}
exports.BplusDiagnostics = BplusDiagnostics;
