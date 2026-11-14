//! Swarmy-style forensic analytics: unit counter scoring, logistic win-chance curve,
//! engagement clustering, turning points, ability efficiency, and costed lessons.

use crate::balance::{
    ENERGY_PER_SECOND, ENGAGEMENT_GAP_SECONDS, FLOATING_THRESHOLD, INJECT_SECONDS,
    MAX_ENGAGEMENT_SECONDS, MIN_ENGAGEMENT_RESOURCES, WIN_CHANCE_COEFFICIENTS, WORKERS,
    base_unit_name, is_structure_unit, lookup_unit_cost,
};
use crate::models::{
    AbilityEfficiencyRow, CostedLesson, EngagementSummary, ProductionIdleRow, RawDeathEvent,
    SideStats, TurningPointRecord, WinChanceSample, round1, round2,
};
use s2protocol::SC2Unit;
use s2protocol::game_events::{UnitShortRef, VersionedBalanceUnits};
use std::collections::BTreeMap;

fn refers_to(units: &[UnitShortRef], target: &str) -> bool {
    units.iter().any(|u| u.id == target)
}

pub type UnitChoiceScore = (f64, BTreeMap<String, usize>, BTreeMap<String, usize>);

pub fn score_unit_choice<'a>(
    balance: &VersionedBalanceUnits,
    unit_name: &str,
    enemy_units: impl IntoIterator<Item = &'a SC2Unit>,
) -> Option<UnitChoiceScore> {
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

pub fn format_counts_map(m: &BTreeMap<String, usize>) -> String {
    m.iter()
        .map(|(k, v)| format!("{v}x{k}"))
        .collect::<Vec<_>>()
        .join(",")
}

pub fn win_chance_coeffs(minute: f32) -> [f32; 4] {
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

pub fn log_ratio(a: i32, b: i32, offset: f32) -> f32 {
    ((a.max(0) as f32 + offset) / (b.max(0) as f32 + offset)).ln()
}

pub(crate) fn compute_win_chance(sec: u32, p1: &SideStats, p2: &SideStats) -> WinChanceSample {
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
        army_term: round2(army_term),
        income_term: round2(income_term),
        workers_term: round2(workers_term),
        trades_term: round2(trades_term),
    }
}

pub fn is_move_or_attack(ability: &str, abil_link: u16, protocol_version: u32) -> bool {
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

pub fn classify_ray_kind(ability: &str, abil_link: u16, protocol_version: u32) -> u8 {
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

pub fn extract_build_target_name(ability: &str) -> Option<String> {
    ability
        .strip_prefix("Build.")
        .filter(|rest| !rest.is_empty())
        .map(str::to_string)
}

pub fn idle_gap_excluding_supply_full(
    finished: u32,
    started: u32,
    supply_full: &[(u32, u32)],
) -> u32 {
    let gap = started.saturating_sub(finished);
    let blocked: u32 = supply_full
        .iter()
        .map(|(s, e)| (*e).min(started).saturating_sub((*s).max(finished)))
        .sum();
    gap.saturating_sub(blocked)
}

pub fn compute_ability_efficiency(
    casters: &BTreeMap<&'static str, f32>,
    early_injects: u32,
    early_chronos: u32,
    early_mules: u32,
) -> Vec<AbilityEfficiencyRow> {
    let sum_sec = |names: &[&str]| -> f32 { names.iter().filter_map(|n| casters.get(n)).sum() };
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

pub(crate) fn cluster_engagements(deaths: &[RawDeathEvent]) -> Vec<EngagementSummary> {
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

pub fn compute_turning_points(
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
pub fn rank_lessons(
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
            (own > opp + 100).then(|| (e, own, own - opp))
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
    out.sort_by_key(|a| std::cmp::Reverse(a.mineral_equiv_cost));
    out.truncate(5);
    out
}
