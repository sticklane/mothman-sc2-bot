//! Minimal State Machine, Enhanced Minimap Timeline, and Swarmy Forensic Engine
//! built directly on `sebosp/s2protocol-rs` (`s2protocol = "5.1.0"`).

use flate2::read::DeflateDecoder;
use s2protocol::basic_replay_data::SC2ReplayBasicData;
use s2protocol::game_events::{
    GameEControlGroupUpdate, GameSCmdData, MultiVersionedBalanceUnits, ReplayGameEvent,
    UnitShortRef, VersionedBalanceUnits, read_balance_data_from_included_assets,
};
use s2protocol::state::SC2UnitCmdData;
use s2protocol::tracker_events::ReplayTrackerEvent;
use s2protocol::{SC2EventIterator, SC2EventType, SC2Unit, UnitChangeHint};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};
use std::io::Read;
use std::path::Path;
use std::sync::OnceLock;

pub const GAME_LOOPS_PER_SECOND: f64 = 22.4;
pub const NORMAL_SECONDS_PER_FASTER_SECOND: f32 = 1.4;
pub const DEATH_VISIBLE_LOOPS: i64 = 112;
pub const COMMAND_VISIBLE_LOOPS: i64 = 56;
pub const ENGAGEMENT_GAP_SECONDS: u32 = 12;
pub const MAX_ENGAGEMENT_SECONDS: u32 = 60;
pub const MIN_ENGAGEMENT_RESOURCES: u32 = 400;
pub const FLOATING_THRESHOLD: i32 = 1000;
pub const PROXY_DISTANCE: f32 = 50.0;
pub const PROXY_MAX_SECONDS: u32 = 240;
pub const SCOUT_DISTANCE: f32 = 30.0;
pub const SNAPSHOT_SECONDS: u32 = 600;
pub const ENERGY_PER_SECOND: f32 = 0.7875;
pub const INJECT_SECONDS: f32 = 29.0;

const WORKERS: &[&str] = &["SCV", "Probe", "Drone", "MULE"];
const MORPH_SOURCES: &[&str] = &["Drone", "HighTemplar", "DarkTemplar"];
const EXPANSION_TOWNHALLS: &[&str] = &["Hatchery", "CommandCenter", "Nexus"];
const TOWNHALLS: &[&str] = &[
    "Hatchery",
    "Lair",
    "Hive",
    "CommandCenter",
    "CommandCenterFlying",
    "OrbitalCommand",
    "OrbitalCommandFlying",
    "PlanetaryFortress",
    "Nexus",
];
const PRODUCTION_STRUCTURES: &[&str] = &[
    "Barracks",
    "Factory",
    "Starport",
    "Gateway",
    "WarpGate",
    "RoboticsFacility",
    "Stargate",
    "CommandCenter",
    "OrbitalCommand",
    "PlanetaryFortress",
    "Nexus",
];
const PROXY_STRUCTURES: &[&str] = &[
    "Barracks",
    "Factory",
    "Starport",
    "Gateway",
    "RoboticsFacility",
    "Stargate",
    "SpawningPool",
];
const NOT_SCOUTS: &[&str] = &[
    "Larva",
    "Egg",
    "BanelingCocoon",
    "RavagerCocoon",
    "LurkerMPEgg",
    "BroodLordCocoon",
    "OverlordCocoon",
    "TransportOverlordCocoon",
    "",
];
const CASTERS: &[&str] = &[
    "Queen",
    "Nexus",
    "OrbitalCommand",
    "Hatchery",
    "Lair",
    "Hive",
];

/// Fitted logistic win-chance coefficients `[army, income, workers, trades]` from Swarmy (27,441 1v1 games).
const WIN_CHANCE_COEFFICIENTS: [(f32, [f32; 4]); 12] = [
    (3.0, [0.231, 0.761, 0.454, 3.786]),
    (5.0, [0.224, 1.215, 0.738, 2.724]),
    (7.0, [0.501, 1.024, 1.202, 2.429]),
    (9.0, [1.017, 0.910, 1.704, 2.616]),
    (11.0, [1.546, 1.290, 1.829, 2.969]),
    (13.0, [1.738, 1.502, 1.684, 3.238]),
    (15.0, [1.878, 1.540, 1.590, 3.732]),
    (17.0, [1.855, 1.633, 1.443, 4.344]),
    (19.0, [1.692, 1.194, 1.461, 4.017]),
    (21.0, [1.892, 1.489, 1.104, 3.615]),
    (23.0, [2.047, 1.415, 1.198, 3.651]),
    (25.0, [1.154, 0.731, 0.914, 2.923]),
];

pub fn balance_units_db() -> Result<&'static MultiVersionedBalanceUnits, String> {
    static DB: OnceLock<MultiVersionedBalanceUnits> = OnceLock::new();
    if let Some(existing) = DB.get() {
        return Ok(existing);
    }
    let loaded = read_balance_data_from_included_assets()
        .map_err(|e| format!("Failed loading embedded s2protocol BalanceData: {e:?}"))?;
    Ok(DB.get_or_init(|| loaded))
}

pub fn closest_patch_balance(version: u32) -> Result<&'static VersionedBalanceUnits, String> {
    let db = balance_units_db()?;
    let mut patch_versions: Vec<u32> = db
        .keys()
        .copied()
        .filter(|v| !s2protocol::game_events::DERIVED_BALANCE_DATA_VERSIONS.contains(v))
        .collect();
    patch_versions.sort_unstable();
    let chosen = patch_versions
        .into_iter()
        .min_by_key(|v| v.abs_diff(version))
        .or_else(|| db.keys().copied().max())
        .ok_or_else(|| "No BalanceData versions found".to_string())?;
    Ok(&db[&chosen])
}

pub fn clean_player_name(raw: &str) -> String {
    let s1 = raw.replace("<sp/>", " ");
    let mut out = String::with_capacity(s1.len());
    let mut rest = s1.as_str();
    while let Some(lt) = rest.find("&lt;") {
        out.push_str(&rest[..lt]);
        if let Some(gt) = rest[lt..].find("&gt;") {
            rest = &rest[lt + gt + 4..];
        } else {
            rest = "";
            break;
        }
    }
    out.push_str(rest);
    // Strip raw <...> clan tags if present
    let mut clean = String::with_capacity(out.len());
    let mut in_tag = false;
    for ch in out.chars() {
        if ch == '<' {
            in_tag = true;
        } else if ch == '>' {
            in_tag = false;
        } else if !in_tag {
            clean.push(ch);
        }
    }
    let trimmed = clean.trim();
    if trimmed.is_empty() {
        raw.to_string()
    } else {
        trimmed.to_string()
    }
}

pub fn normalize_race(raw: &str) -> String {
    if raw.contains("Terr") || raw.contains("테란") || raw.contains("人类") {
        "Terran".to_string()
    } else if raw.contains("Zerg") || raw.contains("저그") || raw.contains("异虫") {
        "Zerg".to_string()
    } else if raw.contains("Prot") || raw.contains("프로토스") || raw.contains("星灵") {
        "Protoss".to_string()
    } else if raw.contains("Rand") {
        "Random".to_string()
    } else {
        raw.trim().to_string()
    }
}

pub fn base_unit_name(name: &str) -> &str {
    match name {
        "SiegeTankSieged" => "SiegeTank",
        "VikingAssault" => "VikingFighter",
        "LiberatorAG" => "Liberator",
        "ThorAP" => "Thor",
        "WarpPrismPhasing" => "WarpPrism",
        "ObserverSiegeMode" => "Observer",
        "OverseerSiegeMode" => "Overseer",
        "WarpGate" => "Gateway",
        "SupplyDepotLowered" => "SupplyDepot",
        "CommandCenterFlying" => "CommandCenter",
        "OrbitalCommandFlying" => "OrbitalCommand",
        "BarracksFlying" => "Barracks",
        "FactoryFlying" => "Factory",
        "StarportFlying" => "Starport",
        _ if name.starts_with("CreepTumor") => name,
        _ => name.strip_suffix("Burrowed").unwrap_or(name),
    }
}

#[derive(Debug, Default, Clone, Copy)]
pub struct UnitCostInfo {
    pub minerals: u32,
    pub vespene: u32,
    pub supply: f32,
    pub time_faster_sec: f32,
}

pub fn lookup_unit_cost(balance: &VersionedBalanceUnits, name: &str) -> UnitCostInfo {
    let base = base_unit_name(name);
    let Some(cost) = balance
        .get(name)
        .or_else(|| balance.get(base))
        .and_then(|u| u.cost.as_ref())
    else {
        return UnitCostInfo::default();
    };
    let units_per_cost = if base == "Zergling" { 2 } else { 1 };
    UnitCostInfo {
        minerals: cost.minerals.unwrap_or(0) / units_per_cost,
        vespene: cost.vespene.unwrap_or(0) / units_per_cost,
        supply: cost.supply.unwrap_or(0.0).max(0.0) / units_per_cost as f32,
        time_faster_sec: cost.time.unwrap_or(0.0) / NORMAL_SECONDS_PER_FASTER_SECOND,
    }
}

pub fn has_resource_cost(balance: &VersionedBalanceUnits, name: &str) -> bool {
    let c = lookup_unit_cost(balance, name);
    c.minerals > 0 || c.vespene > 0
}

pub fn is_structure_unit(balance: &VersionedBalanceUnits, name: &str) -> bool {
    let base = base_unit_name(name);
    balance
        .get(name)
        .or_else(|| balance.get(base))
        .is_some_and(|u| {
            u.attributes
                .inner
                .iter()
                .any(|a| a.kind.as_deref() == Some("Structure"))
        })
        || TOWNHALLS.contains(&name)
        || PRODUCTION_STRUCTURES.contains(&name)
        || name.contains("Pylon")
        || name.contains("SupplyDepot")
        || name.contains("SpineCrawler")
        || name.contains("SporeCrawler")
        || name.contains("PhotonCannon")
        || name.contains("ShieldBattery")
        || name.contains("CreepTumor")
}

