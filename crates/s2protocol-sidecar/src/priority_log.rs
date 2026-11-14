//! Companion `[SCBOT_PRIORITY]` log discovery (plain logs + match ZIP archives) and parsing.

use crate::balance::GAME_LOOPS_PER_SECOND;
use crate::models::{PriorityLogSnapshot, round1};
use flate2::read::DeflateDecoder;
use std::io::Read;
use std::path::{Path, PathBuf};

fn companion_log_candidates(replay_path: &Path) -> ([PathBuf; 4], Option<PathBuf>) {
    let stem = replay_path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or_default();
    let parent = replay_path.parent().unwrap_or_else(|| Path::new("."));
    let priority_dir = parent.join("priority-logs");
    let direct = [
        parent.join(format!("{stem}_priority.log")),
        parent.join(format!("{stem}_stdout.log")),
        priority_dir.join(format!("{stem}-match.log")),
        priority_dir.join(format!("{stem}.log")),
    ];
    let zip_path = stem
        .split('_')
        .next()
        .filter(|id| !id.is_empty() && id.chars().all(|c| c.is_ascii_digit()))
        .map(|id| parent.join(format!("{id}_match_log.zip")));
    (direct, zip_path)
}

/// Fast existence check for whether a replay has an attachable companion priority log or match zip.
pub fn has_companion_priority_log(replay_path: &Path) -> bool {
    let (direct, zip_path) = companion_log_candidates(replay_path);
    direct.iter().any(|p| p.exists()) || zip_path.is_some_and(|p| p.exists())
}

/// Pure-Rust reader for companion `[SCBOT_PRIORITY]` logs and `<match_id>_match_log.zip` using `flate2`.
pub fn read_priority_snapshots_for_replay(replay_path: &Path) -> Vec<PriorityLogSnapshot> {
    let (direct, zip_path) = companion_log_candidates(replay_path);
    for cand in &direct {
        if let Ok(text) = std::fs::read_to_string(cand) {
            let parsed = parse_priority_log_lines(&text);
            if !parsed.is_empty() {
                return parsed;
            }
        }
    }

    if let Some(zip) = zip_path
        && let Ok(bytes) = std::fs::read(&zip)
        && let Some(text) = extract_stdout_from_zip_bytes(&bytes)
    {
        return parse_priority_log_lines(&text);
    }
    vec![]
}

