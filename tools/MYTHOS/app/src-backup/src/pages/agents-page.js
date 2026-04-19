import { listAgents } from '../core/tauri-api.js';
import { AGENTS_DIRS } from '../core/constants.js';

export async function renderAgentsPage(container) {
  container.innerHTML = `
    <div class="p-4">
      <h2 class="mb-2">AI Agents</h2>
      <div class="grid-4" id="agents-grid"></div>
    </div>
  `;
  
  try {
    const agents = await listAgents(AGENTS_DIRS);
    const grid = container.querySelector('#agents-grid');
    
    if (!agents || agents.length === 0) {
      grid.innerHTML = '<div class="text-center">No agents found</div>';
      return;
    }
    
    agents.forEach(agent => {
      const card = document.createElement('div');
      card.className = 'agent-card';
      card.innerHTML = `
        <div class="agent-name">${escapeHtml(agent.name)}</div>
        <div class="agent-model">${escapeHtml(agent.model || 'Unknown')}</div>
        <div class="mt-2" style="font-size: 10px; color: var(--t3);">${escapeHtml(agent.project || 'No project')}</div>
        ${agent.description ? `<div class="mt-2" style="font-size: 10px;">${escapeHtml(agent.description.substring(0, 100))}</div>` : ''}
      `;
      card.addEventListener('click', () => {
        console.log('Agent selected:', agent);
      });
      grid.appendChild(card);
    });
  } catch (e) {
    container.innerHTML += `<div class="p-4 text-red">Error loading agents: ${e.message}</div>`;
  }
}

function escapeHtml(text) {
  if (!text) return '';
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}