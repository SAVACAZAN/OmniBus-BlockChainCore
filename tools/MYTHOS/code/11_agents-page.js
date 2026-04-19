// src/pages/exploits-page.js
import { listExploitBlocks, getBlockContent } from '../core/tauri-api.js';
import { PATHS } from '../core/constants.js';

export async function renderExploitsPage(container) {
  container.innerHTML = `
    <div class="exploits-container">
      <div class="exploits-sidebar">
        <div class="exploits-header">
          <h3>Exploit Blocks</h3>
          <button id="refresh-exploits" class="icon-btn">🔄</button>
        </div>
        <div class="exploits-list" id="exploits-list"></div>
      </div>
      <div class="exploit-preview">
        <div class="preview-header" id="preview-header">Select an exploit to preview</div>
        <div class="code-viewer">
          <pre><code id="exploit-code"></code></pre>
        </div>
      </div>
    </div>
  `;
  
  await loadExploits();
  
  const refreshBtn = container.querySelector('#refresh-exploits');
  if (refreshBtn) {
    refreshBtn.addEventListener('click', () => loadExploits());
  }
}

async function loadExploits() {
  const listEl = document.getElementById('exploits-list');
  if (!listEl) return;
  
  try {
    const blocks = await listExploitBlocks({ 
      blocksDir: `${PATHS.MYTHOS_DIR}/exploits` 
    });
    
    if (!blocks || blocks.length === 0) {
      listEl.innerHTML = '<div class="no-exploits">No exploit blocks found</div>';
      return;
    }
    
    listEl.innerHTML = blocks.map(block => `
      <div class="exploit-item" data-id="${block.id}" data-file="${block.filename}">
        <div class="exploit-title">${escapeHtml(block.id)}</div>
        <div class="exploit-meta">
          <span class="exploit-lang">${escapeHtml(block.language)}</span>
          <span class="exploit-lines">${block.lines} lines</span>
        </div>
      </div>
    `).join('');
    
    // Add click handlers
    listEl.querySelectorAll('.exploit-item').forEach(item => {
      item.addEventListener('click', async () => {
        const filePath = `${PATHS.MYTHOS_DIR}/exploits/${item.dataset.file}`;
        await loadExploitContent(filePath, item.dataset.id);
        
        // Highlight selected
        listEl.querySelectorAll('.exploit-item').forEach(i => i.classList.remove('selected'));
        item.classList.add('selected');
      });
    });
    
  } catch (error) {
    listEl.innerHTML = `<div class="error">Failed to load exploits: ${error}</div>`;
  }
}

async function loadExploitContent(filePath, id) {
  const header = document.getElementById('preview-header');
  const codeEl = document.getElementById('exploit-code');
  
  if (!header || !codeEl) return;
  
  try {
    const content = await getBlockContent({ filePath });
    header.innerHTML = `<span>⚡ ${escapeHtml(id)}</span>`;
    codeEl.textContent = content;
  } catch (error) {
    header.innerHTML = `<span class="error">Failed to load exploit: ${error}</span>`;
    codeEl.textContent = '';
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