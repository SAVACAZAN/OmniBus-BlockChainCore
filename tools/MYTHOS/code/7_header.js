// src/components/status-bar.js
export function initStatusBar(container) {
  if (!container) return;
  
  container.innerHTML = `
    <div class="status-left">
      <span class="status-text">MYTHOS v2.0.0</span>
      <span class="status-divider">|</span>
      <span class="status-text">Tauri v2</span>
    </div>
    <div class="status-right">
      <span class="status-text" id="current-time"></span>
    </div>
  `;
  
  // Update time
  function updateTime() {
    const timeEl = document.getElementById('current-time');
    if (timeEl) {
      timeEl.textContent = new Date().toLocaleTimeString();
    }
  }
  
  updateTime();
  setInterval(updateTime, 1000);
}