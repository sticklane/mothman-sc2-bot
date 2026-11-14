//! Replay catalog scanning, single-file analysis, and live HTTP/SSE sidecar server.

use crate::forensics::{
    CatalogEntry, ReplaySidecarBundle, analyze_replay_bytes, balance_units_db, clean_player_name,
    has_companion_priority_log, normalize_race, read_priority_snapshots_for_replay,
};
use s2protocol::basic_replay_data::SC2ReplayBasicData;
use std::collections::{BTreeMap, HashMap};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock, mpsc};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub struct SidecarState {
    pub started_at: Instant,
    pub watch_dirs: Vec<PathBuf>,
    pub ui_html_path: PathBuf,
    pub balance_versions: Vec<u32>,
    pub catalog: RwLock<Vec<CatalogEntry>>,
    pub replay_cache: RwLock<HashMap<String, Arc<String>>>,
    pub sse_clients: Mutex<Vec<mpsc::Sender<String>>>,
    pub requests_served: AtomicU64,
}

pub fn epoch_now_sec() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub fn replay_id_from_path(path: &Path) -> String {
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("replay");
    let first = stem.split('_').next().unwrap_or(stem);
    if !first.is_empty() && first.chars().all(|c| c.is_ascii_digit()) {
        first.to_string()
    } else {
        stem.chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                    c
                } else {
                    '_'
                }
            })
            .collect()
    }
}

pub fn inspect_catalog_entry(path: &Path) -> Option<CatalogEntry> {
    if path.extension().and_then(|e| e.to_str()) != Some("SC2Replay") {
        return None;
    }
    let meta = std::fs::metadata(path).ok()?;
    if meta.len() == 0 {
        return None;
    }
    let modified_epoch_sec = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let file_name = path.file_name()?.to_string_lossy().to_string();
    let source_dir = path
        .parent()
        .and_then(|p| p.file_name())
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "replays".to_string());
    let id = replay_id_from_path(path);
    let bytes = std::fs::read(path).ok()?;
    let basic = SC2ReplayBasicData::from_bytes(&file_name, 0, &bytes).ok()?;
    let p1 = basic.details.player_list.first();
    let p2 = basic.details.player_list.get(1);
    Some(CatalogEntry {
        id,
        file_name,
        source_dir,
        size_bytes: meta.len(),
        modified_epoch_sec,
        map_name: basic.details.title,
        p1_name: p1.map(|p| clean_player_name(&p.name)).unwrap_or_default(),
        p1_race: p1.map(|p| normalize_race(&p.race)).unwrap_or_default(),
        p1_result: p1
            .map(|p| format!("{:?}", p.result).trim_matches('"').to_string())
            .unwrap_or_default(),
        p2_name: p2.map(|p| clean_player_name(&p.name)).unwrap_or_default(),
        p2_race: p2.map(|p| normalize_race(&p.race)).unwrap_or_default(),
        p2_result: p2
            .map(|p| format!("{:?}", p.result).trim_matches('"').to_string())
            .unwrap_or_default(),
        protocol_version: basic.init_data.version,
        has_priority_log: has_companion_priority_log(path),
        full_path: path.to_path_buf(),
    })
}

pub fn scan_catalog(dirs: &[PathBuf]) -> Vec<CatalogEntry> {
    let mut by_id: BTreeMap<String, CatalogEntry> = BTreeMap::new();
    for dir in dirs {
        let Ok(rd) = std::fs::read_dir(dir) else {
            continue;
        };
        for entry in rd.flatten() {
            let path = entry.path();
            if let Some(cat) = inspect_catalog_entry(&path) {
                let replace = by_id
                    .get(&cat.id)
                    .is_none_or(|prev| cat.modified_epoch_sec >= prev.modified_epoch_sec);
                if replace {
                    by_id.insert(cat.id.clone(), cat);
                }
            }
        }
    }
    let mut list: Vec<CatalogEntry> = by_id.into_values().collect();
    list.sort_by(|a, b| {
        let an = a.id.parse::<u64>().ok();
        let bn = b.id.parse::<u64>().ok();
        match (an, bn) {
            (Some(x), Some(y)) => y.cmp(&x),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => b
                .modified_epoch_sec
                .cmp(&a.modified_epoch_sec)
                .then_with(|| a.id.cmp(&b.id)),
        }
    });
    list
}

