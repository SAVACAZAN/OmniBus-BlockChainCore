/* src/style.css */
:root {
  --bg: #0a0e17;
  --s1: #111827;
  --s2: #1f2937;
  --s3: #374151;
  --accent: #8b5cf6;
  --accent2: #6366f1;
  --green: #10b981;
  --red: #ef4444;
  --yellow: #f59e0b;
  --cyan: #06b6d4;
  --blue: #3b82f6;
  --pink: #ec4899;
  --text: #f3f4f6;
  --t2: #9ca3af;
  --t3: #6b7280;
  --border: #1e293b;
}

* {
  margin: 0;
  padding: 0;
  box-sizing: border-box;
}

body {
  font-family: 'Segoe UI', 'Consolas', monospace;
  background: var(--bg);
  color: var(--text);
  height: 100vh;
  overflow: hidden;
  font-size: 13px;
}

/* Layout */
.hdr {
  background: var(--s1);
  border-bottom: 1px solid var(--border);
  padding: 8px 16px;
  height: 48px;
  display: flex;
  align-items: center;
  justify-content: space-between;
}

.layout {
  display: flex;
  height: calc(100vh - 72px);
}

.side {
  width: 220px;
  background: var(--s1);
  border-right: 1px solid var(--border);
  overflow-y: auto;
  padding: 12px 0;
}

.content {
  flex: 1;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.statusbar {
  height: 24px;
  background: var(--s1);
  border-top: 1px solid var(--border);
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0 12px;
  font-size: 11px;
  color: var(--t2);
}

/* Sidebar */
.sidebar-item {
  padding: 8px 16px;
  cursor: pointer;
  display: flex;
  align-items: center;
  gap: 10px;
  transition: all 0.2s;
  color: var(--t2);
}

.sidebar-item:hover {
  background: var(--s2);
  color: var(--text);
}

.sidebar-item.accent {
  color: var(--accent);
}

.sidebar-icon {
  font-size: 16px;
  width: 20px;
}

.sidebar-section {
  padding: 12px 16px 4px;
  font-size: 10px;
  font-weight: bold;
  color: var(--t3);
  letter-spacing: 1px;
}

/* Tab Bar */
.tab-bar {
  background: var(--s1);
  border-bottom: 1px solid var(--border);
  display: flex;
  align-items: center;
  overflow-x: auto;
  padding: 0 8px;
  gap: 2px;
  min-height: 36px;
}

.tab {
  background: var(--s2);
  padding: 6px 12px;
  display: flex;
  align-items: center;
  gap: 8px;
  cursor: pointer;
  border-radius: 6px 6px 0 0;
  font-size: 12px;
  transition: all 0.2s;
  white-space: nowrap;
}

.tab:hover {
  background: var(--s3);
}

.tab.active {
  background: var(--bg);
  color: var(--accent);
}

.tab-close {
  margin-left: 8px;
  opacity: 0.6;
  cursor: pointer;
  font-size: 14px;
}

.tab-close:hover {
  opacity: 1;
}

.tab-add {
  background: var(--accent);
  color: white;
  padding: 4px 12px;
  border-radius: 4px;
  cursor: pointer;
  font-size: 16px;
  font-weight: bold;
  margin-left: auto;
}

/* Pages */
.pages {
  flex: 1;
  overflow: auto;
  position: relative;
}

.page {
  display: none;
  height: 100%;
  overflow: auto;
  padding: 20px;
}

.page.active {
  display: block;
}

/* Terminal Widget */
.terminal-wrap {
  display: flex;
  flex-direction: column;
  height: 100%;
  background: #000;
}

.terminal-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 6px 12px;
  background: var(--s1);
  border-bottom: 1px solid var(--border);
  font-size: 11px;
}

.terminal-title {
  font-weight: bold;
}

.terminal-status {
  font-size: 9px;
  padding: 2px 8px;
  border-radius: 3px;
}

.status-running {
  background: var(--green);
  color: #000;
}

.status-stopped {
  background: var(--s3);
  color: var(--t2);
}

.status-error {
  background: var(--red);
  color: #fff;
}

.status-idle {
  background: var(--s3);
  color: var(--t3);
}

