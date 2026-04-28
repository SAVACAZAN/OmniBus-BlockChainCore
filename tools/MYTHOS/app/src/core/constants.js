// Path constants
export const SANDBOX = 'C:\\Kits work\\limaje de programare\\OmniBus aweb3 + OmniBus BlockChain';
export const BC_ROOT = SANDBOX + '\\OmniBus-BlockChainCore';
export const AWEB3_ROOT = SANDBOX + '\\OmniBus - aweb3';
export const MYTHOS_DIR = BC_ROOT + '\\tools\\MYTHOS';
export const MYTHOS_DATA = MYTHOS_DIR + '\\data';
export const IMPORTED_DIR = MYTHOS_DIR + '\\imported';
export const AGENTS_DIRS = [AWEB3_ROOT + '\\.claude\\agents', BC_ROOT + '\\.claude\\agents'];
export const BLOCKS_DIR = MYTHOS_DIR + '\\blocks';

// Terminal configs
export const TERMINAL_CONFIGS = {
  cmd: {
    program: 'cmd',
    args: ['/k'],
    workingDir: SANDBOX,
    title: 'CMD Terminal',
    prompt: '$',
    placeholder: 'Type command...'
  },
  claude: {
    program: 'python',
    args: ['-u', MYTHOS_DIR + '\\claude-chat-bridge.py'],
    workingDir: BC_ROOT,
    title: 'Claude Chat',
    prompt: 'claude>',
    placeholder: 'Ask Claude anything...'
  },
  kimi: {
    program: 'python',
    args: ['-u', MYTHOS_DIR + '\\kimi-chat-bridge.py'],
    workingDir: BC_ROOT,
    title: 'Kimi Chat',
    prompt: 'kimi>',
    placeholder: 'Ask Kimi anything...'
  },
  python: {
    program: 'python',
    args: ['-u', '-i'],
    workingDir: SANDBOX,
    title: 'Python REPL',
    prompt: '>>>',
    placeholder: 'Python expression...'
  },
  mythos: {
    program: 'python',
    args: ['-u', MYTHOS_DIR + '\\omnibus-mythos.py'],
    workingDir: BC_ROOT,
    title: 'MYTHOS Runner',
    prompt: 'mythos$',
    placeholder: 'python tools/MYTHOS/omnibus-mythos.py --phase crypto'
  }
};

// Browser URLs
export const BROWSER_URLS = {
  claude: 'https://claude.ai',
  kimi: 'https://kimi.ai',
  deepseek: 'https://chat.deepseek.com',
  chatgpt: 'https://chatgpt.com'
};