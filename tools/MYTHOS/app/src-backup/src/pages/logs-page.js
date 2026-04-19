export function renderLogsPage(container) {
  container.innerHTML = `
    <div class="p-4">
      <h2 class="mb-2">Live Logs</h2>
      <div class="terminal-wrap" style="height: calc(100vh - 100px);">
        <div class="terminal-output" id="live-logs" style="font-family: monospace;"></div>
      </div>
    </div>
  `;
  
  const logsContainer = container.querySelector('#live-logs');
  
  // Simulate live logs (will be replaced with real event listeners)
  const messages = [
    '[INFO] System initialized',
    '[INFO] Agents loaded: 30',
    '[INFO] Blockchain connection established',
    '[INFO] Watching for changes...'
  ];
  
  messages.forEach(msg => {
    const div = document.createElement('div');
    div.className = 'term-info';
    div.textContent = msg;
    logsContainer.appendChild(div);
  });
}