import { getProjectStats, getRunHistory, getLatestScore } from '../core/tauri-api.js';
import { SANDBOX, MYTHOS_DATA } from '../core/constants.js';

export async function renderDashboard(container) {
  container.innerHTML = `
    <div class="p-4">
      <h2 class="mb-2">Dashboard</h2>
      <div class="grid-stats" id="dashboard-stats"></div>
      <div class="grid-4" id="dashboard-phases"></div>
      <div class="mt-2" id="dashboard-history"></div>
    </div>
  `;
  
  // Load stats
  try {
    const stats = await getProjectStats(SANDBOX);
    const latestScore = await getLatestScore(MYTHOS_DATA);
    const history = await getRunHistory(MYTHOS_DATA);
    
    const statsContainer = container.querySelector('#dashboard-stats');
    statsContainer.innerHTML = `
      <div class="stat-card"><div class="stat-number">${stats.aweb3?.total_files || 0}</div><div class="stat-label">AWeb3 Files</div></div>
      <div class="stat-card"><div class="stat-number">${stats.blockchaincore?.total_files || 0}</div><div class="stat-label">BlockChain Files</div></div>
      <div class="stat-card"><div class="stat-number">${latestScore?.score || 0}</div><div class="stat-label">Latest Score</div></div>
      <div class="stat-card"><div class="stat-number">${history?.length || 0}</div><div class="stat-label">Total Runs</div></div>
    `;
    
    // Phases placeholder
    const phasesContainer = container.querySelector('#dashboard-phases');
    phasesContainer.innerHTML = `
      <div class="phase-card"><div class="phase-title">Crypto Phase</div><div class="phase-score">${latestScore?.phases?.crypto || 0}</div><div class="progress-bar"><div class="progress-fill" style="width: ${(latestScore?.phases?.crypto || 0) * 10}%"></div></div></div>
      <div class="phase-card"><div class="phase-title">AI Phase</div><div class="phase-score">${latestScore?.phases?.ai || 0}</div><div class="progress-bar"><div class="progress-fill" style="width: ${(latestScore?.phases?.ai || 0) * 10}%"></div></div></div>
      <div class="phase-card"><div class="phase-title">Web3 Phase</div><div class="phase-score">${latestScore?.phases?.web3 || 0}</div><div class="progress-bar"><div class="progress-fill" style="width: ${(latestScore?.phases?.web3 || 0) * 10}%"></div></div></div>
      <div class="phase-card"><div class="phase-title">Blockchain Phase</div><div class="phase-score">${latestScore?.phases?.blockchain || 0}</div><div class="progress-bar"><div class="progress-fill" style="width: ${(latestScore?.phases?.blockchain || 0) * 10}%"></div></div></div>
    `;
    
    if (history && history.length > 0) {
      const historyContainer = container.querySelector('#dashboard-history');
      historyContainer.innerHTML = `
        <div class="stat-card"><div class="stat-number">${history[0]?.passed || 0}/${history[0]?.total || 0}</div><div class="stat-label">Last Run: ${history[0]?.passed || 0} passed</div></div>
      `;
    }
  } catch (e) {
    console.error('Dashboard error:', e);
    container.innerHTML += `<div class="p-4 text-red">Error loading dashboard: ${e.message}</div>`;
  }
}