pub fn analyze_replay_file(
    path: &Path,
    max_frames: usize,
    summary_only: bool,
) -> Result<ReplaySidecarBundle, String> {
    let bytes = std::fs::read(path)
        .map_err(|e| format!("Failed to read replay {}: {e}", path.display()))?;
    let file_name = path
        .file_name()
        .map(|f| f.to_string_lossy().to_string())
        .unwrap_or_else(|| "replay.SC2Replay".to_string());
    let id = replay_id_from_path(path);
    let prio = read_priority_snapshots_for_replay(path);
    let mut bundle = analyze_replay_bytes(&id, &file_name, &bytes, prio, max_frames)?;
    if summary_only {
        bundle.frames.clear();
        bundle.static_objects.clear();
        bundle.priority_snapshots.clear();
    }
    Ok(bundle)
}

pub fn default_repo_root() -> PathBuf {
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    if cwd.join("replays").is_dir() {
        return cwd;
    }
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    if let Some(root) = manifest.parent().and_then(|p| p.parent())
        && root.join("replays").is_dir()
    {
        return root.to_path_buf();
    }
    cwd
}

pub fn broadcast_sse(state: &SidecarState, event_name: &str, payload_json: &str) {
    let msg = format!("event: {event_name}\ndata: {payload_json}\n\n");
    if let Ok(mut clients) = state.sse_clients.lock() {
        clients.retain(|tx| tx.send(msg.clone()).is_ok());
    }
}

pub fn write_http_response(
    stream: &mut TcpStream,
    status: &str,
    content_type: &str,
    body: &[u8],
) -> std::io::Result<()> {
    let header = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(header.as_bytes())?;
    stream.write_all(body)?;
    stream.flush()
}

