#!/usr/bin/env python3
"""
Full Replay Corpus Forensic Scanner (`tools/evaluate-full-corpus-multi-horizon.py`).

Scans all `.SC2Replay` archives across the full workspace corpus using `multiprocessing.Pool(16)`
to extract ground-truth pro vs. bot telemetry for:
  1. Mineral Walking & Drone Drilling (`worker_mineral_walk_events`, `drone_drill_stack_events`,
     `worker_rush_or_early_pool_defense_pulls`).
  2. Oracle & Stasis Ward (`OracleStasisTrap` / `StasisWard`) usage, placement geometry
     (mineral-line harass vs. expansion blocking vs. defensive ramp/choke), and detonation impact.
"""

import glob
import hashlib
import json
import math
import multiprocessing as mp
import os
import mpyq
from s2protocol import versions

TOWNHALL_RAW = {'Nexus', 'CommandCenter', 'OrbitalCommand', 'PlanetaryFortress', 'Hatchery', 'Lair', 'Hive'}
WORKER_RAW = {'Probe', 'SCV', 'Drone'}
COMBAT_IGNORE_RAW = (
    TOWNHALL_RAW
    | WORKER_RAW
    | {
        'Larva', 'Egg', 'Broodling', 'KD8Charge', 'AdeptPhaseShift', 'Interceptor', 'MULE',
        'CreepTumor', 'CreepTumorBurrowed', 'CreepTumorQueen', 'SupplyDepot', 'SupplyDepotLowered',
        'Pylon', 'Overlord', 'Overseer', 'Observer', 'Assimilator', 'Refinery', 'Extractor',
    }
)


def collect_all_replays():
    patterns = [
        ('pro_tournament', 'external_bots/python-sc2/test/replays/*.SC2Replay'),
        ('pro_corpus', 'replays/pro_corpus/**/*.SC2Replay'),
        ('pro_corpus', 'replays/pro_corpus/*.SC2Replay'),
        ('aiarena_ladder', 'replays/aiarena_matches/*.SC2Replay'),
        ('aiarena_ladder', 'replays/aiarena_matches/**/*.SC2Replay'),
        ('aiarena_ladder', 'data/aiarena_latest/**/*.SC2Replay'),
        ('aiarena_ladder', 'replays/aiarena_corpus/**/*.SC2Replay'),
        ('aiarena_ladder', 'replays/aiarena_corpus/*.SC2Replay'),
        ('local_real_matches', 'replays/local_real_matches/**/*.SC2Replay'),
        ('local_real_matches', 'replays/*.SC2Replay'),
        ('external_gauntlet', 'replays/external_gauntlet/*.SC2Replay'),
        ('external_gauntlet', 'replays/external_bots_gauntlet/*.SC2Replay'),
    ]
    seen_hashes = set()
    items = []
    raw_file_count = 0
    for cohort, pat in patterns:
        for p in sorted(glob.glob(pat, recursive=True)):
            try:
                sz = os.path.getsize(p)
                if sz < 1000:
                    continue
                raw_file_count += 1
                with open(p, 'rb') as fh:
                    h = hashlib.md5(fh.read()).hexdigest()
                key = (sz, h)
                if key not in seen_hashes:
                    seen_hashes.add(key)
                    items.append((cohort, p))
            except Exception:
                continue
    return items, raw_file_count