pub fn is_morph_death(name: &str, has_killer: bool) -> bool {
    !has_killer && MORPH_SOURCES.contains(&base_unit_name(name))
}

fn refers_to(units: &[UnitShortRef], target: &str) -> bool {
    units.iter().any(|u| u.id == target)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnitDecisionRecord {
    pub sec: f32,
    pub unit: String,
    pub score: f64,
    pub strong_vs: String,
    pub weak_vs: String,
}

pub fn score_unit_choice<'a>(
    balance: &VersionedBalanceUnits,
    unit_name: &str,
    enemy_units: impl IntoIterator<Item = &'a SC2Unit>,
) -> Option<(f64, BTreeMap<String, usize>, BTreeMap<String, usize>)> {
    let base = base_unit_name(unit_name);
    if WORKERS.contains(&base) || is_structure_unit(balance, base) {
        return None;
    }
    let cost = lookup_unit_cost(balance, base);
    if cost.supply <= 0.0 {
        return None;
    }
    let unit = balance.get(base)?;
    if unit.strengths.inner.is_empty() && unit.weaknesses.inner.is_empty() {
        return None;
    }
    let mut total_supply = 0.0f64;
    let mut weighted_score = 0.0f64;
    let mut strong_vs: BTreeMap<String, usize> = BTreeMap::new();
    let mut weak_vs: BTreeMap<String, usize> = BTreeMap::new();
    for enemy in enemy_units {
        if enemy.is_init {
            continue;
        }
        let enemy_base = base_unit_name(&enemy.name);
        if WORKERS.contains(&enemy_base) || is_structure_unit(balance, enemy_base) {
            continue;
        }
        let enemy_cost = lookup_unit_cost(balance, enemy_base);
        if enemy_cost.supply <= 0.0 {
            continue;
        }
        let Some(enemy_unit) = balance.get(enemy_base) else {
            continue;
        };
        let favorable = refers_to(&unit.strengths.inner, enemy_base)
            || refers_to(&enemy_unit.weaknesses.inner, base);
        let unfavorable = refers_to(&unit.weaknesses.inner, enemy_base)
            || refers_to(&enemy_unit.strengths.inner, base);
        let advantage = favorable as i32 - unfavorable as i32;
        total_supply += enemy_cost.supply as f64;
        weighted_score += advantage as f64 * enemy_cost.supply as f64;
        if advantage > 0 {
            *strong_vs.entry(enemy_base.to_string()).or_default() += 1;
        } else if advantage < 0 {
            *weak_vs.entry(enemy_base.to_string()).or_default() += 1;
        }
    }
    if total_supply <= 0.0 {
        return None;
    }
    Some((weighted_score / total_supply, strong_vs, weak_vs))
}

fn format_counts_map(m: &BTreeMap<String, usize>) -> String {
    m.iter()
        .map(|(k, v)| format!("{v}x{k}"))
        .collect::<Vec<_>>()
        .join(",")
}

#[derive(Debug, Default, Clone, Copy)]
struct SideStats {
    army: i32,
    income: i32,
    workers: i32,
    killed: i32,
}

fn win_chance_coeffs(minute: f32) -> [f32; 4] {
    if minute <= WIN_CHANCE_COEFFICIENTS[0].0 {
        return WIN_CHANCE_COEFFICIENTS[0].1;
    }
    let last = WIN_CHANCE_COEFFICIENTS[WIN_CHANCE_COEFFICIENTS.len() - 1];
    if minute >= last.0 {
        return last.1;
    }
    let idx = WIN_CHANCE_COEFFICIENTS
        .iter()
        .position(|(m, _)| *m >= minute)
        .unwrap_or(WIN_CHANCE_COEFFICIENTS.len() - 1);
    let (m0, low) = WIN_CHANCE_COEFFICIENTS[idx - 1];
    let (m1, high) = WIN_CHANCE_COEFFICIENTS[idx];
    let w = (minute - m0) / (m1 - m0);
    std::array::from_fn(|i| low[i] + (high[i] - low[i]) * w)
}

