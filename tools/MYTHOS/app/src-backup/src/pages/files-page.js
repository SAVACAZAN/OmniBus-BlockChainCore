import { readDirectory, readFileContent } from '../core/tauri-api.js';
import { SANDBOX } from '../core/constants.js';

export async function renderFilesPage(container) {
  container.innerHTML = `
    <div style="display: flex; height: 100%;">
      <div style="width: 300px; border-right: 1px solid var(--border); overflow: auto;" id="file-tree-container"></div>
      <div style="flex: 1; overflow: auto;" id="code-viewer-container"></div>
    </div>
  `;
  
  const treeContainer = container.querySelector('#file-tree-container');
  const viewerContainer = container.querySelector('#code-viewer-container');
  
  async function loadTree(path, parentEl) {
    try {
      const items = await readDirectory(path);
      items.sort((a, b) => {
        if (a.is_dir !== b.is_dir) return a.is_dir ? -1 : 1;
        return a.name.localeCompare(b.name);
      });
      
      for (const item of items) {
        const div = document.createElement('div');
        div.className = 'tree-item';
        div.innerHTML = `
          <span class="${item.is_dir ? 'tree-item-dir' : 'tree-item-file'}">
            ${item.is_dir ? '📁' : '📄'} ${item.name}
          </span>
        `;
        div.style.paddingLeft = `${parentEl.dataset.level ? parseInt(parentEl.dataset.level) * 20 + 20 : 20}px`;
        
        if (item.is_dir) {
          div.style.cursor = 'pointer';
          const childrenContainer = document.createElement('div');
          childrenContainer.style.display = 'none';
          div.addEventListener('click', async (e) => {
            e.stopPropagation();
            if (childrenContainer.style.display === 'none') {
              childrenContainer.style.display = 'block';
              await loadTree(item.path, childrenContainer);
            } else {
              childrenContainer.style.display = 'none';
            }
          });
          div.appendChild(childrenContainer);
        } else {
          div.addEventListener('click', async () => {
            try {
              const content = await readFileContent(item.path);
              viewerContainer.innerHTML = `
                <div class="code-viewer">
                  <div class="code-header">${item.name}</div>
                  <div class="code-content" id="code-content"></div>
                </div>
              `;
              const lines = content.split('\n');
              const codeContent = viewerContainer.querySelector('#code-content');
              lines.forEach((line, idx) => {
                const lineDiv = document.createElement('div');
                lineDiv.className = 'code-line';
                lineDiv.innerHTML = `
                  <span class="line-number">${idx + 1}</span>
                  <span class="line-text">${escapeHtml(line)}</span>
                `;
                codeContent.appendChild(lineDiv);
              });
            } catch (e) {
              viewerContainer.innerHTML = `<div class="p-4 text-red">Error: ${e.message}</div>`;
            }
          });
        }
        
        parentEl.appendChild(div);
      }
    } catch (e) {
      parentEl.innerHTML = `<div class="tree-item" style="color: var(--red);">Error: ${e.message}</div>`;
    }
  }
  
  const root = document.createElement('div');
  root.dataset.level = '0';
  root.innerHTML = '<div class="tree-item tree-item-dir" style="font-weight: bold;">📁 Sandbox Root</div>';
  const children = document.createElement('div');
  root.appendChild(children);
  treeContainer.appendChild(root);
  
  await loadTree(SANDBOX, children);
}

function escapeHtml(text) {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}