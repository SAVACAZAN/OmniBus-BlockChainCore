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
        <button class="webview-refresh">⟳ Refresh</button>
      </div>
      <div class="webview-container" id="webview-${Date.now()}"></div>
    `;
    
    const containerDiv = wrap.querySelector('.webview-container');
    this.iframe = document.createElement('iframe');
    this.iframe.src = this.url;
    this.iframe.sandbox = 'allow-scripts allow-same-origin allow-forms allow-popups allow-popups-to-escape-sandbox allow-modals';
    containerDiv.appendChild(this.iframe);
    
    const refreshBtn = wrap.querySelector('.webview-refresh');
    refreshBtn.addEventListener('click', () => {
      this.iframe.src = this.url;
    });
    
    container.appendChild(wrap);
  }
}