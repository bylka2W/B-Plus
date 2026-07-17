import * as vscode from "vscode";
export declare class BplusDiagnostics implements vscode.Disposable {
    private pending;
    clear(uri?: vscode.Uri): void;
    trackBuild(planUri: vscode.Uri, planPath: string, exePath: string): void;
    private parseErrors;
    dispose(): void;
}
