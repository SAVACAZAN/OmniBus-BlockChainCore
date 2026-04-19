export function renderSkillsPage(container) {
  container.innerHTML = `
    <div class="p-4">
      <h2 class="mb-2">Skills & Instruments</h2>
      <div class="grid-4">
        <div class="stat-card"><div class="stat-number">12</div><div class="stat-label">Active Skills</div></div>
        <div class="stat-card"><div class="stat-number">8</div><div class="stat-label">Instruments</div></div>
        <div class="stat-card"><div class="stat-number">156</div><div class="stat-label">Total Uses</div></div>
        <div class="stat-card"><div class="stat-number">94%</div><div class="stat-label">Success Rate</div></div>
      </div>
      <div class="mt-2">
        <div class="stat-card">
          <div class="phase-title">Available Skills</div>
          <div style="margin-top: 12px;">
            <div class="flex justify-between align-center mb-2"><span>🔧 Code Analysis</span><span class="text-accent">Level 5</span></div>
            <div class="flex justify-between align-center mb-2"><span>🤖 AI Orchestration</span><span class="text-accent">Level 4</span></div>
            <div class="flex justify-between align-center mb-2"><span>⚡ Exploit Development</span><span class="text-accent">Level 3</span></div>
            <div class="flex justify-between align-center mb-2"><span>📊 Blockchain Analysis</span><span class="text-accent">Level 4</span></div>
          </div>
        </div>
      </div>
    </div>
  `;
}