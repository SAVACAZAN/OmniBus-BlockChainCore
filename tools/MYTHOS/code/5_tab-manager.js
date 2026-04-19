// src/components/sidebar.js
export function initSidebar(tabManager) {
  const sidebar = document.getElementById('sidebar');
  if (!sidebar) return;
  
  const menuItems = [
    { type: 'item', label: 'Dashboard', icon: '■', action: () => tabManager.activateTab('dashboard') },
    { type: 'item', label: 'Run MYTHOS', icon: '▶', action: () => tabManager.openTerminalTab('mythos') },
    { type: 'item', label: 'File Browser', icon: '📁', action: () => tabManager.activateTab('files') },
    { type: 'item', label: 'Agents (30)', icon: '⚙', action: () => tabManager.activateTab('agents') },
    { type: 'item', label: 'Exploit Lab', icon: '⚡', action: () => tabManager.activateTab('exploits') },
    
    { type: 'section', label: 'CONSOLES' },
    { type: 'item', label: 'CMD Terminal', icon: '$', action: () => tabManager.openTerminalTab('cmd') },
    { type: 'item', label: 'Claude Chat', icon: 'C', action: () => tabManager.openTerminalTab('claude'), accent: true },
    { type: 'item', label: 'Kimi Chat', icon: 'K', action: () => tabManager.openTerminalTab('kimi'), accent: true },
    { type: 'item', label: 'Python REPL', icon: 'P', action: () => tabManager.openTerminalTab('python') },
    
    { type: 'section', label: 'TOOLS' },
    { type: 'item', label: 'Run History', icon: '📊', action: () => tabManager.activateTab('history') },
    { type: 'item', label: 'Live Logs', icon: '📝', action: () => tabManager.activateTab('logs') },
    { type: 'item', label: 'Skills', icon: '⚡', action: () => tabManager.activateTab('skills') },
    { type: 'item', label: 'Learning', icon: '🔄', action: () => tabManager.activateTab('learning') },
    { type: 'item', label: 'Settings', icon: '⚙', action: () => tabManager.activateTab('settings') }
  ];
  
  sidebar.innerHTML = '';
  
  menuItems.forEach(item => {
    if (item.type === 'section') {
      const sectionDiv = document.createElement('div');
      sectionDiv.className = 'sidebar-section';
      sectionDiv.textContent = item.label;
      sidebar.appendChild(sectionDiv);
    } else if (item.type === 'item') {
      const itemDiv = document.createElement('div');
      itemDiv.className = 'sidebar-item';
      if (item.accent) itemDiv.classList.add('accent');
      itemDiv.innerHTML = `
        <span class="sidebar-icon">${item.icon}</span>
        <span class="sidebar-label">${item.label}</span>
      `;
      itemDiv.addEventListener('click', item.action);
      sidebar.appendChild(itemDiv);
    }
  });
}