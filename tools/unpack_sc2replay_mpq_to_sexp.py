#!/usr/bin/env python3
"""
Pure Binary .SC2Replay MPQ -> S-Expression Checkpoint Unpacker (`tools/unpack_sc2replay_mpq_to_sexp.py`).

Contains ZERO brain logic, ZERO economy models, ZERO tech inference, ZERO depth prediction,
and ZERO scoring. Strictly unpacks Blizzard MPQ `.SC2Replay` archives (`mpyq` + `s2protocol`)
into raw S-expression checkpoints (`replays/corpus_checkpoints.sexp`) for evaluation by
the pure Racket `#lang sc-bot` brain (`tools/evaluate-replays-racket.rkt`).
"""

import glob
import hashlib
import math
import multiprocessing as mp
import os
import re
import mpyq
from s2protocol import versions

TOWNHALL_RAW = {'Nexus', 'CommandCenter', 'OrbitalCommand', 'PlanetaryFortress', 'Hatchery', 'Lair', 'Hive'}
WORKER_RAW = {'Probe', 'SCV', 'Drone'}
GAS_RAW = {'Assimilator', 'Refinery', 'Extractor'}
SUPPLY_RAW = {'SupplyDepot', 'SupplyDepotLowered', 'Pylon', 'Overlord', 'Overseer'}
IGNORE_RAW = {'Larva', 'Egg', 'Broodling', 'KD8Charge', 'AdeptPhaseShift', 'Interceptor', 'MULE', 'CreepTumor', 'CreepTumorBurrowed', 'CreepTumorQueen'}

BLDG_RAW = TOWNHALL_RAW | GAS_RAW | {
    'SupplyDepot', 'SupplyDepotLowered', 'Pylon', 'SpawningPool', 'RoachWarren', 'BanelingNest',
    'HydraliskDen', 'LurkerDenMP', 'Spire', 'GreaterSpire', 'InfestationPit', 'UltraliskCavern',
    'EvolutionChamber', 'SpineCrawler', 'SporeCrawler', 'SpineCrawlerUprooted',
    'Barracks', 'BarracksTechLab', 'BarracksReactor', 'Factory', 'FactoryTechLab', 'FactoryReactor',
    'Starport', 'StarportTechLab', 'StarportReactor', 'EngineeringBay', 'Armory', 'FusionCore',
    'GhostAcademy', 'Bunker', 'MissileTurret', 'SensorTower',
    'Gateway', 'WarpGate', 'Forge', 'CyberneticsCore', 'PhotonCannon', 'ShieldBattery',
    'TwilightCouncil', 'Stargate', 'RoboticsFacility', 'RoboticsBay', 'FleetBeacon',
    'TemplarArchive', 'DarkShrine',
}

