//! Minimal State Machine, Enhanced Minimap Timeline, and Swarmy Forensic Engine
//! built directly on `sebosp/s2protocol-rs` (`s2protocol = "5.1.0"`).

pub use crate::analytics::*;
pub use crate::balance::*;
pub use crate::models::*;
pub use crate::priority_log::*;

use s2protocol::basic_replay_data::SC2ReplayBasicData;
use s2protocol::game_events::{
    GameEControlGroupUpdate, GameSCmdData, MultiVersionedBalanceUnits, ReplayGameEvent,
    VersionedBalanceUnits,
};
use s2protocol::state::SC2UnitCmdData;
use s2protocol::tracker_events::{
    ReplayTrackerEvent, UnitBornEvent, UnitDiedEvent, UnitDoneEvent, UnitInitEvent,
    UnitTypeChangeEvent, UpgradeEvent,
};
use s2protocol::{SC2EventIterator, SC2EventType, SC2ReplayState, SC2Unit, UnitChangeHint};
use std::collections::{BTreeSet, HashMap, HashSet, VecDeque};

struct ActiveProdSpan {
    pid: u8,
    kind: &'static str,
    name: String,
    start_sec: f32,
    full_sec: f32,
    x: f32,
    y: f32,
}

struct PendingCmdSpan {
    pid: u8,
    name: String,
    start_sec: f32,
    dur_sec: f32,
    xy: Option<[f32; 2]>,
}

struct ReplayAnalysisCtx<'a> {
    protocol_version: u32,
    patch_balance: &'a VersionedBalanceUnits,
    research_index: BalanceResearchIndex,
    players: HashMap<u8, PerPlayerAcc>,
    user_id_to_pid: HashMap<i64, u8>,
    static_objects: Vec<StaticMapObject>,
    static_tags: BTreeSet<u32>,
    born_counted_tags: HashSet<u32>,
    init_creators: HashMap<u32, (u32, String)>,
    active_inits: HashMap<u32, ActiveProdSpan>,
    active_morphs: HashMap<u32, ActiveProdSpan>,
    pending_research_cmds: HashMap<u32, PendingCmdSpan>,
    pending_train_cmds: HashMap<u32, PendingCmdSpan>,
    upgrade_events: Vec<UpgradeEventRecord>,
    production_spans: Vec<ProductionSpan>,
    scored_tags: HashMap<u32, String>,
    active_rays: VecDeque<(i64, MinimapRay)>,
    recent_deaths: VecDeque<(i64, MinimapDeath)>,
    raw_deaths: Vec<RawDeathEvent>,
    death_cells: HashMap<(u32, u32), (u32, u32)>,
    siege_cells: HashMap<(u32, u32), (u32, u32)>,
    max_seen_x: f32,
    max_seen_y: f32,
}

fn init_players(basic_data: &SC2ReplayBasicData) -> HashMap<u8, PerPlayerAcc> {
    let ratings_by_name: HashMap<String, i32> = basic_data
        .init_data
        .sync_lobby_state
        .user_initial_data
        .iter()
        .filter_map(|u| Some((clean_player_name(&u.name), u.scaled_rating?)))
        .collect();

    let mut players: HashMap<u8, PerPlayerAcc> = HashMap::new();
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
    players
}

fn find_max_replay_loop(
    basic_data: &SC2ReplayBasicData,
    bytes: &[u8],
    db: &MultiVersionedBalanceUnits,
) -> Result<i64, String> {
    let iter = SC2EventIterator::from_bytes(basic_data, bytes, db)
        .map_err(|e| format!("SC2EventIterator error: {e:?}"))?;
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
    Ok(max_loop)
}

fn find_priority_idx(priority_snapshots: &[PriorityLogSnapshot], gl: i64) -> Option<usize> {
    if priority_snapshots.is_empty() {
        return None;
    }
    match priority_snapshots.binary_search_by_key(&gl, |s| s.frame) {
        Ok(i) => Some(i),
        Err(0) => Some(0),
        Err(i) => Some(i - 1),
    }
}

fn compute_player_apm(p: &mut PerPlayerAcc, gl: i64) -> [u16; 3] {
    while p
        .recent_cmd_loops
        .front()
        .is_some_and(|&t| t + APM_WINDOW_LOOPS < gl)
    {
        p.recent_cmd_loops.pop_front();
    }
    if gl < 22 {
        return [0, 0, 0];
    }
    let cur_window_sec = (gl.clamp(112, APM_WINDOW_LOOPS) as f64) / GAME_LOOPS_PER_SECOND;
    let cur_apm = ((p.recent_cmd_loops.len() as f64 * 60.0 / cur_window_sec).round() as u32)
        .min(u16::MAX as u32) as u16;
    let elapsed_min = (gl as f64 / GAME_LOOPS_PER_SECOND) / 60.0;
    let (avg_apm, avg_epm) = if elapsed_min <= 0.001 {
        (0, 0)
    } else {
        (
            ((p.raw_commands as f64 / elapsed_min).round() as u32).min(u16::MAX as u32) as u16,
            ((p.macro_filtered_commands as f64 / elapsed_min).round() as u32)
                .min(u16::MAX as u32) as u16,
        )
    };
    [cur_apm, avg_apm, avg_epm]
}

fn snapshot_frame(
    gl: i64,
    state: &SC2ReplayState,
    ctx: &mut ReplayAnalysisCtx<'_>,
    priority_snapshots: &[PriorityLogSnapshot],
) -> MinimapFrame {
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
        } else if is_structure_unit(ctx.patch_balance, &u.name) {
            4
        } else {
            1
        };
        let display_name = if matches!(
            u.name.as_str(),
            "SupplyDepot"
                | "SupplyDepotLowered"
                | "SiegeTankSieged"
                | "WidowMineBurrowed"
                | "LurkerMPBurrowed"
                | "LiberatorAG"
        ) {
            u.name.as_str()
        } else {
            base
        };
        units.push(MinimapUnit {
            x,
            y,
            owner,
            kind,
            r: round1(u.radius.clamp(0.4, 2.8)),
            init: u.is_init,
            name: display_name.to_string(),
        });
    }

    let rays = ctx.active_rays.iter().map(|(_, r)| r.clone()).collect();
    let deaths = ctx.recent_deaths.iter().map(|(_, d)| d.clone()).collect();
    let p1 = ctx.players.get(&1);
    let p2 = ctx.players.get(&2);
    let cam_or_start = |p: Option<&PerPlayerAcc>| -> [f32; 2] {
        p.map(|acc| {
            if acc.camera_moves == 0 && acc.camera_xy == [0.0, 0.0] {
                acc.start_xy.unwrap_or([0.0, 0.0])
            } else {
                acc.camera_xy
            }
        })
        .unwrap_or([0.0, 0.0])
    };
    let cam1 = cam_or_start(p1);
    let cam2 = cam_or_start(p2);
    let p1_stats = p1.map(|p| p.last_stats.clone()).unwrap_or_default();
    let p2_stats = p2.map(|p| p.last_stats.clone()).unwrap_or_default();
    let apm1 = ctx
        .players
        .get_mut(&1)
        .map(|p| compute_player_apm(p, gl))
        .unwrap_or([0; 3]);
    let apm2 = ctx
        .players
        .get_mut(&2)
        .map(|p| compute_player_apm(p, gl))
        .unwrap_or([0; 3]);
    MinimapFrame {
        game_loop: gl,
        sec: round1(gl as f32 / GAME_LOOPS_PER_SECOND as f32),
        units,
        rays,
        deaths,
        cameras: [cam1, cam2],
        creep,
        pylons,
        p1_stats,
        p2_stats,
        apm: [apm1, apm2],
        priority_idx: find_priority_idx(priority_snapshots, gl),
    }
}

