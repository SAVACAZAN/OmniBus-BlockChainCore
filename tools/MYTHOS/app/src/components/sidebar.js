export function initSidebar(tabManager) {
  const sidebar = document.getElementById('sidebar');
  if (!sidebar) return;

  sidebar.innerHTML = `
    <div class="side-score">
      <div class="big">97%</div>
      <div class="lbl">MYTHOS Score</div>
      <div style="font-size:10px;color:var(--t3);margin-top:4px;">1130 blocks | 30 agents | 11 runs</div>
    </div>

    <div class="side-section"><div class="side-label">Main</div></div>
    <div class="side-item active" data-action="dashboard"><span class="side-icon">&#9632;</span> Dashboard <span class="badge g">live</span></div>
    <div class="side-item" data-action="mythos"><span class="side-icon">&#9654;</span> Run MYTHOS</div>
    <div class="side-item" data-action="files"><span class="side-icon">&#128193;</span> File Browser</div>
    <div class="side-item" data-action="agents"><span class="side-icon">&#9881;</span> Agents <span class="badge">30</span></div>
    <div class="side-item" data-action="exploits"><span class="side-icon">&#9889;</span> Exploit Lab <span class="badge r">1130</span></div>

    <div class="side-section"><div class="side-label">Consoles - Browser</div></div>
    <div class="side-item" data-action="browser-claude"><span class="side-icon" style="color:var(--accent);">&#127760;</span> Claude (Browser)</div>
    <div class="side-item" data-action="browser-kimi"><span class="side-icon" style="color:var(--cyan);">&#127760;</span> Kimi (Browser)</div>
    <div class="side-item" data-action="browser-deepseek"><span class="side-icon" style="color:var(--blue);">&#127760;</span> DeepSeek (Browser)</div>
    <div class="side-item" data-action="browser-chatgpt"><span class="side-icon" style="color:var(--green);">&#127760;</span> ChatGPT (Browser)</div>

    <div class="side-section"><div class="side-label">Consoles - Terminal</div></div>
    <div class="side-item" data-action="cmd"><span class="side-icon" style="color:var(--green);">$</span> CMD Terminal</div>
    <div class="side-item" data-action="claude-cli"><span class="side-icon" style="color:var(--accent);">C</span> Claude CLI</div>
    <div class="side-item" data-action="kimi-cli"><span class="side-icon" style="color:var(--cyan);">K</span> Kimi CLI</div>
    <div class="side-item" data-action="python"><span class="side-icon" style="color:var(--yellow);">P</span> Python REPL</div>

    <div class="side-section"><div class="side-label">Categories (27)</div></div>
    <div class="side-item" data-action="exploits"><span class="side-icon">&#128274;</span> 01_omnibus_core <span class="badge">45</span></div>
    <div class="side-item" data-action="exploits"><span class="side-icon">&#128421;</span> 02_omnibus_os <span class="badge">35</span></div>
    <div class="side-item" data-action="exploits"><span class="side-icon">&#9939;</span> 03_aweb3_blockchain <span class="badge">25</span></div>
    <div class="side-item" data-action="exploits"><span class="side-icon">&#128302;</span> 04_claude_bridge <span class="badge">20</span></div>
    <div class="side-item" data-action="exploits"><span class="side-icon">&#128027;</span> 13_cwe_matrix <span class="badge">70</span></div>
    <div class="side-item" data-action="exploits"><span class="side-icon">&#128269;</span> 14_reverse_eng <span class="badge">80</span></div>
    <div class="side-item" data-action="exploits"><span class="side-icon">&#8383;</span> 15_btc_eth_exploits <span class="badge">150</span></div>
    <div class="side-item" data-action="exploits"><span class="side-icon">&#9889;</span> 16_side_channel <span class="badge">50</span></div>
    <div class="side-item" data-action="exploits"><span class="side-icon">&#128421;</span> 17_hardware_emul <span class="badge">40</span></div>
    <div class="side-item" data-action="exploits"><span class="side-icon">&#128208;</span> 18_invariant <span class="badge">45</span></div>
    <div class="side-item" data-action="exploits"><span class="side-icon">&#127922;</span> 19_fuzzing <span class="badge">50</span></div>
    <div class="side-item" data-action="exploits"><span class="side-icon">&#128163;</span> 20_memory_corruption <span class="badge">40</span></div>
    <div class="side-item" data-action="exploits"><span class="side-icon">&#9881;</span> 21_asm_arsenal <span class="badge">80</span></div>
    <div class="side-item" data-action="exploits"><span class="side-icon">&#128640;</span> 22_testnet_runner <span class="badge">60</span></div>
    <div class="side-item" data-action="exploits"><span class="side-icon">&#129504;</span> 23_ml_corpus <span class="badge">50</span></div>
    <div class="side-item" data-action="exploits"><span class="side-icon">&#127919;</span> 24_zero_oracle <span class="badge">35</span></div>
    <div class="side-item" data-action="exploits"><span class="side-icon">&#128230;</span> 25_firmware <span class="badge">30</span></div>
    <div class="side-item" data-action="exploits"><span class="side-icon">&#129504;</span> 26_autonomous_brain <span class="badge">30</span></div>
    <div class="side-item" data-action="exploits"><span class="side-icon">&#128260;</span> 27_self_evolution <span class="badge">20</span></div>

    <div class="side-section"><div class="side-label">Libraries</div></div>
    <div class="side-item"><span class="side-icon" style="color:var(--red);">&#9632;</span> CWE Scanners <span class="badge">70</span></div>
    <div class="side-item"><span class="side-icon" style="color:var(--cyan);">&#9632;</span> Python Exploits <span class="badge">912</span></div>
    <div class="side-item"><span class="side-icon" style="color:var(--green);">&#9632;</span> C++ Exploits <span class="badge">26</span></div>
    <div class="side-item"><span class="side-icon" style="color:var(--blue);">&#9632;</span> Go/Rust/C# <span class="badge">10</span></div>
    <div class="side-item"><span class="side-icon" style="color:var(--yellow);">&#9632;</span> ASM Payloads <span class="badge">24</span></div>
    <div class="side-item"><span class="side-icon" style="color:var(--pink);">&#9632;</span> Solidity/Vyper <span class="badge">65</span></div>
    <div class="side-item"><span class="side-icon" style="color:var(--orange);">&#9632;</span> Bitcoin Script <span class="badge">15</span></div>
    <div class="side-item"><span class="side-icon" style="color:var(--accent);">&#9632;</span> EVM Bytecode <span class="badge">15</span></div>

    <div class="side-section"><div class="side-label">Tools</div></div>
    <div class="side-item" data-action="history"><span class="side-icon">&#128200;</span> Run History</div>
    <div class="side-item" data-action="logs"><span class="side-icon">&#128221;</span> Live Logs</div>
    <div class="side-item" data-action="skills"><span class="side-icon">&#9889;</span> Skills</div>
    <div class="side-item" data-action="learning"><span class="side-icon">&#128260;</span> Learning</div>
    <div class="side-item" data-action="settings"><span class="side-icon">&#9881;</span> Settings</div>
  `;

  // Wire up click handlers
  sidebar.querySelectorAll('.side-item[data-action]').forEach(item => {
    item.addEventListener('click', () => {
      sidebar.querySelectorAll('.side-item').forEach(i => i.classList.remove('active'));
      item.classList.add('active');

      const action = item.dataset.action;
      if (action === 'mythos') tabManager.openTerminalTab('mythos');
      else if (action === 'cmd') tabManager.openTerminalTab('cmd');
      else if (action === 'claude-cli') tabManager.openTerminalTab('claude');
      else if (action === 'kimi-cli') tabManager.openTerminalTab('kimi');
      else if (action === 'python') tabManager.openTerminalTab('python');
      else if (action.startsWith('browser-')) {
        const urls = {
          'browser-claude': 'https://claude.ai',
          'browser-kimi': 'https://kimi.ai',
          'browser-deepseek': 'https://chat.deepseek.com',
          'browser-chatgpt': 'https://chatgpt.com'
        };
        tabManager.openBrowserTab(urls[action], action.replace('browser-',''));
      }
      else tabManager.activateTab(action);
    });
  });
}
