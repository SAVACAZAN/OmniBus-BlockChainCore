import { TabManager } from './core/tab-manager.js';
import { initSidebar } from './components/sidebar.js';
import { initHeader } from './components/header.js';
import { initStatusBar } from './components/status-bar.js';
import { renderDashboard } from './pages/dashboard.js';
import { renderFilesPage } from './pages/files-page.js';
import { renderAgentsPage } from './pages/agents-page.js';
import { renderExploitsPage } from './pages/exploits-page.js';
import { renderSkillsPage } from './pages/skills-page.js';
import { renderLearningPage } from './pages/learning-page.js';
import { renderHistoryPage } from './pages/history-page.js';
import { renderLogsPage } from './pages/logs-page.js';
import { renderSettingsPage } from './pages/settings-page.js';

document.addEventListener('DOMContentLoaded', async () => {
  // Init components
  await initHeader(document.getElementById('header'));
  initStatusBar(document.getElementById('statusbar'));

  // Init tab manager
  const tabBar = document.getElementById('tabBar');
  const pages = document.getElementById('pages');
  const tabManager = new TabManager(tabBar, pages);

  // Add add-tab button functionality
  const addTabBtn = document.getElementById('addTab');
  if (addTabBtn) {
    addTabBtn.addEventListener('click', () => {
      tabManager.openTerminalTab('cmd');
    });
  }

  // Init sidebar with tab manager reference
  initSidebar(tabManager);

  // Add default pages (not closeable)
  tabManager.addTab({ 
    id: 'dashboard', 
    title: 'Dashboard', 
    icon: '📊', 
    closeable: false, 
    render: renderDashboard 
  });
  tabManager.addTab({ 
    id: 'files', 
    title: 'Files', 
    icon: '📁', 
    closeable: false, 
    render: renderFilesPage 
  });
  tabManager.addTab({ 
    id: 'agents', 
    title: 'Agents', 
    icon: '🤖', 
    closeable: false, 
    render: renderAgentsPage 
  });
  tabManager.addTab({ 
    id: 'exploits', 
    title: 'Exploits', 
    icon: '⚡', 
    closeable: false, 
    render: renderExploitsPage 
  });
  tabManager.addTab({ 
    id: 'skills', 
    title: 'Skills', 
    icon: '🎯', 
    closeable: false, 
    render: renderSkillsPage 
  });
  tabManager.addTab({ 
    id: 'learning', 
    title: 'Learning', 
    icon: '🧠', 
    closeable: false, 
    render: renderLearningPage 
  });
  tabManager.addTab({ 
    id: 'history', 
    title: 'History', 
    icon: '📈', 
    closeable: false, 
    render: renderHistoryPage 
  });
  tabManager.addTab({ 
    id: 'logs', 
    title: 'Logs', 
    icon: '📝', 
    closeable: false, 
    render: renderLogsPage 
  });
  tabManager.addTab({ 
    id: 'settings', 
    title: 'Settings', 
    icon: '⚙️', 
    closeable: false, 
    render: renderSettingsPage 
  });

  // Activate dashboard
  tabManager.activateTab('dashboard');

  console.log('MYTHOS LAB initialized');
});