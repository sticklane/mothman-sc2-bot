//! Embedded `s2protocol` balance constants, patch selection, and unit/name helpers.

use crate::models::UnitCostInfo;
use s2protocol::game_events::{
    MultiVersionedBalanceUnits, VersionedBalanceUnits, read_balance_data_from_included_assets,
};
use std::sync::OnceLock;

pub const GAME_LOOPS_PER_SECOND: f64 = 22.4;
pub const NORMAL_SECONDS_PER_FASTER_SECOND: f32 = 1.4;
pub const DEATH_VISIBLE_LOOPS: i64 = 112;
pub const COMMAND_VISIBLE_LOOPS: i64 = 56;
pub const ENGAGEMENT_GAP_SECONDS: u32 = 12;
pub const MAX_ENGAGEMENT_SECONDS: u32 = 60;
pub const MIN_ENGAGEMENT_RESOURCES: u32 = 400;
pub const FLOATING_THRESHOLD: i32 = 1000;
/// Max radius around each of a player's own 3 bases (`main`, `natural`, `3rd`); structures beyond all 3 are proxies.
pub const PROXY_DISTANCE: f32 = 28.0;
pub const PROXY_MAX_SECONDS: u32 = 240;
pub const SCOUT_DISTANCE: f32 = 30.0;
pub const SNAPSHOT_SECONDS: u32 = 600;
pub const ENERGY_PER_SECOND: f32 = 0.7875;
pub const INJECT_SECONDS: f32 = 29.0;

pub const WORKERS: &[&str] = &["SCV", "Probe", "Drone", "MULE"];
pub const MORPH_SOURCES: &[&str] = &["Drone", "HighTemplar", "DarkTemplar"];
pub const EXPANSION_TOWNHALLS: &[&str] = &["Hatchery", "CommandCenter", "Nexus"];
pub const TOWNHALLS: &[&str] = &[
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
pub const PRODUCTION_STRUCTURES: &[&str] = &[
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
pub const PROXY_STRUCTURES: &[&str] = &[
    "Barracks",
    "Factory",
    "Starport",
    "Gateway",
    "RoboticsFacility",
    "Stargate",
    "SpawningPool",
    "Pylon",
    "PhotonCannon",
    "Forge",
    "Bunker",
    "SpineCrawler",
    "ShieldBattery",
    "Hatchery",
];
pub const NOT_SCOUTS: &[&str] = &[
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
pub const CASTERS: &[&str] = &[
    "Queen",
    "Nexus",
    "OrbitalCommand",
    "Hatchery",
    "Lair",
    "Hive",
];

/// Fitted logistic win-chance coefficients `[army, income, workers, trades]` from Swarmy (27,441 1v1 games).
pub const WIN_CHANCE_COEFFICIENTS: [(f32, [f32; 4]); 12] = [
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