CAMEL_TO_KEBAB = {
    'Zergling': 'zergling', 'Baneling': 'baneling', 'Drone': 'drone', 'Queen': 'queen',
    'Roach': 'roach', 'Ravager': 'ravager', 'Hydralisk': 'hydralisk', 'LurkerMP': 'lurker',
    'Lurker': 'lurker', 'Mutalisk': 'mutalisk', 'Corruptor': 'corruptor', 'Ultralisk': 'ultralisk',
    'BroodLord': 'brood-lord', 'Infestor': 'infestor', 'Viper': 'viper', 'Overlord': 'overlord',
    'Overseer': 'overseer', 'Hatchery': 'hatchery', 'Lair': 'lair', 'Hive': 'hive',
    'SpawningPool': 'spawning-pool', 'Extractor': 'extractor', 'RoachWarren': 'roach-warren',
    'BanelingNest': 'baneling-nest', 'HydraliskDen': 'hydralisk-den', 'LurkerDenMP': 'lurker-den',
    'Spire': 'spire', 'GreaterSpire': 'greater-spire', 'InfestationPit': 'infestation-pit',
    'UltraliskCavern': 'ultralisk-cavern', 'EvolutionChamber': 'evolution-chamber',
    'SpineCrawler': 'spine-crawler', 'SpineCrawlerUprooted': 'spine-crawler', 'SporeCrawler': 'spore-crawler',
    'SCV': 'scv', 'Marine': 'marine', 'Marauder': 'marauder', 'Reaper': 'reaper', 'Ghost': 'ghost',
    'Hellion': 'hellion', 'HellionTank': 'hellbat', 'WidowMine': 'widow-mine', 'Cyclone': 'cyclone',
    'SiegeTank': 'siege-tank', 'SiegeTankSieged': 'siege-tank-sieged', 'Thor': 'thor',
    'VikingFighter': 'viking', 'VikingAssault': 'viking', 'Medivac': 'medivac', 'Liberator': 'liberator',
    'Banshee': 'banshee', 'Raven': 'raven', 'Battlecruiser': 'battlecruiser',
    'CommandCenter': 'command-center', 'OrbitalCommand': 'orbital-command',
    'PlanetaryFortress': 'planetary-fortress', 'SupplyDepot': 'supply-depot',
    'SupplyDepotLowered': 'supply-depot', 'Refinery': 'refinery', 'Barracks': 'barracks',
    'BarracksTechLab': 'barracks-techlab', 'BarracksReactor': 'barracks-reactor',
    'Factory': 'factory', 'FactoryTechLab': 'factory-techlab', 'FactoryReactor': 'factory-reactor',
    'Starport': 'starport', 'StarportTechLab': 'starport-techlab', 'StarportReactor': 'starport-reactor',
    'EngineeringBay': 'engineering-bay', 'Armory': 'armory', 'FusionCore': 'fusion-core',
    'GhostAcademy': 'ghost-academy', 'Bunker': 'bunker', 'MissileTurret': 'missile-turret',
    'Probe': 'probe', 'Zealot': 'zealot', 'Stalker': 'stalker', 'Sentry': 'sentry', 'Adept': 'adept',
    'HighTemplar': 'high-templar', 'DarkTemplar': 'dark-templar', 'Archon': 'archon',
    'Observer': 'observer', 'WarpPrism': 'warp-prism', 'Immortal': 'immortal', 'Colossus': 'colossus',
    'Disruptor': 'disruptor', 'Phoenix': 'phoenix', 'VoidRay': 'void-ray', 'Oracle': 'oracle',
    'Tempest': 'tempest', 'Carrier': 'carrier', 'Nexus': 'nexus', 'Pylon': 'pylon',
    'Assimilator': 'assimilator', 'Gateway': 'gateway', 'WarpGate': 'warpgate', 'Forge': 'forge',
    'CyberneticsCore': 'cybernetics-core', 'PhotonCannon': 'photon-cannon',
    'ShieldBattery': 'shield-battery', 'TwilightCouncil': 'twilight-council', 'Stargate': 'stargate',
    'RoboticsFacility': 'robotics-facility', 'RoboticsBay': 'robotics-bay',
    'FleetBeacon': 'fleet-beacon', 'TemplarArchive': 'templar-archive', 'DarkShrine': 'dark-shrine',
}


def to_sym(utype):
    if utype in CAMEL_TO_KEBAB:
        return CAMEL_TO_KEBAB[utype]
    s = re.sub(r'([a-z0-9])([A-Z])', r'\1-\2', utype).lower()
    return re.sub(r'[^a-z0-9\-]', '', s) or 'unknown'


def clean_str(s):
    return s.replace('\\', '').replace('"', '').replace('\n', ' ').strip()