.terminal-output {
  flex: 1;
  background: #000;
  padding: 10px;
  overflow-y: auto;
  font-size: 11px;
  line-height: 1.6;
  font-family: 'Consolas', monospace;
}

.term-pass {
  color: #4ade80;
}

.term-fail,
.term-error {
  color: #f87171;
}

.term-warn {
  color: #fbbf24;
}

.term-info {
  color: #22d3ee;
}

.term-phase {
  color: #a78bfa;
}

.term-ai {
  color: #a78bfa;
}

.term-user {
  color: #22d3ee;
}

.term-input {
  color: #60a5fa;
}

.term-default {
  color: #4b5563;
}

.terminal-input-bar {
  display: flex;
  background: #000;
  border-top: 1px solid var(--s3);
}

.terminal-prompt {
  padding: 8px;
  color: var(--green);
  font-size: 12px;
}

.terminal-input {
  flex: 1;
  background: transparent;
  border: none;
  color: var(--green);
  padding: 8px 4px;
  outline: none;
  font-family: inherit;
  font-size: 12px;
}

.terminal-send {
  background: var(--accent);
  border: none;
  color: #fff;
  padding: 0 14px;
  cursor: pointer;
  font-family: inherit;
  font-size: 11px;
}

.terminal-send:hover {
  background: var(--accent2);
}

/* Dashboard */
.dashboard-container {
  max-width: 1200px;
  margin: 0 auto;
}

.dashboard-header {
  margin-bottom: 24px;
}

.dashboard-header h1 {
  font-size: 28px;
  margin-bottom: 8px;
}

.stats-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
  gap: 16px;
  margin-bottom: 32px;
}

.stat-card {
  background: var(--s1);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 20px;
  text-align: center;
}

.stat-value {
  font-size: 32px;
  font-weight: bold;
  color: var(--accent);
  margin-bottom: 8px;
}

.stat-label {
  color: var(--t2);
  font-size: 12px;
}

.phases-section,
.history-section {
  margin-bottom: 32px;
}

.phases-section h2,
.history-section h2 {
  margin-bottom: 16px;
  font-size: 18px;
}

.phases-grid {
  display: grid;
  gap: 12px;
}

.phase-card {
  background: var(--s1);
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 12px;
}

.phase-header {
  display: flex;
  justify-content: space-between;
  margin-bottom: 8px;
}

.phase-progress {
  background: var(--s3);
  height: 4px;
  border-radius: 2px;
  overflow: hidden;
  margin: 8px 0;
}

.progress-bar {
  background: var(--accent);
  height: 100%;
  transition: width 0.3s;
}

.history-table-container {
  overflow-x: auto;
}

.history-table {
  width: 100%;
  border-collapse: collapse;
}

.history-table th,
.history-table td {
  padding: 10px;
  text-align: left;
  border-bottom: 1px solid var(--border);
}

.success-row {
  color: var(--green);
}

.fail-row {
  color: var(--red);
}

.quick-actions {
  display: flex;
  gap: 12px;
}

.action-btn {
  background: var(--accent);
  color: white;
  border: none;
  padding: 10px 20px;
  border-radius: 6px;
  cursor: pointer;
  font-size: 12px;
  transition: all 0.2s;
}

.action-btn:hover {
  background: var(--accent2);
  transform: translateY(-1px);
}

/* Files Page */
.files-container {
  display: flex;
  height: 100%;
  gap: 20px;
}

.file-sidebar {
  width: 300px;
  background: var(--s1);
  border-radius: 8px;
  overflow: hidden;
  display: flex;
  flex-direction: column;
}

.file-tree-header {
  padding: 12px;
  border-bottom: 1px solid var(--border);
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.file-tree {
  flex: 1;
  overflow-y: auto;
  padding: 8px;
}

.file-item {
  padding: 4px 8px;
  cursor: pointer;
  display: flex;
  align-items: center;
  gap: 8px;
  border-radius: 4px;
}

.file-item:hover {
  background: var(--s2);
}

.file-content {
  flex: 1;
  display: flex;
  flex-direction: column;
  background: var(--s1);
  border-radius: 8px;
  overflow: hidden;
}

.file-preview-header {
  padding: 12px;
  border-bottom: 1px solid var(--border);
  background: var(--s2);
}

.code-viewer {
  flex: 1;
  overflow: auto;
  padding: 16px;
}

.code-viewer pre {
  margin: 0;
  font-family: 'Consolas', monospace;
  font-size: 12px;
  line-height: 1.5;
}

/* Agents Page */
.agents-container {
  height: 100%;
}

.agents-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 24px;
}

