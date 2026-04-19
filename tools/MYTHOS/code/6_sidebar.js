// src/components/header.js
import { getProjectStats, getLatestScore } from '../core/tauri-api.js';
import { PATHS } from '../core/constants.js';

export async function initHeader(container) {
  if (!container) return;
  
  container.innerHTML = `
    <div class="header-left">
      <div class="logo">
        <span class="logo-icon">⚡</span>
        <span class="logo-text">MYTHOS LAB</span>
      </div>
      <div class="project-stats">
        <div class="stat-badge" id="aweb3-status">Loading...</div>
        <div class="stat-badge" id="bc-status">Loading...</div>
      </div>
    </div>
    <div class="header-right">
      <div class="score-display">
        <span class="score-label">Latest Score:</span>
        <span class="score-value" id="latest-score">---</span>
      </div>
      <div class="status-dot" id="status-dot"></div>
    </div>
  `;
  
  // Load initial stats
  await updateStats();
  
  // Refresh stats every 30 seconds
  setInterval(updateStats, 30000);
}

async function updateStats() {
  try {
    const stats = await getProjectStats({ sandboxPath: PATHS.SANDBOX });
    
    const aweb3El = document.getElementById('aweb3-status');
    const bcEl = document.getElementById('bc-status');
    
    if (aweb3El && stats.aweb3) {
      aweb3El.innerHTML = `🌐 AWEB3: ${stats.aweb3.phases_completed || 0}/${stats.aweb3.total_phases || 0} phases`;
    }
    
    if (bcEl && stats.blockchaincore) {
      bcEl.innerHTML = `⛓️ BCore: ${stats.blockchaincore.phases_completed || 0}/${stats.blockchaincore.total_phases || 0} phases`;
    }
    
    const score = await getLatestScore({ mythosDataDir: PATHS.MYTHOS_DATA });
    const scoreEl = document.getElementById('latest-score');
    if (scoreEl && score) {
      scoreEl.textContent = `${score.passed || 0}/${(score.passed || 0) + (score.failed || 0)}`;
    }
  } catch (error) {
    console.error('Failed to update stats:', error);
  }
}