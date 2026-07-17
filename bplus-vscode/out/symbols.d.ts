import * as vscode from "vscode";
export declare class BplusSymbolProvider implements vscode.DocumentSymbolProvider {
    provideDocumentSymbols(document: vscode.TextDocument, _token: vscode.CancellationToken): vscode.SymbolInformation[];
}