fn detect_proxy_distance(
    x: f32,
    y: f32,
    start_xy: [f32; 2],
    static_objects: &[StaticMapObject],
) -> Option<f32> {
    let [sx, sy] = start_xy;
    let mut clusters: Vec<Vec<[f32; 2]>> = Vec::new();
    for obj in static_objects {
        if obj.kind != 0 && obj.kind != 1 {
            continue;
        }
        let mut placed = false;
        for cl in &mut clusters {
            let n = cl.len() as f32;
            let cx = cl.iter().map(|q| q[0]).sum::<f32>() / n;
            let cy = cl.iter().map(|q| q[1]).sum::<f32>() / n;
            if ((obj.x - cx).powi(2) + (obj.y - cy).powi(2)).sqrt() <= 14.0 {
                cl.push([obj.x, obj.y]);
                placed = true;
                break;
            }
        }
        if !placed {
            clusters.push(vec![[obj.x, obj.y]]);
        }
    }
    let mut centroids: Vec<[f32; 2]> = clusters
        .into_iter()
        .map(|cl| {
            let n = cl.len().max(1) as f32;
            [
                cl.iter().map(|q| q[0]).sum::<f32>() / n,
                cl.iter().map(|q| q[1]).sum::<f32>() / n,
            ]
        })
        .collect();
    centroids.sort_by(|a, b| {
        let da = (a[0] - sx).powi(2) + (a[1] - sy).powi(2);
        let db = (b[0] - sx).powi(2) + (b[1] - sy).powi(2);
        da.partial_cmp(&db).unwrap_or(std::cmp::Ordering::Equal)
    });
    let mut own_3_bases = vec![[sx, sy]];
    for c in centroids.into_iter().take(3) {
        own_3_bases.push(c);
    }
    let min_own_base_dist = own_3_bases
        .iter()
        .map(|b| ((x - b[0]).powi(2) + (y - b[1]).powi(2)).sqrt())
        .fold(f32::INFINITY, f32::min);
    (min_own_base_dist > PROXY_DISTANCE).then_some(min_own_base_dist)
}

fn evaluate_and_record_unit_choice(
    ctx: &mut ReplayAnalysisCtx<'_>,
    sc2_state: &SC2ReplayState,
    tag_index: u32,
    pid: u8,
    base: &str,
    sec_f: f32,
) {
    if ctx.scored_tags.get(&tag_index).map(String::as_str) == Some(base) {
        return;
    }
    ctx.scored_tags.insert(tag_index, base.to_string());
    let enemy_pid = if pid == 1 { 2 } else { 1 };
    let enemy_units = sc2_state
        .units
        .values()
        .filter(|eu| eu.user_id == Some(enemy_pid));
    let Some((sc, strong, weak)) = score_unit_choice(ctx.patch_balance, base, enemy_units) else {
        return;
    };
    let Some(p) = ctx.players.get_mut(&pid) else {
        return;
    };
    if sc > 0.05 {
        p.good_decisions += 1;
    } else if sc < -0.05 {
        p.bad_decisions.push(UnitDecisionRecord {
            sec: round1(sec_f),
            unit: base.to_string(),
            score: round2(sc as f32) as f64,
            strong_vs: format_counts_map(&strong),
            weak_vs: format_counts_map(&weak),
        });
    } else {
        p.even_decisions += 1;
    }
}

fn handle_unit_born(
    ctx: &mut ReplayAnalysisCtx<'_>,
    gl: i64,
    sec_f: f32,
    sec_u: u32,
    ub: &UnitBornEvent,
    change_hint: &UnitChangeHint,
    sc2_state: &SC2ReplayState,
) {
    let x = ub.x as f32;
    let y = ub.y as f32;
    ctx.max_seen_x = ctx.max_seen_x.max(x + 8.0);
    ctx.max_seen_y = ctx.max_seen_y.max(y + 8.0);
    if ub.control_player_id == 0 && !ctx.static_tags.contains(&ub.unit_tag_index) {
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
            ctx.static_tags.insert(ub.unit_tag_index);
            ctx.static_objects.push(StaticMapObject {
                x: round1(x),
                y: round1(y),
                kind: k,
                name: uname.to_string(),
            });
        }
        return;
    }
    if ub.control_player_id != 1 && ub.control_player_id != 2 {
        return;
    }
    let pid = ub.control_player_id;
    if gl == 0 {
        let rolled = match ub.unit_type_name.as_str() {
            "Hatchery" | "Drone" => Some("Zerg"),
            "CommandCenter" | "SCV" => Some("Terran"),
            "Nexus" | "Probe" => Some("Protoss"),
            _ => None,
        };
        if let Some(r) = rolled
            && let Some(p) = ctx.players.get_mut(&pid)
        {
            p.actual_race = r.to_string();
            if EXPANSION_TOWNHALLS.contains(&ub.unit_type_name.as_str()) {
                p.start_xy = Some([round1(x), round1(y)]);
                if p.camera_moves == 0 {
                    p.camera_xy = [round1(x), round1(y)];
                }
            }
        }
        return;
    }

    let base = base_unit_name(&ub.unit_type_name).to_string();
    if ub.unit_type_name == "CreepTumorBurrowed"
        && let Some(p) = ctx.players.get_mut(&pid)
    {
        p.creep_placed += 1;
    }
    if !has_resource_cost(ctx.patch_balance, &base) {
        return;
    }

    ctx.born_counted_tags.insert(ub.unit_tag_index);
    let is_struct = is_structure_unit(ctx.patch_balance, &base);
    if !is_struct {
        let btime = lookup_unit_cost(ctx.patch_balance, &base)
            .time_faster_sec
            .max(2.0);
        let mut start_sec = (sec_f - btime).max(0.0);
        let mut approx = true;
        if let UnitChangeHint::Registered {
            creator: Some(creator),
            ..
        } = change_hint
            && let Some(pcmd) = ctx.pending_train_cmds.get(&creator.tag_index)
            && base_unit_name(&pcmd.name) == base
            && sec_f >= pcmd.start_sec
            && (sec_f - pcmd.start_sec) <= btime * 1.35
        {
            start_sec = pcmd.start_sec;
            approx = false;
            ctx.pending_train_cmds.remove(&creator.tag_index);
        }
        ctx.production_spans.push(ProductionSpan {
            owner: pid,
            kind: "unit".to_string(),
            name: base.clone(),
            start_sec: round1(start_sec),
            end_sec: round1(sec_f),
            full_sec: round1((sec_f - start_sec).max(btime).max(1.0)),
            approx,
            x: Some(round1(x)),
            y: Some(round1(y)),
        });
    }
    if let Some(p) = ctx.players.get_mut(&pid) {
        *p.produced.entry(base.clone()).or_default() += 1;
        if is_struct {
            *p.unit_dones.entry(base.clone()).or_default() += 1;
        }
        if let UnitChangeHint::Registered {
            creator: Some(creator),
            ..
        } = change_hint
        {
            record_prod_idle(
                p,
                ctx.patch_balance,
                &base,
                creator.tag_index,
                &creator.name,
                sec_u,
            );
        }
    }
    evaluate_and_record_unit_choice(ctx, sc2_state, ub.unit_tag_index, pid, &base, sec_f);
}