def scan_single_replay(item):
    cohort, path = item
    res = {
        'cohort': cohort,
        'path': path,
        'valid': False,
        'p1_race': 'Unknown',
        'p2_race': 'Unknown',
        'worker_mineral_walk_events': 0,
        'drone_drill_stack_events': 0,
        'early_defense_worker_pull_events': 0,
        'replays_with_mineral_walk': 0,
        'replays_with_drone_drill': 0,
        'oracles_spawned': 0,
        'stasis_wards_placed': 0,
        'stasis_mineral_line_harass': 0,
        'stasis_expansion_blocking': 0,
        'stasis_defensive_ramp_choke': 0,
        'stasis_ward_detonations': 0,
        'stasis_workers_caught_estimate': 0,
    }
    try:
        archive = mpyq.MPQArchive(path)
        header = versions.latest().decode_replay_header(archive.header['user_data_header']['content'])
        protocol = versions.build(header['m_version']['m_baseBuild'])
        details = protocol.decode_replay_details(archive.read_file('replay.details'))
        tracker = list(protocol.decode_replay_tracker_events(archive.read_file('replay.tracker.events')))
    except Exception:
        return res

    if not details or len(details.get('m_playerList', [])) < 2:
        return res

    res['valid'] = True
    races = {}
    for idx, p in enumerate(details['m_playerList'][:2]):
        r = p['m_race'].decode('utf-8', errors='ignore') if isinstance(p['m_race'], bytes) else str(p['m_race'])
        if '테란' in r or '人类' in r or 'Terran' in r:
            r = 'Terran'
        elif '저그' in r or '异虫' in r or 'Zerg' in r:
            r = 'Zerg'
        elif '프로토스' in r or '星灵' in r or 'Protoss' in r:
            r = 'Protoss'
        else:
            r = 'Terran'
        races[idx + 1] = r
    res['p1_race'] = races.get(1, 'Unknown')
    res['p2_race'] = races.get(2, 'Unknown')

    mineral_patches = []
    units = {}
    alive_workers = {1: set(), 2: set()}
    alive_combat = {1: set(), 2: set()}
    alive_townhalls = {1: set(), 2: set()}
    stasis_wards = {}
    combat_windows = {1: [], 2: []}

    for ev in tracker:
        gl = ev.get('_gameloop', 0)
        etype = ev.get('_event')
        if etype in ('NNet.Replay.Tracker.SUnitBornEvent', 'NNet.Replay.Tracker.SUnitInitEvent'):
            tag = ev.get('m_unitTagIndex', 0)
            p = ev.get('m_controlPlayerId', 0)
            utype = ev['m_unitTypeName'].decode('utf-8', errors='ignore') if isinstance(ev.get('m_unitTypeName'), bytes) else str(ev.get('m_unitTypeName', ''))
            x = float(ev.get('m_x', 0))
            y = float(ev.get('m_y', 0))
            if 'MineralField' in utype:
                mineral_patches.append((x, y))
            elif p in (1, 2):
                units[tag] = {'tag': tag, 'p': p, 'utype': utype, 'x': x, 'y': y, 'born': gl, 'alive': True}
                if utype in WORKER_RAW:
                    alive_workers[p].add(tag)
                elif utype in TOWNHALL_RAW:
                    alive_townhalls[p].add(tag)
                elif utype == 'Oracle' and etype == 'NNet.Replay.Tracker.SUnitBornEvent':
                    res['oracles_spawned'] += 1
                    alive_combat[p].add(tag)
                elif utype in ('OracleStasisTrap', 'StasisTrap') or 'StasisTrap' in utype:
                    res['stasis_wards_placed'] += 1
                    stasis_wards[tag] = {'p': p, 'x': x, 'y': y, 'born': gl}
                    opp_p = 3 - p
                    opp_ths = [units[t] for t in alive_townhalls[opp_p] if t in units]
                    our_ths = [units[t] for t in alive_townhalls[p] if t in units]
                    near_opp_th = any(math.hypot(x - th['x'], y - th['y']) <= 11.5 for th in opp_ths)
                    near_mineral = any(math.hypot(x - mx, y - my) <= 9.5 for (mx, my) in mineral_patches)
                    near_any_th = any(math.hypot(x - th['x'], y - th['y']) <= 11.5 for th in (opp_ths + our_ths))
                    if near_opp_th:
                        res['stasis_mineral_line_harass'] += 1
                    elif near_mineral and not near_any_th:
                        res['stasis_expansion_blocking'] += 1
                    else:
                        res['stasis_defensive_ramp_choke'] += 1
                elif not utype.startswith('Beacon') and utype not in COMBAT_IGNORE_RAW:
                    alive_combat[p].add(tag)

        elif etype == 'NNet.Replay.Tracker.SUnitDiedEvent':
            tag = ev.get('m_unitTagIndex', 0)
            if tag in stasis_wards:
                sw = stasis_wards.pop(tag)
                opp_p = 3 - sw['p']
                opp_w = [units[t] for t in alive_workers[opp_p] if t in units]
                opp_c = [units[t] for t in alive_combat[opp_p] if t in units]
                caught_w = sum(1 for w in opp_w if math.hypot(w['x'] - sw['x'], w['y'] - sw['y']) <= 7.0)
                caught_c = sum(1 for c in opp_c if math.hypot(c['x'] - sw['x'], c['y'] - sw['y']) <= 7.0)
                if caught_w > 0 or caught_c > 0 or (gl - sw['born']) < 3800:
                    res['stasis_ward_detonations'] += 1
                    res['stasis_workers_caught_estimate'] += max(caught_w, 3 if caught_w > 0 else 0)
            if tag in units:
                u = units[tag]
                u['alive'] = False
                p = u['p']
                alive_workers[p].discard(tag)
                alive_combat[p].discard(tag)
                alive_townhalls[p].discard(tag)

        elif etype == 'NNet.Replay.Tracker.SUnitPositionsEvent':
            idx = ev.get('m_firstUnitIndex', 0)
            items = ev.get('m_items', [])
            moved_workers = {1: [], 2: []}
            for i in range(0, len(items), 3):
                idx += items[i]
                if idx in units:
                    u = units[idx]
                    old_x, old_y = u['x'], u['y']
                    new_x, new_y = float(items[i + 1]), float(items[i + 2])
                    u['x'], u['y'] = new_x, new_y
                    if u['alive'] and u['utype'] in WORKER_RAW and math.hypot(new_x - old_x, new_y - old_y) >= 0.5:
                        moved_workers[u['p']].append((u, old_x, old_y))

            for p in (1, 2):
                if not moved_workers[p]:
                    continue
                opp_p = 3 - p
                opp_units = [units[t] for t in (alive_combat[opp_p] | alive_workers[opp_p]) if t in units]
                if not opp_units:
                    continue
                workers_in_combat = []
                for (w, ox, oy) in moved_workers[p]:
                    if any(math.hypot(w['x'] - eu['x'], w['y'] - eu['y']) <= 9.0 for eu in opp_units):
                        workers_in_combat.append((w, ox, oy))
                if not workers_in_combat:
                    continue
                combat_windows[p].append(gl)
                if gl <= 4032 and len(workers_in_combat) >= 4:
                    res['early_defense_worker_pull_events'] += 1

                # Check if >= 4 workers in combat are stacked within <= 1.5 tiles (drone drill / mineral stack)
                w_coords = [w for (w, _, _) in workers_in_combat]
                stacked = False
                for i_w, w1 in enumerate(w_coords):
                    close_cnt = sum(
                        1 for w2 in w_coords
                        if math.hypot(w1['x'] - w2['x'], w1['y'] - w2['y']) <= 1.5
                    )
                    if close_cnt >= 4:
                        stacked = True
                        break
                if stacked:
                    res['drone_drill_stack_events'] += 1

                # Check kinematic mineral-walking: worker in close contact (<= 4.5 tiles of enemy) moving toward a mineral patch
                for (w, ox, oy) in workers_in_combat:
                    if any(math.hypot(w['x'] - eu['x'], w['y'] - eu['y']) <= 4.5 for eu in opp_units):
                        if any(
                            math.hypot(w['x'] - mx, w['y'] - my) + 0.4 < math.hypot(ox - mx, oy - my)
                            and math.hypot(w['x'] - mx, w['y'] - my) <= 10.0
                            for (mx, my) in mineral_patches[:24]
                        ):
                            res['worker_mineral_walk_events'] += 1
                            break

    # Also scan replay.game.events for explicit HarvestGather / mineral-target commands during combat windows
    try:
        raw_game = archive.read_file('replay.game.events')
        if raw_game and (combat_windows[1] or combat_windows[2]):
            cset = {
                1: {gl // 64 for gl in combat_windows[1]},
                2: {gl // 64 for gl in combat_windows[2]},
            }
            for gev in protocol.decode_replay_game_events(raw_game):
                if gev.get('_event') == 'NNet.Game.SCmdEvent':
                    uid = gev.get('_userid', {}).get('m_userId', -1) + 1
                    gl = gev.get('_gameloop', 0)
                    if uid in (1, 2) and (gl // 64) in cset[uid]:
                        data = gev.get('m_data', {})
                        if isinstance(data, dict) and 'TargetUnit' in data:
                            tu = data['TargetUnit']
                            pt = tu.get('m_snapshotPoint', {})
                            tx = pt.get('x', 0) / 4096.0
                            ty = pt.get('y', 0) / 4096.0
                            if tx > 0 and ty > 0:
                                if any(math.hypot(tx - mx, ty - my) <= 2.5 for (mx, my) in mineral_patches):
                                    res['worker_mineral_walk_events'] += 1
    except Exception:
        pass

    if res['worker_mineral_walk_events'] > 0:
        res['replays_with_mineral_walk'] = 1
    if res['drone_drill_stack_events'] > 0:
        res['replays_with_drone_drill'] = 1

    return res


def aggregate_cohort(records):
    valid = [r for r in records if r['valid']]
    n = max(1, len(valid))
    total_wards = sum(r['stasis_wards_placed'] for r in valid)
    w_denom = max(1, total_wards)
    return {
        'replays_scanned': len(valid),
        'worker_mineral_walk_events': sum(r['worker_mineral_walk_events'] for r in valid),
        'worker_mineral_walk_per_replay': round(sum(r['worker_mineral_walk_events'] for r in valid) / n, 2),
        'replays_with_mineral_walk': sum(r['replays_with_mineral_walk'] for r in valid),
        'replays_with_mineral_walk_pct': round(100.0 * sum(r['replays_with_mineral_walk'] for r in valid) / n, 1),
        'drone_drill_stack_events': sum(r['drone_drill_stack_events'] for r in valid),
        'drone_drill_stack_per_replay': round(sum(r['drone_drill_stack_events'] for r in valid) / n, 2),
        'replays_with_drone_drill': sum(r['replays_with_drone_drill'] for r in valid),
        'replays_with_drone_drill_pct': round(100.0 * sum(r['replays_with_drone_drill'] for r in valid) / n, 1),
        'early_defense_worker_pull_events': sum(r['early_defense_worker_pull_events'] for r in valid),
        'oracles_spawned': sum(r['oracles_spawned'] for r in valid),
        'stasis_wards_placed': total_wards,
        'stasis_mineral_line_harass': sum(r['stasis_mineral_line_harass'] for r in valid),
        'stasis_mineral_line_harass_pct': round(100.0 * sum(r['stasis_mineral_line_harass'] for r in valid) / w_denom, 1),
        'stasis_expansion_blocking': sum(r['stasis_expansion_blocking'] for r in valid),
        'stasis_expansion_blocking_pct': round(100.0 * sum(r['stasis_expansion_blocking'] for r in valid) / w_denom, 1),
        'stasis_defensive_ramp_choke': sum(r['stasis_defensive_ramp_choke'] for r in valid),
        'stasis_defensive_ramp_choke_pct': round(100.0 * sum(r['stasis_defensive_ramp_choke'] for r in valid) / w_denom, 1),
        'stasis_ward_detonations': sum(r['stasis_ward_detonations'] for r in valid),
        'stasis_workers_caught_estimate': sum(r['stasis_workers_caught_estimate'] for r in valid),
    }


def main():
    items, raw_file_count = collect_all_replays()
    with mp.Pool(processes=min(16, max(1, mp.cpu_count()))) as pool:
        records = list(pool.imap_unordered(scan_single_replay, items, chunksize=16))

    pro_recs = [r for r in records if r['cohort'] in ('pro_tournament', 'pro_corpus')]
    bot_recs = [r for r in records if r['cohort'] in ('aiarena_ladder', 'external_gauntlet')]
    local_recs = [r for r in records if r['cohort'] == 'local_real_matches']

    summary = {
        'total_raw_sc2replay_files_on_disk': raw_file_count,
        'unique_sc2replay_archives_scanned': len(items),
        'valid_decoded_replays': sum(1 for r in records if r['valid']),
        'cohorts': {
            'all': aggregate_cohort(records),
            'pro_all': aggregate_cohort(pro_recs),
            'aiarena_ladder': aggregate_cohort(bot_recs),
            'local_real_matches': aggregate_cohort(local_recs),
        },
    }

    os.makedirs('benchmarks', exist_ok=True)
    out_path = 'benchmarks/full_corpus_multi_horizon_report.json'
    existing = {}
    if os.path.exists(out_path):
        try:
            with open(out_path, 'r') as fh:
                existing = json.load(fh)
        except Exception:
            existing = {}
    existing['forensic_tactical_telemetry'] = summary
    with open(out_path, 'w') as fh:
        json.dump(existing, fh, indent=2)

    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
