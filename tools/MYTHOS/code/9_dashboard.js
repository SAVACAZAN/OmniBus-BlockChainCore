// src/pages/files-page.js
import { readDirectory, readFileContent } from '../core/tauri-api.js';
import { PATHS } from '../core/constants.js';

export async function renderFilesPage(container) {
  container.innerHTML = `
    <div class="files-container">
      <div class="file-sidebar">
        <div class="file-tree-header">
          <h3>Project Files</h3>
          <button id="refresh-files" class="icon-btn">🔄</button>
        </div>
        <div class="file-tree" id="file-tree"></div>
      </div>
      <div class="file-content">
        <div class="file-preview-header" id="file-preview-header">
          <span>Select a file to preview</span>
        </div>
        <div class="code-viewer" id="code-viewer">
          <pre><code id="code-content"></code></pre>
        </div>
      </div>
    </div>
  `;
  
  await loadFileTree();
  
  const refreshBtn = container.querySelector('#refresh-files');
  if (refreshBtn) {
    refreshBtn.addEventListener('click', () => loadFileTree());
  }
}

async function loadFileTree() {
  const treeContainer = document.getElementById('file-tree');
  if (!treeContainer) return;
  
  try {
    const files = await readDirectory({ path: PATHS.SANDBOX });
    treeContainer.innerHTML = renderTree(files, PATHS.SANDBOX);
    
    // Add click handlers
    treeContainer.querySelectorAll('.file-item').forEach(item => {
      item.addEventListener('click', async (e) => {
        e.stopPropagation();
        const path = item.dataset.path;
        if (path && !item.classList.contains('directory')) {
          await loadFileContent(path);
        }
      });
    });
  } catch (error) {
    treeContainer.innerHTML = `<div class="error">Failed to load files: ${error}</div>`;
  }
}

function renderTree(items, basePath, level = 0) {
  if (!items || items.length === 0) return '<div class="empty-dir">Empty directory</div>';
  
  return items.map(item => {
    const indent = level * 20;
    const icon = item.is_dir ? '📁' : getFileIcon(item.extension);
    
    if (item.is_dir) {
      return `
        <div class="directory-item" data-path="${item.path}" style="padding-left: ${indent}px">
          <div class="dir-toggle">▶</div>
          <div class="file-item directory" data-path="${item.path}">
            <span class="file-icon">${icon}</span>
            <span class="file-name">${item.name}</span>
          </div>
          <div class="dir-children" style="display: none"></div>
        </div>
      `;
    } else {
      return `
        <div class="file-item" data-path="${item.path}" style="padding-left: ${indent + 20}px">
          <span class="file-icon">${icon}</span>
          <span class="file-name">${item.name}</span>
          <span class="file-size">${formatSize(item.size)}</span>
        </div>
      `;
    }
  }).join('');
}

function getFileIcon(extension) {
  const icons = {
    '.js': '📜', '.py': '🐍', '.rs': '🦀', '.html': '🌐',
    '.css': '🎨', '.json': '📋', '.md': '📝', '.txt': '📄'
  };
  return icons[extension] || '📄';
}

function formatSize(bytes) {
  if (!bytes) return '';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

async function loadFileContent(path) {
  const header = document.getElementById('file-preview-header');
  const codeEl = document.getElementById('code-content');
  
  if (!header || !codeEl) return;
  
  try {
    const content = await readFileContent({ path });
    header.innerHTML = `<span>📄 ${path.split('\\').pop()}</span>`;
    codeEl.textContent = content;
  } catch (error) {
    header.innerHTML = `<span class="error">Failed to load file: ${error}</span>`;
    codeEl.textContent = '';
  }
}