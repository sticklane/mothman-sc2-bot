//! Antigravity Sidecar for `sebosp/s2protocol-rs` (`s2protocol = "5.1.0"`).
//!
//! Modes:
//! 1. Live HTTP + Server-Sent Events (SSE) Sidecar Daemon (`--serve --port 4322`):
//!    - `GET /` or `GET /sidecar` : Interactive Enhanced Minimap & Forensic UI (`sidecar-ui.html`)
//!    - `GET /api/status`         : Health, uptime, loaded `BalanceData` versions (incl. `75689`), catalog count
//!    - `GET /api/catalog`        : Sorted `.SC2Replay` catalog across watched replay directories
//!    - `GET /api/replay/<id>`    : Cached `SC2EventIterator` Enhanced Minimap frames + forensic report JSON
//!    - `POST /api/analyze-bytes` : In-memory `.SC2Replay` drag-and-drop analyzer (`?name=foo.SC2Replay`)
//!    - `GET /api/events`         : SSE stream (`catalog-updated` + `heartbeat`)
//! 2. Fast CLI Bridge for Pure-Racket `tools/analyze-aiarena-replays.rkt`:
//!    - `--analyze <file.SC2Replay> [--max-frames N] [--summary-only] [--pretty]`
//!    - `--batch-dir <dir> [--limit N] [--summary-only] [--out <file.json>]`
//!    - `--export-ui-bundle <out.json> [--dirs d1,d2] [--ids id1,id2] [--limit 5] [--max-frames 140]`

mod analytics;
mod balance;
mod forensics;
mod models;
mod priority_log;
mod server;

pub use forensics::*;
pub use server::analyze_replay_file;

use server::{default_repo_root, epoch_now_sec, run_server, scan_catalog};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

fn resolve_default_port_from(primary: Option<&str>, secondary: Option<&str>) -> u16 {
    [primary, secondary]
        .into_iter()
        .flatten()
        .find_map(|v| v.trim().parse::<u16>().ok())
        .unwrap_or(4322)
}

fn resolve_default_port() -> u16 {
    let p = std::env::var("ANTIGRAVITY_SIDECAR_WEB_PORT").ok();
    let s = std::env::var("PORT").ok();
    resolve_default_port_from(p.as_deref(), s.as_deref())
}

fn default_watch_dirs(root: &Path) -> Vec<PathBuf> {
    vec![
        root.join("replays/aiarena_matches"),
        root.join("replays/aiarena_live_cache"),
        root.join("replays/local_real_matches"),
        root.join("replays"),
    ]
}

fn resolve_ui_html_path(root: &Path, ui_arg: Option<String>) -> PathBuf {
    ui_arg.map(PathBuf::from).unwrap_or_else(|| {
        let nested = root.join("crates/s2protocol-sidecar/sidecar-ui.html");
        if nested.exists() {
            nested
        } else {
            let local = root.join("sidecar-ui.html");
            if local.exists() {
                local
            } else {
                PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("sidecar-ui.html")
            }
        }
    })
}

