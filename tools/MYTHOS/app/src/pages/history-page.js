import { getRunHistory } from '../core/tauri-api.js';
import { MYTHOS_DATA } from '../core/constants.js';

export async function renderHistoryPage(container) {
  container.innerHTML = `
    <div class="p-4">
      <h2 class="mb-2">Run History</h2>
      <div id="history-list"></div>
    </div>
  `;
  
  try {
    const history = await getRunHistory(MYTHOS_DATA);
    const listContainer = container.querySelector('#history-list');
    
    if (!history || history.length === 0) {
      listContainer.innerHTML = '<div>No runs recorded yet</div>';
      return;
    }
    
    history.forEach(run => {
      const runDiv = document.createElement('div');
      runDiv.className = 'stat-card mb-2';
      const date = new Date(run.timestamp);
      runDiv.innerHTML = `
        <div class="flex justify-between align-center">
          <span class="phase-title">${date.toLocaleString()}</span>
          <span class="${run.passed === run.total ? 'text-green' : 'text-red'}">${run.passed || 0}/${run.total || 0} passed</span>
        </div>
        <div class="progress-bar mt-2"><div class="progress-fill" style="width: ${((run.passed || 0) / (run.total || 1)) * 100}%"></div></div>
      `;
      listContainer.appendChild(runDiv);
    });
  } catch (e) {
    container.innerHTML += `<div class="p-4 text-red">Error: ${e.message}</div>`;
  }
}