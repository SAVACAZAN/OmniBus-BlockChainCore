export function initStatusBar(container) {
  if (!container) return;
  
  container.innerHTML = `
    <span>⚡ MYTHOS v2.0</span>
    <span>🔗 Blockchain Core Active</span>
    <span>🤖 Agents: 30</span>
    <span>📦 Sandbox: Ready</span>
  `;
}