fn print_usage() {
    eprintln!(
        "Usage:
  s2protocol-sidecar --serve [--host 127.0.0.1] [--port 4322] [--dirs dir1,dir2] [--ui path/to/sidecar-ui.html]
  s2protocol-sidecar --analyze <file.SC2Replay> [--max-frames 240] [--summary-only] [--pretty]
  s2protocol-sidecar --batch-dir <dir> [--limit 20] [--summary-only] [--out report.json]
  s2protocol-sidecar --export-ui-bundle <out.json> [--dirs dir1,dir2] [--ids id1,id2] [--limit 5] [--max-frames 140]"
    );
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|a| a == "-h" || a == "--help") {
        print_usage();
        return;
    }

    let mut mode = "serve";
    let mut target_path = String::new();
    let mut out_path: Option<String> = None;
    let mut host = "127.0.0.1".to_string();
    let mut port: u16 = resolve_default_port();
    let mut dirs_arg: Option<String> = None;
    let mut ids_arg: Option<String> = None;
    let mut ui_arg: Option<String> = None;
    let mut max_frames: usize = 240;
    let mut limit: usize = 20;
    let mut summary_only = false;
    let mut pretty = false;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--serve" => mode = "serve",
            "--analyze" => {
                mode = "analyze";
                i += 1;
                target_path = args.get(i).cloned().unwrap_or_default();
            }
            "--batch-dir" => {
                mode = "batch";
                i += 1;
                target_path = args.get(i).cloned().unwrap_or_default();
            }
            "--export-ui-bundle" => {
                mode = "export-bundle";
                i += 1;
                target_path = args.get(i).cloned().unwrap_or_default();
            }
            "--host" => {
                i += 1;
                host = args.get(i).cloned().unwrap_or(host);
            }
            "--port" => {
                i += 1;
                port = args.get(i).and_then(|s| s.parse().ok()).unwrap_or(port);
            }
            "--dirs" => {
                i += 1;
                dirs_arg = args.get(i).cloned();
            }
            "--ids" => {
                i += 1;
                ids_arg = args.get(i).cloned();
            }
            "--ui" => {
                i += 1;
                ui_arg = args.get(i).cloned();
            }
            "--out" => {
                i += 1;
                out_path = args.get(i).cloned();
            }
            "--max-frames" => {
                i += 1;
                max_frames = args
                    .get(i)
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(240);
            }
            "--limit" => {
                i += 1;
                limit = args.get(i).and_then(|s| s.parse().ok()).unwrap_or(20);
            }
            "--summary-only" => summary_only = true,
            "--pretty" => pretty = true,
            _ => {}
        }
        i += 1;
    }

    let root = default_repo_root();
    let watch_dirs: Vec<PathBuf> = match dirs_arg {
        Some(raw) => raw.split(',').map(PathBuf::from).collect(),
        None => default_watch_dirs(&root),
    };
    let ui_html_path = resolve_ui_html_path(&root, ui_arg);

    match mode {
        "analyze" => {
            if target_path.is_empty() {
                print_usage();
                std::process::exit(2);
            }
            match analyze_replay_file(Path::new(&target_path), max_frames, summary_only) {
                Ok(bundle) => {
                    let s = if pretty {
                        serde_json::to_string_pretty(&bundle)
                    } else {
                        serde_json::to_string(&bundle)
                    }
                    .unwrap_or_default();
                    println!("{s}");
                }
                Err(e) => {
                    eprintln!("Error: {e}");
                    std::process::exit(1);
                }
            }
        }
        "batch" => {
            if target_path.is_empty() {
                print_usage();
                std::process::exit(2);
            }
            let cat = scan_catalog(&[PathBuf::from(&target_path)]);
            let mut results = Vec::new();
            for entry in cat.into_iter().take(limit) {
                match analyze_replay_file(&entry.full_path, max_frames, summary_only) {
                    Ok(b) => results.push(b),
                    Err(e) => eprintln!("Skipping {}: {e}", entry.file_name),
                }
            }
            let s = if pretty {
                serde_json::to_string_pretty(&results)
            } else {
                serde_json::to_string(&results)
            }
            .unwrap_or_default();
            if let Some(out) = out_path {
                std::fs::write(&out, s).expect("Failed writing batch output");
            } else {
                println!("{s}");
            }
        }
        "export-bundle" => {
            if target_path.is_empty() {
                print_usage();
                std::process::exit(2);
            }
            let catalog = scan_catalog(&watch_dirs);
            let wanted_ids: Vec<String> = ids_arg
                .map(|s| {
                    s.split(',')
                        .map(|x| x.trim().to_string())
                        .filter(|x| !x.is_empty())
                        .collect()
                })
                .unwrap_or_default();

            let selected: Vec<&CatalogEntry> = if wanted_ids.is_empty() {
                catalog.iter().take(limit).collect()
            } else {
                wanted_ids
                    .iter()
                    .filter_map(|wid| catalog.iter().find(|c| &c.id == wid || &c.file_name == wid))
                    .collect()
            };

            let mut replays = BTreeMap::new();
            for entry in selected {
                match analyze_replay_file(&entry.full_path, max_frames.min(180), false) {
                    Ok(b) => {
                        replays.insert(entry.id.clone(), b);
                    }
                    Err(e) => eprintln!("Warning: failed exporting {}: {e}", entry.file_name),
                }
            }
            let preload = UiPreloadBundle {
                generated_at_epoch_sec: epoch_now_sec(),
                s2protocol_version: "5.1.0".to_string(),
                catalog,
                replays,
            };
            let json = serde_json::to_string(&preload).expect("Failed serializing UI bundle");
            std::fs::write(&target_path, json).expect("Failed writing UI bundle");
            eprintln!(
                "[s2protocol-sidecar] Exported UI preload bundle to {} ({} full timelines, {} catalog entries)",
                target_path,
                preload.replays.len(),
                preload.catalog.len()
            );
        }
        _ => {
            if let Err(e) = run_server(&host, port, watch_dirs, ui_html_path) {
                eprintln!("Server error: {e}");
                std::process::exit(1);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use forensics::{
        compute_turning_points, format_counts_map, has_companion_priority_log, is_morph_death,
        normalize_race, parse_priority_log_lines, read_priority_snapshots_for_replay,
        win_chance_coeffs,
    };

    #[test]
    fn test_clean_player_name_and_race() {
        assert_eq!(
            clean_player_name("&lt;CLAN&gt;<sp/>Mothman-X"),
            "Mothman-X"
        );
        assert_eq!(clean_player_name("<Tag>Creepy_strategies"), "Creepy_strategies");
        assert_eq!(normalize_race("프로토스"), "Protoss");
        assert_eq!(normalize_race("Terr"), "Terran");
        assert_eq!(normalize_race("Zerg"), "Zerg");
    }

    #[test]
    fn test_morph_death_filter() {
        assert!(is_morph_death("Drone", false));
        assert!(is_morph_death("HighTemplar", false));
        assert!(is_morph_death("DarkTemplar", false));
        assert!(!is_morph_death("Drone", true));
        assert!(!is_morph_death("Marine", false));
        assert!(!is_morph_death("Zergling", false));
    }

    #[test]
    fn test_priority_log_parser() {
        let sample = "[SCBOT_PRIORITY] f=672 race=Zerg bank=250M/0G sup=19/22 bo=done saving_for=(spawning-pool@115.0) approved=(drone overlord) escrow_queue=(spawning-pool:200M) blocked=() step_ms=1.4ms\n";
        let snaps = parse_priority_log_lines(sample);
        assert_eq!(snaps.len(), 1);
        assert_eq!(snaps[0].frame, 672);
        assert_eq!(snaps[0].race, "Zerg");
        assert_eq!(snaps[0].saving_for, "(spawning-pool@115.0)");
        assert_eq!(snaps[0].approved, "(drone overlord)");
        assert!((snaps[0].step_ms - 1.4).abs() < 0.01);
    }

    #[test]
    fn test_priority_logs_dir_discovery_with_temp_files() {
        let uniq = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let base_dir = std::env::temp_dir().join(format!(
            "s2protocol_sidecar_prio_test_{}_{}",
            std::process::id(),
            uniq
        ));
        let prio_dir = base_dir.join("priority-logs");
        std::fs::create_dir_all(&prio_dir).unwrap();

        let replay_match = base_dir.join("Mothman-P-test.SC2Replay");
        let replay_plain = base_dir.join("Mothman-X-test.SC2Replay");
        let replay_none = base_dir.join("Mothman-Missing.SC2Replay");
        std::fs::write(&replay_match, b"dummy").unwrap();
        std::fs::write(&replay_plain, b"dummy").unwrap();
        std::fs::write(&replay_none, b"dummy").unwrap();

        std::fs::write(
            prio_dir.join("Mothman-P-test-match.log"),
            "[SCBOT_PRIORITY] f=112 race=Protoss bank=150M/0G sup=14/15 bo=pylon saving_for=none sched=(probe@90.0) escrow_queue=() step_ms=2.1\n",
        )
        .unwrap();
        std::fs::write(
            prio_dir.join("Mothman-X-test.log"),
            "[SCBOT_PRIORITY] f=224 race=Zerg bank=200M/0G sup=15/16 bo=done saving_for=none approved=(drone) escrow_queue=() blocked=() step_ms=1.2ms\n",
        )
        .unwrap();

        assert!(has_companion_priority_log(&replay_match));
        assert!(has_companion_priority_log(&replay_plain));
        assert!(!has_companion_priority_log(&replay_none));

        let p_snaps = read_priority_snapshots_for_replay(&replay_match);
        assert_eq!(p_snaps.len(), 1);
        assert_eq!(p_snaps[0].frame, 112);
        assert_eq!(p_snaps[0].race, "Protoss");
        assert_eq!(p_snaps[0].approved, "(probe@90.0)");

        let x_snaps = read_priority_snapshots_for_replay(&replay_plain);
        assert_eq!(x_snaps.len(), 1);
        assert_eq!(x_snaps[0].frame, 224);
        assert_eq!(x_snaps[0].race, "Zerg");

        assert!(read_priority_snapshots_for_replay(&replay_none).is_empty());

        let _ = std::fs::remove_dir_all(&base_dir);
    }

    #[test]
    fn test_module_boundary_reexports_and_helpers() {
        // Verify balance + analytics + models re-exports via `forensics` and `crate::*`
        assert_eq!(forensics::base_unit_name("SiegeTankSieged"), "SiegeTank");
        let coeffs = win_chance_coeffs(3.0);
        assert!((coeffs[0] - 0.231).abs() < 1e-4);

        let mut counts = BTreeMap::new();
        counts.insert("Zealot".to_string(), 3);
        counts.insert("Stalker".to_string(), 2);
        assert_eq!(format_counts_map(&counts), "2xStalker,3xZealot");

        assert!(compute_turning_points(&[], &[]).is_empty());
        assert_eq!(resolve_default_port_from(Some("8080"), Some("9000")), 8080);
        assert_eq!(resolve_default_port_from(Some("bad"), Some("5050")), 5050);
        assert_eq!(resolve_default_port_from(None, None), 4322);

        let root = Path::new("/example/repo");
        let dirs = default_watch_dirs(root);
        assert_eq!(dirs.len(), 4);
        assert_eq!(dirs[0], root.join("replays/aiarena_matches"));
        assert_eq!(dirs[1], root.join("replays/aiarena_live_cache"));
        assert_eq!(dirs[2], root.join("replays/local_real_matches"));
        assert_eq!(dirs[3], root.join("replays"));
    }

    #[test]
    fn test_balance_db_includes_ai_arena_75689() {
        let db = balance_units_db().expect("embedded BalanceData must load");
        assert!(
            db.contains_key(&75689),
            "s2protocol 5.1.0 must include AI Arena protocol 75689"
        );
    }

    #[test]
    fn test_real_replay_state_machine_if_present() {
        let root = default_repo_root();
        let cat = scan_catalog(&default_watch_dirs(&root));
        if let Some(first) = cat.first() {
            let bundle = analyze_replay_file(&first.full_path, 90, false)
                .expect("Real AI Arena replay must parse cleanly");
            assert_eq!(bundle.players.len(), 2);
            assert!(!bundle.frames.is_empty());
            assert!(bundle.protocol_version > 0);
        }
        let top_replay = root.join("replays/Mothman-P-full.SC2Replay");
        if top_replay.exists() {
            assert!(has_companion_priority_log(&top_replay));
            let snaps = read_priority_snapshots_for_replay(&top_replay);
            assert!(!snaps.is_empty());
        }
    }
}
