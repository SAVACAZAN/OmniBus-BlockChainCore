import { processManager } from '../core/process-manager.js';
import { TERMINAL_CONFIGS } from '../core/constants.js';

export class Terminal {
  constructor({ containerId, processType, workingDir, onReady }) {
    this.containerId = containerId;
    this.processType = processType;
    this.workingDir = workingDir || TERMINAL_CONFIGS[processType]?.workingDir;
    this.processId = null;
    this.element = null;
    this.outputEl = null;
    this.inputEl = null;
    this.onReady = onReady;
    this.config = TERMINAL_CONFIGS[processType];
  }

  render(container) {
    this.element = document.createElement('div');
    this.element.className = 'terminal-wrap';
    this.element.innerHTML = `
      <div class="terminal-header">
        <span class="terminal-title">${this.config?.title || this.processType}</span>
        <span class="terminal-status" id="status-${this.containerId}">idle</span>
      </div>
      <div class="terminal-output" id="output-${this.containerId}"></div>
      <div class="terminal-input-bar">
        <span class="terminal-prompt">${this.config?.prompt || '$'}</span>
        <input type="text" class="terminal-input" id="input-${this.containerId}" 
               placeholder="${this.config?.placeholder || 'Type command...'}" />
        <button class="terminal-send" id="send-${this.containerId}">RUN</button>
      </div>
    `;
    container.appendChild(this.element);
    
    this.outputEl = this.element.querySelector(`#output-${this.containerId}`);
    this.inputEl = this.element.querySelector(`#input-${this.containerId}`);
    
    this.inputEl.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') this.handleInput();
    });
    this.element.querySelector(`#send-${this.containerId}`).addEventListener('click', () => {
      this.handleInput();
    });
    
    if (this.onReady) this.onReady(this);
  }

  async start() {
    if (!this.config) {
      this.appendLine(`[ERROR] Unknown process type: ${this.processType}`);
      return;
    }
    
    try {
      this.processId = await processManager.spawn(
        this.processType,
        this.config.program,
        this.config.args,
        this.workingDir,
        (output) => this.appendLine(output),
        () => this.setStatus('stopped')
      );
      
      this.setStatus('running');
      this.appendLine(`[Started: ${this.config.program} ${this.config.args.join(' ')}]`);
      this.appendLine(`[Working Dir: ${this.workingDir}]`);
    } catch (e) {
      this.appendLine(`[ERROR] ${e}`);
      this.setStatus('error');
    }
  }

  async handleInput() {
    const text = this.inputEl.value.trim();
    if (!text) return;
    this.inputEl.value = '';

    if (this.processType === 'claude' || this.processType === 'kimi') {
      this.appendLine(`You: ${text}`, 'user');
    }

    if (this.processId) {
      try {
        await processManager.sendInput(this.processId, text);
      } catch (e) {
        this.appendLine(`[ERROR] send_input: ${e}`);
      }
    }
  }

  appendLine(text, type = 'auto') {
    const div = document.createElement('div');
    if (type === 'auto') {
      if (text.includes('[PASS]') || text.includes('✓')) div.className = 'term-pass';
      else if (text.includes('[FAIL]') || text.includes('✗')) div.className = 'term-fail';
      else if (text.includes('[WARN]')) div.className = 'term-warn';
      else if (text.includes('[INFO]')) div.className = 'term-info';
      else if (text.includes('PHASE:')) div.className = 'term-phase';
      else if (text.toLowerCase().includes('claude>') || text.toLowerCase().includes('claude:')) div.className = 'term-ai';
      else if (text.startsWith('You:')) div.className = 'term-user';
      else if (text.startsWith('[ERROR]') || text.startsWith('[stderr]')) div.className = 'term-error';
      else div.className = 'term-default';
    } else {
      div.className = `term-${type}`;
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
    if (this.processId) {
      await processManager.kill(this.processId);
      this.processId = null;
    }
  }

  clear() {
    if (this.outputEl) this.outputEl.innerHTML = '';
  }
}