.agents-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(350px, 1fr));
  gap: 20px;
}

.agent-card {
  background: var(--s1);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 16px;
  transition: all 0.2s;
}

.agent-card:hover {
  transform: translateY(-2px);
  border-color: var(--accent);
}

.agent-header {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-bottom: 12px;
}

.agent-icon {
  font-size: 24px;
}

.agent-name {
  font-size: 16px;
}

.agent-details {
  margin-bottom: 16px;
  font-size: 12px;
  color: var(--t2);
}

.agent-description {
  margin-top: 8px;
  font-style: italic;
}

.agent-actions {
  display: flex;
  gap: 8px;
}

.agent-run,
.agent-edit {
  padding: 6px 12px;
  border: none;
  border-radius: 4px;
  cursor: pointer;
  font-size: 11px;
}

.agent-run {
  background: var(--accent);
  color: white;
}

.agent-edit {
  background: var(--s3);
  color: var(--text);
}

/* Exploits Page */
.exploits-container {
  display: flex;
  height: 100%;
  gap: 20px;
}

.exploits-sidebar {
  width: 300px;
  background: var(--s1);
  border-radius: 8px;
  overflow: hidden;
  display: flex;
  flex-direction: column;
}

.exploits-header {
  padding: 12px;
  border-bottom: 1px solid var(--border);
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.exploits-list {
  flex: 1;
  overflow-y: auto;
}

.exploit-item {
  padding: 12px;
  border-bottom: 1px solid var(--border);
  cursor: pointer;
  transition: all 0.2s;
}

.exploit-item:hover {
  background: var(--s2);
}

.exploit-item.selected {
  background: var(--accent);
  color: white;
}

.exploit-title {
  font-weight: bold;
  margin-bottom: 4px;
}

.exploit-meta {
  font-size: 11px;
  color: var(--t2);
}

.exploit-preview {
  flex: 1;
  display: flex;
  flex-direction: column;
  background: var(--s1);
  border-radius: 8px;
  overflow: hidden;
}

.preview-header {
  padding: 12px;
  border-bottom: 1px solid var(--border);
  background: var(--s2);
}

/* Utility Classes */
.icon-btn {
  background: transparent;
  border: none;
  color: var(--t2);
  cursor: pointer;
  font-size: 16px;
  padding: 4px 8px;
}

.icon-btn:hover {
  color: var(--text);
}

.loading {
  text-align: center;
  padding: 40px;
  color: var(--t2);
}

.error {
  color: var(--red);
  text-align: center;
  padding: 20px;
}

.page-container {
  padding: 20px;
}

.page-container h1 {
  margin-bottom: 20px;
}

.setting-group {
  margin-bottom: 20px;
}

.setting-group label {
  display: block;
  margin-bottom: 8px;
  color: var(--t2);
}

.setting-group input,
.setting-group select {
  width: 100%;
  max-width: 400px;
  padding: 8px;
  background: var(--s2);
  border: 1px solid var(--border);
  color: var(--text);
  border-radius: 4px;
}

.logs-viewer {
  background: #000;
  padding: 16px;
  height: 500px;
  overflow-y: auto;
  font-family: 'Consolas', monospace;
  font-size: 11px;
}

.log-entry {
  padding: 4px 0;
  border-bottom: 1px solid var(--border);
}

.skills-placeholder {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
  gap: 20px;
  margin-top: 20px;
}

.skill-card {
  background: var(--s1);
  padding: 20px;
  border-radius: 8px;
  border: 1px solid var(--border);
}

.skill-card h3 {
  margin-bottom: 8px;
}

.history-filters {
  display: flex;
  gap: 12px;
  margin-bottom: 20px;
}

.filter-btn {
  padding: 6px 12px;
  background: var(--s2);
  border: 1px solid var(--border);
  color: var(--text);
  cursor: pointer;
  border-radius: 4px;
}

.filter-btn.active {
  background: var(--accent);
  border-color: var(--accent);
}