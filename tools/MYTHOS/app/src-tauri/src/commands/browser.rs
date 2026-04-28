use std::path::PathBuf;
use tauri::{AppHandle, Emitter, Manager, Url, WebviewUrl, WebviewWindowBuilder};
use tauri::webview::WebviewBuilder;

/// Returns the shared browser profile directory used for persistent cookies/storage.
/// All browser webviews (both tabs and OAuth popups) use this same directory.
fn get_shared_profile_dir(app: &AppHandle) -> PathBuf {
    let base = app.path().app_data_dir().unwrap_or_else(|_| {
        PathBuf::from(std::env::var("APPDATA").unwrap_or_else(|_| ".".to_string()))
    });
    let profile_dir = base.join("OmniBusDEV").join("browser_profile");
    std::fs::create_dir_all(&profile_dir).ok();
    profile_dir
}

/// Checks if a URL looks like an OAuth callback / completion page.
fn is_oauth_callback(url: &str) -> bool {
    let callbacks = [
        "/google-callback",
        "/auth/callback",
        "myaccount.google.com",
        "/oauth2/",
        "/signin/oauth",
        "accounts.google.com/ServiceLogin",
        "accounts.google.com/signin",
    ];
    callbacks.iter().any(|cb| url.contains(cb))
}

/// Injects JavaScript into a WebviewWindow to intercept `window.open` and OAuth link clicks,
/// redirecting them to the Tauri backend command `open_oauth_popup`.
fn inject_oauth_intercept(win: &tauri::WebviewWindow, tab_id: &str) {
    let script = format!(
        r#"
        (function() {{
            if (window.__omnibus_oauth_hooked) return;
            window.__omnibus_oauth_hooked = true;
            window.__omnibus_tab_id = '{}';

            const tabId = '{}';
            const origOpen = window.open;
            window.open = function(url, target, features) {{
                if (typeof url === 'string' && (
                    url.includes('accounts.google.com') ||
                    url.includes('google.com/o/oauth') ||
                    url.includes('auth0') ||
                    url.includes('microsoftonline') ||
                    url.includes('oauth')
                )) {{
                    console.log('[OmniBus] Intercepted OAuth popup:', url);
                    if (window.__TAURI__ && window.__TAURI__.core) {{
                        window.__TAURI__.core.invoke('open_oauth_popup', {{
                            url: url,
                            parentTabId: tabId
                        }});
                    }}
                    return null;
                }}
                return origOpen.call(this, url, target, features);
            }};

            document.addEventListener('click', function(e) {{
                const a = e.target.closest('a');
                if (a && a.target === '_blank') {{
                    const href = a.href;
                    if (href && (
                        href.includes('accounts.google.com') ||
                        href.includes('google.com/o/oauth') ||
                        href.includes('auth0') ||
                        href.includes('microsoftonline') ||
                        href.includes('oauth')
                    )) {{
                        e.preventDefault();
                        if (window.__TAURI__ && window.__TAURI__.core) {{
                            window.__TAURI__.core.invoke('open_oauth_popup', {{
                                url: href,
                                parentTabId: tabId
                            }});
                        }}
                    }}
                }}
            }}, true);
        }})();
        "#,
        tab_id, tab_id
    );
    let _ = win.eval(&script);
}

/// Opens a browser tab as a separate WebviewWindow with persistent shared cookies.
#[tauri::command]
pub async fn open_browser_tab(
    app: AppHandle,
    url: String,
    title: String,
    tab_id: String,
) -> Result<String, String> {
    let profile_dir = get_shared_profile_dir(&app);

    let url_parsed = url
        .parse::<Url>()
        .map_err(|e| format!("Invalid URL: {}", e))?;

    let _window = WebviewWindowBuilder::new(
        &app,
        &tab_id,
        WebviewUrl::External(url_parsed),
    )
    .title(&title)
    .inner_size(1200.0, 800.0)
    .data_directory(profile_dir)
    .on_navigation(|url| {
        let url_str = url.as_str();
        if url_str.contains("accounts.google.com") || url_str.contains("oauth") {
            println!(
                "[BROWSER] Navigating to auth URL: {}",
                &url_str[..80.min(url_str.len())]
            );
        }
        true
    })
    .build()
    .map_err(|e| format!("Failed to create browser window: {}", e))?;

    // Inject OAuth interception after the page starts loading
    let tab_id_clone = tab_id.clone();
    let app_clone = app.clone();
    tokio::spawn(async move {
        tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
        if let Some(win) = app_clone.get_webview_window(&tab_id_clone) {
            inject_oauth_intercept(&win, &tab_id_clone);
        }
        // Re-inject after a longer delay to catch late-loaded scripts (SPA hydration)
        tokio::time::sleep(tokio::time::Duration::from_secs(3)).await;
        if let Some(win) = app_clone.get_webview_window(&tab_id_clone) {
            inject_oauth_intercept(&win, &tab_id_clone);
        }
    });

    Ok(format!("Browser tab '{}' opened with URL: {}", title, url))
}