pub fn extract_stdout_from_zip_bytes(zip_bytes: &[u8]) -> Option<String> {
    // Scan Central Directory at end of ZIP for exact compressed sizes (handles data descriptors cleanly!)
    let mut eocd_pos = None;
    let min_pos = zip_bytes.len().saturating_sub(65557);
    for i in (min_pos..=zip_bytes.len().saturating_sub(22)).rev() {
        if &zip_bytes[i..i + 4] == b"PK\x05\x06" {
            eocd_pos = Some(i);
            break;
        }
    }
    let eocd = eocd_pos?;
    let cd_entries = u16::from_le_bytes([zip_bytes[eocd + 10], zip_bytes[eocd + 11]]) as usize;
    let cd_offset = u32::from_le_bytes([
        zip_bytes[eocd + 16],
        zip_bytes[eocd + 17],
        zip_bytes[eocd + 18],
        zip_bytes[eocd + 19],
    ]) as usize;

    let mut pos = cd_offset;
    let mut combined = String::new();
    for _ in 0..cd_entries {
        if pos + 46 > zip_bytes.len() || &zip_bytes[pos..pos + 4] != b"PK\x01\x02" {
            break;
        }
        let method = u16::from_le_bytes([zip_bytes[pos + 10], zip_bytes[pos + 11]]);
        let comp_size = u32::from_le_bytes([
            zip_bytes[pos + 20],
            zip_bytes[pos + 21],
            zip_bytes[pos + 22],
            zip_bytes[pos + 23],
        ]) as usize;
        let name_len = u16::from_le_bytes([zip_bytes[pos + 28], zip_bytes[pos + 29]]) as usize;
        let extra_len = u16::from_le_bytes([zip_bytes[pos + 30], zip_bytes[pos + 31]]) as usize;
        let comment_len = u16::from_le_bytes([zip_bytes[pos + 32], zip_bytes[pos + 33]]) as usize;
        let lfh_offset = u32::from_le_bytes([
            zip_bytes[pos + 42],
            zip_bytes[pos + 43],
            zip_bytes[pos + 44],
            zip_bytes[pos + 45],
        ]) as usize;

        if pos + 46 + name_len > zip_bytes.len() {
            break;
        }
        let fname = String::from_utf8_lossy(&zip_bytes[pos + 46..pos + 46 + name_len]);
        pos += 46 + name_len + extra_len + comment_len;

        if !(fname.contains("stderr") || fname.contains("stdout") || fname.ends_with(".log")) {
            continue;
        }
        if lfh_offset + 30 > zip_bytes.len() || &zip_bytes[lfh_offset..lfh_offset + 4] != b"PK\x03\x04"
        {
            continue;
        }
        let lfh_name_len =
            u16::from_le_bytes([zip_bytes[lfh_offset + 26], zip_bytes[lfh_offset + 27]]) as usize;
        let lfh_extra_len =
            u16::from_le_bytes([zip_bytes[lfh_offset + 28], zip_bytes[lfh_offset + 29]]) as usize;
        let data_start = lfh_offset + 30 + lfh_name_len + lfh_extra_len;
        let data_end = (data_start + comp_size).min(zip_bytes.len());
        if data_start >= data_end {
            continue;
        }
        let slice = &zip_bytes[data_start..data_end];
        let mut content = Vec::new();
        if method == 0 {
            content.extend_from_slice(slice);
        } else if method == 8 {
            let mut decoder = DeflateDecoder::new(slice);
            let _ = decoder.read_to_end(&mut content);
        }
        if !content.is_empty() {
            let text = String::from_utf8_lossy(&content);
            if text.contains("[SCBOT_PRIORITY]") {
                combined.push_str(&text);
                combined.push('\n');
            }
        }
    }
    if combined.is_empty() {
        None
    } else {
        Some(combined)
    }
}

fn extract_kv<'a>(line: &'a str, key: &str) -> &'a str {
    let pat = format!("{key}=");
    let Some(start) = line.find(&pat) else {
        return "";
    };
    let rest = &line[start + pat.len()..];
    if rest.starts_with('(') {
        let mut depth = 0i32;
        for (i, ch) in rest.char_indices() {
            if ch == '(' {
                depth += 1;
            } else if ch == ')' {
                depth -= 1;
                if depth == 0 {
                    return &rest[..=i];
                }
            }
        }
        rest
    } else {
        rest.split_whitespace().next().unwrap_or("")
    }
}

pub fn parse_priority_log_lines(text: &str) -> Vec<PriorityLogSnapshot> {
    let mut out = Vec::new();
    for line in text.lines() {
        if !line.contains("[SCBOT_PRIORITY]") {
            continue;
        }
        let frame: i64 = extract_kv(line, "f").parse().unwrap_or(0);
        let race = extract_kv(line, "race").to_string();
        let bank = extract_kv(line, "bank").to_string();
        let sup = extract_kv(line, "sup").to_string();
        let bo = extract_kv(line, "bo").to_string();
        let saving_for = extract_kv(line, "saving_for").to_string();
        let approved_raw = extract_kv(line, "approved");
        let approved = if approved_raw.is_empty() {
            extract_kv(line, "sched").to_string()
        } else {
            approved_raw.to_string()
        };
        let escrow_queue = extract_kv(line, "escrow_queue").to_string();
        let blocked = extract_kv(line, "blocked").to_string();
        let step_ms: f32 = extract_kv(line, "step_ms")
            .trim_end_matches("ms")
            .parse()
            .unwrap_or(0.0);
        out.push(PriorityLogSnapshot {
            frame,
            sec: round1(frame as f32 / GAME_LOOPS_PER_SECOND as f32),
            race,
            bank,
            sup,
            bo,
            saving_for,
            approved,
            escrow_queue,
            blocked,
            step_ms,
        });
    }
    out.sort_by_key(|s| s.frame);
    out
}
