# ========== VS Code Remote Control: create, install, and configure (workspace) ==========

"""
    install_vscode_remote_control(workspace_dir; publisher="your-publisher-id",
                                  name="vscode-remote-control", version="0.0.1",
                                  allowed_commands=["workbench.action.files.save"],
                                  require_confirmation=false)

Creates a minimal VS Code extension that exposes a `vscode://` URI handler, installs it
(by copying into the user's VS Code extensions dir), and updates the given workspace's
`.vscode/settings.json` to allow the specified command IDs and (optionally) disable the
confirmation prompt.

Usage:
    install_vscode_remote_control(pwd(); allowed_commands=[
        "language-julia.startREPL",
        "workbench.action.reloadWindow",
        "workbench.action.files.save",
    ])
"""
function install_vscode_remote_control(
    workspace_dir::AbstractString;
    publisher::AbstractString = "Kaimon",
    name::AbstractString = "vscode-remote-control",
    version::AbstractString = "0.0.1",
    allowed_commands::Vector{String} = String[],
    require_confirmation::Bool = false,
)

    # -------------------------------- paths --------------------------------
    ext_folder_name = "$(publisher).$(name)-$(version)"
    exts_dir = vscode_extensions_dir()
    ext_path = joinpath(exts_dir, ext_folder_name)
    src_path = joinpath(ext_path, "out")
    workspace_dir = abspath(workspace_dir)
    ws_vscode = joinpath(workspace_dir, ".vscode")
    ws_settings_path = joinpath(ws_vscode, "settings.json")

    # Remove old extension versions if they exist
    if isdir(exts_dir)
        for entry in readdir(exts_dir)
            # Match any version of this extension
            if startswith(entry, "$(publisher).$(name)-")
                old_path = joinpath(exts_dir, entry)
                try
                    rm(old_path; recursive = true, force = true)
                    println("Removed old extension: $entry")
                catch e
                    @warn "Could not remove old extension at $old_path" exception = e
                end
            end
        end
    end

    mkpath(src_path)
    mkpath(ws_vscode)

    # --------------------------- write package.json -------------------------
    pkgjson = """
    {
      "name": "$(name)",
      "displayName": "VS Code Remote Control",
      "description": "Execute allowlisted VS Code commands via vscode:// URI",
      "version": "$(version)",
      "publisher": "$(publisher)",
      "engines": { "vscode": "^1.85.0" },
      "activationEvents": ["onUri"],
      "main": "./out/extension.js",
      "contributes": {
        "configuration": {
          "type": "object",
          "title": "Remote Control",
          "properties": {
            "vscode-remote-control.allowedCommands": {
              "type": "array",
              "default": ["workbench.action.files.save"],
              "description": "Command IDs this extension may run."
            },
            "vscode-remote-control.requireConfirmation": {
              "type": "boolean",
              "default": true,
              "description": "Ask before executing a command."
            }
          }
        }
      }
    }
    """
    open(joinpath(ext_path, "package.json"), "w") do io
        write(io, pkgjson)
    end

    # --------------------------- write extension.js -------------------------
    # Plain CommonJS; no build step required.
    extjs = raw"""
    const vscode = require('vscode');

    /**
     * Convert arguments for a specific VS Code command.
     * Uses command signature knowledge for precise type conversion.
     */
    function convertArgsForCommand(command, args) {
      // Commands that expect (uri: Uri, position: Position)
      const uriPositionCommands = [
        'vscode.executeDefinitionProvider',
        'vscode.executeTypeDefinitionProvider',
        'vscode.executeImplementationProvider',
        'vscode.executeReferenceProvider',
        'vscode.executeHoverProvider',
        'vscode.executeCompletionItemProvider',
        'vscode.executeSignatureHelpProvider',
        'vscode.executeDocumentHighlightProvider',
        'vscode.prepareCallHierarchy',
        'vscode.prepareTypeHierarchy'
      ];
      
      // Commands that expect (uri: Uri, range: Range, ...)
      const uriRangeCommands = [
        'vscode.executeCodeActionProvider'
      ];
      
      // Commands that expect (uri: Uri, position: Position, newName: string)
      const renameCommand = 'vscode.executeDocumentRenameProvider';
      
      // Commands that expect just (uri: Uri)
      const uriOnlyCommands = [
        'vscode.executeDocumentSymbolProvider'
      ];
      
      // Commands that expect (query: string)
      const queryCommands = [
        'vscode.executeWorkspaceSymbolProvider'
      ];
      
      if (uriPositionCommands.includes(command)) {
        // [uri_string, {line, character}] -> [Uri, Position]
        if (!args[0] || !args[1] || typeof args[1].line !== 'number' || typeof args[1].character !== 'number') {
          throw new Error(`Invalid arguments for ${command}: expected [uri_string, {line, character}]`);
        }
        return [
          vscode.Uri.parse(args[0]),
          new vscode.Position(args[1].line, args[1].character)
        ];
      }
      
      if (uriRangeCommands.includes(command)) {
        // [uri_string, {start: {line, character}, end: {line, character}}, ...] -> [Uri, Range, ...]
        if (!args[0] || !args[1] || !args[1].start || !args[1].end) {
          throw new Error(`Invalid arguments for ${command}: expected [uri_string, {start, end}]`);
        }
        
        const startPos = new vscode.Position(args[1].start.line, args[1].start.character);
        const endPos = new vscode.Position(args[1].end.line, args[1].end.character);
        const range = new vscode.Range(startPos, endPos);
        
        const converted = [
          vscode.Uri.parse(args[0]),
          range
        ];
        // Pass through any additional args (like kind filter for code actions)
        if (args.length > 2) {
          converted.push(...args.slice(2));
        }
        return converted;
      }
      
      if (command === renameCommand) {
        // [uri_string, {line, character}, newName] -> [Uri, Position, string]
        if (!args[0] || !args[1] || typeof args[1].line !== 'number' || typeof args[1].character !== 'number' || !args[2]) {
          throw new Error(`Invalid arguments for ${command}: expected [uri_string, {line, character}, newName]`);
        }
        return [
          vscode.Uri.parse(args[0]),
          new vscode.Position(args[1].line, args[1].character),
          args[2]  // newName as string
        ];
      }
      
      if (uriOnlyCommands.includes(command)) {
        // [uri_string] -> [Uri]
        return [vscode.Uri.parse(args[0])];
      }
      
      if (queryCommands.includes(command)) {
        // [query_string] -> [query_string] (no conversion needed)
        return args;
      }
      
      // For non-LSP commands, just convert file:// strings to Uri objects
      return args.map(arg => {
        if (typeof arg === 'string' && arg.startsWith('file://')) {
          return vscode.Uri.parse(arg);
        }
        return arg;
      });
    }

    function activate(context) {
      const handler = {
        async handleUri(uri) {
          let requestId = null;
          let mcpPort = 3000;  // Default MCP server port
          let nonce = null;    // Single-use nonce from URI
          
          try {
            const query = new URLSearchParams(uri.query || "");
            const cmd = query.get('cmd') || '';
            const argsRaw = query.get('args');
            requestId = query.get('request_id');
            const portRaw = query.get('mcp_port');
            nonce = query.get('nonce');  // Get nonce from URI
            
            if (portRaw) {
              mcpPort = parseInt(portRaw, 10);
            }

            if (!cmd) {
              vscode.window.showErrorMessage('Remote Control: missing "cmd".');
              return;
            }

            let args = [];
            if (argsRaw) {
              try {
                const decoded = decodeURIComponent(argsRaw);
                const parsed = JSON.parse(decoded);
                args = Array.isArray(parsed) ? parsed : [parsed];
              } catch (e) {
                vscode.window.showErrorMessage('Remote Control: invalid args JSON: ' + e);
                await sendResponse(mcpPort, requestId, null, 'Failed to parse args: ' + e, nonce);
                return;
              }
            }

            const cfg = vscode.workspace.getConfiguration('vscode-remote-control');
            const allowed = cfg.get('allowedCommands', []);
            const requireConfirmation = cfg.get('requireConfirmation', true);

            if (!allowed.includes(cmd)) {
              const msg = 'Remote Control: command not allowed: ' + cmd;
              vscode.window.showErrorMessage(msg);
              await sendResponse(mcpPort, requestId, null, msg, nonce);
              return;
            }

            if (requireConfirmation) {
              const ok = await vscode.window.showWarningMessage(
                `Run command: ${cmd}${args.length ? ' with args' : ''}?`,
                { modal: true }, 'Run'
              );
              if (ok !== 'Run') {
                await sendResponse(mcpPort, requestId, null, 'User cancelled command', nonce);
                return;
              }
            }

            // Convert arguments based on the specific command being executed
            // This is more reliable than generic property inspection
            const convertedArgs = convertArgsForCommand(cmd, args);

            // For LSP commands, ensure the document is open
            if (cmd.startsWith('vscode.execute')) {
              const uriArg = convertedArgs[0];
              if (uriArg && uriArg.scheme === 'file') {
                try {
                  await vscode.workspace.openTextDocument(uriArg);
                } catch (e) {
                  // Silently continue if document can't be opened
                }
              }
            }
            
            // Execute command and capture result
            const result = await vscode.commands.executeCommand(cmd, ...convertedArgs);
            
            // Send result back to MCP server if request_id was provided
            await sendResponse(mcpPort, requestId, result, null, nonce);
            
          } catch (err) {
            vscode.window.showErrorMessage('Remote Control error: ' + err);
            await sendResponse(mcpPort, requestId, null, String(err), nonce);
          }
        }
      };
      context.subscriptions.push(vscode.window.registerUriHandler(handler));
    }

    // Helper function to send response back to MCP server
    async function sendResponse(port, requestId, result, error, nonceFromUri) {
      // Only send if requestId was provided (indicates caller wants response)
      if (!requestId) return;
      
      try {
        const http = require('http');
        const fs = require('fs');
        const path = require('path');
        
        const payload = JSON.stringify({
          request_id: requestId,
          result: result,
          error: error,
          timestamp: Date.now()
        });
        
        // Try to read port from .vscode/mcp.json
        let mcpConfigPort = null;
        let authHeader = null;
        
        // Use nonce from URI (single-use token for this specific request)
        if (nonceFromUri) {
          authHeader = `Bearer ${nonceFromUri}`;
        }
        
        // Try to read port from .vscode/mcp.json
        try {
          const workspaceFolders = vscode.workspace.workspaceFolders;
          if (workspaceFolders && workspaceFolders.length > 0) {
            const mcpConfigPath = path.join(workspaceFolders[0].uri.fsPath, '.vscode', 'mcp.json');
            if (fs.existsSync(mcpConfigPath)) {
              const mcpConfig = JSON.parse(fs.readFileSync(mcpConfigPath, 'utf8'));
              if (mcpConfig.servers && mcpConfig.servers['kaimon']) {
                const juliaServer = mcpConfig.servers['kaimon'];
                
                // Extract port from URL
                if (juliaServer.url) {
                  const urlMatch = juliaServer.url.match(/localhost:(\d+)/);
                  if (urlMatch) {
                    mcpConfigPort = parseInt(urlMatch[1], 10);
                  }
                }
              }
            }
          }
        } catch (e) {
          console.error('Could not read mcp.json:', e);
        }
        
        // Use port from URI if provided and valid (not default 3000)
        // Otherwise fall back to config files
        if (!port || port === 3000) {
          // Try mcp.json port first
          if (mcpConfigPort) {
            port = mcpConfigPort;
          } else {
            // Try to read from .kaimon/security.json as last resort
            try {
              const workspaceFolders = vscode.workspace.workspaceFolders;
              if (workspaceFolders && workspaceFolders.length > 0) {
                const securityPath = path.join(workspaceFolders[0].uri.fsPath, '.kaimon', 'security.json');
                if (fs.existsSync(securityPath)) {
                  const securityConfig = JSON.parse(fs.readFileSync(securityPath, 'utf8'));
                  if (securityConfig.port) {
                    port = securityConfig.port;
                  }
                }
              }
            } catch (e) {
              console.error('Could not read .kaimon/security.json:', e);
            }
          }
        }
        // If port is still not set or is 3000, use the default
        if (!port) {
          port = 3000;
        }
        
        console.log(`[Kaimon] Sending response to http://localhost:${port}/vscode-response`);
        console.log(`[Kaimon] Auth header: ${authHeader ? 'present' : 'not set'}`);
        
        const headers = {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(payload)
        };
        
        // Add Authorization header if found
        if (authHeader) {
          headers['Authorization'] = authHeader;
        }
        
        const options = {
          hostname: 'localhost',
          port: port,
          path: '/vscode-response',
          method: 'POST',
          headers: headers
        };
        
        const req = http.request(options, (res) => {
          // Consume response data to free up memory
          res.on('data', () => {});
        });
        
        req.on('error', () => {
          // Silently fail - MCP server may not be running
        });
        
        req.write(payload);
        req.end();
      } catch (e) {
        // Silently fail - this is optional communication
      }
    }

    function deactivate() {}

    module.exports = { activate, deactivate };
    """
    open(joinpath(src_path, "extension.js"), "w") do io
        write(io, extjs)
    end

    # ------------------------ write a basic README.md -----------------------
    readme = """
    # VS Code Remote Control

    Use \`vscode://$(publisher).$(name)?cmd=COMMAND_ID&args=JSON_ENCODED_ARGS\`
    to execute allowlisted commands. Configure allowed commands in settings:
    \`vscode-remote-control.allowedCommands\`.
    """
    open(joinpath(ext_path, "README.md"), "w") do io
        write(io, readme)
    end

    # ----------------------------- settings.json ----------------------------
    # Merge workspace settings using JSON
    existing = Dict{String,Any}()
    if isfile(ws_settings_path)
        try
            existing =
                JSON.parse(read(ws_settings_path, String); dicttype = Dict{String,Any})
        catch e
            @warn "Could not parse existing workspace settings.json; will preserve it unchanged." exception =
                e
        end
    end

    # Merge our keys
    ns = "vscode-remote-control"
    key_allowed = "$ns.allowedCommands"
    key_confirm = "$ns.requireConfirmation"

    # Merge allowed commands (union with existing)
    allowed_set = Set{String}(get(existing, key_allowed, String[]))
    union!(allowed_set, allowed_commands)
    existing[key_allowed] = sort(collect(allowed_set))
    existing[key_confirm] = require_confirmation

    # Write back with pretty-printed JSON (2-space indentation)
    json_str = JSON.json(existing, 2)
    write(ws_settings_path, json_str)

    println("Installed extension into: ", ext_path)
    println("Workspace settings updated at: ", ws_settings_path)
    println("Now you can call, e.g.:")
    println("  open(\"vscode://$(publisher).$(name)?cmd=workbench.action.reloadWindow\")")

    return ext_path
end

# ------------------------ helpers: paths ------------------------

function vscode_extensions_dir()
    # Default per-user extensions dir used by VS Code
    home = homedir()
    if Sys.iswindows()
        # %USERPROFILE%\.vscode\extensions
        return joinpath(get(ENV, "USERPROFILE", home), ".vscode", "extensions")
    else
        # macOS & Linux
        return joinpath(home, ".vscode", "extensions")
    end
end