fn log_ratio(a: i32, b: i32, offset: f32) -> f32 {
    ((a.max(0) as f32 + offset) / (b.max(0) as f32 + offset)).ln()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WinChanceSample {
    pub sec: u32,
    pub p1_chance: f32,
    pub army_term: f32,
    pub income_term: f32,
    pub workers_term: f32,
    pub trades_term: f32,
}

fn compute_win_chance(sec: u32, p1: &SideStats, p2: &SideStats) -> WinChanceSample {
    let minute = sec.saturating_sub(30) as f32 / 60.0;
    let [c_army, c_inc, c_wrk, c_trd] = win_chance_coeffs(minute);
    let killed_denom = (p1.killed.max(0) + p2.killed.max(0) + 1000) as f32;
    let army_term = c_army * log_ratio(p1.army, p2.army, 200.0);
    let income_term = c_inc * log_ratio(p1.income, p2.income, 100.0);
    let workers_term = c_wrk * log_ratio(p1.workers, p2.workers, 5.0);
    let trades_term = c_trd * (p1.killed.max(0) - p2.killed.max(0)) as f32 / killed_denom;
    let log_odds = army_term + income_term + workers_term + trades_term;
    let p1_chance = 1.0 / (1.0 + (-log_odds).exp());
    WinChanceSample {
        sec,
        p1_chance: (p1_chance * 1000.0).round() / 1000.0,
        army_term: (army_term * 100.0).round() / 100.0,
        income_term: (income_term * 100.0).round() / 100.0,
        workers_term: (workers_term * 100.0).round() / 100.0,
        trades_term: (trades_term * 100.0).round() / 100.0,
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TurningPointRecord {
    pub start_sec: u32,
    pub end_sec: u32,
    pub delta_p1_chance: f32,
    pub summary: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EngagementSummary {
    pub start_sec: u32,
    pub end_sec: u32,
    pub center_x: f32,
    pub center_y: f32,
    pub p1_lost_resources: u32,
    pub p2_lost_resources: u32,
    pub p1_mining_sec_lost: f32,
    pub p2_mining_sec_lost: f32,
    pub p1_units_lost: String,
    pub p2_units_lost: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WireActuationAuditRow {
    pub structure: String,
    pub wire_build_cmds: u32,
    pub unit_init_count: u32,
    pub unit_done_count: u32,
    pub canceled_or_sniped: u32,
    pub first_wire_sec: Option<f32>,
    pub first_init_sec: Option<f32>,
    pub sample_target_xy: Option<[f32; 2]>,
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProductionIdleRow {
    pub structure: String,
    pub facilities: usize,
    pub idle_seconds: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AbilityEfficiencyRow {
    pub ability: String,
    pub caster: String,
    pub uses_until_10m: u32,
    pub possible_until_10m: f32,
    pub efficiency_pct: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnitEffectivenessRow {
    pub unit: String,
    pub produced: usize,
    pub lost: usize,
    pub kills: usize,
    pub value_killed: u32,
    pub unit_cost: u32,
    pub roi: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CostedLesson {
    pub title: String,
    pub detail: String,
    pub mineral_equiv_cost: u32,
    pub at_sec: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayerForensicReport {
    pub pid: u8,
    pub name: String,
    pub declared_race: String,
    pub actual_race: String,
    pub result: String,
    pub scaled_rating: Option<i32>,
    pub start_xy: Option<[f32; 2]>,
    pub opening_tech: Vec<String>,
    // High-APM & BotFilter metrics
    pub raw_commands: u32,
    pub macro_filtered_commands: u32,
    pub raw_cpm: f32,
    pub macro_cpm: f32,
    pub move_attack_spam_pct: f32,
    pub worker_thrash_events: u32,
    pub control_groups_used: Vec<u8>,
    pub control_group_assigns: u32,
    pub control_group_recalls_per_min: f32,
    pub camera_moves_per_min: f32,
    pub top_abilities: Vec<(String, u32)>,
    // Macro & Economy
    pub supply_blocked_seconds: u32,
    pub floating_seconds: u32,
    pub avg_unspent: u32,
    pub avg_income: u32,
    pub mining_seconds_lost: f32,
    pub resources_lost: u32,
    pub resources_killed: u32,
    pub injects: u32,
    pub chrono_boosts: u32,
    pub mules: u32,
    pub creep_tumors_placed: u32,
    pub creep_tumors_cleared_by_enemy: u32,
    pub first_scout: Option<(f32, String)>,
    pub proxy_detected: Option<(f32, String, f32)>,
    pub bases_lost: Vec<(f32, String)>,
    // Wire vs Init vs Done Audit
    pub wire_actuation_audit: Vec<WireActuationAuditRow>,
    pub production_idle: Vec<ProductionIdleRow>,
    pub ability_efficiency: Vec<AbilityEfficiencyRow>,
    pub unit_effectiveness: Vec<UnitEffectivenessRow>,
    pub killed_by: Vec<(String, usize)>,
    // Counter-choice decisions
    pub good_decisions: usize,
    pub even_decisions: usize,
    pub bad_decisions: Vec<UnitDecisionRecord>,
    pub lessons: Vec<CostedLesson>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StaticMapObject {
    pub x: f32,
    pub y: f32,
    /// 0 = mineral, 1 = geyser, 2 = destructible rock/tower
    pub kind: u8,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MinimapUnit {
    pub x: f32,
    pub y: f32,
    pub owner: u8,
    /// 0 = worker, 1 = army, 2 = townhall, 3 = production/tech structure, 4 = static defense / pylon / depot
    pub kind: u8,
    pub r: f32,
    pub init: bool,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MinimapRay {
    pub ox: f32,
    pub oy: f32,
    pub tx: f32,
    pub ty: f32,
    pub owner: u8,
    /// 0 = move/attack micro, 1 = build/expand, 2 = ability/cast, 3 = harvest/other
    pub kind: u8,
    pub label: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MinimapDeath {
    pub x: f32,
    pub y: f32,
    pub owner: u8,
    pub unit: String,
    pub killer: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FramePlayerStat {
    pub minerals: i32,
    pub vespene: i32,
    pub min_rate: i32,
    pub gas_rate: i32,
    pub workers: i32,
    pub food_used: i32,
    pub food_made: i32,
    pub army_value: i32,
    pub killed_value: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MinimapFrame {
    pub game_loop: i64,
    pub sec: f32,
    pub units: Vec<MinimapUnit>,
    pub rays: Vec<MinimapRay>,
    pub deaths: Vec<MinimapDeath>,
    pub cameras: [[f32; 2]; 2],
    pub creep: Vec<[f32; 2]>,
    pub pylons: Vec<[f32; 3]>,
    pub p1_stats: FramePlayerStat,
    pub p2_stats: FramePlayerStat,
    pub priority_idx: Option<usize>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PriorityLogSnapshot {
    pub frame: i64,
    pub sec: f32,
    pub race: String,
    pub bank: String,
    pub sup: String,
    pub bo: String,
    pub saving_for: String,
    pub approved: String,
    pub escrow_queue: String,
    pub blocked: String,
    pub step_ms: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HeatmapCell {
    pub x: u32,
    pub y: u32,
    pub count: u32,
    pub value: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReplaySidecarBundle {
    pub replay_id: String,
    pub file_name: String,
    pub sha256: String,
    pub protocol_version: u32,
    pub map_name: String,
    pub map_width: f32,
    pub map_height: f32,
    pub total_loops: i64,
    pub duration_sec: f32,
    pub sample_interval_loops: i64,
    pub parse_elapsed_ms: f64,
    pub players: Vec<PlayerForensicReport>,
    pub win_chance_curve: Vec<WinChanceSample>,
    pub turning_points: Vec<TurningPointRecord>,
    pub engagements: Vec<EngagementSummary>,
    pub findings: Vec<String>,
    pub static_objects: Vec<StaticMapObject>,
    pub death_heatmap: Vec<HeatmapCell>,
    pub siege_spots: Vec<HeatmapCell>,
    pub frames: Vec<MinimapFrame>,
    pub priority_snapshots: Vec<PriorityLogSnapshot>,
}

#[derive(Clone)]
struct RawDeathEvent {
    sec: u32,
    owner_pid: u8,
    unit: String,
    x: f32,
    y: f32,
    cost: u32,
    mining_sec: f32,
}

#[derive(Default)]
struct PerPlayerAcc {
    pid: u8,
    user_id: Option<i64>,
    name: String,
    declared_race: String,
    actual_race: String,
    result: String,
    scaled_rating: Option<i32>,
    start_xy: Option<[f32; 2]>,
    camera_xy: [f32; 2],
    last_stats: FramePlayerStat,
    side_stats: SideStats,
    last_stats_sec: Option<u32>,
    supply_blocked_sec: u32,
    supply_full_intervals: Vec<(u32, u32)>,
    floating_sec: u32,
    unspent_samples: Vec<i32>,
    income_samples: Vec<i32>,
    mining_sec_lost: f32,
    resources_lost: u32,
    resources_killed: u32,
    raw_commands: u32,
    macro_filtered_commands: u32,
    worker_thrash_events: u32,
    last_worker_build_loop: HashMap<u32, i64>,
    control_groups: BTreeSet<u8>,
    cg_assigns: u32,
    cg_recalls: u32,
    camera_moves: u32,
    ability_counts: BTreeMap<String, u32>,
    wire_builds: BTreeMap<String, (u32, Option<f32>, Option<[f32; 2]>)>,
    unit_inits: BTreeMap<String, (u32, Option<f32>)>,
    unit_dones: BTreeMap<String, u32>,
    injects: u32,
    early_injects: u32,
    chrono_boosts: u32,
    early_chrono_boosts: u32,
    mules: u32,
    early_mules: u32,
    caster_seconds: BTreeMap<&'static str, f32>,
    creep_placed: u32,
    creep_cleared_by_enemy: u32,
    first_scout: Option<(f32, String)>,
    proxy_detected: Option<(f32, String, f32)>,
    bases_lost: Vec<(f32, String)>,
    opening_tech: Vec<String>,
    produced: BTreeMap<String, usize>,
    lost_counts: BTreeMap<String, usize>,
    kills_by_unit: BTreeMap<String, (usize, u32)>,
    killed_by: BTreeMap<String, usize>,
    prod_last_finish: HashMap<u32, (String, u32)>,
    prod_idle: BTreeMap<String, (usize, u32)>,
    good_decisions: usize,
    even_decisions: usize,
    bad_decisions: Vec<UnitDecisionRecord>,
}

impl Default for FramePlayerStat {
    fn default() -> Self {
        Self {
            minerals: 50,
            vespene: 0,
            min_rate: 0,
            gas_rate: 0,
            workers: 12,
            food_used: 12,
            food_made: 15,
            army_value: 0,
            killed_value: 0,
        }
    }
}

fn round1(v: f32) -> f32 {
    (v * 10.0).round() / 10.0
}

fn round2(v: f32) -> f32 {
    (v * 100.0).round() / 100.0
}

fn is_move_or_attack(ability: &str, abil_link: u16, protocol_version: u32) -> bool {
    if ability.is_empty() {
        if protocol_version == 75689 {
            abil_link == 42 || abil_link == 45
        } else {
            abil_link == 43 || abil_link == 46
        }
    } else {
        ability.starts_with("move.")
            || ability.starts_with("attack.")
            || ability == "move"
            || ability == "attack"
    }
}

fn classify_ray_kind(ability: &str, abil_link: u16, protocol_version: u32) -> u8 {
    if ability.starts_with("Build.")
        || ability.starts_with("ProtossBuild")
        || ability.starts_with("TerranBuild")
        || ability.starts_with("ZergBuild")
    {
        1
    } else if is_move_or_attack(ability, abil_link, protocol_version) {
        0
    } else if ability.contains("Harvest") || ability.contains("Gather") {
        3
    } else if !ability.is_empty() {
        2
    } else {
        0
    }
}

fn extract_build_target_name(ability: &str) -> Option<String> {
    if let Some(rest) = ability.strip_prefix("Build.") {
        if !rest.is_empty() {
            return Some(rest.to_string());
        }
    }
    None
}

fn idle_gap_excluding_supply_full(finished: u32, started: u32, supply_full: &[(u32, u32)]) -> u32 {
    let gap = started.saturating_sub(finished);
    let blocked: u32 = supply_full
        .iter()
        .map(|(s, e)| (*e).min(started).saturating_sub((*s).max(finished)))
        .sum();
    gap.saturating_sub(blocked)
}

/// Minimal pure-Rust reader for `stdout.log` inside `<match_id>_match_log.zip` using `flate2`.
pub fn read_priority_snapshots_for_replay(replay_path: &Path) -> Vec<PriorityLogSnapshot> {
    let stem = replay_path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or_default();
    let parent = replay_path.parent().unwrap_or_else(|| Path::new("."));

    // 1. Check `<stem>_priority.log` or `<stem>_stdout.log` (local `run-real-sc2-bot-match.rkt`)
    let direct_candidates = [
        parent.join(format!("{stem}_priority.log")),
        parent.join(format!("{stem}_stdout.log")),
    ];
    for cand in &direct_candidates {
        if let Ok(text) = std::fs::read_to_string(cand) {
            let parsed = parse_priority_log_lines(&text);
            if !parsed.is_empty() {
                return parsed;
            }
        }
    }

    // 2. Check `<match_id>_match_log.zip` in `replays/aiarena_live_cache`
    if let Some(match_id) = stem.split('_').next()
        && match_id.chars().all(|c| c.is_ascii_digit())
        && !match_id.is_empty()
    {
        let zip_path = parent.join(format!("{match_id}_match_log.zip"));
        if let Ok(bytes) = std::fs::read(&zip_path)
            && let Some(text) = extract_stdout_from_zip_bytes(&bytes)
        {
            return parse_priority_log_lines(&text);
        }
    }
    vec![]
}

fn extract_stdout_from_zip_bytes(zip_bytes: &[u8]) -> Option<String> {
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

pub fn analyze_replay_bytes(
    replay_id: &str,
    file_name: &str,
    bytes: &[u8],
    priority_snapshots: Vec<PriorityLogSnapshot>,
    max_timeline_frames: usize,
) -> Result<ReplaySidecarBundle, String> {
    let t0 = std::time::Instant::now();
    let db = balance_units_db()?;
    let basic_data = SC2ReplayBasicData::from_bytes(file_name, 0, bytes)
        .map_err(|e| format!("SC2ReplayBasicData error: {e:?}"))?;
    let protocol_version = basic_data.init_data.version;
    let patch_balance = closest_patch_balance(protocol_version)?;
    let iter = SC2EventIterator::from_bytes(&basic_data, bytes, db)
        .map_err(|e| format!("SC2EventIterator error: {e:?}"))?;

    let mut map_w = basic_data
        .init_data
        .sync_lobby_state
        .game_description
        .map_size_x as f32;
    let mut map_h = basic_data
        .init_data
        .sync_lobby_state
        .game_description
        .map_size_y as f32;

    let ratings_by_name: HashMap<String, i32> = basic_data
        .init_data
        .sync_lobby_state
        .user_initial_data
        .iter()
        .filter_map(|u| Some((clean_player_name(&u.name), u.scaled_rating?)))
        .collect();

    let mut players: HashMap<u8, PerPlayerAcc> = HashMap::new();
    let mut user_id_to_pid: HashMap<i64, u8> = HashMap::new();

    for (idx, p) in basic_data.details.player_list.iter().take(2).enumerate() {
        let pid = (idx + 1) as u8;
        let cname = clean_player_name(&p.name);
        let decl_race = normalize_race(&p.race);
        players.insert(
            pid,
            PerPlayerAcc {
                pid,
                user_id: None,
                name: cname.clone(),
                declared_race: decl_race.clone(),
                actual_race: decl_race,
                result: format!("{:?}", p.result).trim_matches('"').to_string(),
                scaled_rating: ratings_by_name.get(&cname).copied(),
                ..Default::default()
            },
        );
    }
    for pid in [1u8, 2u8] {
        players.entry(pid).or_insert_with(|| PerPlayerAcc {
            pid,
            name: format!("Player{pid}"),
            declared_race: "Unknown".to_string(),
            actual_race: "Unknown".to_string(),
            result: "Unknown".to_string(),
            ..Default::default()
        });
    }

    // Scan max_loop first so we can choose an exact adaptive frame stride (`<= max_timeline_frames`).
    let mut max_loop: i64 = 0;
    for item in iter {
        let gl = match &item.event_type {
            SC2EventType::Tracker { tracker_loop, .. } => *tracker_loop,
            SC2EventType::Game { game_loop, .. } => *game_loop,
        };
        if gl > max_loop {
            max_loop = gl;
        }
    }

    // Re-run clean state machine pass with adaptive snapshot cadence (`<= max_timeline_frames`)
    let mut iter = SC2EventIterator::from_bytes(&basic_data, bytes, db)
        .map_err(|e| format!("SC2EventIterator second pass error: {e:?}"))?;
    let target_frames = max_timeline_frames.max(60) as i64;
    let sample_interval_loops = ((max_loop / target_frames).max(22) / 2) * 2;
    let sample_interval_loops = sample_interval_loops.max(22);

    let mut static_objects: Vec<StaticMapObject> = Vec::new();
    let mut static_tags: BTreeSet<u32> = BTreeSet::new();
    let mut scored_tags: HashMap<u32, String> = HashMap::new();
    let mut active_rays: VecDeque<(i64, MinimapRay)> = VecDeque::new();
    let mut recent_deaths: VecDeque<(i64, MinimapDeath)> = VecDeque::new();
    let mut raw_deaths: Vec<RawDeathEvent> = Vec::new();
    let mut death_cells: HashMap<(u32, u32), (u32, u32)> = HashMap::new();
    let mut siege_cells: HashMap<(u32, u32), (u32, u32)> = HashMap::new();
    let mut win_chance_curve: Vec<WinChanceSample> = Vec::new();
    let mut next_win_chance_sec: u32 = 120;
    let mut frames: Vec<MinimapFrame> = Vec::new();
    let mut next_frame_loop: i64 = 0;
    let mut max_seen_x: f32 = map_w;
    let mut max_seen_y: f32 = map_h;

    let find_priority_idx = |gl: i64| -> Option<usize> {
        if priority_snapshots.is_empty() {
            return None;
        }
        match priority_snapshots.binary_search_by_key(&gl, |s| s.frame) {
            Ok(i) => Some(i),
            Err(0) => Some(0),
            Err(i) => Some(i - 1),
        }
    };

    let snapshot_frame = |gl: i64,
                          state: &s2protocol::SC2ReplayState,
                          players: &HashMap<u8, PerPlayerAcc>,
                          active_rays: &VecDeque<(i64, MinimapRay)>,
                          recent_deaths: &VecDeque<(i64, MinimapDeath)>|
     -> MinimapFrame {
        let mut units = Vec::new();
        let mut creep = Vec::new();
        let mut pylons = Vec::new();

        for u in state.units.values() {
            let owner = u.user_id.unwrap_or(0);
            if owner != 1 && owner != 2 {
                continue;
            }
            let base = base_unit_name(&u.name);
            if NOT_SCOUTS.contains(&base) {
                continue;
            }
            let x = round1(u.pos.x());
            let y = round1(u.pos.y());
            if !u.is_init
                && (base == "Hatchery"
                    || base == "Lair"
                    || base == "Hive"
                    || u.name == "CreepTumorBurrowed")
            {
                creep.push([x, y]);
            }
            if !u.is_init && base == "Pylon" {
                pylons.push([x, y, owner as f32]);
            }
            if u.name.starts_with("CreepTumor") {
                continue;
            }
            let kind = if WORKERS.contains(&base) {
                0
            } else if TOWNHALLS.contains(&u.name.as_str()) || TOWNHALLS.contains(&base) {
                2
            } else if PRODUCTION_STRUCTURES.contains(&base) {
                3
            } else if is_structure_unit(patch_balance, &u.name) {
                4
            } else {
                1
            };
            units.push(MinimapUnit {
                x,
                y,
                owner,
                kind,
                r: round1(u.radius.clamp(0.4, 2.8)),
                init: u.is_init,
                name: base.to_string(),
            });
        }

        let rays = active_rays.iter().map(|(_, r)| r.clone()).collect();
        let deaths = recent_deaths.iter().map(|(_, d)| d.clone()).collect();
        let p1 = players.get(&1);
        let p2 = players.get(&2);
        let cam1 = p1.map(|p| p.camera_xy).unwrap_or([0.0, 0.0]);
        let cam2 = p2.map(|p| p.camera_xy).unwrap_or([0.0, 0.0]);
        MinimapFrame {
            game_loop: gl,
            sec: round1(gl as f32 / GAME_LOOPS_PER_SECOND as f32),
            units,
            rays,
            deaths,
            cameras: [cam1, cam2],
            creep,
            pylons,
            p1_stats: p1.map(|p| p.last_stats.clone()).unwrap_or_default(),
            p2_stats: p2.map(|p| p.last_stats.clone()).unwrap_or_default(),
            priority_idx: find_priority_idx(gl),
        }
    };

    while let Some(item) = iter.next() {
        let gl = match &item.event_type {
            SC2EventType::Tracker { tracker_loop, .. } => *tracker_loop,
            SC2EventType::Game { game_loop, .. } => *game_loop,
        };

        while gl > next_frame_loop && !frames.is_empty() {
            frames.push(snapshot_frame(
                next_frame_loop,
                &iter.sc2_state,
                &players,
                &active_rays,
                &recent_deaths,
            ));
            next_frame_loop += sample_interval_loops;
        }
        while active_rays
            .front()
            .is_some_and(|(t, _)| *t + COMMAND_VISIBLE_LOOPS <= gl)
        {
            active_rays.pop_front();
        }
        while recent_deaths
            .front()
            .is_some_and(|(t, _)| *t + DEATH_VISIBLE_LOOPS <= gl)
        {
            recent_deaths.pop_front();
        }

        let sec_f = gl as f32 / GAME_LOOPS_PER_SECOND as f32;
        let sec_u = sec_f.max(0.0) as u32;

        while sec_u >= next_win_chance_sec {
            let s1 = players.get(&1).map(|p| p.side_stats).unwrap_or_default();
            let s2 = players.get(&2).map(|p| p.side_stats).unwrap_or_default();
            win_chance_curve.push(compute_win_chance(next_win_chance_sec, &s1, &s2));
            next_win_chance_sec += 30;
        }

        match &item.event_type {
            SC2EventType::Tracker { event, .. } => match event {
                ReplayTrackerEvent::PlayerSetup(setup) => {
                    if (setup.player_id == 1 || setup.player_id == 2)
                        && let Some(uid) = setup.user_id
                    {
                        user_id_to_pid.insert(uid as i64, setup.player_id);
                        if let Some(p) = players.get_mut(&setup.player_id) {
                            p.user_id = Some(uid as i64);
                        }
                    }
                }
                ReplayTrackerEvent::UnitBorn(ub) => {
                    let x = ub.x as f32;
                    let y = ub.y as f32;
                    max_seen_x = max_seen_x.max(x + 8.0);
                    max_seen_y = max_seen_y.max(y + 8.0);
                    if ub.control_player_id == 0 && !static_tags.contains(&ub.unit_tag_index) {
                        let uname = ub.unit_type_name.as_str();
                        let kind = if uname.contains("Mineral") {
                            Some(0)
                        } else if uname.contains("Vespene") || uname.contains("Geyser") {
                            Some(1)
                        } else if uname.contains("Destructible") || uname.contains("XelNagaTower") {
                            Some(2)
                        } else {
                            None
                        };
                        if let Some(k) = kind {
                            static_tags.insert(ub.unit_tag_index);
                            static_objects.push(StaticMapObject {
                                x: round1(x),
                                y: round1(y),
                                kind: k,
                                name: uname.to_string(),
                            });
                        }
                    } else if ub.control_player_id == 1 || ub.control_player_id == 2 {
                        let pid = ub.control_player_id;
                        if gl == 0 {
                            let rolled = match ub.unit_type_name.as_str() {
                                "Hatchery" | "Drone" => Some("Zerg"),
                                "CommandCenter" | "SCV" => Some("Terran"),
                                "Nexus" | "Probe" => Some("Protoss"),
                                _ => None,
                            };
                            if let Some(r) = rolled
                                && let Some(p) = players.get_mut(&pid)
                            {
                                p.actual_race = r.to_string();
                                if EXPANSION_TOWNHALLS.contains(&ub.unit_type_name.as_str()) {
                                    p.start_xy = Some([round1(x), round1(y)]);
                                    p.camera_xy = [round1(x), round1(y)];
                                }
                            }
                        } else {
                            let base = base_unit_name(&ub.unit_type_name).to_string();
                            if ub.unit_type_name == "CreepTumorBurrowed"
                                && let Some(p) = players.get_mut(&pid)
                            {
                                p.creep_placed += 1;
                            }
                            if has_resource_cost(patch_balance, &base) {
                                // Score unit counter decision before mutating `players`
                                let enemy_pid = if pid == 1 { 2 } else { 1 };
                                let choice = if scored_tags.get(&ub.unit_tag_index) != Some(&base) {
                                    scored_tags.insert(ub.unit_tag_index, base.clone());
                                    let enemy_units = iter
                                        .sc2_state
                                        .units
                                        .values()
                                        .filter(|eu| eu.user_id == Some(enemy_pid));
                                    score_unit_choice(patch_balance, &base, enemy_units)
                                } else {
                                    None
                                };
                                if let Some(p) = players.get_mut(&pid) {
                                    *p.produced.entry(base.clone()).or_default() += 1;
                                    if is_structure_unit(patch_balance, &base) {
                                        *p.unit_dones.entry(base.clone()).or_default() += 1;
                                    }
                                    if let UnitChangeHint::Registered {
                                        creator: Some(creator),
                                        ..
                                    } = &item.change_hint
                                    {
                                        let cbase = base_unit_name(&creator.name).to_string();
                                        if PRODUCTION_STRUCTURES.contains(&cbase.as_str()) {
                                            let btime = lookup_unit_cost(patch_balance, &base)
                                                .time_faster_sec as u32;
                                            let started = sec_u.saturating_sub(btime);
                                            let prev = p
                                                .prod_last_finish
                                                .insert(creator.tag_index, (cbase.clone(), sec_u));
                                            let entry = p.prod_idle.entry(cbase).or_default();
                                            match prev {
                                                Some((_, fin)) => {
                                                    entry.1 += idle_gap_excluding_supply_full(
                                                        fin,
                                                        started,
                                                        &p.supply_full_intervals,
                                                    );
                                                }
                                                None => entry.0 += 1,
                                            }
                                        }
                                    }
                                    if let Some((sc, strong, weak)) = choice {
                                        if sc > 0.05 {
                                            p.good_decisions += 1;
                                        } else if sc < -0.05 {
                                            p.bad_decisions.push(UnitDecisionRecord {
                                                sec: round1(sec_f),
                                                unit: base.clone(),
                                                score: (sc * 100.0).round() / 100.0,
                                                strong_vs: format_counts_map(&strong),
                                                weak_vs: format_counts_map(&weak),
                                            });
                                        } else {
                                            p.even_decisions += 1;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                ReplayTrackerEvent::UnitInit(ui) => {
                    if ui.control_player_id == 1 || ui.control_player_id == 2 {
                        let pid = ui.control_player_id;
                        let base = base_unit_name(&ui.unit_type_name).to_string();
                        let x = ui.x as f32;
                        let y = ui.y as f32;
                        if let Some(p) = players.get_mut(&pid) {
                            let entry = p.unit_inits.entry(base.clone()).or_default();
                            entry.0 += 1;
                            if entry.1.is_none() {
                                entry.1 = Some(round1(sec_f));
                            }
                            if p.opening_tech.len() < 4
                                && is_structure_unit(patch_balance, &base)
                                && !EXPANSION_TOWNHALLS.contains(&base.as_str())
                                && base != "Pylon"
                                && base != "SupplyDepot"
                                && base != "Extractor"
                                && base != "Assimilator"
                                && base != "Refinery"
                                && !p.opening_tech.contains(&base)
                            {
                                p.opening_tech.push(base.clone());
                            }
                            if p.proxy_detected.is_none()
                                && sec_u <= PROXY_MAX_SECONDS
                                && PROXY_STRUCTURES.contains(&base.as_str())
                                && let Some([sx, sy]) = p.start_xy
                            {
                                let dist = ((x - sx).powi(2) + (y - sy).powi(2)).sqrt();
                                if dist > PROXY_DISTANCE {
                                    p.proxy_detected =
                                        Some((round1(sec_f), base.clone(), round1(dist)));
                                }
                            }
                        }
                    }
                }
                ReplayTrackerEvent::UnitDone(ud) => {
                    if let Some(u) = iter.sc2_state.units.get(&ud.unit_tag_index)
                        && let Some(pid) = u.user_id
                        && (pid == 1 || pid == 2)
                    {
                        let base = base_unit_name(&u.name).to_string();
                        if let Some(p) = players.get_mut(&pid) {
                            *p.unit_dones.entry(base.clone()).or_default() += 1;
                            *p.produced.entry(base).or_default() += 1;
                        }
                    }
                }
                ReplayTrackerEvent::UnitTypeChange(utc) => {
                    if let Some(u) = iter.sc2_state.units.get(&utc.unit_tag_index)
                        && let Some(pid) = u.user_id
                        && (pid == 1 || pid == 2)
                    {
                        if utc.unit_type_name == "CreepTumorBurrowed" {
                            if let Some(p) = players.get_mut(&pid) {
                                p.creep_placed += 1;
                            }
                        } else {
                            let mname = utc.unit_type_name.as_str();
                            let is_morphed_tech_struct = matches!(
                                mname,
                                "Lair"
                                    | "Hive"
                                    | "GreaterSpire"
                                    | "OrbitalCommand"
                                    | "PlanetaryFortress"
                            );
                            let is_morphed_unit = matches!(
                                mname,
                                "Baneling" | "Ravager" | "LurkerMP" | "BroodLord" | "Overseer"
                            );
                            if is_morphed_tech_struct {
                                if let Some(p) = players.get_mut(&pid) {
                                    let entry =
                                        p.unit_inits.entry(mname.to_string()).or_default();
                                    entry.0 += 1;
                                    if entry.1.is_none() {
                                        entry.1 = Some(round1(sec_f));
                                    }
                                    *p.unit_dones.entry(mname.to_string()).or_default() += 1;
                                    *p.produced.entry(mname.to_string()).or_default() += 1;
                                    if p.opening_tech.len() < 4
                                        && !p.opening_tech.contains(&mname.to_string())
                                    {
                                        p.opening_tech.push(mname.to_string());
                                    }
                                }
                            } else if is_morphed_unit {
                                let base = base_unit_name(mname).to_string();
                                let enemy_pid = if pid == 1 { 2 } else { 1 };
                                let choice = if scored_tags.get(&utc.unit_tag_index) != Some(&base)
                                {
                                    scored_tags.insert(utc.unit_tag_index, base.clone());
                                    let enemy_units = iter
                                        .sc2_state
                                        .units
                                        .values()
                                        .filter(|eu| eu.user_id == Some(enemy_pid));
                                    score_unit_choice(patch_balance, &base, enemy_units)
                                } else {
                                    None
                                };
                                if let Some(p) = players.get_mut(&pid) {
                                    *p.produced.entry(base.clone()).or_default() += 1;
                                    if let Some((sc, strong, weak)) = choice {
                                        if sc > 0.05 {
                                            p.good_decisions += 1;
                                        } else if sc < -0.05 {
                                            p.bad_decisions.push(UnitDecisionRecord {
                                                sec: round1(sec_f),
                                                unit: base,
                                                score: (sc * 100.0).round() / 100.0,
                                                strong_vs: format_counts_map(&strong),
                                                weak_vs: format_counts_map(&weak),
                                            });
                                        } else {
                                            p.even_decisions += 1;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                ReplayTrackerEvent::UnitDied(ud) => {
                    if let UnitChangeHint::Unregistered { killer, killed } = &item.change_hint {
                        let owner = killed.user_id.unwrap_or(0);
                        if owner == 1 || owner == 2 {
                            let enemy_pid = if owner == 1 { 2 } else { 1 };
                            if killed.name == "CreepTumorBurrowed"
                                && ud.killer_player_id == Some(enemy_pid)
                                && let Some(p) = players.get_mut(&owner)
                            {
                                p.creep_cleared_by_enemy += 1;
                            }
                            let base = base_unit_name(&killed.name).to_string();
                            if has_resource_cost(patch_balance, &base)
                                && !is_morph_death(&base, killer.is_some())
                            {
                                let cost_info = lookup_unit_cost(patch_balance, &base);
                                let res_val = cost_info.minerals + cost_info.vespene;
                                let kx = round1(killed.pos.x());
                                let ky = round1(killed.pos.y());
                                let killer_name = killer
                                    .as_ref()
                                    .map(|k| base_unit_name(&k.name).to_string())
                                    .unwrap_or_else(|| "Environment".to_string());

                                // Record spatial death cell (4x4 tile bins)
                                let cell = ((kx.max(0.0) as u32) / 4, (ky.max(0.0) as u32) / 4);
                                let dc = death_cells.entry(cell).or_default();
                                dc.0 += 1;
                                dc.1 += res_val;

                                if let Some(k) = killer.as_ref()
                                    && k.name.contains("SiegeTank")
                                {
                                    let scell = (
                                        (k.pos.x().max(0.0) as u32) / 4,
                                        (k.pos.y().max(0.0) as u32) / 4,
                                    );
                                    let sc = siege_cells.entry(scell).or_default();
                                    sc.0 += 1;
                                    sc.1 += res_val;
                                }

                                let mining_sec = players
                                    .get(&owner)
                                    .map(|p| {
                                        let inc =
                                            p.last_stats.min_rate + p.last_stats.gas_rate;
                                        if inc > 0 {
                                            res_val as f32 * 60.0 / inc as f32
                                        } else {
                                            0.0
                                        }
                                    })
                                    .unwrap_or(0.0);

                                if let Some(p) = players.get_mut(&owner) {
                                    p.prod_last_finish.remove(&killed.tag_index);
                                    *p.lost_counts.entry(base.clone()).or_default() += 1;
                                    p.resources_lost += res_val;
                                    p.mining_sec_lost += mining_sec;
                                    if killer.is_some() {
                                        *p.killed_by.entry(killer_name.clone()).or_default() += 1;
                                    }
                                    if TOWNHALLS.contains(&killed.name.as_str()) {
                                        p.bases_lost.push((
                                            round1(sec_f),
                                            format!("{} killed by {}", killed.name, killer_name),
                                        ));
                                    }
                                }
                                if killer.is_some()
                                    && let Some(ep) = players.get_mut(&enemy_pid)
                                {
                                    ep.resources_killed += res_val;
                                    let ku = ep.kills_by_unit.entry(killer_name.clone()).or_default();
                                    ku.0 += 1;
                                    ku.1 += res_val;
                                }

                                raw_deaths.push(RawDeathEvent {
                                    sec: sec_u,
                                    owner_pid: owner,
                                    unit: base.clone(),
                                    x: kx,
                                    y: ky,
                                    cost: res_val,
                                    mining_sec,
                                });
                                recent_deaths.push_back((
                                    gl,
                                    MinimapDeath {
                                        x: kx,
                                        y: ky,
                                        owner,
                                        unit: base,
                                        killer: killer_name,
                                    },
                                ));
                            }
                        }
                    }
                }
                ReplayTrackerEvent::PlayerStats(ps) => {
                    if ps.player_id == 1 || ps.player_id == 2 {
                        let st = &ps.stats;
                        let army_val =
                            st.minerals_used_current_army + st.vespene_used_current_army;
                        let killed_val = st.minerals_killed_army
                            + st.minerals_killed_economy
                            + st.minerals_killed_technology
                            + st.vespene_killed_army
                            + st.vespene_killed_economy
                            + st.vespene_killed_technology;

                        // Caster seconds alive up to 10:00
                        let interval = players
                            .get(&ps.player_id)
                            .and_then(|p| p.last_stats_sec)
                            .map(|prev| sec_u.saturating_sub(prev))
                            .unwrap_or(0);

                        if sec_u <= SNAPSHOT_SECONDS && interval > 0 {
                            for u in iter.sc2_state.units.values() {
                                if !u.is_init
                                    && u.user_id == Some(ps.player_id)
                                    && let Some(c) = CASTERS.iter().find(|&&c| c == u.name)
                                    && let Some(p) = players.get_mut(&ps.player_id)
                                {
                                    *p.caster_seconds.entry(c).or_default() += interval as f32;
                                }
                            }
                        }

                        if let Some(p) = players.get_mut(&ps.player_id) {
                            p.last_stats_sec = Some(sec_u);
                            p.last_stats = FramePlayerStat {
                                minerals: st.minerals_current,
                                vespene: st.vespene_current,
                                min_rate: st.minerals_collection_rate,
                                gas_rate: st.vespene_collection_rate,
                                workers: st.workers_active_count,
                                food_used: st.food_used,
                                food_made: st.food_made,
                                army_value: army_val,
                                killed_value: killed_val,
                            };
                            let inc = st.minerals_collection_rate + st.vespene_collection_rate;
                            p.side_stats = SideStats {
                                army: army_val,
                                income: inc,
                                workers: st.workers_active_count,
                                killed: killed_val,
                            };
                            if st.food_made > 0 && st.food_used >= st.food_made && interval > 0 {
                                p.supply_full_intervals
                                    .push((sec_u.saturating_sub(interval), sec_u));
                                if st.food_made < 200 {
                                    p.supply_blocked_sec += interval;
                                }
                            }
                            if sec_u >= 60 {
                                p.income_samples.push(inc);
                                let unspent = st.minerals_current + st.vespene_current;
                                p.unspent_samples.push(unspent);
                                if unspent > FLOATING_THRESHOLD {
                                    p.floating_sec += interval;
                                }
                            }
                        }
                    }
                }
                _ => {}
            },
            SC2EventType::Game {
                user_id,
                player_name,
                event,
                ..
            } => {
                let pid = user_id_to_pid.get(user_id).copied().or_else(|| {
                    let pname = player_name.as_deref().map(clean_player_name)?;
                    players
                        .values()
                        .find(|p| p.name == pname)
                        .map(|p| p.pid)
                });
                let Some(pid) = pid else {
                    continue;
                };
                let enemy_start = players
                    .get(&if pid == 1 { 2 } else { 1 })
                    .and_then(|ep| ep.start_xy);

                match event {
                    ReplayGameEvent::CameraUpdate(cam) => {
                        if let Some(target) = &cam.m_target
                            && let Some(p) = players.get_mut(&pid)
                        {
                            p.camera_moves += 1;
                            p.camera_xy = [
                                round1(target.x as f32 / 256.0),
                                round1(target.y as f32 / 256.0),
                            ];
                        }
                    }
                    ReplayGameEvent::ControlGroupUpdate(cg) => {
                        if let Some(p) = players.get_mut(&pid) {
                            match cg.m_control_group_update {
                                GameEControlGroupUpdate::ERecall => p.cg_recalls += 1,
                                GameEControlGroupUpdate::EClear => {}
                                _ => {
                                    p.cg_assigns += 1;
                                    p.control_groups.insert(cg.m_control_group_index);
                                }
                            }
                        }
                    }
                    ReplayGameEvent::Cmd(cmd) => {
                        let enriched_cmd = match &item.change_hint {
                            UnitChangeHint::Abilities { event, .. } => event,
                            _ => cmd,
                        };
                        let abil_link = enriched_cmd
                            .m_abil
                            .as_ref()
                            .map(|a| a.m_abil_link)
                            .unwrap_or(0);
                        let ability = enriched_cmd
                            .m_abil
                            .as_ref()
                            .map(|a| a.ability.as_str())
                            .unwrap_or("");
                        let is_spam = is_move_or_attack(ability, abil_link, protocol_version);

                        let target_xy: Option<[f32; 2]> = match &enriched_cmd.m_data {
                            GameSCmdData::TargetPoint(pt) => {
                                let v: s2protocol::Vec3D = pt.clone().into();
                                Some([round1(v.x()), round1(-v.y())])
                            }
                            GameSCmdData::TargetUnit(tu) => {
                                let v: s2protocol::Vec3D = tu.m_snapshot_point.clone().into();
                                Some([round1(v.x()), round1(-v.y())])
                            }
                            _ => None,
                        };

                        if let Some(p) = players.get_mut(&pid) {
                            p.raw_commands += 1;
                            if !is_spam && enriched_cmd.m_abil.is_some() {
                                p.macro_filtered_commands += 1;
                            }
                            if !ability.is_empty() && !is_spam {
                                *p.ability_counts.entry(ability.to_string()).or_default() += 1;
                            }
                            let early = sec_u <= SNAPSHOT_SECONDS;
                            if ability.starts_with("SpawnLarva") {
                                p.injects += 1;
                                if early {
                                    p.early_injects += 1;
                                }
                            } else if ability.starts_with("ChronoBoost") {
                                p.chrono_boosts += 1;
                                if early {
                                    p.early_chrono_boosts += 1;
                                }
                            } else if ability.starts_with("CalldownMULE") {
                                p.mules += 1;
                                if early {
                                    p.early_mules += 1;
                                }
                            }
                            if let Some(bldg) = extract_build_target_name(ability) {
                                let base_bldg = base_unit_name(&bldg).to_string();
                                let entry = p.wire_builds.entry(base_bldg).or_default();
                                entry.0 += 1;
                                if entry.1.is_none() {
                                    entry.1 = Some(round1(sec_f));
                                }
                                if entry.2.is_none() {
                                    entry.2 = target_xy;
                                }
                            }

                            if let UnitChangeHint::Abilities { units, .. } = &item.change_hint {
                                let is_build_cmd = ability.starts_with("Build.");
                                for u in units {
                                    let ubase = base_unit_name(&u.name);
                                    if WORKERS.contains(&ubase) {
                                        if is_build_cmd {
                                            p.last_worker_build_loop.insert(u.tag_index, gl);
                                        } else if let Some(prev_gl) =
                                            p.last_worker_build_loop.get(&u.tag_index)
                                            && gl - *prev_gl <= 16
                                            && (is_spam || ability.contains("Harvest"))
                                        {
                                            p.worker_thrash_events += 1;
                                        }
                                    }
                                    if p.first_scout.is_none()
                                        && !NOT_SCOUTS.contains(&ubase)
                                        && let (Some([tx, ty]), Some([ex, ey])) =
                                            (target_xy, enemy_start)
                                    {
                                        let d = ((tx - ex).powi(2) + (ty - ey).powi(2)).sqrt();
                                        if d <= SCOUT_DISTANCE {
                                            p.first_scout =
                                                Some((round1(sec_f), ubase.to_string()));
                                        }
                                    }
                                }
                                if let Some([tx, ty]) = target_xy {
                                    let rkind =
                                        classify_ray_kind(ability, abil_link, protocol_version);
                                    // Limit per-step micro rays so high-APM steps stay compact
                                    for u in units.iter().take(if rkind == 0 { 2 } else { 4 }) {
                                        active_rays.push_back((
                                            gl,
                                            MinimapRay {
                                                ox: round1(u.pos.x()),
                                                oy: round1(u.pos.y()),
                                                tx,
                                                ty,
                                                owner: pid,
                                                kind: rkind,
                                                label: if ability.is_empty() {
                                                    "RightClick".to_string()
                                                } else {
                                                    ability.to_string()
                                                },
                                            },
                                        ));
                                    }
                                }
                            }
                        }
                    }
                    ReplayGameEvent::CmdUpdateTargetPoint(_)
                    | ReplayGameEvent::CmdUpdateTargetUnit(_) => {
                        let units_slice: &[SC2Unit] = match &item.change_hint {
                            UnitChangeHint::TargetPoints(u) => u,
                            UnitChangeHint::TargetUnits { units, .. } => units,
                            _ => &[],
                        };
                        for u in units_slice.iter().take(2) {
                            let tgt = match &u.cmd.data {
                                SC2UnitCmdData::TargetPoint(tp) => {
                                    Some([round1(tp.x()), round1(-tp.y())])
                                }
                                SC2UnitCmdData::TargetUnit(tu) => Some([
                                    round1(tu.snapshot_point.x()),
                                    round1(-tu.snapshot_point.y()),
                                ]),
                                _ => None,
                            };
                            if let Some([tx, ty]) = tgt {
                                active_rays.push_back((
                                    gl,
                                    MinimapRay {
                                        ox: round1(u.pos.x()),
                                        oy: round1(u.pos.y()),
                                        tx,
                                        ty,
                                        owner: pid,
                                        kind: 0,
                                        label: "UpdateTarget".to_string(),
                                    },
                                ));
                            }
                        }
                    }
                    _ => {}
                }
            }
        }

        if frames.is_empty() && gl == 0 {
            frames.push(snapshot_frame(
                0,
                &iter.sc2_state,
                &players,
                &active_rays,
                &recent_deaths,
            ));
            next_frame_loop = sample_interval_loops;
        }
    }

    // Push final end-of-game frame
    frames.push(snapshot_frame(
        max_loop,
        &iter.sc2_state,
        &players,
        &active_rays,
        &recent_deaths,
    ));

    if map_w < 32.0 {
        map_w = max_seen_x.max(152.0);
    }
    if map_h < 32.0 {
        map_h = max_seen_y.max(152.0);
    }

    let engagements = cluster_engagements(&raw_deaths);
    let turning_points = compute_turning_points(&win_chance_curve, &engagements);

    let mut findings: Vec<String> = Vec::new();
    let duration_sec = round1(max_loop as f32 / GAME_LOOPS_PER_SECOND as f32);
    let game_mins = (duration_sec / 60.0).max(1.0);

    let mut player_reports = Vec::new();
    for pid in [1u8, 2u8] {
        let Some(p) = players.remove(&pid) else {
            continue;
        };
        let mut all_bldg_keys: BTreeSet<String> = BTreeSet::new();
        all_bldg_keys.extend(p.wire_builds.keys().cloned());
        all_bldg_keys.extend(p.unit_inits.keys().cloned());

        let mut wire_actuation_audit = Vec::new();
        for bldg in all_bldg_keys {
            let (w_cnt, w_sec, w_xy) = p
                .wire_builds
                .get(&bldg)
                .cloned()
                .unwrap_or((0, None, None));
            let (i_cnt, i_sec) = p.unit_inits.get(&bldg).cloned().unwrap_or((0, None));
            let d_cnt = p.unit_dones.get(&bldg).copied().unwrap_or(0);
            let canceled_or_sniped = i_cnt.saturating_sub(d_cnt);
            let status = if w_cnt > 0 && i_cnt == 0 {
                findings.push(format!(
                    "[WIRE_BUILD_DROPPED] {} issued Build.{} {}x (first {:?}s at {:?}) with 0 SUnitInit!",
                    p.name, bldg, w_cnt, w_sec, w_xy
                ));
                "WIRE_DROPPED_0_INIT".to_string()
            } else if i_cnt > 0 && d_cnt == 0 {
                findings.push(format!(
                    "[CONSTRUCTION_FAILED] {} started {} ({}x) but 0 completed (sniped/canceled)!",
                    p.name, bldg, i_cnt
                ));
                "SNIPED_OR_CANCELED".to_string()
            } else {
                "OK".to_string()
            };
            wire_actuation_audit.push(WireActuationAuditRow {
                structure: bldg,
                wire_build_cmds: w_cnt,
                unit_init_count: i_cnt,
                unit_done_count: d_cnt,
                canceled_or_sniped,
                first_wire_sec: w_sec,
                first_init_sec: i_sec,
                sample_target_xy: w_xy,
                status,
            });
        }

        if p.worker_thrash_events > 10 {
            findings.push(format!(
                "[WORKER_BUILD_THRASH] {} interrupted a building worker within <=16 loops {}x!",
                p.name, p.worker_thrash_events
            ));
        }
        if let Some((sec, bldg, dist)) = &p.proxy_detected {
            findings.push(format!(
                "[PROXY_DETECTED] {} built proxy {} at {}s ({} tiles from start)",
                p.name, bldg, sec, dist
            ));
        }

        let mut top_abilities: Vec<(String, u32)> = p.ability_counts.into_iter().collect();
        top_abilities.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        top_abilities.truncate(12);

        let mut production_idle: Vec<ProductionIdleRow> = p
            .prod_idle
            .into_iter()
            .map(|(structure, (facilities, idle_seconds))| ProductionIdleRow {
                structure,
                facilities: facilities.max(1),
                idle_seconds,
            })
            .collect();
        production_idle.sort_by(|a, b| b.idle_seconds.cmp(&a.idle_seconds));

        let ability_efficiency = compute_ability_efficiency(
            &p.caster_seconds,
            p.early_injects,
            p.early_chrono_boosts,
            p.early_mules,
        );

        let mut unit_effectiveness: Vec<UnitEffectivenessRow> = p
            .produced
            .iter()
            .filter_map(|(u, &prod)| {
                let c = lookup_unit_cost(patch_balance, u);
                let unit_cost = c.minerals + c.vespene;
                if unit_cost == 0 || WORKERS.contains(&u.as_str()) || is_structure_unit(patch_balance, u)
                {
                    return None;
                }
                let (kills, value_killed) = p.kills_by_unit.get(u).copied().unwrap_or((0, 0));
                let lost = p.lost_counts.get(u).copied().unwrap_or(0);
                let roi = value_killed as f32 / (unit_cost * prod.max(1) as u32) as f32;
                Some(UnitEffectivenessRow {
                    unit: u.clone(),
                    produced: prod,
                    lost,
                    kills,
                    value_killed,
                    unit_cost,
                    roi: round2(roi),
                })
            })
            .collect();
        unit_effectiveness.sort_by(|a, b| b.value_killed.cmp(&a.value_killed));

        let mut killed_by: Vec<(String, usize)> = p.killed_by.into_iter().collect();
        killed_by.sort_by(|a, b| b.1.cmp(&a.1));

        let avg_income = if p.income_samples.is_empty() {
            0
        } else {
            (p.income_samples.iter().sum::<i32>() / p.income_samples.len() as i32).max(0) as u32
        };
        let avg_unspent = if p.unspent_samples.is_empty() {
            0
        } else {
            (p.unspent_samples.iter().sum::<i32>() / p.unspent_samples.len() as i32).max(0) as u32
        };

        let lessons = rank_lessons(
            pid,
            p.supply_blocked_sec,
            avg_income,
            avg_unspent,
            p.floating_sec,
            &production_idle,
            &ability_efficiency,
            &engagements,
        );

        let spam_cmds = p.raw_commands.saturating_sub(p.macro_filtered_commands);
        let spam_pct = if p.raw_commands > 0 {
            round1(spam_cmds as f32 * 100.0 / p.raw_commands as f32)
        } else {
            0.0
        };

        player_reports.push(PlayerForensicReport {
            pid,
            name: p.name,
            declared_race: p.declared_race,
            actual_race: p.actual_race,
            result: p.result,
            scaled_rating: p.scaled_rating,
            start_xy: p.start_xy,
            opening_tech: p.opening_tech,
            raw_commands: p.raw_commands,
            macro_filtered_commands: p.macro_filtered_commands,
            raw_cpm: round1(p.raw_commands as f32 / game_mins),
            macro_cpm: round1(p.macro_filtered_commands as f32 / game_mins),
            move_attack_spam_pct: spam_pct,
            worker_thrash_events: p.worker_thrash_events,
            control_groups_used: p.control_groups.into_iter().collect(),
            control_group_assigns: p.cg_assigns,
            control_group_recalls_per_min: round1(p.cg_recalls as f32 / game_mins),
            camera_moves_per_min: round1(p.camera_moves as f32 / game_mins),
            top_abilities,
            supply_blocked_seconds: p.supply_blocked_sec,
            floating_seconds: p.floating_sec,
            avg_unspent,
            avg_income,
            mining_seconds_lost: round1(p.mining_sec_lost),
            resources_lost: p.resources_lost,
            resources_killed: p.resources_killed,
            injects: p.injects,
            chrono_boosts: p.chrono_boosts,
            mules: p.mules,
            creep_tumors_placed: p.creep_placed,
            creep_tumors_cleared_by_enemy: p.creep_cleared_by_enemy,
            first_scout: p.first_scout,
            proxy_detected: p.proxy_detected,
            bases_lost: p.bases_lost,
            wire_actuation_audit,
            production_idle,
            ability_efficiency,
            unit_effectiveness,
            killed_by,
            good_decisions: p.good_decisions,
            even_decisions: p.even_decisions,
            bad_decisions: p.bad_decisions,
            lessons,
        });
    }

    let mut death_heatmap: Vec<HeatmapCell> = death_cells
        .into_iter()
        .map(|((x, y), (count, value))| HeatmapCell {
            x: x * 4 + 2,
            y: y * 4 + 2,
            count,
            value,
        })
        .collect();
    death_heatmap.sort_by(|a, b| b.value.cmp(&a.value));

    let mut siege_spots: Vec<HeatmapCell> = siege_cells
        .into_iter()
        .map(|((x, y), (count, value))| HeatmapCell {
            x: x * 4 + 2,
            y: y * 4 + 2,
            count,
            value,
        })
        .collect();
    siege_spots.sort_by(|a, b| b.value.cmp(&a.value));

    Ok(ReplaySidecarBundle {
        replay_id: replay_id.to_string(),
        file_name: file_name.to_string(),
        sha256: basic_data.init_data.ext_fs_sha256,
        protocol_version,
        map_name: basic_data.details.title,
        map_width: round1(map_w),
        map_height: round1(map_h),
        total_loops: max_loop,
        duration_sec,
        sample_interval_loops,
        parse_elapsed_ms: (t0.elapsed().as_secs_f64() * 1000.0 * 100.0).round() / 100.0,
        players: player_reports,
        win_chance_curve,
        turning_points,
        engagements,
        findings,
        static_objects,
        death_heatmap,
        siege_spots,
        frames,
        priority_snapshots,
    })
}

fn compute_ability_efficiency(
    casters: &BTreeMap<&'static str, f32>,
    early_injects: u32,
    early_chronos: u32,
    early_mules: u32,
) -> Vec<AbilityEfficiencyRow> {
    let sum_sec = |names: &[&str]| -> f32 {
        names.iter().filter_map(|n| casters.get(n)).sum()
    };
    let mut out = Vec::new();
    let q_sec = sum_sec(&["Queen"]);
    if q_sec > 0.0 {
        let possible = (q_sec * ENERGY_PER_SECOND / 25.0)
            .min(sum_sec(&["Hatchery", "Lair", "Hive"]) / INJECT_SECONDS);
        if possible >= 0.5 {
            out.push(AbilityEfficiencyRow {
                ability: "Inject Larva".to_string(),
                caster: "Queen".to_string(),
                uses_until_10m: early_injects,
                possible_until_10m: round1(possible),
                efficiency_pct: round1((early_injects as f32 * 100.0 / possible).min(100.0)),
            });
        }
    }
    let nx_sec = sum_sec(&["Nexus"]);
    if nx_sec > 0.0 {
        let possible = nx_sec * ENERGY_PER_SECOND / 50.0;
        if possible >= 0.5 {
            out.push(AbilityEfficiencyRow {
                ability: "Chrono Boost".to_string(),
                caster: "Nexus".to_string(),
                uses_until_10m: early_chronos,
                possible_until_10m: round1(possible),
                efficiency_pct: round1((early_chronos as f32 * 100.0 / possible).min(100.0)),
            });
        }
    }
    let oc_sec = sum_sec(&["OrbitalCommand"]);
    if oc_sec > 0.0 {
        let possible = oc_sec * ENERGY_PER_SECOND / 50.0;
        if possible >= 0.5 {
            out.push(AbilityEfficiencyRow {
                ability: "Calldown MULE".to_string(),
                caster: "OrbitalCommand".to_string(),
                uses_until_10m: early_mules,
                possible_until_10m: round1(possible),
                efficiency_pct: round1((early_mules as f32 * 100.0 / possible).min(100.0)),
            });
        }
    }
    out
}

fn cluster_engagements(deaths: &[RawDeathEvent]) -> Vec<EngagementSummary> {
    let mut groups: Vec<Vec<&RawDeathEvent>> = Vec::new();
    for d in deaths {
        match groups.last_mut() {
            Some(g)
                if d.sec <= g.last().map(|x| x.sec).unwrap_or(0) + ENGAGEMENT_GAP_SECONDS
                    && d.sec <= g.first().map(|x| x.sec).unwrap_or(0) + MAX_ENGAGEMENT_SECONDS =>
            {
                g.push(d);
            }
            _ => groups.push(vec![d]),
        }
    }
    groups
        .into_iter()
        .filter_map(|g| {
            let total: u32 = g.iter().map(|d| d.cost).sum();
            if total < MIN_ENGAGEMENT_RESOURCES {
                return None;
            }
            let start_sec = g.first()?.sec;
            let end_sec = g.last()?.sec;
            let n = g.len() as f32;
            let cx = round1(g.iter().map(|d| d.x).sum::<f32>() / n);
            let cy = round1(g.iter().map(|d| d.y).sum::<f32>() / n);
            let mut p1_lost = 0u32;
            let mut p2_lost = 0u32;
            let mut p1_msec = 0.0f32;
            let mut p2_msec = 0.0f32;
            let mut p1_u: BTreeMap<String, usize> = BTreeMap::new();
            let mut p2_u: BTreeMap<String, usize> = BTreeMap::new();
            for d in g {
                if d.owner_pid == 1 {
                    p1_lost += d.cost;
                    p1_msec += d.mining_sec;
                    *p1_u.entry(d.unit.clone()).or_default() += 1;
                } else {
                    p2_lost += d.cost;
                    p2_msec += d.mining_sec;
                    *p2_u.entry(d.unit.clone()).or_default() += 1;
                }
            }
            Some(EngagementSummary {
                start_sec,
                end_sec,
                center_x: cx,
                center_y: cy,
                p1_lost_resources: p1_lost,
                p2_lost_resources: p2_lost,
                p1_mining_sec_lost: round1(p1_msec),
                p2_mining_sec_lost: round1(p2_msec),
                p1_units_lost: format_counts_map(&p1_u),
                p2_units_lost: format_counts_map(&p2_u),
            })
        })
        .collect()
}

fn compute_turning_points(
    curve: &[WinChanceSample],
    engagements: &[EngagementSummary],
) -> Vec<TurningPointRecord> {
    if curve.len() <= 2 {
        return vec![];
    }
    let mut deltas: Vec<(usize, f32)> = (2..curve.len())
        .map(|i| (i, curve[i].p1_chance - curve[i - 2].p1_chance))
        .filter(|(_, d)| d.abs() >= 0.15)
        .collect();
    deltas.sort_by(|a, b| b.1.abs().total_cmp(&a.1.abs()));
    let mut chosen: Vec<(usize, f32)> = Vec::new();
    for (idx, d) in deltas {
        if chosen.len() >= 3 {
            break;
        }
        if chosen.iter().all(|(o, _)| o.abs_diff(idx) > 2) {
            chosen.push((idx, d));
        }
    }
    chosen.sort_by_key(|(idx, _)| *idx);
    chosen
        .into_iter()
        .map(|(idx, d)| {
            let start_sec = curve[idx - 2].sec;
            let end_sec = curve[idx].sec;
            let summary = engagements
                .iter()
                .filter(|e| e.end_sec + 30 >= start_sec && e.start_sec <= end_sec)
                .max_by_key(|e| e.p1_lost_resources + e.p2_lost_resources)
                .map(|e| {
                    format!(
                        "P1 lost {} ({}) vs P2 lost {} ({}) near ({}, {})",
                        e.p1_lost_resources,
                        e.p1_units_lost,
                        e.p2_lost_resources,
                        e.p2_units_lost,
                        e.center_x,
                        e.center_y
                    )
                })
                .unwrap_or_else(|| "Macro economy/army swing".to_string());
            TurningPointRecord {
                start_sec,
                end_sec,
                delta_p1_chance: round2(d),
                summary,
            }
        })
        .collect()
}

#[allow(clippy::too_many_arguments)]
fn rank_lessons(
    pid: u8,
    supply_blocked_sec: u32,
    avg_income: u32,
    avg_unspent: u32,
    floating_sec: u32,
    prod_idle: &[ProductionIdleRow],
    eff: &[AbilityEfficiencyRow],
    engagements: &[EngagementSummary],
) -> Vec<CostedLesson> {
    let mut out = Vec::new();
    let inc_per_sec = avg_income as f32 / 60.0;
    if supply_blocked_sec > 0 {
        let cost = (supply_blocked_sec as f32 * inc_per_sec) as u32;
        if cost >= 100 {
            out.push(CostedLesson {
                title: "Supply blocked".to_string(),
                detail: format!("{supply_blocked_sec}s capped below 200 supply"),
                mineral_equiv_cost: cost,
                at_sec: None,
            });
        }
    }
    let total_idle: u32 = prod_idle.iter().map(|r| r.idle_seconds).sum();
    if let Some(worst) = prod_idle.first() {
        let cost = total_idle * 2;
        if cost >= 100 {
            out.push(CostedLesson {
                title: "Idle production".to_string(),
                detail: format!(
                    "{total_idle}s total facility idle (worst: {} {}s)",
                    worst.structure, worst.idle_seconds
                ),
                mineral_equiv_cost: cost,
                at_sec: None,
            });
        }
    }
    if avg_unspent > FLOATING_THRESHOLD as u32 {
        let cost = avg_unspent - FLOATING_THRESHOLD as u32;
        if cost >= 100 {
            out.push(CostedLesson {
                title: "Floating resources".to_string(),
                detail: format!("{avg_unspent} avg unspent ({floating_sec}s > 1000 bank)"),
                mineral_equiv_cost: cost,
                at_sec: None,
            });
        }
    }
    for e in eff {
        let missed = (e.possible_until_10m - e.uses_until_10m as f32).max(0.0);
        let unit_val = match e.ability.as_str() {
            "Inject Larva" => 50.0,
            "Chrono Boost" => 20.0,
            _ => 225.0,
        };
        let cost = (missed * unit_val) as u32;
        if missed >= 1.0 && cost >= 100 {
            out.push(CostedLesson {
                title: format!("Missed {}", e.ability),
                detail: format!(
                    "{}/~{:.0} uses by 10:00 ({:.0}%)",
                    e.uses_until_10m, e.possible_until_10m, e.efficiency_pct
                ),
                mineral_equiv_cost: cost,
                at_sec: None,
            });
        }
    }
    if let Some((worst_e, own_lost, net_deficit)) = engagements
        .iter()
        .filter_map(|e| {
            let (own, opp) = if pid == 1 {
                (e.p1_lost_resources, e.p2_lost_resources)
            } else {
                (e.p2_lost_resources, e.p1_lost_resources)
            };
            (own > opp + 100).then_some((e, own, own - opp))
        })
        .max_by_key(|(_, _, def)| *def)
    {
        out.push(CostedLesson {
            title: "Unfavorable engagement".to_string(),
            detail: format!(
                "Lost {own_lost} vs {} killed at {}s ({}, {})",
                own_lost - net_deficit,
                worst_e.start_sec,
                worst_e.center_x,
                worst_e.center_y
            ),
            mineral_equiv_cost: net_deficit,
            at_sec: Some(worst_e.start_sec),
        });
    }
    out.sort_by(|a, b| b.mineral_equiv_cost.cmp(&a.mineral_equiv_cost));
    out.truncate(5);
    out
}