/// Opens an OAuth popup window that shares the same cookie profile as the parent tab.
/// Auto-closes when a callback URL is detected.
#[tauri::command]
pub async fn open_oauth_popup(
    app: AppHandle,
    url: String,
    parent_tab_id: String,
) -> Result<String, String> {
    let profile_dir = get_shared_profile_dir(&app);
    let popup_id = format!("oauth-popup-{}", chrono::Utc::now().timestamp_millis());

    let url_parsed = url
        .parse::<Url>()
        .map_err(|e| format!("Invalid URL: {}", e))?;

    let app_clone = app.clone();
    let parent_id = parent_tab_id.clone();
    let popup_id_clone = popup_id.clone();

    let _window = WebviewWindowBuilder::new(
        &app,
        &popup_id,
        WebviewUrl::External(url_parsed),
    )
    .title("Login — Google OAuth")
    .inner_size(500.0, 700.0)
    .data_directory(profile_dir)
    .on_navigation(move |nav_url| {
        let url_str = nav_url.as_str();

        if is_oauth_callback(url_str) {
            println!(
                "[OAUTH] Callback detected: {}",
                &url_str[..80.min(url_str.len())]
            );

            let _ = app_clone.emit(
                "oauth-complete",
                serde_json::json!({
                    "parent_tab": parent_id,
                    "callback_url": url_str
                }),
            );

            let app_for_close = app_clone.clone();
            let popup_id_for_close = popup_id_clone.clone();
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_secs(2));
                if let Some(window) = app_for_close.get_webview_window(&popup_id_for_close) {
                    let _ = window.close();
                }
            });
        }
        true
    })
    .build()
    .map_err(|e| format!("Failed to create OAuth popup: {}", e))?;

    Ok("OAuth popup opened".to_string())
}