pub fn url_decode_simple(raw: &str) -> String {
    let mut out = Vec::with_capacity(raw.len());
    let bytes = raw.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let Ok(hex) = std::str::from_utf8(&bytes[i + 1..i + 3])
            && let Ok(val) = u8::from_str_radix(hex, 16)
        {
            out.push(val);
            i += 3;
            continue;
        } else if bytes[i] == b'+' {
            out.push(b' ');
        } else {
            out.push(bytes[i]);
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

pub fn handle_client(mut stream: TcpStream, state: Arc<SidecarState>) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(15)));
    let Ok(cloned) = stream.try_clone() else {
        return;
    };
    let mut reader = BufReader::new(cloned);
    let mut req_line = String::new();
    if reader.read_line(&mut req_line).unwrap_or(0) == 0 {
        return;
    }
    let parts: Vec<&str> = req_line.split_whitespace().collect();
    if parts.len() < 2 {
        return;
    }
    let method = parts[0];
    let full_target = parts[1];
    let (path, query) = full_target.split_once('?').unwrap_or((full_target, ""));

    let mut content_length: usize = 0;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap_or(0) == 0 {
            break;
        }
        let trimmed = line.trim_end();
        if trimmed.is_empty() {
            break;
        }
        if let Some((k, v)) = trimmed.split_once(':')
            && k.trim().eq_ignore_ascii_case("content-length")
        {
            content_length = v.trim().parse().unwrap_or(0);
        }
    }

    state.requests_served.fetch_add(1, Ordering::Relaxed);

    if method == "OPTIONS" {
        let _ = write_http_response(&mut stream, "204 No Content", "text/plain", b"");
        return;
    }

    if method == "GET" && path == "/api/events" {
        let _ = stream.set_read_timeout(None);
        let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n";
        if stream.write_all(header.as_bytes()).is_err() {
            return;
        }
        let cat_len = state.catalog.read().map(|c| c.len()).unwrap_or(0);
        let hello =
            format!("event: connected\ndata: {{\"ok\":true,\"catalog_count\":{cat_len}}}\n\n");
        if stream.write_all(hello.as_bytes()).is_err() || stream.flush().is_err() {
            return;
        }
        let (tx, rx) = mpsc::channel::<String>();
        if let Ok(mut clients) = state.sse_clients.lock() {
            clients.push(tx);
        }
        while let Ok(msg) = rx.recv() {
            if stream.write_all(msg.as_bytes()).is_err() || stream.flush().is_err() {
                break;
            }
        }
        return;
    }

    if method == "GET" && (path == "/" || path == "/sidecar" || path == "/index.html") {
        match std::fs::read(&state.ui_html_path) {
            Ok(html) => {
                let _ = write_http_response(
                    &mut stream,
                    "200 OK",
                    "text/html; charset=utf-8",
                    &html,
                );
            }
            Err(e) => {
                let msg = format!("sidecar-ui.html not found ({e})");
                let _ = write_http_response(
                    &mut stream,
                    "404 Not Found",
                    "text/plain; charset=utf-8",
                    msg.as_bytes(),
                );
            }
        }
        return;
    }

    if method == "GET" && path == "/api/status" {
        let cat_count = state.catalog.read().map(|c| c.len()).unwrap_or(0);
        let cached_count = state.replay_cache.read().map(|c| c.len()).unwrap_or(0);
        let sse_count = state.sse_clients.lock().map(|c| c.len()).unwrap_or(0);
        let status_json = serde_json::json!({
            "ok": true,
            "service": "s2protocol-sidecar",
            "s2protocol_version": "5.1.0",
            "ai_arena_75689_supported": state.balance_versions.contains(&75689),
            "balance_versions": state.balance_versions,
            "uptime_sec": state.started_at.elapsed().as_secs(),
            "catalog_count": cat_count,
            "cached_replays": cached_count,
            "sse_clients": sse_count,
            "requests_served": state.requests_served.load(Ordering::Relaxed),
            "watched_dirs": state.watch_dirs.iter().map(|d| d.file_name().unwrap_or_default().to_string_lossy().to_string()).collect::<Vec<_>>(),
        });
        let body = serde_json::to_vec(&status_json).unwrap_or_default();
        let _ = write_http_response(&mut stream, "200 OK", "application/json", &body);
        return;
    }

    if method == "GET" && path == "/api/catalog" {
        let list = state.catalog.read().map(|c| c.clone()).unwrap_or_default();
        let body = serde_json::to_vec(&list).unwrap_or_default();
        let _ = write_http_response(&mut stream, "200 OK", "application/json", &body);
        return;
    }

    if method == "GET"
        && let Some(raw_id) = path.strip_prefix("/api/replay/")
    {
        let id = url_decode_simple(raw_id);
        if let Ok(cache) = state.replay_cache.read()
            && let Some(cached_json) = cache.get(&id)
        {
            let _ = write_http_response(
                &mut stream,
                "200 OK",
                "application/json",
                cached_json.as_bytes(),
            );
            return;
        }

        let found_path = state.catalog.read().ok().and_then(|cat| {
            cat.iter()
                .find(|e| e.id == id || e.file_name == id)
                .map(|e| (e.id.clone(), e.full_path.clone()))
        });
        let Some((canon_id, full_path)) = found_path else {
            let err = serde_json::json!({ "ok": false, "error": format!("Replay '{id}' not found in catalog") });
            let _ = write_http_response(
                &mut stream,
                "404 Not Found",
                "application/json",
                err.to_string().as_bytes(),
            );
            return;
        };

        match analyze_replay_file(&full_path, 260, false) {
            Ok(bundle) => {
                let json_str = Arc::new(serde_json::to_string(&bundle).unwrap_or_default());
                if let Ok(mut cache) = state.replay_cache.write() {
                    cache.insert(canon_id, Arc::clone(&json_str));
                }
                let _ = write_http_response(
                    &mut stream,
                    "200 OK",
                    "application/json",
                    json_str.as_bytes(),
                );
            }
            Err(e) => {
                let err = serde_json::json!({ "ok": false, "error": e });
                let _ = write_http_response(
                    &mut stream,
                    "500 Internal Server Error",
                    "application/json",
                    err.to_string().as_bytes(),
                );
            }
        }
        return;
    }

    if method == "POST" && path == "/api/analyze-bytes" {
        if content_length == 0 || content_length > 25 * 1024 * 1024 {
            let err = serde_json::json!({ "ok": false, "error": "Invalid replay upload size (must be >0 and <=25MB)" });
            let _ = write_http_response(
                &mut stream,
                "400 Bad Request",
                "application/json",
                err.to_string().as_bytes(),
            );
            return;
        }
        let mut body_bytes = vec![0u8; content_length];
        if reader.read_exact(&mut body_bytes).is_err() {
            let err =
                serde_json::json!({ "ok": false, "error": "Failed reading uploaded replay bytes" });
            let _ = write_http_response(
                &mut stream,
                "400 Bad Request",
                "application/json",
                err.to_string().as_bytes(),
            );
            return;
        }
        let file_name = query
            .split('&')
            .find_map(|kv| kv.strip_prefix("name="))
            .map(url_decode_simple)
            .unwrap_or_else(|| format!("uploaded_{}.SC2Replay", epoch_now_sec()));
        let id = replay_id_from_path(Path::new(&file_name));
        match analyze_replay_bytes(&id, &file_name, &body_bytes, vec![], 260) {
            Ok(bundle) => {
                let json_str = Arc::new(serde_json::to_string(&bundle).unwrap_or_default());
                if let Ok(mut cache) = state.replay_cache.write() {
                    cache.insert(id, Arc::clone(&json_str));
                }
                let _ = write_http_response(
                    &mut stream,
                    "200 OK",
                    "application/json",
                    json_str.as_bytes(),
                );
            }
            Err(e) => {
                let err = serde_json::json!({ "ok": false, "error": e });
                let _ = write_http_response(
                    &mut stream,
                    "422 Unprocessable Entity",
                    "application/json",
                    err.to_string().as_bytes(),
                );
            }
        }
        return;
    }

    let err = serde_json::json!({ "ok": false, "error": format!("Unknown route: {method} {path}") });
    let _ = write_http_response(
        &mut stream,
        "404 Not Found",
        "application/json",
        err.to_string().as_bytes(),
    );
}

