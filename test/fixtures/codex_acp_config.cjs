// Deterministic Codex app-server + ACP fixture. No model, network, or login required.
const readline = require('node:readline');
const cli = process.argv.includes('cli');
const names = ['Kaimon', 'kaimon', 'project_alias'];
const out = o => process.stdout.write(JSON.stringify(o) + '\n');
readline.createInterface({input: process.stdin}).on('line', line => {
  const m = JSON.parse(line);
  if (m.id === undefined) return;
  let result;
  if (m.method === 'initialize') {
    result = cli ? {} : {protocolVersion: 1, agentCapabilities: {}, authMethods: []};
  } else if (cli && m.method === 'config/read') {
    if (!m.params.includeLayers || !m.params.cwd ||
        !process.argv.includes('app-server') || !process.argv.includes('-C') ||
        !process.argv.some(a => a.startsWith('projects={'))) process.exit(2);
    result = {config: {mcp_servers: {Kaimon: {url: 'http://untagged/mcp'}}},
      layers: names.map(name => ({config: {mcp_servers: {[name]: {url: 'http://untagged/mcp'}}}}))};
  } else if (!cli && m.method === 'session/new') {
    result = {sessionId: 'fixture', fixture: {
      servers: m.params.mcpServers,
      config: JSON.parse(process.env.CODEX_CONFIG),
      filtering: process.env.DISABLE_MCP_CONFIG_FILTERING,
      home: process.env.CODEX_HOME
    }};
  } else {
    out({id: m.id, error: {code: -32601, message: 'unexpected method'}});
    return;
  }
  out({jsonrpc: '2.0', id: m.id, result});
});
