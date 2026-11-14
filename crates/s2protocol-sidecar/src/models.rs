//! Serializable data models and internal accumulator structures for `s2protocol-sidecar`.

use crate::terrain::TerrainOverlay;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CatalogEntry {
    pub id: String,
    pub file_name: String,
    pub source_dir: String,
    pub size_bytes: u64,
    pub modified_epoch_sec: u64,
    pub map_name: String,
    pub p1_name: String,
    pub p1_race: String,
    pub p1_result: String,
    pub p2_name: String,
    pub p2_race: String,
    pub p2_result: String,
    pub protocol_version: u32,
    pub has_priority_log: bool,
    #[serde(skip)]
    pub full_path: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UiPreloadBundle {
    pub generated_at_epoch_sec: u64,
    pub s2protocol_version: String,
    pub catalog: Vec<CatalogEntry>,
    pub replays: BTreeMap<String, ReplaySidecarBundle>,
}

#[derive(Debug, Default, Clone, Copy)]
pub struct UnitCostInfo {
    pub minerals: u32,
    pub vespene: u32,
    pub supply: f32,
    pub time_faster_sec: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnitDecisionRecord {
    pub sec: f32,
    pub unit: String,
    pub score: f64,
    pub strong_vs: String,
    pub weak_vs: String,
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
    #[serde(default)]
    pub tag: u32,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpgradeEventRecord {
    pub game_loop: i64,
    pub sec: f32,
    pub owner: u8,
    pub name: String,
    pub count: i32,
}

pub type UpgradeTimelineEvent = UpgradeEventRecord;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProductionSpan {
    pub owner: u8,
    /// "building" | "unit" | "upgrade"
    pub kind: String,
    pub name: String,
    pub start_sec: f32,
    pub end_sec: f32,
    /// Expected full build/research duration in Faster seconds (for accurate % when unfinished/canceled).
    pub full_sec: f32,
    pub approx: bool,
    pub x: Option<f32>,
    pub y: Option<f32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeathTimelineEvent {
    pub sec: f32,
    pub owner: u8,
    pub unit: String,
    pub cost: u32,
    pub x: f32,
    pub y: f32,
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
    /// Per player (`[P1, P2]`): `[current_apm_22s, avg_apm, avg_epm]`.
    pub apm: [[u16; 3]; 2],
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
    pub upgrade_events: Vec<UpgradeEventRecord>,
    pub production_spans: Vec<ProductionSpan>,
    pub death_log: Vec<DeathTimelineEvent>,
    #[serde(default)]
    pub terrain: Option<TerrainOverlay>,
}

#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct SideStats {
    pub(crate) army: i32,
    pub(crate) income: i32,
    pub(crate) workers: i32,
    pub(crate) killed: i32,
}

#[derive(Clone)]
pub(crate) struct RawDeathEvent {
    pub(crate) sec: u32,
    pub(crate) owner_pid: u8,
    pub(crate) unit: String,
    pub(crate) x: f32,
    pub(crate) y: f32,
    pub(crate) cost: u32,
    pub(crate) mining_sec: f32,
}

pub(crate) type WireBuildInfo = (u32, Option<f32>, Option<[f32; 2]>);

#[derive(Default)]
pub(crate) struct PerPlayerAcc {
    pub(crate) pid: u8,
    pub(crate) user_id: Option<i64>,
    pub(crate) name: String,
    pub(crate) declared_race: String,
    pub(crate) actual_race: String,
    pub(crate) result: String,
    pub(crate) scaled_rating: Option<i32>,
    pub(crate) start_xy: Option<[f32; 2]>,
    pub(crate) camera_xy: [f32; 2],
    pub(crate) last_stats: FramePlayerStat,
    pub(crate) side_stats: SideStats,
    pub(crate) last_stats_sec: Option<u32>,
    pub(crate) supply_blocked_sec: u32,
    pub(crate) supply_full_intervals: Vec<(u32, u32)>,
    pub(crate) floating_sec: u32,
    pub(crate) unspent_samples: Vec<i32>,
    pub(crate) income_samples: Vec<i32>,
    pub(crate) mining_sec_lost: f32,
    pub(crate) resources_lost: u32,
    pub(crate) resources_killed: u32,
    pub(crate) raw_commands: u32,
    pub(crate) macro_filtered_commands: u32,
    pub(crate) recent_cmd_loops: std::collections::VecDeque<i64>,
    pub(crate) worker_thrash_events: u32,
    pub(crate) last_worker_build_loop: HashMap<u32, i64>,
    pub(crate) control_groups: BTreeSet<u8>,
    pub(crate) cg_assigns: u32,
    pub(crate) cg_recalls: u32,
    pub(crate) camera_moves: u32,
    pub(crate) ability_counts: BTreeMap<String, u32>,
    pub(crate) wire_builds: BTreeMap<String, WireBuildInfo>,
    pub(crate) unit_inits: BTreeMap<String, (u32, Option<f32>)>,
    pub(crate) unit_dones: BTreeMap<String, u32>,
    pub(crate) injects: u32,
    pub(crate) early_injects: u32,
    pub(crate) chrono_boosts: u32,
    pub(crate) early_chrono_boosts: u32,
    pub(crate) mules: u32,
    pub(crate) early_mules: u32,
    pub(crate) caster_seconds: BTreeMap<&'static str, f32>,
    pub(crate) creep_placed: u32,
    pub(crate) creep_cleared_by_enemy: u32,
    pub(crate) first_scout: Option<(f32, String)>,
    pub(crate) proxy_detected: Option<(f32, String, f32)>,
    pub(crate) bases_lost: Vec<(f32, String)>,
    pub(crate) opening_tech: Vec<String>,
    pub(crate) produced: BTreeMap<String, usize>,
    pub(crate) lost_counts: BTreeMap<String, usize>,
    pub(crate) kills_by_unit: BTreeMap<String, (usize, u32)>,
    pub(crate) killed_by: BTreeMap<String, usize>,
    pub(crate) prod_last_finish: HashMap<u32, (String, u32)>,
    pub(crate) prod_idle: BTreeMap<String, (usize, u32)>,
    pub(crate) good_decisions: usize,
    pub(crate) even_decisions: usize,
    pub(crate) bad_decisions: Vec<UnitDecisionRecord>,
}

pub(crate) fn round1(v: f32) -> f32 {
    (v * 10.0).round() / 10.0
}

pub(crate) fn round2(v: f32) -> f32 {
    (v * 100.0).round() / 100.0
}