pub fn run_server(
    host: &str,
    port: u16,
    watch_dirs: Vec<PathBuf>,
    ui_html_path: PathBuf,
) -> Result<(), String> {
    let db = balance_units_db()?;
    let mut balance_versions: Vec<u32> = db.keys().copied().collect();
    balance_versions.sort_unstable();

    let initial_catalog = scan_catalog(&watch_dirs);
    let state = Arc::new(SidecarState {
        started_at: Instant::now(),
        watch_dirs: watch_dirs.clone(),
        ui_html_path,
        balance_versions,
        catalog: RwLock::new(initial_catalog.clone()),
        replay_cache: RwLock::new(HashMap::new()),
        sse_clients: Mutex::new(Vec::new()),
        requests_served: AtomicU64::new(0),
    });

    let addr = format!("{host}:{port}");
    let listener =
        TcpListener::bind(&addr).map_err(|e| format!("Failed binding {addr}: {e}"))?;
    eprintln!(
        "[s2protocol-sidecar] Listening on http://{addr} | catalog={} replays | protocol 75689 ready",
        initial_catalog.len()
    );

    // Background directory watcher + SSE heartbeat thread
    let watcher_state = Arc::clone(&state);
    std::thread::spawn(move || {
        let mut tick = 0u64;
        loop {
            std::thread::sleep(Duration::from_secs(4));
            tick += 1;
            let updated = scan_catalog(&watcher_state.watch_dirs);
            let changed = watcher_state
                .catalog
                .read()
                .map(|old| {
                    old.len() != updated.len()
                        || old.first().map(|e| (&e.id, e.modified_epoch_sec))
                            != updated.first().map(|e| (&e.id, e.modified_epoch_sec))
                })
                .unwrap_or(false);
            if changed {
                let count = updated.len();
                let newest = updated.first().map(|e| e.id.clone()).unwrap_or_default();
                if let Ok(mut w) = watcher_state.catalog.write() {
                    *w = updated;
                }
                let payload = serde_json::json!({
                    "catalog_count": count,
                    "newest_id": newest,
                    "epoch_sec": epoch_now_sec()
                });
                broadcast_sse(&watcher_state, "catalog-updated", &payload.to_string());
            } else if tick.is_multiple_of(3) {
                let payload = serde_json::json!({
                    "uptime_sec": watcher_state.started_at.elapsed().as_secs(),
                    "epoch_sec": epoch_now_sec()
                });
                broadcast_sse(&watcher_state, "heartbeat", &payload.to_string());
            }
        }
    });

    for stream in listener.incoming().flatten() {
        let st = Arc::clone(&state);
        std::thread::spawn(move || handle_client(stream, st));
    }
    Ok(())
}
