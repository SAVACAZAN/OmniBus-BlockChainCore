import { Terminal } from '../components/terminal.js';
import { WebViewTab } from '../components/webview-tab.js';
import { BROWSER_URLS, TERMINAL_CONFIGS } from './constants.js';

export class TabManager {
  constructor(tabBarEl, contentEl) {
    this.tabBar = tabBarEl;
    this.content = contentEl;
    this.tabs = new Map();
    this.activeTab = null;
    this.terminals = new Map(); // Store terminal instances
    this.nextId = 1;
  }

  addTab({ id, title, icon, closeable = true, render, onClose }) {
    const tabId = id || `tab-${this.nextId++}`;
    
    // Tab button
    const tabEl = document.createElement('div');
    tabEl.className = 'tab';
    tabEl.dataset.id = tabId;
    tabEl.innerHTML = `
      <span class="tab-icon">${icon || ''}</span>
      <span class="tab-title">${title}</span>
      ${closeable ? '<span class="tab-close">&times;</span>' : ''}
    `;
    tabEl.addEventListener('click', (e) => {
      if (e.target.classList.contains('tab-close')) return;
      this.activateTab(tabId);
    });
    if (closeable) {
      tabEl.querySelector('.tab-close').addEventListener('click', (e) => {
        e.stopPropagation();
        this.closeTab(tabId, onClose);
      });
    }

    // Page content
    const pageEl = document.createElement('div');
    pageEl.className = 'page';
    pageEl.id = `page-${tabId}`;

    // Insert before add button
    const addBtn = this.tabBar.querySelector('.tab-add');
    this.tabBar.insertBefore(tabEl, addBtn);
    this.content.appendChild(pageEl);
    
    this.tabs.set(tabId, { tabEl, pageEl, closeable, onClose });
    
    // Render content
    if (render) render(pageEl);
    
    this.activateTab(tabId);
    return tabId;
  }

  openTerminalTab(type) {
    const id = `${type}-${Date.now()}`;
    const titles = { cmd: 'CMD', claude: 'Claude CLI', kimi: 'Kimi CLI', python: 'Python', mythos: 'MYTHOS' };
    const icons = { cmd: '$', claude: 'C', kimi: 'K', python: 'P', mythos: 'M' };
    
    const terminal = new Terminal({
      containerId: id,
      processType: type,
      workingDir: TERMINAL_CONFIGS[type]?.workingDir
    });

    this.addTab({
      id,
      title: titles[type] || type,
      icon: icons[type] || '>',
      closeable: true,
      render: async (container) => {
        terminal.render(container);
        await terminal.start();
        this.terminals.set(id, terminal);
      },
      onClose: async () => {
        await terminal.destroy();
        this.terminals.delete(id);
      }
    });
  }

  openBrowserTab(urlKey, title) {
    // Launch PyQt6 WebEngine browser (real browser with Google login, cookies)
    // This opens a SEPARATE window — not an iframe
    const siteKey = urlKey.replace('https://', '').replace('http://', '').split('.')[0];
    const key = siteKey === 'chat' ? 'deepseek' : siteKey; // chat.deepseek.com -> deepseek

    if (window.__TAURI__) {
      // Launch browser-launcher.py via Tauri process spawn
      const id = `browser-launch-${Date.now()}`;
      window.__TAURI__.core.invoke('spawn_process', {
        program: 'python',
        args: ['-u', 'tools/MYTHOS/browser-launcher.py', key],
        workingDir: TERMINAL_CONFIGS.claude?.workingDir || 'C:\\Kits work\\limaje de programare\\OmniBus aweb3 + OmniBus BlockChain\\OmniBus-BlockChainCore',
        processId: id
      }).then(() => {
        console.log(`Browser launched: ${key}`);
      }).catch(e => {
        console.error(`Browser launch failed: ${e}`);
        // Fallback: open in default browser
        window.__TAURI__.shell.open(BROWSER_URLS[urlKey] || urlKey);
      });
    } else {
      // Fallback: open in default browser
      window.open(BROWSER_URLS[urlKey] || urlKey, '_blank');
    }
  }

  activateTab(id) {
    this.tabs.forEach(({ tabEl, pageEl }) => {
      tabEl.classList.remove('active');
      pageEl.classList.remove('active');
    });
    
    const tab = this.tabs.get(id);
    if (tab) {
      tab.tabEl.classList.add('active');
      tab.pageEl.classList.add('active');
      this.activeTab = id;
    }
  }

  async closeTab(id, onClose) {
    const tab = this.tabs.get(id);
    if (!tab) return;
    
    if (onClose) await onClose();
    tab.tabEl.remove();
    tab.pageEl.remove();
    this.tabs.delete(id);
    
    if (this.activeTab === id) {
      const remaining = Array.from(this.tabs.keys());
      if (remaining.length > 0) {
        this.activateTab(remaining[remaining.length - 1]);
      }
    }
  }

  getActiveTab() {
    return this.activeTab;
  }
}