def unpack_single_replay(item):
    cohort, path = item
    try:
        archive = mpyq.MPQArchive(path)
        header = versions.latest().decode_replay_header(archive.header['user_data_header']['content'])
        protocol = versions.build(header['m_version']['m_baseBuild'])
        details = protocol.decode_replay_details(archive.read_file('replay.details'))
        tracker = list(protocol.decode_replay_tracker_events(archive.read_file('replay.tracker.events')))
    except Exception:
        return []

    if not details or len(details.get('m_playerList', [])) < 2:
        return []

    players = {}
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
        name = p['m_name'].decode('utf-8', errors='ignore') if isinstance(p['m_name'], bytes) else str(p['m_name'])
        players[idx + 1] = {'name': clean_str(name), 'race': r}

    future_spawns = {1: [], 2: []}
    for ev in tracker:
        if ev.get('_event') in ('NNet.Replay.Tracker.SUnitBornEvent', 'NNet.Replay.Tracker.SUnitInitEvent'):
            p = ev.get('m_controlPlayerId', 0)
            if p in (1, 2):
                utype = ev['m_unitTypeName'].decode('utf-8', errors='ignore') if isinstance(ev['m_unitTypeName'], bytes) else str(ev['m_unitTypeName'])
                if not utype.startswith('Beacon') and utype not in IGNORE_RAW and utype not in WORKER_RAW and utype not in SUPPLY_RAW and utype not in GAS_RAW:
                    future_spawns[p].append((ev.get('_gameloop', 0), to_sym(utype)))

    units = {}
    alive_units = {1: set(), 2: set()}
    workers_lost = {1: 0, 2: 0}
    stats_snap = {1: {}, 2: {}}
    seen_by_opponent = {1: {}, 2: {}}

    checkpoints = [1344, 2016, 2688, 3360, 4032, 4704, 5376]
    cp_idx = 0
    replay_id = clean_str(os.path.basename(path))
    sexp_lines = []

    for ev in tracker:
        gl = ev.get('_gameloop', 0)
        while cp_idx < len(checkpoints) and gl >= checkpoints[cp_idx]:
            cp_gl = checkpoints[cp_idx]
            for obs_p in (1, 2):
                opp_p = 3 - obs_p
                opp_alive = [units[t] for t in alive_units[opp_p] if t in units]
                our_alive = [units[t] for t in alive_units[obs_p] if t in units]
                if not opp_alive or not our_alive:
                    continue
                true_w = sum(1 for u in opp_alive if u['raw_type'] in WORKER_RAW)
                st = stats_snap[opp_p]
                true_cum_min = sum(st.get(k, 0) for k in ('m_scoreValueMineralsCurrent','m_scoreValueMineralsUsedInProgressArmy','m_scoreValueMineralsUsedInProgressEconomy','m_scoreValueMineralsUsedInProgressTechnology','m_scoreValueMineralsUsedCurrentArmy','m_scoreValueMineralsUsedCurrentEconomy','m_scoreValueMineralsUsedCurrentTechnology','m_scoreValueMineralsLostArmy','m_scoreValueMineralsLostEconomy','m_scoreValueMineralsLostTechnology'))
                true_cum_gas = sum(st.get(k, 0) for k in ('m_scoreValueVespeneCurrent','m_scoreValueVespeneUsedInProgressArmy','m_scoreValueVespeneUsedInProgressEconomy','m_scoreValueVespeneUsedInProgressTechnology','m_scoreValueVespeneUsedCurrentArmy','m_scoreValueVespeneUsedCurrentEconomy','m_scoreValueVespeneUsedCurrentTechnology','m_scoreValueVespeneLostArmy','m_scoreValueVespeneLostEconomy','m_scoreValueVespeneLostTechnology'))

                for u_opp_tag in alive_units[opp_p]:
                    u_opp = units[u_opp_tag]
                    for u_obs in our_alive:
                        if math.hypot(u_opp['x'] - u_obs['x'], u_opp['y'] - u_obs['y']) <= 14.0:
                            seen_by_opponent[opp_p][u_opp_tag] = cp_gl
                            break

                seen_opp = [units[t] for t in seen_by_opponent[opp_p] if t in units]
                ally_u_sexp = " ".join(
                    f"({u['tag']} {u['sym']} {int(u['x']*10)} {int(u['y']*10)})"
                    for u in our_alive if u['raw_type'] not in BLDG_RAW and u['raw_type'] not in IGNORE_RAW and not u['raw_type'].startswith('Beacon')
                )
                ally_b_sexp = " ".join(
                    f"({u['tag']} {u['sym']} {int(u['x']*10)} {int(u['y']*10)})"
                    for u in our_alive if u['raw_type'] in BLDG_RAW
                )
                opp_u_sexp = " ".join(
                    f"({u['tag']} {u['sym']} {int(u['x']*10)} {int(u['y']*10)} {1 if u['alive'] else 0} {seen_by_opponent[opp_p].get(u['tag'], cp_gl)})"
                    for u in seen_opp if u['raw_type'] not in BLDG_RAW and u['raw_type'] not in IGNORE_RAW and not u['raw_type'].startswith('Beacon')
                )
                opp_b_sexp = " ".join(
                    f"({u['tag']} {u['sym']} {int(u['x']*10)} {int(u['y']*10)} {1 if u['alive'] else 0})"
                    for u in seen_opp if u['raw_type'] in BLDG_RAW
                )
                fut_sexp = " ".join(
                    ut_sym for (s_gl, ut_sym) in future_spawns[opp_p]
                    if cp_gl < s_gl <= (cp_gl + 1344)
                )
                true_opp_combat = [u for u in opp_alive if u['raw_type'] not in WORKER_RAW and u['raw_type'] not in BLDG_RAW and u['raw_type'] not in SUPPLY_RAW and u['raw_type'] not in IGNORE_RAW and not u['raw_type'].startswith('Beacon')]
                if true_opp_combat:
                    tcx = int(sum(u['x']*10 for u in true_opp_combat) / len(true_opp_combat))
                    tcy = int(sum(u['y']*10 for u in true_opp_combat) / len(true_opp_combat))
                else:
                    tcx, tcy = -1, -1

                sexp_lines.append(
                    f'(checkpoint "{cohort}" "{replay_id}" {obs_p} "{players[obs_p]["name"]}" {players[obs_p]["race"]} '
                    f'"{players[opp_p]["name"]}" {players[opp_p]["race"]} {cp_gl} {true_w} {int(true_cum_min)} {int(true_cum_gas)} '
                    f'{workers_lost[opp_p]} {tcx} {tcy} '
                    f'({ally_u_sexp}) ({ally_b_sexp}) ({opp_u_sexp}) ({opp_b_sexp}) ({fut_sexp}))'
                )
            cp_idx += 1

        etype = ev.get('_event')
        if etype in ('NNet.Replay.Tracker.SUnitBornEvent', 'NNet.Replay.Tracker.SUnitInitEvent'):
            p = ev.get('m_controlPlayerId', 0)
            if p in (1, 2):
                tag = ev['m_unitTagIndex']
                utype = ev['m_unitTypeName'].decode('utf-8', errors='ignore') if isinstance(ev['m_unitTypeName'], bytes) else str(ev['m_unitTypeName'])
                units[tag] = {'tag': tag, 'p': p, 'raw_type': utype, 'sym': to_sym(utype), 'x': ev.get('m_x', 0), 'y': ev.get('m_y', 0), 'born': gl, 'alive': True}
                alive_units[p].add(tag)
        elif etype == 'NNet.Replay.Tracker.SUnitTypeChangeEvent':
            tag = ev['m_unitTagIndex']
            if tag in units:
                utype = ev['m_unitTypeName'].decode('utf-8', errors='ignore') if isinstance(ev['m_unitTypeName'], bytes) else str(ev['m_unitTypeName'])
                units[tag]['raw_type'] = utype
                units[tag]['sym'] = to_sym(utype)
        elif etype == 'NNet.Replay.Tracker.SUnitDiedEvent':
            tag = ev['m_unitTagIndex']
            if tag in units:
                u = units[tag]
                u['alive'] = False
                p = u['p']
                alive_units[p].discard(tag)
                if u['raw_type'] in WORKER_RAW:
                    workers_lost[p] += 1
                seen_by_opponent[p][tag] = gl
                kt = ev.get('m_killerUnitTagIndex')
                if kt and kt in units:
                    seen_by_opponent[units[kt]['p']][kt] = gl
        elif etype == 'NNet.Replay.Tracker.SUnitPositionsEvent':
            idx = ev.get('m_firstUnitIndex', 0)
            items = ev.get('m_items', [])
            for i in range(0, len(items), 3):
                idx += items[i]
                if idx in units:
                    units[idx]['x'], units[idx]['y'] = items[i + 1], items[i + 2]
        elif etype == 'NNet.Replay.Tracker.SPlayerStatsEvent':
            p = ev.get('m_playerId', 0)
            if p in (1, 2):
                stats_snap[p] = ev.get('m_stats', {})

    return sexp_lines


