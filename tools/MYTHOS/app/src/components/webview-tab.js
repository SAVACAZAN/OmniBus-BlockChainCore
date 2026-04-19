export class WebViewTab {
  constructor({ url, title }) {
    this.url = url;
    this.title = title;
    this.iframe = null;
  }

  render(container) {
    const wrap = document.createElement('div');
    wrap.className = 'webview-wrap';
    wrap.innerHTML = `
      <div class="webview-toolbar">
        <input type="text" class="webview-url" value="${this.url}" readonly />
        <button class="webview-refresh">Refresh</button>
        <button class="webview-external">Open in Browser</button>
      </div>
      <div class="webview-container" id="webview-${Date.now()}"></div>
    `;

    const containerDiv = wrap.querySelector('.webview-container');

    // Try iframe first
    this.iframe = document.createElement('iframe');
    this.iframe.src = this.url;
    this.iframe.sandbox = 'allow-scripts allow-same-origin allow-forms allow-popups allow-popups-to-escape-sandbox allow-modals';
    containerDiv.appendChild(this.iframe);

    // If iframe fails (CORS), show fallback message
    this.iframe.addEventListener('error', () => {
      containerDiv.innerHTML = `
        <div style="padding:40px;text-align:center;color:var(--t2);">
          <div style="font-size:48px;margin-bottom:16px;">&#127760;</div>
          <div style="font-size:16px;font-weight:bold;color:var(--text);margin-bottom:8px;">${this.title}</div>
          <div style="margin-bottom:16px;">${this.url} does not allow embedding (CORS policy).</div>
          <button style="background:var(--accent);color:#fff;border:none;padding:12px 24px;border-radius:8px;cursor:pointer;font-size:14px;" id="open-ext-${Date.now()}">
            Open in Browser
          </button>
        </div>
      `;
      containerDiv.querySelector('button').addEventListener('click', () => this.openExternal());
    });

    // Also detect X-Frame-Options block after load
    setTimeout(() => {
      try {
        // If we can't access iframe content, it's probably blocked
        const test = this.iframe.contentWindow.location.href;
      } catch(e) {
        // Blocked by CORS - show fallback
        containerDiv.innerHTML = `
          <div style="padding:40px;text-align:center;color:var(--t2);">
            <div style="font-size:48px;margin-bottom:16px;">&#127760;</div>
            <div style="font-size:16px;font-weight:bold;color:var(--text);margin-bottom:8px;">${this.title}</div>
            <div style="margin-bottom:8px;">Site loaded but may have restricted features in embedded mode.</div>
            <div style="margin-bottom:16px;font-size:11px;color:var(--t3);">For full Google login, use "Open in Browser" button.</div>
            <button style="background:var(--accent);color:#fff;border:none;padding:12px 24px;border-radius:8px;cursor:pointer;font-size:14px;">
              Open in Browser
            </button>
          </div>
        `;
        containerDiv.querySelector('button').addEventListener('click', () => this.openExternal());
      }
    }, 3000);

    // Refresh button
    wrap.querySelector('.webview-refresh').addEventListener('click', () => {
      if (this.iframe) this.iframe.src = this.url;
    });

    // Open in browser button
    wrap.querySelector('.webview-external').addEventListener('click', () => {
      this.openExternal();
    });

    container.appendChild(wrap);
  }

  openExternal() {
    if (window.__TAURI__) {
      window.__TAURI__.shell.open(this.url);
    } else {
      window.open(this.url, '_blank');
    }
  }
}