fn record_prod_idle(
    p: &mut PerPlayerAcc,
    patch_balance: &VersionedBalanceUnits,
    base: &str,
    creator_tag: u32,
    creator_name: &str,
    sec_u: u32,
) {
    let cbase = base_unit_name(creator_name).to_string();
    if PRODUCTION_STRUCTURES.contains(&cbase.as_str()) {
        let btime = lookup_unit_cost(patch_balance, base).time_faster_sec as u32;
        let started = sec_u.saturating_sub(btime);
        let prev = p.prod_last_finish.insert(creator_tag, (cbase.clone(), sec_u));
        let entry = p.prod_idle.entry(cbase).or_default();
        match prev {
            Some((_, fin)) => {
                entry.1 += idle_gap_excluding_supply_full(fin, started, &p.supply_full_intervals);
            }
            None => entry.0 += 1,
        }
    }
}

fn handle_unit_init(
    ctx: &mut ReplayAnalysisCtx<'_>,
    sec_f: f32,
    sec_u: u32,
    ui: &UnitInitEvent,
    change_hint: &UnitChangeHint,
) {
    if ui.control_player_id != 1 && ui.control_player_id != 2 {
        return;
    }
    let pid = ui.control_player_id;
    let base = base_unit_name(&ui.unit_type_name).to_string();
    let x = ui.x as f32;
    let y = ui.y as f32;
    let is_struct = is_structure_unit(ctx.patch_balance, &base);
    let mut from_warpgate = false;
    if let UnitChangeHint::Registered {
        creator: Some(creator),
        ..
    } = change_hint
    {
        from_warpgate = creator.name == "WarpGate";
        ctx.init_creators
            .insert(ui.unit_tag_index, (creator.tag_index, creator.name.clone()));
    }
    let expected_sec = if from_warpgate {
        3.6
    } else {
        lookup_unit_cost(ctx.patch_balance, &base)
            .time_faster_sec
            .max(2.0)
    };
    ctx.active_inits.insert(
        ui.unit_tag_index,
        ActiveProdSpan {
            pid,
            kind: if is_struct { "building" } else { "unit" },
            name: base.clone(),
            start_sec: sec_f,
            full_sec: expected_sec,
            x: round1(x),
            y: round1(y),
        },
    );
    let Some(p) = ctx.players.get_mut(&pid) else {
        return;
    };
    let entry = p.unit_inits.entry(base.clone()).or_default();
    entry.0 += 1;
    if entry.1.is_none() {
        entry.1 = Some(round1(sec_f));
    }
    if p.opening_tech.len() < 4
        && is_structure_unit(ctx.patch_balance, &base)
        && !EXPANSION_TOWNHALLS.contains(&base.as_str())
        && !matches!(
            base.as_str(),
            "Pylon" | "SupplyDepot" | "Extractor" | "Assimilator" | "Refinery"
        )
        && !p.opening_tech.contains(&base)
    {
        p.opening_tech.push(base.clone());
    }
    if p.proxy_detected.is_none()
        && sec_u <= PROXY_MAX_SECONDS
        && !(sec_u > 150 && EXPANSION_TOWNHALLS.contains(&base.as_str()))
        && PROXY_STRUCTURES.contains(&base.as_str())
        && let Some(start_xy) = p.start_xy
        && let Some(dist) = detect_proxy_distance(x, y, start_xy, &ctx.static_objects)
    {
        p.proxy_detected = Some((round1(sec_f), base, round1(dist)));
    }
}

fn handle_unit_done(
    ctx: &mut ReplayAnalysisCtx<'_>,
    sec_f: f32,
    sec_u: u32,
    ud: &UnitDoneEvent,
    change_hint: &UnitChangeHint,
    sc2_state: &SC2ReplayState,
) {
    let init_creator = ctx.init_creators.remove(&ud.unit_tag_index);
    if let Some(act) = ctx.active_inits.remove(&ud.unit_tag_index) {
        let end_sec = round1(sec_f.max(act.start_sec + 0.2));
        ctx.production_spans.push(ProductionSpan {
            owner: act.pid,
            kind: act.kind.to_string(),
            name: act.name,
            start_sec: round1(act.start_sec),
            end_sec,
            full_sec: round1((sec_f - act.start_sec).max(0.5)),
            approx: false,
            x: Some(act.x),
            y: Some(act.y),
        });
    }
    let Some(u) = sc2_state.units.get(&ud.unit_tag_index) else {
        return;
    };
    let Some(pid) = u.user_id.filter(|&p| p == 1 || p == 2) else {
        return;
    };
    let base = base_unit_name(&u.name).to_string();
    let newly_counted = ctx.born_counted_tags.insert(ud.unit_tag_index);
    let creator_info = init_creator.or_else(|| {
        if let UnitChangeHint::Registered {
            creator: Some(creator),
            ..
        } = change_hint
        {
            Some((creator.tag_index, creator.name.clone()))
        } else {
            None
        }
    });
    let has_cost = has_resource_cost(ctx.patch_balance, &base);
    let is_struct = is_structure_unit(ctx.patch_balance, &base);
    if let Some(p) = ctx.players.get_mut(&pid) {
        *p.unit_dones.entry(base.clone()).or_default() += 1;
        if newly_counted && has_cost {
            *p.produced.entry(base.clone()).or_default() += 1;
            if !is_struct && let Some((ctag, cname)) = creator_info {
                record_prod_idle(p, ctx.patch_balance, &base, ctag, &cname, sec_u);
            }
        }
    }
    if newly_counted && has_cost && !is_struct {
        evaluate_and_record_unit_choice(ctx, sc2_state, ud.unit_tag_index, pid, &base, sec_f);
    }
}