def collect_replay_paths():
    patterns = [
        ('pro_tournament', 'external_bots/python-sc2/test/replays/*.SC2Replay'),
        ('pro_corpus', 'replays/pro_corpus/**/*.SC2Replay'),
        ('pro_corpus', 'replays/pro_corpus/*.SC2Replay'),
        ('aiarena_ladder', 'replays/aiarena_matches/*.SC2Replay'),
        ('aiarena_ladder', 'replays/aiarena_corpus/**/*.SC2Replay'),
        ('aiarena_ladder', 'replays/aiarena_corpus/*.SC2Replay'),
        ('external_gauntlet', 'replays/external_gauntlet/*.SC2Replay'),
        ('external_gauntlet', 'replays/external_bots_gauntlet/*.SC2Replay'),
    ]
    seen_hashes = set()
    items = []
    for cohort, pat in patterns:
        for p in sorted(glob.glob(pat, recursive=True)):
            try:
                sz = os.path.getsize(p)
                if sz < 1000:
                    continue
                with open(p, 'rb') as fh:
                    h = hashlib.md5(fh.read(8192)).hexdigest()
                key = (sz, h)
                if key not in seen_hashes:
                    seen_hashes.add(key)
                    items.append((cohort, p))
            except Exception:
                continue
    return items


def main():
    items = collect_replay_paths()
    os.makedirs('replays', exist_ok=True)
    out_path = 'replays/corpus_checkpoints.sexp'
    total_lines = 0
    with mp.Pool(processes=min(16, max(1, mp.cpu_count()))) as pool, open(out_path, 'w') as out_f:
        for lines in pool.imap_unordered(unpack_single_replay, items, chunksize=16):
            for ln in lines:
                out_f.write(ln + '\n')
                total_lines += 1
    print(f"Unpacked {total_lines} raw S-expression checkpoints from {len(items)} .SC2Replay archives into {out_path}")


if __name__ == '__main__':
    main()
