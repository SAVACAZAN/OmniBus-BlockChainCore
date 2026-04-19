export function initSidebar(tabManager) {
  const sidebar = document.getElementById('sidebar');
  if (!sidebar) return;
  
  const sections = [
    {
      title: 'MAIN',
      items: [
        { label: 'Dashboard', icon: '📊', action: () => tabManager.activateTab('dashboard') },
        { label: 'Run MYTHOS', icon: '▶', action: () => tabManager.openTerminalTab('mythos') },
        { label: 'File Browser', icon: '📁', action: () => tabManager.activateTab('files') },
        { label: 'Agents', icon: '🤖', action: () => tabManager.activateTab('agents') },
        { label: 'Exploit Lab', icon: '⚡', action: () => tabManager.activateTab('exploits') }
      ]
    },
    {
      title: 'CONSOLES — Browser',
      items: [
        { label: 'Claude (Browser)', icon: '🌐', action: () => tabManager.openBrowserTab('claude', 'Claude Browser') },
        { label: 'Kimi (Browser)', icon: '🌐', action: () => tabManager.openBrowserTab('kimi', 'Kimi Browser') },
        { label: 'DeepSeek (Browser)', icon: '🌐', action: () => tabManager.openBrowserTab('deepseek', 'DeepSeek Browser') },
        { label: 'ChatGPT (Browser)', icon: '🌐', action: () => tabManager.openBrowserTab('chatgpt', 'ChatGPT Browser') }
      ]
    },
    {
      title: 'CONSOLES — Terminal',
      items: [
        { label: 'CMD Terminal', icon: '$', action: () => tabManager.openTerminalTab('cmd') },
        { label: 'Claude CLI', icon: 'C', action: () => tabManager.openTerminalTab('claude') },
        { label: 'Python REPL', icon: 'P', action: () => tabManager.openTerminalTab('python') }
      ]
    },
    {
      title: 'TOOLS',
      items: [
        { label: 'Run History', icon: '📈', action: () => tabManager.activateTab('history') },
        { label: 'Live Logs', icon: '📝', action: () => tabManager.activateTab('logs') },
        { label: 'Skills', icon: '🎯', action: () => tabManager.activateTab('skills') },
        { label: 'Learning', icon: '🧠', action: () => tabManager.activateTab('learning') },
        { label: 'Settings', icon: '⚙️', action: () => tabManager.activateTab('settings') }
      ]
    }
  ];
  
  sidebar.innerHTML = '';
  
  sections.forEach(section => {
    const sectionDiv = document.createElement('div');
    sectionDiv.className = 'side-section';
    sectionDiv.textContent = section.title;
    sidebar.appendChild(sectionDiv);
    
    section.items.forEach(item => {
      const itemDiv = document.createElement('div');
      itemDiv.className = 'side-item';
      itemDiv.innerHTML = `
        <span class="side-icon">${item.icon}</span>
        <span class="side-label">${item.label}</span>
      `;
      itemDiv.addEventListener('click', item.action);
      sidebar.appendChild(itemDiv);
    });
  });
}