fn handle_unit_type_change(
    ctx: &mut ReplayAnalysisCtx<'_>,
    sec_f: f32,
    utc: &UnitTypeChangeEvent,
    sc2_state: &SC2ReplayState,
) {
    let Some(u) = sc2_state.units.get(&utc.unit_tag_index) else {
        return;
    };
    let Some(pid) = u.user_id else {
        return;
    };
    if pid != 1 && pid != 2 {
        return;
    }
    if utc.unit_type_name == "CreepTumorBurrowed" {
        if let Some(p) = ctx.players.get_mut(&pid) {
            p.creep_placed += 1;
        }
        return;
    }
    let mname = utc.unit_type_name.as_str();
    let cocoon_target = match mname {
        "BanelingCocoon" => Some("Baneling"),
        "RavagerCocoon" => Some("Ravager"),
        "LurkerMPEgg" => Some("LurkerMP"),
        "BroodLordCocoon" => Some("BroodLord"),
        "OverlordCocoon" => Some("Overseer"),
        _ => None,
    };
    if let Some(target_name) = cocoon_target {
        let dur = lookup_unit_cost(ctx.patch_balance, target_name)
            .time_faster_sec
            .max(2.0);
        ctx.active_morphs.insert(
            utc.unit_tag_index,
            ActiveProdSpan {
                pid,
                kind: "unit",
                name: target_name.to_string(),
                start_sec: sec_f,
                full_sec: dur,
                x: round1(u.pos.x()),
                y: round1(u.pos.y()),
            },
        );
        return;
    }
    let is_morphed_tech_struct = matches!(
        mname,
        "Lair" | "Hive" | "GreaterSpire" | "OrbitalCommand" | "PlanetaryFortress"
    );
    let is_morphed_unit = matches!(
        mname,
        "Baneling" | "Ravager" | "LurkerMP" | "BroodLord" | "Overseer"
    );
    if is_morphed_tech_struct {
        let btime = lookup_unit_cost(ctx.patch_balance, mname)
            .time_faster_sec
            .max(15.0);
        ctx.production_spans.push(ProductionSpan {
            owner: pid,
            kind: "building".to_string(),
            name: mname.to_string(),
            start_sec: round1((sec_f - btime).max(0.0)),
            end_sec: round1(sec_f),
            full_sec: round1(btime),
            approx: true,
            x: Some(round1(u.pos.x())),
            y: Some(round1(u.pos.y())),
        });
        if let Some(p) = ctx.players.get_mut(&pid) {
            let entry = p.unit_inits.entry(mname.to_string()).or_default();
            entry.0 += 1;
            if entry.1.is_none() {
                entry.1 = Some(round1(sec_f));
            }
            *p.unit_dones.entry(mname.to_string()).or_default() += 1;
            *p.produced.entry(mname.to_string()).or_default() += 1;
            if p.opening_tech.len() < 4 && !p.opening_tech.contains(&mname.to_string()) {
                p.opening_tech.push(mname.to_string());
            }
        }
    } else if is_morphed_unit {
        let base = base_unit_name(mname).to_string();
        if let Some(act) = ctx.active_morphs.remove(&utc.unit_tag_index) {
            ctx.production_spans.push(ProductionSpan {
                owner: pid,
                kind: "unit".to_string(),
                name: base.clone(),
                start_sec: round1(act.start_sec),
                end_sec: round1(sec_f.max(act.start_sec + 0.5)),
                full_sec: round1((sec_f - act.start_sec).max(0.5)),
                approx: false,
                x: Some(round1(u.pos.x())),
                y: Some(round1(u.pos.y())),
            });
        }
        if let Some(p) = ctx.players.get_mut(&pid) {
            *p.produced.entry(base.clone()).or_default() += 1;
        }
        evaluate_and_record_unit_choice(ctx, sc2_state, utc.unit_tag_index, pid, &base, sec_f);
    }
}

