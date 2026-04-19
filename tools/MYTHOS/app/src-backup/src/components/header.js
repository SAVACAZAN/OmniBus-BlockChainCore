import { getLatestScore } from '../core/tauri-api.js';
import { MYTHOS_DATA } from '../core/constants.js';

export async function initHeader(container) {
  if (!container) return;
  
  let score = 0;
  try {
    const latest = await getLatestScore(MYTHOS_DATA);
    if (latest && latest.score !== undefined) score = latest.score;
  } catch (e) {
    console.error('Failed to load score:', e);
  }
  
  container.innerHTML = `
    <div class="header-left">
      <div class="logo">MYTHOS LAB</div>
      <div class="score-badge">SCORE: ${score}</div>
    </div>
    <div class="status-dots">
      <div class="dot green" title="System OK"></div>
      <div class="dot yellow" title="Agents Ready"></div>
      <div class="dot green" title="Blockchain Active"></div>
    </div>
  `;
}