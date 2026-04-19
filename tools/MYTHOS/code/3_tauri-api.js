// src/components/terminal.js
import { spawnProcess, sendInput, killProcess, listen } from '../core/tauri-api.js';
import { PROCESS_CONFIGS } from '../core/constants.js';

export class Terminal {
  constructor({ containerId, processType, workingDir, onReady }) {
    this.containerId = containerId;
    this.processType = processType;
    this.workingDir = workingDir || PROCESS_CONFIGS[processType]?.workingDir;
    this.processId = null;
    this.element = null;
    this.outputEl = null;
    this.inputEl = null;
    this.onReady = onReady;
    this.unlistenFns = [];
  }

  getConfig() {
    return PROCESS_CONFIGS[this.processType] || PROCESS_CONFIGS.cmd;
  }

  render(container) {
    const config = this.getConfig();
    
    this.element = document.createElement('div');
    this.element.className = 'terminal-wrap';
    this.element.innerHTML = `
      <div class="terminal-header">
        <span class="terminal-title">${config.title}</span>
        <span class="terminal-status" id="status-${this.containerId}">idle</span>
      </div>
      <div class="terminal-output" id="output-${this.containerId}"></div>
      <div class="terminal-input-bar">
        <span class="terminal-prompt">${config.prompt}</span>
        <input type="text" class="terminal-input" id="input-${this.containerId}" 
               placeholder="${config.placeholder}" />
        <button class="terminal-send" id="send-${this.containerId}">RUN</button>
      </div>
    `;
    container.appendChild(this.element);
    
    this.outputEl = this.element.querySelector(`#output-${this.containerId}`);
    this.inputEl = this.element.querySelector(`#input-${this.containerId}`);
    
    // Event listeners
    this.inputEl.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') this.handleInput();
    });
    this.element.querySelector(`#send-${this.containerId}`).addEventListener('click', () => {
      this.handleInput();
    });
    
    if (this.onReady) this.onReady(this);
  }

  async start() {
    const config = this.getConfig();
    this.processId = `${this.processType}_${this.containerId}_${Date.now()}`;
    
    // Setup listeners
    try {
      const unlistenOutput = await listen(`process-output-${this.processId}`, (event) => {
        this.appendLine(event.payload);
      });
      this.unlistenFns.push(unlistenOutput);
      
      const unlistenExit = await listen(`process-exit-${this.processId}`, () => {
        this.appendLine('[Process ended]');
        this.setStatus('stopped');
      });
      this.unlistenFns.push(unlistenExit);
    } catch (error) {
      console.error('Failed to setup listeners:', error);
    }
    
    // Spawn process
    try {
      await spawnProcess({
        program: config.program,
        args: config.args,
        workingDir: this.workingDir,
        processId: this.processId
      });
      this.setStatus('running');
      this.appendLine(`[Started: ${config.program} ${config.args.join(' ')}]`);
      this.appendLine(`[Working Dir: ${this.workingDir}]`);
    } catch (error) {
      this.appendLine(`[ERROR] Failed to start process: ${error}`);
      this.setStatus('error');
    }
  }
  
  async handleInput() {
    const text = this.inputEl.value.trim();
    if (!text) return;
    this.inputEl.value = '';
    
    // For chat modes, echo user input
    if (this.processType === 'claude' || this.processType === 'kimi') {
      this.appendLine(`You: ${text}`, 'user');
    } else if (this.processType === 'python') {
      this.appendLine(`${text}`, 'input');
    }
    
    if (this.processId) {
      try {
        await sendInput({ processId: this.processId, input: text + '\n' });
      } catch (error) {
        this.appendLine(`[ERROR] send_input failed: ${error}`, 'error');
      }
    }
  }
  
  appendLine(text, type = 'auto') {
    const div = document.createElement('div');
    
    if (type === 'auto') {
      if (text.includes('[PASS]')) div.className = 'term-pass';
      else if (text.includes('[FAIL]')) div.className = 'term-fail';
      else if (text.includes('[WARN]')) div.className = 'term-warn';
      else if (text.includes('[INFO]')) div.className = 'term-info';
      else if (text.includes('PHASE:')) div.className = 'term-phase';
      else if (text.startsWith('Claude>') || text.includes('Claude:')) div.className = 'term-ai';
      else if (text.startsWith('You:')) div.className = 'term-user';
      else if (text.startsWith('[ERROR]') || text.includes('[stderr]')) div.className = 'term-error';
      else div.className = 'term-default';
    } else {
      const typeMap = {
        'user': 'term-user',
        'ai': 'term-ai',
        'error': 'term-error',
        'pass': 'term-pass',
        'fail': 'term-fail',
        'warn': 'term-warn',
        'info': 'term-info',
        'phase': 'term-phase',
        'input': 'term-input'
      };
      div.className = typeMap[type] || 'term-default';
    }
    
    div.textContent = text;
    this.outputEl.appendChild(div);
    this.outputEl.scrollTop = this.outputEl.scrollHeight;
  }
  
  setStatus(status) {
    const el = this.element?.querySelector(`#status-${this.containerId}`);
    if (el) {
      el.textContent = status;
      el.className = `terminal-status status-${status}`;
    }
  }
  
  async destroy() {
    // Remove all event listeners
    for (const unlisten of this.unlistenFns) {
      try {
        await unlisten();
      } catch (error) {
        console.error('Error removing listener:', error);
      }
    }
    
    // Kill process if running
    if (this.processId) {
      try {
        await killProcess({ processId: this.processId });
      } catch (error) {
        console.error('Error killing process:', error);
      }
    }
    
    // Remove DOM element
    if (this.element) {
      this.element.remove();
    }
  }
  
  clear() {
    if (this.outputEl) this.outputEl.innerHTML = '';
  }
  
  focus() {
    if (this.inputEl) this.inputEl.focus();
  }
}