fn handle_unit_died(
    ctx: &mut ReplayAnalysisCtx<'_>,
    gl: i64,
    sec_f: f32,
    sec_u: u32,
    ud: &UnitDiedEvent,
    change_hint: &UnitChangeHint,
) {
    for act in [
        ctx.active_inits.remove(&ud.unit_tag_index),
        ctx.active_morphs.remove(&ud.unit_tag_index),
    ]
    .into_iter()
    .flatten()
    {
        if sec_f > act.start_sec {
            ctx.production_spans.push(ProductionSpan {
                owner: act.pid,
                kind: act.kind.to_string(),
                name: act.name,
                start_sec: round1(act.start_sec),
                end_sec: round1(sec_f),
                full_sec: round1(act.full_sec.max(sec_f - act.start_sec)),
                approx: false,
                x: Some(act.x),
                y: Some(act.y),
            });
        }
    }
    ctx.pending_train_cmds.remove(&ud.unit_tag_index);
    if let Some(cmd) = ctx.pending_research_cmds.remove(&ud.unit_tag_index)
        && sec_f > cmd.start_sec
        && sec_f < cmd.start_sec + cmd.dur_sec
    {
        ctx.production_spans.push(ProductionSpan {
            owner: cmd.pid,
            kind: "upgrade".to_string(),
            name: cmd.name,
            start_sec: round1(cmd.start_sec),
            end_sec: round1(sec_f),
            full_sec: round1(cmd.dur_sec.max(1.0)),
            approx: true,
            x: cmd.xy.map(|p| p[0]),
            y: cmd.xy.map(|p| p[1]),
        });
    }

    let UnitChangeHint::Unregistered { killer, killed } = change_hint else {
        return;
    };
    let owner = killed.user_id.unwrap_or(0);
    if owner != 1 && owner != 2 {
        return;
    }
    let enemy_pid = if owner == 1 { 2 } else { 1 };
    if killed.name == "CreepTumorBurrowed"
        && ud.killer_player_id == Some(enemy_pid)
        && let Some(p) = ctx.players.get_mut(&owner)
    {
        p.creep_cleared_by_enemy += 1;
    }
    let base = base_unit_name(&killed.name).to_string();
    if !has_resource_cost(ctx.patch_balance, &base) || is_morph_death(&base, killer.is_some()) {
        return;
    }
    let cost_info = lookup_unit_cost(ctx.patch_balance, &base);
    let res_val = cost_info.minerals + cost_info.vespene;
    let kx = round1(killed.pos.x());
    let ky = round1(killed.pos.y());
    let killer_name = killer
        .as_ref()
        .map(|k| base_unit_name(&k.name).to_string())
        .unwrap_or_else(|| "Environment".to_string());

    // Record spatial death cell (4x4 tile bins)
    let cell = ((kx.max(0.0) as u32) / 4, (ky.max(0.0) as u32) / 4);
    let dc = ctx.death_cells.entry(cell).or_default();
    dc.0 += 1;
    dc.1 += res_val;

    if let Some(k) = killer.as_ref()
        && k.name.contains("SiegeTank")
    {
        let scell = (
            (k.pos.x().max(0.0) as u32) / 4,
            (k.pos.y().max(0.0) as u32) / 4,
        );
        let sc = ctx.siege_cells.entry(scell).or_default();
        sc.0 += 1;
        sc.1 += res_val;
    }

    let mining_sec = ctx
        .players
        .get(&owner)
        .map(|p| {
            let inc = p.last_stats.min_rate + p.last_stats.gas_rate;
            if inc > 0 {
                res_val as f32 * 60.0 / inc as f32
            } else {
                0.0
            }
        })
        .unwrap_or(0.0);

    if let Some(p) = ctx.players.get_mut(&owner) {
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
        && let Some(ep) = ctx.players.get_mut(&enemy_pid)
    {
        ep.resources_killed += res_val;
        let ku = ep.kills_by_unit.entry(killer_name.clone()).or_default();
        ku.0 += 1;
        ku.1 += res_val;
    }

    ctx.raw_deaths.push(RawDeathEvent {
        sec: sec_u,
        owner_pid: owner,
        unit: base.clone(),
        x: kx,
        y: ky,
        cost: res_val,
        mining_sec,
    });
    ctx.recent_deaths.push_back((
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

fn handle_upgrade_event(ctx: &mut ReplayAnalysisCtx<'_>, gl: i64, sec_f: f32, up: &UpgradeEvent) {
    if (up.player_id != 1 && up.player_id != 2)
        || up.count <= 0
        || up.upgrade_type_name.is_empty()
        || up.upgrade_type_name.starts_with("Spray")
        || up.upgrade_type_name.starts_with("Reward")
    {
        return;
    }
    let pid = up.player_id;
    let uname = up.upgrade_type_name.clone();
    ctx.upgrade_events.push(UpgradeEventRecord {
        game_loop: gl,
        sec: round1(sec_f),
        owner: pid,
        name: uname.clone(),
        count: up.count,
    });

    let matched_tag = ctx
        .pending_research_cmds
        .iter()
        .filter(|(_, cmd)| {
            cmd.pid == pid && sec_f >= cmd.start_sec && cmd.name.eq_ignore_ascii_case(&uname)
        })
        .min_by(|(_, a), (_, b)| {
            a.start_sec
                .partial_cmp(&b.start_sec)
                .unwrap_or(std::cmp::Ordering::Equal)
        })
        .map(|(&tag, _)| tag);

    if let Some(tag) = matched_tag
        && let Some(cmd) = ctx.pending_research_cmds.remove(&tag)
    {
        ctx.production_spans.push(ProductionSpan {
            owner: pid,
            kind: "upgrade".to_string(),
            name: uname,
            start_sec: round1(cmd.start_sec),
            end_sec: round1(sec_f.max(cmd.start_sec + 0.5)),
            full_sec: round1((sec_f - cmd.start_sec).max(1.0)),
            approx: false,
            x: cmd.xy.map(|p| p[0]),
            y: cmd.xy.map(|p| p[1]),
        });
    } else {
        let dur = lookup_upgrade_duration_sec(&ctx.research_index, &uname).max(5.0);
        ctx.production_spans.push(ProductionSpan {
            owner: pid,
            kind: "upgrade".to_string(),
            name: uname,
            start_sec: round1((sec_f - dur).max(0.0)),
            end_sec: round1(sec_f),
            full_sec: round1(dur),
            approx: true,
            x: None,
            y: None,
        });
    }
}

fn handle_tracker_event(
    ctx: &mut ReplayAnalysisCtx<'_>,
    gl: i64,
    sec_f: f32,
    sec_u: u32,
    event: &ReplayTrackerEvent,
    change_hint: &UnitChangeHint,
    sc2_state: &SC2ReplayState,
) {
    match event {
        ReplayTrackerEvent::PlayerSetup(setup) => {
            if (setup.player_id == 1 || setup.player_id == 2)
                && let Some(uid) = setup.user_id
            {
                ctx.user_id_to_pid.insert(uid as i64, setup.player_id);
                if let Some(p) = ctx.players.get_mut(&setup.player_id) {
                    p.user_id = Some(uid as i64);
                }
            }
        }
        ReplayTrackerEvent::UnitBorn(ub) => {
            handle_unit_born(ctx, gl, sec_f, sec_u, ub, change_hint, sc2_state);
        }
        ReplayTrackerEvent::UnitInit(ui) => handle_unit_init(ctx, sec_f, sec_u, ui, change_hint),
        ReplayTrackerEvent::UnitDone(ud) => {
            handle_unit_done(ctx, sec_f, sec_u, ud, change_hint, sc2_state);
        }
        ReplayTrackerEvent::UnitTypeChange(utc) => {
            handle_unit_type_change(ctx, sec_f, utc, sc2_state);
        }
        ReplayTrackerEvent::UnitDied(ud) => {
            handle_unit_died(ctx, gl, sec_f, sec_u, ud, change_hint);
        }
        ReplayTrackerEvent::Upgrade(up) => {
            handle_upgrade_event(ctx, gl, sec_f, up);
        }
        ReplayTrackerEvent::PlayerStats(ps) => {
            if ps.player_id != 1 && ps.player_id != 2 {
                return;
            }
            let st = &ps.stats;
            let army_val = st.minerals_used_current_army + st.vespene_used_current_army;
            let killed_val = st.minerals_killed_army
                + st.minerals_killed_economy
                + st.minerals_killed_technology
                + st.vespene_killed_army
                + st.vespene_killed_economy
                + st.vespene_killed_technology;

            // Caster seconds alive up to 10:00
            let interval = ctx
                .players
                .get(&ps.player_id)
                .and_then(|p| p.last_stats_sec)
                .map(|prev| sec_u.saturating_sub(prev))
                .unwrap_or(0);

            if sec_u <= SNAPSHOT_SECONDS && interval > 0 {
                for u in sc2_state.units.values() {
                    if !u.is_init
                        && u.user_id == Some(ps.player_id)
                        && let Some(c) = CASTERS.iter().find(|&&c| c == u.name)
                        && let Some(p) = ctx.players.get_mut(&ps.player_id)
                    {
                        *p.caster_seconds.entry(c).or_default() += interval as f32;
                    }
                }
            }

            if let Some(p) = ctx.players.get_mut(&ps.player_id) {
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
        _ => {}
    }
}

#[allow(clippy::too_many_arguments)]
fn handle_game_event(
    ctx: &mut ReplayAnalysisCtx<'_>,
    gl: i64,
    sec_f: f32,
    sec_u: u32,
    user_id: i64,
    player_name: Option<&str>,
    event: &ReplayGameEvent,
    change_hint: &UnitChangeHint,
) {
    let pid = ctx
        .user_id_to_pid
        .get(&user_id)
        .copied()
        .or_else(|| {
            let pname = player_name.map(clean_player_name)?;
            ctx.players.values().find(|p| p.name == pname).map(|p| p.pid)
        });
    let Some(pid) = pid else {
        return;
    };
    let enemy_start = ctx
        .players
        .get(&if pid == 1 { 2 } else { 1 })
        .and_then(|ep| ep.start_xy);

    match event {
        ReplayGameEvent::CameraUpdate(cam) => {
            if let Some(target) = &cam.m_target
                && let Some(p) = ctx.players.get_mut(&pid)
            {
                p.camera_moves += 1;
                p.camera_xy = [
                    round1(target.x as f32 / 256.0),
                    round1(target.y as f32 / 256.0),
                ];
            }
        }
        ReplayGameEvent::ControlGroupUpdate(cg) => {
            if let Some(p) = ctx.players.get_mut(&pid) {
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
            let enriched_cmd = match change_hint {
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
            let is_spam = is_move_or_attack(ability, abil_link, ctx.protocol_version);

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

            if let Some(p) = ctx.players.get_mut(&pid) {
                p.raw_commands += 1;
                p.recent_cmd_loops.push_back(gl);
                while p
                    .recent_cmd_loops
                    .front()
                    .is_some_and(|&t| t + APM_WINDOW_LOOPS < gl)
                {
                    p.recent_cmd_loops.pop_front();
                }
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

                if let UnitChangeHint::Abilities { units, .. } = change_hint {
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
                            && let (Some([tx, ty]), Some([ex, ey])) = (target_xy, enemy_start)
                        {
                            let d = ((tx - ex).powi(2) + (ty - ey).powi(2)).sqrt();
                            if d <= SCOUT_DISTANCE {
                                p.first_scout = Some((round1(sec_f), ubase.to_string()));
                            }
                        }
                    }
                    if let Some([tx, ty]) = target_xy {
                        let rkind = classify_ray_kind(ability, abil_link, ctx.protocol_version);
                        // Limit per-step micro rays so high-APM steps stay compact
                        for u in units.iter().take(if rkind == 0 { 2 } else { 4 }) {
                            ctx.active_rays.push_back((
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
            if let UnitChangeHint::Abilities { units, .. } = change_hint {
                if let Some(unit_target) = extract_train_target_name(ability) {
                    let base_t = base_unit_name(unit_target);
                    if !is_structure_unit(ctx.patch_balance, base_t) {
                        let dur = lookup_unit_cost(ctx.patch_balance, base_t).time_faster_sec;
                        if dur > 0.0
                            && let Some(fac) = units
                                .iter()
                                .find(|u| PRODUCTION_STRUCTURES.contains(&base_unit_name(&u.name)))
                        {
                            let entry = ctx.pending_train_cmds.get(&fac.tag_index);
                            if entry.is_none_or(|e| sec_f > e.start_sec + e.dur_sec * 1.2) {
                                ctx.pending_train_cmds.insert(
                                    fac.tag_index,
                                    PendingCmdSpan {
                                        pid,
                                        name: base_t.to_string(),
                                        start_sec: sec_f,
                                        dur_sec: dur,
                                        xy: Some([round1(fac.pos.x()), round1(fac.pos.y())]),
                                    },
                                );
                            }
                        }
                    }
                }
                let res_opt = extract_research_target_name(ability)
                    .map(|n| {
                        (
                            n.to_string(),
                            lookup_upgrade_duration_sec(&ctx.research_index, n),
                        )
                    })
                    .or_else(|| {
                        ctx.research_index
                            .by_abil_link
                            .get(&abil_link)
                            .map(|(n, d)| (n.clone(), *d))
                    });
                if let Some((rname, rdur)) = res_opt
                    && let Some(fac) = units
                        .iter()
                        .find(|u| is_structure_unit(ctx.patch_balance, &u.name))
                {
                    let entry = ctx.pending_research_cmds.get(&fac.tag_index);
                    if entry.is_none_or(|e| sec_f > e.start_sec + e.dur_sec * 1.15) {
                        ctx.pending_research_cmds.insert(
                            fac.tag_index,
                            PendingCmdSpan {
                                pid,
                                name: rname,
                                start_sec: sec_f,
                                dur_sec: rdur,
                                xy: Some([round1(fac.pos.x()), round1(fac.pos.y())]),
                            },
                        );
                    }
                }
            }
        }
        ReplayGameEvent::CmdUpdateTargetPoint(_) | ReplayGameEvent::CmdUpdateTargetUnit(_) => {
            let units_slice: &[SC2Unit] = match change_hint {
                UnitChangeHint::TargetPoints(u) => u,
                UnitChangeHint::TargetUnits { units, .. } => units,
                _ => &[],
            };
            for u in units_slice.iter().take(2) {
                let tgt = match &u.cmd.data {
                    SC2UnitCmdData::TargetPoint(tp) => Some([round1(tp.x()), round1(-tp.y())]),
                    SC2UnitCmdData::TargetUnit(tu) => Some([
                        round1(tu.snapshot_point.x()),
                        round1(-tu.snapshot_point.y()),
                    ]),
                    _ => None,
                };
                if let Some([tx, ty]) = tgt {
                    ctx.active_rays.push_back((
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

fn build_player_reports(
    players: &mut HashMap<u8, PerPlayerAcc>,
    engagements: &[EngagementSummary],
    patch_balance: &VersionedBalanceUnits,
    game_mins: f32,
    findings: &mut Vec<String>,
) -> Vec<PlayerForensicReport> {
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
        production_idle.sort_by_key(|a| std::cmp::Reverse(a.idle_seconds));

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
        unit_effectiveness.sort_by_key(|a| std::cmp::Reverse(a.value_killed));

        let mut killed_by: Vec<(String, usize)> = p.killed_by.into_iter().collect();
        killed_by.sort_by_key(|a| std::cmp::Reverse(a.1));

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
            engagements,
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
    player_reports
}

fn to_sorted_heatmap(cells: HashMap<(u32, u32), (u32, u32)>) -> Vec<HeatmapCell> {
    let mut heatmap: Vec<HeatmapCell> = cells
        .into_iter()
        .map(|((x, y), (count, value))| HeatmapCell {
            x: x * 4 + 2,
            y: y * 4 + 2,
            count,
            value,
        })
        .collect();
    heatmap.sort_by_key(|a| std::cmp::Reverse(a.value));
    heatmap
}

fn is_undecided_result(res: &str) -> bool {
    matches!(res, "" | "Undecided" | "Unknown")
}

pub(crate) fn infer_undecided_results(
    players: &mut HashMap<u8, PerPlayerAcc>,
    p1_surviving_structures: usize,
    p2_surviving_structures: usize,
    final_p1_chance: Option<f32>,
    findings: &mut Vec<String>,
) {
    let p1_res = players.get(&1).map(|p| p.result.clone()).unwrap_or_default();
    let p2_res = players.get(&2).map(|p| p.result.clone()).unwrap_or_default();
    let p1_und = is_undecided_result(&p1_res);
    let p2_und = is_undecided_result(&p2_res);
    if !p1_und && !p2_und {
        return;
    }

    let (winner_pid, reason) = if p1_und != p2_und {
        if p1_res == "Win" || p2_res == "Loss" {
            (Some(1u8), "mirroring opponent's recorded result".to_string())
        } else if p2_res == "Win" || p1_res == "Loss" {
            (Some(2u8), "mirroring opponent's recorded result".to_string())
        } else {
            (None, String::new())
        }
    } else if p1_surviving_structures == 0 && p2_surviving_structures > 0 {
        (
            Some(2u8),
            format!(
                "0 surviving P1 structures vs {} P2 structures",
                p2_surviving_structures
            ),
        )
    } else if p2_surviving_structures == 0 && p1_surviving_structures > 0 {
        (
            Some(1u8),
            format!(
                "{} surviving P1 structures vs 0 P2 structures",
                p1_surviving_structures
            ),
        )
    } else if let Some(p1_chance) = final_p1_chance {
        if p1_chance >= 0.85 {
            (
                Some(1u8),
                format!("final win probability {:.1}% >= 85%", p1_chance * 100.0),
            )
        } else if p1_chance <= 0.15 {
            (
                Some(2u8),
                format!(
                    "final win probability P1 {:.1}% <= 15% (P2 {:.1}%)",
                    p1_chance * 100.0,
                    (1.0 - p1_chance) * 100.0
                ),
            )
        } else {
            (None, String::new())
        }
    } else {
        (None, String::new())
    };

    let Some(win_pid) = winner_pid else {
        return;
    };
    let lose_pid = if win_pid == 1 { 2 } else { 1 };
    if let Some(pw) = players.get_mut(&win_pid)
        && is_undecided_result(&pw.result)
    {
        pw.result = "Win*".to_string();
    }
    if let Some(pl) = players.get_mut(&lose_pid)
        && is_undecided_result(&pl.result)
    {
        pl.result = "Loss*".to_string();
    }
    let wname = players
        .get(&win_pid)
        .map(|p| p.name.as_str())
        .unwrap_or("Winner");
    let lname = players
        .get(&lose_pid)
        .map(|p| p.name.as_str())
        .unwrap_or("Loser");
    findings.push(format!(
        "Match result inferred (*): {} Win* vs {} Loss* ({}; replay header reported Undecided/Unknown).",
        wname, lname, reason
    ));
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

    let max_loop = find_max_replay_loop(&basic_data, bytes, db)?;

    // Re-run clean state machine pass with adaptive snapshot cadence (`<= max_timeline_frames`)
    let mut iter = SC2EventIterator::from_bytes(&basic_data, bytes, db)
        .map_err(|e| format!("SC2EventIterator second pass error: {e:?}"))?;
    let target_frames = max_timeline_frames.max(60) as i64;
    let sample_interval_loops = (((max_loop / target_frames).max(22) / 2) * 2).max(22);

    let mut ctx = ReplayAnalysisCtx {
        protocol_version,
        patch_balance,
        research_index: build_research_index(patch_balance),
        players: init_players(&basic_data),
        user_id_to_pid: HashMap::new(),
        static_objects: Vec::new(),
        static_tags: BTreeSet::new(),
        born_counted_tags: HashSet::new(),
        init_creators: HashMap::new(),
        active_inits: HashMap::new(),
        active_morphs: HashMap::new(),
        pending_research_cmds: HashMap::new(),
        pending_train_cmds: HashMap::new(),
        upgrade_events: Vec::new(),
        production_spans: Vec::new(),
        scored_tags: HashMap::new(),
        active_rays: VecDeque::new(),
        recent_deaths: VecDeque::new(),
        raw_deaths: Vec::new(),
        death_cells: HashMap::new(),
        siege_cells: HashMap::new(),
        max_seen_x: map_w,
        max_seen_y: map_h,
    };

    let mut win_chance_curve: Vec<WinChanceSample> = Vec::new();
    let mut next_win_chance_sec: u32 = 120;
    let mut frames: Vec<MinimapFrame> = Vec::new();
    let mut next_frame_loop: i64 = 0;

    while let Some(item) = iter.next() {
        let gl = match &item.event_type {
            SC2EventType::Tracker { tracker_loop, .. } => *tracker_loop,
            SC2EventType::Game { game_loop, .. } => *game_loop,
        };

        if frames.is_empty() && gl > 0 {
            frames.push(snapshot_frame(
                0,
                &iter.sc2_state,
                &mut ctx,
                &priority_snapshots,
            ));
            next_frame_loop = sample_interval_loops;
        }

        while gl > next_frame_loop && !frames.is_empty() {
            frames.push(snapshot_frame(
                next_frame_loop,
                &iter.sc2_state,
                &mut ctx,
                &priority_snapshots,
            ));
            next_frame_loop += sample_interval_loops;
        }
        while ctx
            .active_rays
            .front()
            .is_some_and(|(t, _)| *t + COMMAND_VISIBLE_LOOPS <= gl)
        {
            ctx.active_rays.pop_front();
        }
        while ctx
            .recent_deaths
            .front()
            .is_some_and(|(t, _)| *t + DEATH_VISIBLE_LOOPS <= gl)
        {
            ctx.recent_deaths.pop_front();
        }

        let sec_f = gl as f32 / GAME_LOOPS_PER_SECOND as f32;
        let sec_u = sec_f.max(0.0) as u32;

        while sec_u >= next_win_chance_sec {
            let s1 = ctx.players.get(&1).map(|p| p.side_stats).unwrap_or_default();
            let s2 = ctx.players.get(&2).map(|p| p.side_stats).unwrap_or_default();
            win_chance_curve.push(compute_win_chance(next_win_chance_sec, &s1, &s2));
            next_win_chance_sec += 30;
        }

        match &item.event_type {
            SC2EventType::Tracker { event, .. } => {
                handle_tracker_event(
                    &mut ctx,
                    gl,
                    sec_f,
                    sec_u,
                    event,
                    &item.change_hint,
                    &iter.sc2_state,
                );
            }
            SC2EventType::Game {
                user_id,
                player_name,
                event,
                ..
            } => {
                handle_game_event(
                    &mut ctx,
                    gl,
                    sec_f,
                    sec_u,
                    *user_id,
                    player_name.as_deref(),
                    event,
                    &item.change_hint,
                );
            }
        }
    }

    if frames.is_empty() {
        frames.push(snapshot_frame(
            0,
            &iter.sc2_state,
            &mut ctx,
            &priority_snapshots,
        ));
    }

    // Push final end-of-game frame
    frames.push(snapshot_frame(
        max_loop,
        &iter.sc2_state,
        &mut ctx,
        &priority_snapshots,
    ));

    if map_w < 32.0 {
        map_w = ctx.max_seen_x.max(152.0);
    }
    if map_h < 32.0 {
        map_h = ctx.max_seen_y.max(152.0);
    }

    let engagements = cluster_engagements(&ctx.raw_deaths);
    let turning_points = compute_turning_points(&win_chance_curve, &engagements);

    let mut findings: Vec<String> = Vec::new();
    let duration_sec = round1(max_loop as f32 / GAME_LOOPS_PER_SECOND as f32);
    let game_mins = (duration_sec / 60.0).max(1.0);

    finalize_open_production_spans(&mut ctx, duration_sec);
    ctx.upgrade_events
        .sort_by(|a, b| a.game_loop.cmp(&b.game_loop).then(a.owner.cmp(&b.owner)));
    ctx.production_spans.sort_by(|a, b| {
        a.start_sec
            .partial_cmp(&b.start_sec)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.owner.cmp(&b.owner))
            .then(a.name.cmp(&b.name))
    });
    let death_log: Vec<DeathTimelineEvent> = ctx
        .raw_deaths
        .iter()
        .map(|d| DeathTimelineEvent {
            sec: d.sec as f32,
            owner: d.owner_pid,
            unit: d.unit.clone(),
            cost: d.cost,
            x: d.x,
            y: d.y,
        })
        .collect();

    let mut surviving_structures = [0usize; 3];
    for u in iter.sc2_state.units.values() {
        if !u.is_init
            && !u.name.starts_with("CreepTumor")
            && let Some(pid) = u.user_id
            && (pid == 1 || pid == 2)
            && is_structure_unit(patch_balance, &u.name)
        {
            surviving_structures[pid as usize] += 1;
        }
    }
    let final_p1_chance = win_chance_curve.last().map(|s| s.p1_chance).or_else(|| {
        let s1 = ctx.players.get(&1).map(|p| p.side_stats).unwrap_or_default();
        let s2 = ctx.players.get(&2).map(|p| p.side_stats).unwrap_or_default();
        if s1.army + s1.income + s2.army + s2.income > 0 {
            Some(compute_win_chance(duration_sec.max(1.0) as u32, &s1, &s2).p1_chance)
        } else {
            None
        }
    });
    infer_undecided_results(
        &mut ctx.players,
        surviving_structures[1],
        surviving_structures[2],
        final_p1_chance,
        &mut findings,
    );

    let player_reports = build_player_reports(
        &mut ctx.players,
        &engagements,
        patch_balance,
        game_mins,
        &mut findings,
    );

    let death_heatmap = to_sorted_heatmap(ctx.death_cells);
    let siege_spots = to_sorted_heatmap(ctx.siege_cells);

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
        static_objects: ctx.static_objects,
        death_heatmap,
        siege_spots,
        frames,
        priority_snapshots,
        upgrade_events: ctx.upgrade_events,
        production_spans: ctx.production_spans,
        death_log,
    })
}

fn finalize_open_production_spans(ctx: &mut ReplayAnalysisCtx<'_>, duration_sec: f32) {
    let end_sentinel = round1(duration_sec + 0.1);
    for (_, act) in ctx.active_inits.drain().chain(ctx.active_morphs.drain()) {
        if duration_sec >= act.start_sec {
            ctx.production_spans.push(ProductionSpan {
                owner: act.pid,
                kind: act.kind.to_string(),
                name: act.name,
                start_sec: round1(act.start_sec),
                end_sec: end_sentinel,
                full_sec: round1(act.full_sec.max(1.0)),
                approx: false,
                x: Some(act.x),
                y: Some(act.y),
            });
        }
    }
    for (_, cmd) in ctx.pending_research_cmds.drain() {
        if duration_sec >= cmd.start_sec && duration_sec <= cmd.start_sec + cmd.dur_sec * 1.15 {
            ctx.production_spans.push(ProductionSpan {
                owner: cmd.pid,
                kind: "upgrade".to_string(),
                name: cmd.name,
                start_sec: round1(cmd.start_sec),
                end_sec: end_sentinel,
                full_sec: round1(cmd.dur_sec.max(1.0)),
                approx: true,
                x: cmd.xy.map(|p| p[0]),
                y: cmd.xy.map(|p| p[1]),
            });
        }
    }
    for (_, cmd) in ctx.pending_train_cmds.drain() {
        if duration_sec >= cmd.start_sec && duration_sec <= cmd.start_sec + cmd.dur_sec * 1.15 {
            ctx.production_spans.push(ProductionSpan {
                owner: cmd.pid,
                kind: "unit".to_string(),
                name: cmd.name,
                start_sec: round1(cmd.start_sec),
                end_sec: end_sentinel,
                full_sec: round1(cmd.dur_sec.max(1.0)),
                approx: true,
                x: cmd.xy.map(|p| p[0]),
                y: cmd.xy.map(|p| p[1]),
            });
        }
    }
}
