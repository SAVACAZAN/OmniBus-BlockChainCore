export function renderSettingsPage(container) {
  container.innerHTML = `
    <div class="p-4">
      <h2 class="mb-2">Settings</h2>
      <div class="stat-card">
        <div class="phase-title mb-2">General</div>
        <div class="flex justify-between align-center mb-2">
          <span>Dark Theme</span>
          <span class="text-green">Enabled (fixed)</span>
        </div>
        <div class="flex justify-between align-center mb-2">
          <span>Auto-save logs</span>
          <span class="text-green">Enabled</span>
        </div>
        <div class="flex justify-between align-center mb-2">
          <span>Console history limit</span>
          <span>1000 lines</span>
        </div>
      </div>
      <div class="stat-card mt-2">
        <div class="phase-title mb-2">Paths</div>
        <div class="mb-1" style="font-size: 11px; color: var(--t3);">Sandbox: C:\\Kits work\\...</div>
        <div class="mb-1" style="font-size: 11px; color: var(--t3);">MYTHOS Dir: tools\\MYTHOS</div>
      </div>
    </div>
  `;
}