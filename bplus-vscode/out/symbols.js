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
exports.BplusSymbolProvider = void 0;
const vscode = __importStar(require("vscode"));
class BplusSymbolProvider {
    provideDocumentSymbols(document, _token) {
        const symbols = [];
        const text = document.getText();
        const lines = text.split("\n");
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i];
            const trimmed = line.trim();
            // state S_Name { ... }
            const stateMatch = trimmed.match(/^state\s+([A-Za-z_][A-Za-z0-9_]*)\s*\{/);
            if (stateMatch) {
                symbols.push(new vscode.SymbolInformation(stateMatch[1], vscode.SymbolKind.Class, new vscode.Range(i, 0, i, line.length), document.uri));
                continue;
            }
            // fn name(...) { ... }  or  fn name(...) -> type { ... }
            const fnMatch = trimmed.match(/^fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/);
            if (fnMatch) {
                symbols.push(new vscode.SymbolInformation(fnMatch[1], vscode.SymbolKind.Function, new vscode.Range(i, 0, i, line.length), document.uri));
                continue;
            }
            // entry { ... }
            if (trimmed.startsWith("entry") || trimmed.startsWith("always")) {
                symbols.push(new vscode.SymbolInformation(trimmed.split(/\s/)[0], vscode.SymbolKind.Event, new vscode.Range(i, 0, i, line.length), document.uri));
                continue;
            }
        }
        return symbols;
    }
}
exports.BplusSymbolProvider = BplusSymbolProvider;
