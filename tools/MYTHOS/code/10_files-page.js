// src/pages/agents-page.js
import { listAgents } from '../core/tauri-api.js';
import { PATHS } from '../core/constants.js';

export async function renderAgentsPage(container) {
  container.innerHTML = `
    <div class="agents-container">
      <div class="agents-header">
        <h1>AI Agents</h1>
        <button id="refresh-agents" class="action-btn">🔄 Refresh</button>
      </div>
      <div class="agents-grid" id="agents-grid">
        <div class="loading">Loading agents...</div>
      </div>
    </div>
  `;
  
  await loadAgents();
  
  const refreshBtn = container.querySelector('#refresh-agents');
  if (refreshBtn) {
    refreshBtn.addEventListener('click', () => loadAgents());
  }
}

async function loadAgents() {
  const grid = document.getElementById('agents-grid');
  if (!grid) return;
  
  try {
    const agents = await listAgents({ 
      agentsDirs: [`${PATHS.MYTHOS_DIR}/agents`] 
    });
    
    if (!agents || agents.length === 0) {
      grid.innerHTML = '<div class="no-agents">No agents found. Add agents to the agents directory.</div>';
      return;
    }
    
    grid.innerHTML = agents.map(agent => `
      <div class="agent-card">
        <div class="agent-header">
          <span class="agent-icon">🤖</span>
          <h3 class="agent-name">${escapeHtml(agent.name)}</h3>
        </div>
        <div class="agent-details">
          <div class="agent-model">Model: ${escapeHtml(agent.model || 'Unknown')}</div>
          <div class="agent-project">Project: ${escapeHtml(agent.project || 'General')}</div>
          ${agent.description ? `<div class="agent-description">${escapeHtml(agent.description)}</div>` : ''}
        </div>
        <div class="agent-actions">
          <button class="agent-run" data-file="${agent.file_path}">▶ Run Agent</button>
          <button class="agent-edit" data-file="${agent.file_path}">✏️ Edit</button>
        </div>
      </div>
    `).join('');
    
    // Add event listeners for agent buttons
    grid.querySelectorAll('.agent-run').forEach(btn => {
      btn.addEventListener('click', () => {
        console.log('Run agent:', btn.dataset.file);
        // This would open a terminal tab with the agent
      });
    });
    
  } catch (error) {
    grid.innerHTML = `<div class="error">Failed to load agents: ${error}</div>`;
  }
}

function escapeHtml(str) {
  if (!str) return '';
  return str.replace(/[&<>]/g, function(m) {
    if (m === '&') return '&amp;';
    if (m === '<') return '&lt;';
    if (m === '>') return '&gt;';
    return m;
  });
}