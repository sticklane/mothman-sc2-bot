//! Terrain and map-geometry extraction for `s2protocol-sidecar`.
//!
//! Uses `s2protocol::cache_handles` when `.s2ma` depots or local `.SC2Map` MPQ archives
//! are available (`MapInfo`, `T3HeightMap`, and `Minimap.tga`), and always synthesizes
//! base/expansion plateaus from replay resource clusters so tactical map context renders
//! cleanly even for headless AI Arena replays without depot cache handles.

use crate::models::StaticMapObject;
use flate2::Compression;
use flate2::write::ZlibEncoder;
use s2protocol::basic_replay_data::SC2ReplayBasicData;
use s2protocol::cache_handles::{CacheCollection, CacheHandle};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TerrainOverlay {
    /// `"mpq_s2ma"` | `"local_sc2map"` | `"inferred"`
    pub source: String,
    pub width: usize,
    pub height: usize,
    /// `[left, bottom, right, top]` in map tile coordinates.
    pub playable_bounds: [f32; 4],
    /// Playable elevation tiers (`0..=6`), row-major bottom-to-top (`y=bottom..top`).
    pub heights: Vec<u8>,
    /// Optional playable-cropped Blizzard `Minimap.tga` encoded as base64 PNG.
    pub minimap_png_b64: Option<String>,
    /// Detected mineral/geyser base clusters `[cx, cy, radius]`.
    pub base_plateaus: Vec<[f32; 3]>,
}

pub fn normalize_map_slug(name: &str) -> String {
    name.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .flat_map(|c| c.to_lowercase())
        .collect()
}

/// Clusters mineral fields (`kind=0`) and vespene geysers (`kind=1`) into expansion plateaus.
pub fn cluster_base_plateaus(static_objects: &[StaticMapObject]) -> Vec<[f32; 3]> {
    let nodes: Vec<(f32, f32)> = static_objects
        .iter()
        .filter(|o| o.kind == 0 || o.kind == 1)
        .map(|o| (o.x, o.y))
        .collect();
    let mut visited = vec![false; nodes.len()];
    let mut plateaus = Vec::new();
    let merge_r2 = 13.0f32 * 13.0f32;

    for i in 0..nodes.len() {
        if visited[i] {
            continue;
        }
        visited[i] = true;
        let mut stack = vec![i];
        let mut group = Vec::new();
        while let Some(cur) = stack.pop() {
            group.push(nodes[cur]);
            for j in 0..nodes.len() {
                if visited[j] {
                    continue;
                }
                let dx = nodes[cur].0 - nodes[j].0;
                let dy = nodes[cur].1 - nodes[j].1;
                if dx * dx + dy * dy <= merge_r2 {
                    visited[j] = true;
                    stack.push(j);
                }
            }
        }
        if group.len() < 4 {
            continue;
        }
        let n = group.len() as f32;
        let cx = group.iter().map(|p| p.0).sum::<f32>() / n;
        let cy = group.iter().map(|p| p.1).sum::<f32>() / n;
        let max_d = group
            .iter()
            .map(|p| ((p.0 - cx).powi(2) + (p.1 - cy).powi(2)).sqrt())
            .fold(6.0f32, f32::max);
        plateaus.push([
            (cx * 10.0).round() / 10.0,
            (cy * 10.0).round() / 10.0,
            ((max_d + 3.0).clamp(7.0, 14.0) * 10.0).round() / 10.0,
        ]);
    }
    plateaus
}

fn encode_b64(bytes: &[u8]) -> String {
    const LUT: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as usize;
        let b1 = *chunk.get(1).unwrap_or(&0) as usize;
        let b2 = *chunk.get(2).unwrap_or(&0) as usize;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(LUT[(n >> 18) & 63] as char);
        out.push(LUT[(n >> 12) & 63] as char);
        out.push(if chunk.len() > 1 {
            LUT[(n >> 6) & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            LUT[n & 63] as char
        } else {
            '='
        });
    }
    out
}

