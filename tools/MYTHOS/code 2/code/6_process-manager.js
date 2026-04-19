import { spawnProcess, sendInput, killProcess, listProcesses } from './tauri-api.js';
import { listen } from './tauri-api.js';
import { eventBus } from './event-bus.js';

export class ProcessManager {
  constructor() {
    this.processes = new Map(); // processId -> { type, status, listeners }
  }

  async spawn(type, program, args, workingDir, onOutput, onExit) {
    const processId = `${type}_${Date.now()}_${Math.random().toString(36).substr(2, 6)}`;
    
    // Listen for output
    const outputUnlisten = await listen(`process-output-${processId}`, (event) => {
      if (onOutput) onOutput(event.payload);
      eventBus.emit('process-output', { processId, output: event.payload });
    });
    
    // Listen for exit
    const exitUnlisten = await listen(`process-exit-${processId}`, () => {
      if (onExit) onExit();
      eventBus.emit('process-exit', { processId });
      this.processes.delete(processId);
    });
    
    // Spawn the process
    await spawnProcess(program, args, workingDir, processId);
    
    this.processes.set(processId, {
      type,
      status: 'running',
      outputUnlisten,
      exitUnlisten
    });
    
    return processId;
  }
  
  async sendInput(processId, input) {
    const proc = this.processes.get(processId);
    if (!proc || proc.status !== 'running') {
      throw new Error(`Process ${processId} is not running`);
    }
    await sendInput(processId, input);
  }
  
  async kill(processId) {
    const proc = this.processes.get(processId);
    if (!proc) return;
    
    try {
      await killProcess(processId);
    } catch (e) {
      console.error(`Failed to kill process ${processId}:`, e);
    }
    
    if (proc.outputUnlisten) proc.outputUnlisten();
    if (proc.exitUnlisten) proc.exitUnlisten();
    this.processes.delete(processId);
  }
  
  getStatus(processId) {
    const proc = this.processes.get(processId);
    return proc ? proc.status : 'unknown';
  }
  
  async list() {
    return await listProcesses();
  }
  
  async killAll() {
    for (const [processId] of this.processes) {
      await this.kill(processId);
    }
  }
}

export const processManager = new ProcessManager();