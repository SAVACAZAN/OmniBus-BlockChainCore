// src/pages/dashboard.js
import { getProjectStats, getRunHistory, getLatestScore } from '../core/tauri-api.js';
import { PATHS } from '../core/constants.js';

export async function renderDashboard(container) {
  container.innerHTML = `
    <div class="dashboard-container">
      <div class="dashboard-header">
        <h1>Dashboard</h1>
        <p>MYTHOS Lab Control Center</p>
      </div>
      
      <div class="stats-grid" id="stats-grid">
        <div class="stat-card">Loading stats...</div>
      </div>
      
      <div class="phases-section">
        <h2>Project Phases</h2>
        <div class="phases-grid" id="phases-grid">
          <div class="phase-card">Loading phases...</div>
        </div>
      </div>
      
      <div class="history-section">
        <h2>Recent Runs</h2>
        <div class="history-table-container">
          <table class="history-table" id="history-table">
            <thead>
              <tr><th>Timestamp</th><th>Status</th><th>Score</th></tr>
            </thead>
            <tbody id="history-body">
              <tr><td colspan="3">Loading...</td></tr>
            </tbody>
          </table>
        </div>
      </div>
      
      <div class="quick-actions">
        <button class="action-btn" id="quick-mythos">▶ Run MYTHOS</button>
        <button class="action-btn" id="quick-claude">💬 Claude Chat</button>
        <button class="action-btn" id="quick-cmd">$ CMD Terminal</button>
      </div>
    </div>
  `;
  
  // Load data
  await loadStats();
  await loadPhases();
  await loadHistory();
  
  // Setup quick actions (these will be connected to tab manager from main)
  const quickMythos = container.querySelector('#quick-mythos');
  const quickClaude = container.querySelector('#quick-claude');
  const quickCmd = container.querySelector('#quick-cmd');
  
  if (quickMythos) quickMythos.dataset.action = 'mythos';
  if (quickClaude) quickClaude.dataset.action = 'claude';
  if (quickCmd) quickCmd.dataset.action = 'cmd';
}

async function loadStats() {
  try {
    const stats = await getProjectStats({ sandboxPath: PATHS.SANDBOX });
    const grid = document.getElementById('stats-grid');
    if (!grid) return;
    
    grid.innerHTML = `
      <div class="stat-card">
        <div class="stat-value">${stats.aweb3?.phases_completed || 0}/${stats.aweb3?.total_phases || 0}</div>
        <div class="stat-label">AWEB3 Phases</div>
      </div>
      <div class="stat-card">
        <div class="stat-value">${stats.blockchaincore?.phases_completed || 0}/${stats.blockchaincore?.total_phases || 0}</div>
        <div class="stat-label">BlockChainCore Phases</div>
      </div>
    `;
    
    const score = await getLatestScore({ mythosDataDir: PATHS.MYTHOS_DATA });
    if (score) {
      const scoreCard = document.createElement('div');
      scoreCard.className = 'stat-card';
      scoreCard.innerHTML = `
        <div class="stat-value">${score.passed || 0}/${(score.passed || 0) + (score.failed || 0)}</div>
        <div class="stat-label">Latest Test Score</div>
      `;
      grid.appendChild(scoreCard);
    }
  } catch (error) {
    console.error('Failed to load stats:', error);
  }
}

async function loadPhases() {
  try {
    const stats = await getProjectStats({ sandboxPath: PATHS.SANDBOX });
    const phasesGrid = document.getElementById('phases-grid');
    if (!phasesGrid) return;
    
    const phases = [];
    if (stats.aweb3?.phases) {
      phases.push(...stats.aweb3.phases.map(p => ({ ...p, project: 'AWEB3' })));
    }
    if (stats.blockchaincore?.phases) {
      phases.push(...stats.blockchaincore.phases.map(p => ({ ...p, project: 'BlockChainCore' })));
    }
    
    if (phases.length === 0) {
      phasesGrid.innerHTML = '<div class="phase-card">No phases loaded</div>';
      return;
    }
    
    phasesGrid.innerHTML = phases.map(phase => `
      <div class="phase-card">
        <div class="phase-header">
          <span class="phase-name">${phase.name || 'Phase ' + phase.id}</span>
          <span class="phase-project">${phase.project}</span>
        </div>
        <div class="phase-progress">
          <div class="progress-bar" style="width: ${phase.progress || 0}%"></div>
        </div>
        <div class="phase-score">Score: ${phase.score || 0}%</div>
      </div>
    `).join('');
  } catch (error) {
    console.error('Failed to load phases:', error);
  }
}

async function loadHistory() {
  try {
    const history = await getRunHistory({ mythosDataDir: PATHS.MYTHOS_DATA });
    const tbody = document.getElementById('history-body');
    if (!tbody) return;
    
    if (!history || history.length === 0) {
      tbody.innerHTML = '<tr><td colspan="3">No run history found</td></tr>';
      return;
    }
    
    tbody.innerHTML = history.slice(0, 10).map(run => `
      <tr class="${run.passed && !run.failed ? 'success-row' : 'fail-row'}">
        <td>${new Date(run.timestamp).toLocaleString()}</td>
        <td>${run.passed && !run.failed ? '✅ PASSED' : '❌ FAILED'}</td>
        <td>${run.passed || 0}/${(run.passed || 0) + (run.failed || 0)}</td>
      </tr>
    `).join('');
  } catch (error) {
    console.error('Failed to load history:', error);
  }
}