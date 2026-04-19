// src/core/tab-manager.js
import { Terminal } from '../components/terminal.js';

export class TabManager {
  constructor(tabBarEl, contentEl) {
    this.tabBar = tabBarEl;
    this.content = contentEl;
    this.tabs = new Map();
    this.activeTab = null;
    this.nextId = 1;
  }
  
  addTab({ id, title, icon, closeable = true, render, onActivate, onClose }) {
    // Generate ID if not provided
    const tabId = id || `tab-${this.nextId++}`;
    
    // Check if tab already exists
    if (this.tabs.has(tabId)) {
      this.activateTab(tabId);
      return;
    }
    
    // Create tab button
    const tabEl = document.createElement('div');
    tabEl.className = 'tab';
    tabEl.dataset.id = tabId;
    tabEl.innerHTML = `
      <span class="tab-icon">${icon || ''}</span>
      <span class="tab-title">${title}</span>
      ${closeable ? '<span class="tab-close">&times;</span>' : ''}
    `;
    
    tabEl.addEventListener('click', (e) => {
      if (!e.target.classList.contains('tab-close')) {
        this.activateTab(tabId);
      }
    });
    
    if (closeable) {
      const closeBtn = tabEl.querySelector('.tab-close');
      closeBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        this.closeTab(tabId);
      });
    }
    
    // Create page content
    const pageEl = document.createElement('div');
    pageEl.className = 'page';
    pageEl.id = `page-${tabId}`;
    pageEl.style.display = 'none';
    
    // Store tab info
    this.tabs.set(tabId, {
      tabEl,
      pageEl,
      closeable,
      onActivate,
      onClose,
      terminal: null
    });
    
    // Insert tab before add button
    const addButton = this.tabBar.querySelector('.tab-add');
    this.tabBar.insertBefore(tabEl, addButton);
    this.content.appendChild(pageEl);
    
    // Render content
    if (render) {
      render(pageEl);
    }
    
    // Activate
    this.activateTab(tabId);
    
    return { tabId, pageEl };
  }
  
  openTerminalTab(processType) {
    const id = `${processType}-${Date.now()}`;
    const config = this.getTerminalConfig(processType);
    
    let terminal = null;
    
    this.addTab({
      id,
      title: config.title,
      icon: config.icon,
      closeable: true,
      render: async (container) => {
        terminal = new Terminal({
          containerId: id,
          processType: processType,
          workingDir: config.workingDir
        });
        terminal.render(container);
        await terminal.start();
        terminal.focus();
        
        // Store terminal reference
        const tab = this.tabs.get(id);
        if (tab) tab.terminal = terminal;
      },
      onClose: async () => {
        if (terminal) {
          await terminal.destroy();
        }
      }
    });
  }
  
  getTerminalConfig(type) {
    const configs = {
      cmd: { title: 'CMD Terminal', icon: '$', workingDir: null },
      claude: { title: 'Claude Chat', icon: 'C', workingDir: null },
      kimi: { title: 'Kimi Chat', icon: 'K', workingDir: null },
      python: { title: 'Python REPL', icon: 'P', workingDir: null },
      mythos: { title: 'MYTHOS Runner', icon: 'M', workingDir: null }
    };
    return configs[type] || configs.cmd;
  }
  
  activateTab(id) {
    // Deactivate all tabs
    this.tabs.forEach((tab, tabId) => {
      tab.tabEl.classList.remove('active');
      tab.pageEl.style.display = 'none';
    });
    
    // Activate target tab
    const tab = this.tabs.get(id);
    if (tab) {
      tab.tabEl.classList.add('active');
      tab.pageEl.style.display = 'flex';
      this.activeTab = id;
      
      // Call onActivate callback
      if (tab.onActivate) {
        tab.onActivate();
      }
      
      // Focus terminal if exists
      if (tab.terminal && tab.terminal.focus) {
        setTimeout(() => tab.terminal.focus(), 100);
      }
    }
  }
  
  async closeTab(id) {
    const tab = this.tabs.get(id);
    if (!tab) return;
    
    // Call onClose callback
    if (tab.onClose) {
      await tab.onClose();
    }
    
    // Remove DOM elements
    tab.tabEl.remove();
    tab.pageEl.remove();
    
    // Remove from map
    this.tabs.delete(id);
    
    // Activate another tab
    if (this.activeTab === id) {
      const remaining = Array.from(this.tabs.keys());
      if (remaining.length > 0) {
        this.activateTab(remaining[remaining.length - 1]);
      } else {
        this.activeTab = null;
      }
    }
  }
  
  getActiveTab() {
    return this.activeTab ? this.tabs.get(this.activeTab) : null;
  }
}