/// Closes a browser tab (either a WebviewWindow or an inline Webview).
#[tauri::command]
pub async fn close_browser_tab(app: AppHandle, tab_id: String) -> Result<(), String> {
    if let Some(window) = app.get_webview_window(&tab_id) {
        window.close().map_err(|e| e.to_string())?;
        return Ok(());
    }
    // Try to find as inline webview in the main window
    if let Some(main_wv) = app.get_webview_window("main") {
        let window = main_wv.as_ref().window();
        if let Some(webview) = window.webviews().into_iter().find(|w| w.label() == tab_id) {
            webview.close().map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

/// Reloads a browser tab by evaluating `window.location.reload()`.
#[tauri::command]
pub async fn reload_browser_tab(app: AppHandle, tab_id: String) -> Result<(), String> {
    if let Some(window) = app.get_webview_window(&tab_id) {
        window
            .eval("window.location.reload()")
            .map_err(|e| e.to_string())?;
        return Ok(());
    }
    // Try inline webview
    if let Some(main_wv) = app.get_webview_window("main") {
        let window = main_wv.as_ref().window();
        if let Some(webview) = window.webviews().into_iter().find(|w| w.label() == tab_id) {
            webview
                .eval("window.location.reload()")
                .map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

/// Creates an inline browser webview inside the main window.
/// Use `show_browser` / `hide_browser` for tab switching.
#[tauri::command]
pub async fn create_inline_browser(
    app: AppHandle,
    url: String,
    tab_id: String,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> Result<String, String> {
    let profile_dir = get_shared_profile_dir(&app);
    let main_wv = app
        .get_webview_window("main")
        .ok_or("Main window not found")?;
    let main_window = main_wv.as_ref().window();

    let url_parsed = url
        .parse::<Url>()
        .map_err(|e| format!("Invalid URL: {}", e))?;

    let _webview = main_window
        .add_child(
            WebviewBuilder::new(&tab_id, WebviewUrl::External(url_parsed))
                .data_directory(profile_dir),
            tauri::LogicalPosition::new(x, y),
            tauri::LogicalSize::new(width, height),
        )
        .map_err(|e| format!("Failed to create inline browser: {}", e))?;

    // Inject OAuth interception after page load
    let tab_id_clone = tab_id.clone();
    let app_clone = app.clone();
    tokio::spawn(async move {
        tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
        if let Some(main_wv) = app_clone.get_webview_window("main") {
            let window = main_wv.as_ref().window();
            if let Some(wv) = window.webviews().into_iter().find(|w| w.label() == &tab_id_clone) {
                let script = format!(
                    r#"
                    (function() {{
                        if (window.__omnibus_oauth_hooked) return;
                        window.__omnibus_oauth_hooked = true;
                        window.__omnibus_tab_id = '{}';
                        const tabId = '{}';
                        const origOpen = window.open;
                        window.open = function(url, target, features) {{
                            if (typeof url === 'string' && (
                                url.includes('accounts.google.com') ||
                                url.includes('google.com/o/oauth') ||
                                url.includes('auth0') ||
                                url.includes('microsoftonline') ||
                                url.includes('oauth')
                            )) {{
                                if (window.__TAURI__ && window.__TAURI__.core) {{
                                    window.__TAURI__.core.invoke('open_oauth_popup', {{
                                        url: url,
                                        parentTabId: tabId
                                    }});
                                }}
                                return null;
                            }}
                            return origOpen.call(this, url, target, features);
                        }};
                    }})();
                    "#,
                    tab_id_clone, tab_id_clone
                );
                let _ = wv.eval(&script);
            }
        }
    });

    Ok(format!("Inline browser created: {}", tab_id))
}

/// Shows a previously hidden inline browser webview by restoring its position and size.
#[tauri::command]
pub async fn show_browser(
    app: AppHandle,
    tab_id: String,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> Result<(), String> {
    if let Some(main_wv) = app.get_webview_window("main") {
        let window = main_wv.as_ref().window();
        if let Some(webview) = window.webviews().into_iter().find(|w| w.label() == &tab_id) {
            webview
                .set_position(tauri::LogicalPosition::new(x, y))
                .map_err(|e| e.to_string())?;
            webview
                .set_size(tauri::LogicalSize::new(width, height))
                .map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

/// Hides an inline browser webview by moving it off-screen and shrinking it.
#[tauri::command]
pub async fn hide_browser(app: AppHandle, tab_id: String) -> Result<(), String> {
    if let Some(main_wv) = app.get_webview_window("main") {
        let window = main_wv.as_ref().window();
        if let Some(webview) = window.webviews().into_iter().find(|w| w.label() == &tab_id) {
            webview
                .set_position(tauri::LogicalPosition::new(-9999.0, -9999.0))
                .map_err(|e| e.to_string())?;
            webview
                .set_size(tauri::LogicalSize::new(1.0, 1.0))
                .map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

/// Returns a tracking hint. Actual URL monitoring is done via `on_navigation`.
#[tauri::command]
pub async fn get_browser_url(app: AppHandle, tab_id: String) -> Result<String, String> {
    if let Some(window) = app.get_webview_window(&tab_id) {
        let _ = window.eval(r#"console.log('[OmniBus] Current URL:', window.location.href);"#);
        return Ok("URL logged to browser console".to_string());
    }
    if let Some(main_wv) = app.get_webview_window("main") {
        let window = main_wv.as_ref().window();
        if let Some(webview) = window.webviews().into_iter().find(|w| w.label() == &tab_id) {
            let _ = webview.eval(r#"console.log('[OmniBus] Current URL:', window.location.href);"#);
        }
    }
    Ok("URL tracking via navigation handler — check browser logs or use on_navigation events".to_string())
}