fn crc32_ieee(data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for &b in data {
        crc ^= b as u32;
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    !crc
}

fn push_png_chunk(out: &mut Vec<u8>, tag: &[u8; 4], payload: &[u8]) {
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    let crc_start = out.len();
    out.extend_from_slice(tag);
    out.extend_from_slice(payload);
    let crc = crc32_ieee(&out[crc_start..]);
    out.extend_from_slice(&crc.to_be_bytes());
}

/// Encodes RGBA8 pixel data into a lossless PNG and returns base64.
pub fn encode_png_rgba_b64(width: u32, height: u32, rgba: &[u8]) -> Option<String> {
    let row_bytes = width.checked_mul(4)? as usize;
    let expected = row_bytes.checked_mul(height as usize)?;
    if width == 0 || height == 0 || rgba.len() < expected {
        return None;
    }

    let mut raw = Vec::with_capacity((row_bytes + 1) * height as usize);
    for y in 0..height as usize {
        raw.push(0); // Filter type 0 (None)
        let row = &rgba[y * row_bytes..(y + 1) * row_bytes];
        raw.extend_from_slice(row);
    }

    let mut encoder = ZlibEncoder::new(Vec::new(), Compression::fast());
    encoder.write_all(&raw).ok()?;
    let idat = encoder.finish().ok()?;

    let mut png = Vec::with_capacity(idat.len() + 64);
    png.extend_from_slice(&[137, 80, 78, 71, 13, 10, 26, 10]);

    let mut ihdr = Vec::with_capacity(13);
    ihdr.extend_from_slice(&width.to_be_bytes());
    ihdr.extend_from_slice(&height.to_be_bytes());
    ihdr.push(8); // bit depth
    ihdr.push(6); // RGBA
    ihdr.push(0); // compression
    ihdr.push(0); // filter
    ihdr.push(0); // interlace
    push_png_chunk(&mut png, b"IHDR", &ihdr);
    push_png_chunk(&mut png, b"IDAT", &idat);
    push_png_chunk(&mut png, b"IEND", &[]);
    Some(encode_b64(&png))
}

fn resolve_s2ma_cache_dir() -> PathBuf {
    if let Ok(env_dir) = std::env::var("S2_MAP_CACHE_DIR")
        && !env_dir.trim().is_empty()
    {
        return PathBuf::from(env_dir);
    }
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    if cwd.join("replays").is_dir() {
        return cwd.join("replays/.s2ma_cache");
    }
    cwd.join(".s2ma_cache")
}

fn find_local_sc2map(map_title: &str) -> Option<PathBuf> {
    let target_slug = normalize_map_slug(map_title);
    if target_slug.is_empty() {
        return None;
    }
    let mut dirs = vec![
        PathBuf::from("replays/maps"),
        PathBuf::from("maps"),
    ];
    if let Ok(sc2path) = std::env::var("SC2PATH") {
        dirs.push(PathBuf::from(sc2path).join("Maps"));
    }
    for dir in dirs {
        let Ok(rd) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in rd.flatten() {
            let p = entry.path();
            let ext = p
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            if ext != "sc2map" && ext != "s2ma" {
                continue;
            }
            let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("");
            if normalize_map_slug(stem) == target_slug {
                return Some(p);
            }
        }
    }
    None
}

fn ensure_s2ma_present(cache_dir: &Path, region: &str, ext: &str, handle: &str) -> bool {
    let target = cache_dir.join(format!("{handle}.s2ma"));
    if target.exists() {
        return true;
    }
    let miss_marker = cache_dir.join(format!("{handle}.miss"));
    if miss_marker.exists() || std::env::var("S2_NO_NET").as_deref() == Ok("1") {
        return false;
    }
    if std::fs::create_dir_all(cache_dir).is_err() {
        return false;
    }
    let ch = CacheHandle::new(region, ext, handle);
    let tmp = cache_dir.join(format!("{handle}.s2ma.part"));
    let ok = Command::new("curl")
        .args(["-fsSL", "--max-time", "5", "-o"])
        .arg(&tmp)
        .arg(ch.url())
        .status()
        .is_ok_and(|s| s.success() && std::fs::metadata(&tmp).is_ok_and(|m| m.len() > 256));
    if ok {
        if std::fs::rename(&tmp, &target).is_ok() {
            return true;
        }
    } else {
        let _ = std::fs::remove_file(&tmp);
        let _ = std::fs::write(&miss_marker, b"miss");
    }
    false
}

fn try_extract_mpq_terrain(
    basic_data: &SC2ReplayBasicData,
    base_plateaus: &[ [f32; 3] ],
) -> Option<TerrainOverlay> {
    let cache_dir = resolve_s2ma_cache_dir();
    let mut candidate_ids: Vec<String> = Vec::new();
    let mut source_tag = "mpq_s2ma";

    // 1. Check local .SC2Map / .s2ma matching map title
    if let Some(local_map) = find_local_sc2map(&basic_data.details.title) {
        let slug = format!("local_{}", normalize_map_slug(&basic_data.details.title));
        let staged = cache_dir.join(format!("{slug}.s2ma"));
        if !staged.exists() && std::fs::create_dir_all(&cache_dir).is_ok() {
            #[cfg(unix)]
            let _ = std::os::unix::fs::symlink(
                std::fs::canonicalize(&local_map).unwrap_or(local_map),
                &staged,
            );
            #[cfg(not(unix))]
            let _ = std::fs::copy(&local_map, &staged);
        }
        if staged.exists() {
            candidate_ids.push(slug);
            source_tag = "local_sc2map";
        }
    }

    // 2. Collect cache_handles from details + init_data (often non-empty in Battle.net replays)
    let gd = &basic_data.init_data.sync_lobby_state.game_description;
    let region = if gd.cache_handle_region.trim().is_empty() {
        "us"
    } else {
        gd.cache_handle_region.as_str()
    };
    let ext = if gd.cache_handle_extension.trim().is_empty() {
        "s2ma"
    } else {
        gd.cache_handle_extension.as_str()
    };

    let mut seen_handles = BTreeSet::new();
    let mut net_handles = Vec::new();
    for h in gd
        .cache_handles
        .iter()
        .chain(basic_data.details.cache_handles.iter())
    {
        let h = h.trim();
        if h.len() == 64 && seen_handles.insert(h.to_string()) {
            net_handles.push(h.to_string());
        }
    }
    // Check handles in reverse order (map archive is typically last after core mod deps)
    for h in net_handles.iter().rev() {
        if ensure_s2ma_present(&cache_dir, region, ext, h) {
            candidate_ids.push(h.clone());
        }
    }
    if candidate_ids.is_empty() {
        return None;
    }

    let mut coll = CacheCollection::new(cache_dir.to_string_lossy().to_string());
    coll.add_cache_ids(&candidate_ids);
    let map_cache = coll.build_map_cache(&candidate_ids).ok()?;

    let info = &map_cache.map_info;
    let hm = &map_cache.t3_height_map;
    let left = info.cell_left.min(info.cell_width);
    let right = info.cell_right.min(hm.width).max(left);
    let bottom = info.cell_bottom.min(info.cell_height);
    let top = info.cell_top.min(hm.height).max(bottom);
    let out_w = right.saturating_sub(left);
    let out_h = top.saturating_sub(bottom);

    let mut heights = Vec::with_capacity(out_w * out_h);
    if out_w > 0 && out_h > 0 && hm.data.len() >= hm.width * hm.height {
        for y in bottom..top {
            for x in left..right {
                heights.push(hm.data[y * hm.width + x]);
            }
        }
    }

    let minimap_png_b64 = map_cache.minimap.as_ref().and_then(|mm| {
        let cropped = mm.crop_to_playable(info);
        if cropped.width > 0 && cropped.height > 0 {
            encode_png_rgba_b64(cropped.width, cropped.height, &cropped.pixels)
        } else {
            encode_png_rgba_b64(mm.width, mm.height, &mm.pixels)
        }
    });

    Some(TerrainOverlay {
        source: source_tag.to_string(),
        width: out_w,
        height: out_h,
        playable_bounds: [left as f32, bottom as f32, right as f32, top as f32],
        heights,
        minimap_png_b64,
        base_plateaus: base_plateaus.to_vec(),
    })
}

pub fn extract_terrain_overlay(
    basic_data: &SC2ReplayBasicData,
    static_objects: &[StaticMapObject],
    map_w: f32,
    map_h: f32,
) -> TerrainOverlay {
    let base_plateaus = cluster_base_plateaus(static_objects);
    if let Some(mpq_terrain) = try_extract_mpq_terrain(basic_data, &base_plateaus) {
        return mpq_terrain;
    }
    TerrainOverlay {
        source: "inferred".to_string(),
        width: map_w.round().max(1.0) as usize,
        height: map_h.round().max(1.0) as usize,
        playable_bounds: [0.0, 0.0, map_w, map_h],
        heights: Vec::new(),
        minimap_png_b64: None,
        base_plateaus,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_base_plateaus_and_png_encoding() {
        let objs = vec![
            StaticMapObject { x: 30.0, y: 34.0, kind: 0, name: "MineralField".into() },
            StaticMapObject { x: 31.0, y: 35.0, kind: 0, name: "MineralField".into() },
            StaticMapObject { x: 32.0, y: 34.5, kind: 0, name: "MineralField".into() },
            StaticMapObject { x: 33.0, y: 32.0, kind: 1, name: "VespeneGeyser".into() },
            StaticMapObject { x: 120.0, y: 120.0, kind: 0, name: "SingleCrystal".into() },
        ];
        let plateaus = cluster_base_plateaus(&objs);
        assert_eq!(plateaus.len(), 1);
        assert!((plateaus[0][0] - 31.5).abs() < 0.2);

        let rgba = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255];
        let b64 = encode_png_rgba_b64(2, 2, &rgba).expect("2x2 PNG encodes cleanly");
        assert!(b64.starts_with("iVBORw0KGgo"));
    }
}
