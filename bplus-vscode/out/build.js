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
exports.bplusBuild = bplusBuild;
const vscode = __importStar(require("vscode"));
const BPC = "C:\\B-Plus\\zig\\zig-out\\bin\\bpc.exe";
function bplusBuild(diag) {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
        vscode.window.showErrorMessage("No active editor");
        return;
    }
    const filePath = editor.document.uri.fsPath;
    if (!filePath.endsWith(".plan") && !filePath.endsWith(".metal")) {
        vscode.window.showErrorMessage("Not a B+ file (.plan or .metal)");
        return;
    }
    diag.clear(editor.document.uri);
    const terminal = vscode.window.createTerminal("B+ Build");
    terminal.show();
    terminal.sendText(`"${BPC}" build "${filePath}"`);
    // After build, parse stderr for errors
    const exePath = filePath.replace(/\.(plan|metal)$/, ".exe");
    diag.trackBuild(editor.document.uri, filePath, exePath);
}
