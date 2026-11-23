/* Shared 5-Tab, 22-Graph Pro Comparison Observatory (pure inline SVG, zero external deps).
 * Works identically in mothman-dashboard (dark theme) and GitHub Pages index.html (warm light theme).
 * Exposes window.MothmanObservatory = { mount(container, data, opts) }.
 */
(function (global) {
  'use strict';

  const THEMES = {
    light: {
      m: '#C4633E', p: '#3B6E9C', o: '#7A5A8E',
      good: '#1F6E43', bad: '#B43C2E', warn: '#B8761A',
      ink: '#141413', ink2: '#5E5D59', muted: '#7A7870',
      grid: '#E7E3D8', gridSub: '#EFECE3', cardBg: '#FFFFFF', surface: '#F4F1EA',
      dotStroke: '#FFFFFF', dangerFill: 'rgba(180, 60, 46, 0.08)',
      goodFill: 'rgba(31, 110, 67, 0.07)',
      tiers: ['#3B6E9C', '#C4633E', '#7A5A8E'],
      units: ['#C4633E', '#3B6E9C', '#1F6E43', '#B8761A', '#7A5A8E', '#2A8C82', '#C24D68', '#5E6C84', '#9A8F7A'],
      split: ['#C4633E', '#3B6E9C', '#1F6E43', '#B8761A', '#7A5A8E', '#8C8980'],
    },
    dark: {
      m: '#F07D52', p: '#60A5FA', o: '#C084FC',
      good: '#4ADE80', bad: '#F87171', warn: '#FBBF24',
      ink: '#E6E9EF', ink2: '#AEB6C4', muted: '#8590A2',
      grid: 'rgba(255,255,255,0.10)', gridSub: 'rgba(255,255,255,0.05)',
      cardBg: '#161B22', surface: '#1E2530',
      dotStroke: '#161B22', dangerFill: 'rgba(248, 113, 113, 0.12)',
      goodFill: 'rgba(74, 222, 128, 0.08)',
      tiers: ['#60A5FA', '#F07D52', '#C084FC'],
      units: ['#F07D52', '#60A5FA', '#4ADE80', '#FBBF24', '#C084FC', '#2DD4BF', '#FB7185', '#94A3B8', '#64748B'],
      split: ['#F07D52', '#60A5FA', '#4ADE80', '#FBBF24', '#C084FC', '#94A3B8'],
    },
  };

  const MATCHUPS = ['PvP', 'PvT', 'PvZ', 'TvP', 'TvT', 'TvZ', 'ZvP', 'ZvT', 'ZvZ'];
  const RACE_MATCHUPS = {
    all: MATCHUPS,
    Protoss: ['PvP', 'PvT', 'PvZ'],
    Terran: ['TvP', 'TvT', 'TvZ'],
    Zerg: ['ZvP', 'ZvT', 'ZvZ'],
  };

  const CORE_SPECS = [
    { key: 'apm', title: 'Actions Per Minute (APM)', unit: 'APM', scaleToggle: true, showBands: true },
    { key: 'epm', title: 'Effective Actions (EPM)', unit: 'EPM', scaleToggle: true, showBands: true },
    { key: 'spm', title: 'Screens Per Minute (SPM)', unit: 'SPM', scaleToggle: false, showBands: true, spmNote: true, spanFull: true },
    { key: 'army_minerals', title: 'Army Value (Minerals)', unit: 'min', scaleToggle: false, showBands: true, showPeak: true },
    { key: 'army_gas', title: 'Army Value (Gas)', unit: 'gas', scaleToggle: false, showBands: true, showPeak: true },
    { key: 'collection_minerals', title: 'Mineral Income / Min', unit: 'min/m', scaleToggle: false, showBands: true, showPeak: true },
    { key: 'collection_gas', title: 'Gas Income / Min', unit: 'gas/m', scaleToggle: false, showBands: true, showPeak: true },
  ];

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function fmt(v, dec) {
    if (v == null || Number.isNaN(Number(v))) return '--';
    const n = Number(v);
    if (typeof dec === 'number') return n.toFixed(dec);
    if (Math.abs(n) >= 10000) return (n / 1000).toFixed(1) + 'k';
    if (Math.abs(n) >= 1000) return (n / 1000).toFixed(2).replace(/\.00$/, '') + 'k';
    if (Math.abs(n) >= 100) return String(Math.round(n));
    return n % 1 === 0 ? String(n) : n.toFixed(1);
  }

  function fmtInt(v) {
    if (v == null || Number.isNaN(Number(v))) return '--';
    return Math.round(Number(v)).toLocaleString('en-US');
  }

  const HUMAN_KEY_MAP = {
    TechUpgrades: 'Tech Upgrades',
    SupplyDrop: 'Extra Supplies',
    CreepTumor: 'Creep Tumor',
    SiegeTank: 'Siege Tank',
    WidowMine: 'Widow Mine',
    CommandCenter: 'Command Center',
    OrbitalCommand: 'Orbital Command',
    Robo: 'Robotics',
    __other__: 'Other',
    hydraliskspeed: 'Muscular Augments (Hydra Speed)',
    'Carrier Launch Speed Upgrade': 'Graviton Catapult',
    'Terran Vehicle And Ship Weapons Level 1': '+1 Mech/Air Weapons',
    'Terran Vehicle And Ship Weapons Level 2': '+2 Mech/Air Weapons',
    'Terran Vehicle And Ship Weapons Level 3': '+3 Mech/Air Weapons',
  };

  function humanize(s) {
    const raw = String(s == null ? '' : s).trim();
    if (!raw) return '';
    if (HUMAN_KEY_MAP[raw]) return HUMAN_KEY_MAP[raw];
    return raw.replace(/([a-z])([A-Z])/g, '$1 $2');
  }

  function mmss(sec) {
    if (sec == null || Number.isNaN(Number(sec))) return '--';
    const s = Math.max(0, Math.round(Number(sec)));
    return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
  }

  function signedSec(mSec, pSec) {
    if (mSec == null || pSec == null) return '';
    const d = Math.round(Number(mSec) - Number(pSec));
    const sgn = d >= 0 ? '+' : '-';
    const a = Math.abs(d);
    return sgn + Math.floor(a / 60) + ':' + String(a % 60).padStart(2, '0');
  }

  function niceMax(rawMax, minFloor) {
    const v = Math.max(minFloor || 1, Number(rawMax) || 1);
    const mag = Math.pow(10, Math.floor(Math.log10(v)));
    const norm = v / mag;
    let step = 10;
    if (norm <= 1.2) step = 1.2;
    else if (norm <= 1.5) step = 1.5;
    else if (norm <= 2) step = 2;
    else if (norm <= 2.5) step = 2.5;
    else if (norm <= 3) step = 3;
    else if (norm <= 4) step = 4;
    else if (norm <= 5) step = 5;
    else if (norm <= 6) step = 6;
    else if (norm <= 8) step = 8;
    return step * mag;
  }

  function mount(container, data, opts) {
    if (!container || !data) return;
    opts = opts || {};
    const themeName = opts.theme === 'dark' ? 'dark' : 'light';
    const T = THEMES[themeName];
    const tipEl = opts.tooltipEl || document.getElementById('site-curve-tooltip') || document.getElementById('curve-tooltip');

    const state = {
      tab: opts.initialTab || 'mine_trade',
      race: opts.initialRace || 'all',
      scale: opts.initialScale || 'log',
      matchup: 'TvP',
      clusterIdx: 0,
      prodRace: 'Protoss',
      upgScope: 'Protoss',
      timingRace: 'Protoss',
      timingKind: 'all',
      combatScope: 'all',
      tierScope: 'all',
      spellRace: 'all',
      macroSlice: 'overall',
      ocCloak: 'inherit',
    };

    function showTip(evt, html) {
      if (!tipEl) return;
      tipEl.innerHTML = html;
      tipEl.classList.remove('hidden');
      tipEl.style.display = 'block';
      const pad = 12;
      const vw = window.innerWidth, vh = window.innerHeight;
      const r = tipEl.getBoundingClientRect();
      let x = evt.clientX + pad, y = evt.clientY - r.height / 2;
      if (x + r.width > vw - 8) x = evt.clientX - r.width - pad;
      if (x < 8) x = 8;
      if (y < 8) y = 8;
      if (y + r.height > vh - 8) y = vh - r.height - 8;
      tipEl.style.left = x + 'px';
      tipEl.style.top = y + 'px';
    }

    function hideTip() {
      if (!tipEl) return;
      tipEl.style.display = 'none';
      tipEl.classList.add('hidden');
    }

    // ---------- Shared Reusable Time-Series Card Builder ----------
    function renderTimeSeriesSvg(optsChart) {
      const mPts = optsChart.mPts || [], pPts = optsChart.pPts || [], oPts = optsChart.oPts || [];
      const buckets = optsChart.buckets || [];
      const maxT = optsChart.maxT || (buckets.length ? buckets[buckets.length - 1] : 900);
      const useLog = !!optsChart.useLog;
      const zoomPro = !!optsChart.zoomPro;
      const showBands = optsChart.showBands !== false;
      const W = optsChart.W || 420, H = optsChart.H || 200;
      const PL = 46, PR = 14, PT = 14, PB = 26;
      const CW = W - PL - PR, CH = H - PT - PB;
      const minN = optsChart.minN != null ? optsChart.minN : 2;
      const valKey = optsChart.valKey || 'med';

      let yMax, ticks;
      if (useLog) {
        let maxRaw = 200;
        [mPts, pPts, oPts].forEach(function (arr) {
          arr.forEach(function (pt) { if ((pt.n || 0) >= minN && pt[valKey] != null) maxRaw = Math.max(maxRaw, pt[valKey]); });
        });
        const logCap = Math.max(1000, Math.pow(10, Math.ceil(Math.log10(maxRaw + 1))));
        const cand = logCap >= 50000 ? [0, 10, 100, 1000, 10000, 50000] : [0, 10, 50, 200, 1000, 5000, 20000];
        yMax = Math.log10(logCap + 1);
        ticks = cand.filter(function (v) { return v <= logCap; });
      } else if (optsChart.fixedYMax) {
        yMax = optsChart.fixedYMax;
        ticks = optsChart.fixedTicks || [0, yMax * 0.25, yMax * 0.5, yMax * 0.75, yMax];
      } else {
        let maxRaw = optsChart.minYMax || 1;
        (zoomPro ? [mPts, pPts] : [mPts, pPts, oPts]).forEach(function (arr, idx) {
          arr.forEach(function (pt) {
            if ((pt.n || 0) < minN) return;
            if (pt[valKey] != null) maxRaw = Math.max(maxRaw, pt[valKey]);
            if (showBands && idx < 2 && pt.p75 != null) maxRaw = Math.max(maxRaw, pt.p75);
          });
        });
        yMax = niceMax(maxRaw * 1.08, optsChart.minYMax || 1);
        ticks = [0, 0.25, 0.5, 0.75, 1].map(function (f) { return +(yMax * f).toFixed(yMax <= 5 ? 1 : 0); });
      }

      const xOf = function (t) { return PL + (Math.max(0, Math.min(maxT, t)) / Math.max(1, maxT)) * CW; };
      const yOf = function (val) {
        const v = Math.max(0, Number(val) || 0);
        const frac = useLog ? Math.log10(v + 1) / yMax : Math.min(1.06, v / yMax);
        return PT + CH - Math.max(0, Math.min(1.04, frac)) * CH;
      };
      const makeLine = function (pts) {
        const valid = pts.filter(function (pt) { return (pt.n || 0) >= minN && pt[valKey] != null; });
        return valid.map(function (pt, i) { return (i === 0 ? 'M' : 'L') + xOf(pt.t).toFixed(1) + ',' + yOf(pt[valKey]).toFixed(1); }).join(' ');
      };
      const makeBand = function (pts) {
        const valid = pts.filter(function (pt) { return (pt.n || 0) >= Math.max(3, minN) && pt.p25 != null && pt.p75 != null; });
        if (valid.length < 2) return '';
        const top = valid.map(function (pt) { return xOf(pt.t).toFixed(1) + ',' + yOf(pt.p75).toFixed(1); }).join(' ');
        const bot = valid.slice().reverse().map(function (pt) { return xOf(pt.t).toFixed(1) + ',' + yOf(pt.p25).toFixed(1); }).join(' ');
        return top + ' ' + bot;
      };

      let grid = '';
      if (optsChart.dangerAbove != null && !useLog) {
        const yD = yOf(optsChart.dangerAbove);
        grid += '<rect x="' + PL + '" y="' + PT + '" width="' + CW + '" height="' + Math.max(0, yD - PT).toFixed(1) + '" fill="' + T.dangerFill + '" />';
        grid += '<line x1="' + PL + '" y1="' + yD.toFixed(1) + '" x2="' + (W - PR) + '" y2="' + yD.toFixed(1) + '" stroke="' + T.bad + '" stroke-width="1" stroke-dasharray="3 3" opacity="0.6" />';
        grid += '<text x="' + (PL + 6) + '" y="' + (PT + 11) + '" text-anchor="start" fill="' + T.bad + '" font-size="8.8" font-weight="600" font-family="var(--mono,monospace)">' + esc(optsChart.dangerLabel || 'Cap zone') + '</text>';
      }
      ticks.forEach(function (tv) {
        const yy = yOf(tv);
        grid += '<line x1="' + PL + '" y1="' + yy.toFixed(1) + '" x2="' + (W - PR) + '" y2="' + yy.toFixed(1) + '" stroke="' + T.grid + '" stroke-width="1" />';
        const lbl = optsChart.yFmt ? optsChart.yFmt(tv) : fmt(tv);
        grid += '<text x="' + (PL - 6) + '" y="' + (yy + 3.5).toFixed(1) + '" text-anchor="end" fill="' + T.muted + '" font-size="9.5" font-family="var(--mono,monospace)">' + esc(lbl) + '</text>';
      });
      const stepSec = maxT > 960 ? 240 : 180;
      for (let s = 0; s <= maxT; s += stepSec) {
        const xx = xOf(s);
        grid += '<line x1="' + xx.toFixed(1) + '" y1="' + PT + '" x2="' + xx.toFixed(1) + '" y2="' + (H - PB) + '" stroke="' + T.gridSub + '" stroke-width="0.8" stroke-dasharray="2 3" />';
        grid += '<text x="' + xx.toFixed(1) + '" y="' + (H - PB + 15) + '" text-anchor="middle" fill="' + T.ink2 + '" font-size="9.5" font-family="var(--mono,monospace)">' + Math.round(s / 60) + 'm</text>';
      }
      const pBand = (showBands && !useLog) ? makeBand(pPts) : '';
      const mBand = (showBands && !useLog) ? makeBand(mPts) : '';
      const oPath = zoomPro ? '' : makeLine(oPts);
      const pPath = makeLine(pPts);
      const mPath = makeLine(mPts);
      const svgId = optsChart.svgKey || '';
      return (
        '<svg viewBox="0 0 ' + W + ' ' + H + '" class="obs-svg" data-obs-ts="' + esc(svgId) + '" role="img" aria-label="' + esc(optsChart.title || '') + '">' +
          grid +
          (pBand ? '<polygon points="' + pBand + '" fill="' + T.p + '" opacity="0.11" />' : '') +
          (mBand ? '<polygon points="' + mBand + '" fill="' + T.m + '" opacity="0.16" />' : '') +
          (oPath ? '<path d="' + oPath + '" fill="none" stroke="' + T.o + '" stroke-width="1.6" opacity="0.82" stroke-linejoin="round" />' : '') +
          (pPath ? '<path d="' + pPath + '" fill="none" stroke="' + T.p + '" stroke-width="2.0" stroke-dasharray="5 3" stroke-linejoin="round" />' : '') +
          (mPath ? '<path d="' + mPath + '" fill="none" stroke="' + T.m + '" stroke-width="2.5" stroke-linejoin="round" />' : '') +
          '<line class="obs-cross" x1="0" y1="' + PT + '" x2="0" y2="' + (H - PB) + '" stroke="' + T.muted + '" stroke-width="1" stroke-dasharray="2 2" style="display:none" />' +
          '<circle class="obs-dm" r="3.6" fill="' + T.m + '" stroke="' + T.dotStroke + '" stroke-width="1.2" style="display:none" />' +
          '<circle class="obs-dp" r="3.2" fill="' + T.p + '" stroke="' + T.dotStroke + '" stroke-width="1.2" style="display:none" />' +
          '<circle class="obs-do" r="3.0" fill="' + T.o + '" stroke="' + T.dotStroke + '" stroke-width="1.2" style="display:none" />' +
          '<rect class="obs-hit" x="' + PL + '" y="' + PT + '" width="' + CW + '" height="' + CH + '" fill="transparent" style="cursor:crosshair" />' +
        '</svg>'
      );
    }

    function wireTimeSeriesHover(svgEl, optsChart) {
      if (!svgEl) return;
      const mPts = optsChart.mPts || [], pPts = optsChart.pPts || [], oPts = optsChart.oPts || [];
      const buckets = optsChart.buckets || [];
      const maxT = optsChart.maxT || (buckets.length ? buckets[buckets.length - 1] : 900);
      const useLog = !!optsChart.useLog;
      const zoomPro = !!optsChart.zoomPro;
      const showBands = optsChart.showBands !== false;
      const W = optsChart.W || 420, H = optsChart.H || 200;
      const PL = 46, PR = 14, PT = 14, PB = 26;
      const CW = W - PL - PR, CH = H - PT - PB;
      const minN = optsChart.minN != null ? optsChart.minN : 2;
      const valKey = optsChart.valKey || 'med';

      let yMax;
      if (useLog) {
        let maxRaw = 200;
        [mPts, pPts, oPts].forEach(function (arr) {
          arr.forEach(function (pt) { if ((pt.n || 0) >= minN && pt[valKey] != null) maxRaw = Math.max(maxRaw, pt[valKey]); });
        });
        yMax = Math.log10(Math.max(1000, Math.pow(10, Math.ceil(Math.log10(maxRaw + 1)))) + 1);
      } else if (optsChart.fixedYMax) {
        yMax = optsChart.fixedYMax;
      } else {
        let maxRaw = optsChart.minYMax || 1;
        (zoomPro ? [mPts, pPts] : [mPts, pPts, oPts]).forEach(function (arr, idx) {
          arr.forEach(function (pt) {
            if ((pt.n || 0) < minN) return;
            if (pt[valKey] != null) maxRaw = Math.max(maxRaw, pt[valKey]);
            if (showBands && idx < 2 && pt.p75 != null) maxRaw = Math.max(maxRaw, pt.p75);
          });
        });
        yMax = niceMax(maxRaw * 1.08, optsChart.minYMax || 1);
      }
      const xOf = function (t) { return PL + (Math.max(0, Math.min(maxT, t)) / Math.max(1, maxT)) * CW; };
      const yOf = function (val) {
        const v = Math.max(0, Number(val) || 0);
        const frac = useLog ? Math.log10(v + 1) / yMax : Math.min(1.06, v / yMax);
        return PT + CH - Math.max(0, Math.min(1.04, frac)) * CH;
      };
      const toMap = function (arr) { const mp = {}; arr.forEach(function (pt) { mp[pt.t] = pt; }); return mp; };
      const mMap = toMap(mPts), pMap = toMap(pPts), oMap = toMap(oPts);
      const hit = svgEl.querySelector('.obs-hit');
      const cross = svgEl.querySelector('.obs-cross');
      const dM = svgEl.querySelector('.obs-dm'), dP = svgEl.querySelector('.obs-dp'), dO = svgEl.querySelector('.obs-do');
      const vFmt = optsChart.yFmt || fmt;
      const onMove = function (evt) {
        const pe = evt.touches ? evt.touches[0] : evt;
        const r = svgEl.getBoundingClientRect();
        const sx = ((pe.clientX - r.left) / Math.max(1, r.width)) * W;
        const frac = Math.max(0, Math.min(1, (sx - PL) / CW));
        const idx = Math.round(frac * Math.max(0, buckets.length - 1));
        const t = buckets[idx] != null ? buckets[idx] : 0;
        const xx = xOf(t);
        const pm = mMap[t], pp = pMap[t], po = oMap[t];
        cross.setAttribute('x1', xx.toFixed(1)); cross.setAttribute('x2', xx.toFixed(1)); cross.style.display = '';
        const setD = function (el, pt, ok) {
          if (ok && pt && (pt.n || 0) >= minN && pt[valKey] != null) {
            el.setAttribute('cx', xx.toFixed(1)); el.setAttribute('cy', yOf(pt[valKey]).toFixed(1)); el.style.display = '';
          } else el.style.display = 'none';
        };
        setD(dM, pm, true); setD(dP, pp, true); setD(dO, po, !zoomPro);
        const rowT = function (col, lbl, pt) {
          if (!pt || pt[valKey] == null) return '<div class="obs-tip-row"><span><span class="obs-dot" style="background:' + col + '"></span>' + lbl + '</span><span>--</span></div>';
          const rng = (pt.p25 != null && pt.p75 != null) ? (' (' + vFmt(pt.p25) + '–' + vFmt(pt.p75) + ')') : '';
          return '<div class="obs-tip-row"><span><span class="obs-dot" style="background:' + col + '"></span>' + lbl + '</span><span><strong>' + esc(vFmt(pt[valKey])) + '</strong><span style="opacity:.7">' + esc(rng) + '</span></span></div>';
        };
        showTip(pe,
          '<div class="obs-tip-head">' + esc(optsChart.title || '') + ' · ' + mmss(t) + '</div>' +
          rowT(T.m, 'Mothman', pm) + rowT(T.p, 'Pro GM', pp) + (oPts.length ? rowT(T.o, 'Opponents', po) : '') +
          '<div class="obs-tip-sub">Active @ ' + mmss(t) + ': ' + (pm ? pm.n : 0) + ' M · ' + (pp ? pp.n : 0) + ' Pro' + (oPts.length ? ' · ' + (po ? po.n : 0) + ' Opp' : '') + '</div>'
        );
      };
      const onLeave = function () {
        cross.style.display = 'none'; dM.style.display = 'none'; dP.style.display = 'none'; dO.style.display = 'none';
        hideTip();
      };
      hit.addEventListener('mousemove', onMove);
      hit.addEventListener('touchstart', onMove, { passive: true });
      hit.addEventListener('mouseleave', onLeave);
      hit.addEventListener('touchend', onLeave);
    }

    // ---------- TAB 1: MINE x TRADE (North Star + Core Curves 1-8) ----------
    function buildMineTradeScatter(points, raceFilter) {
      const pts = (points || []).filter(function (pt) {
        return pt && pt.min_ratio != null && pt.trade_ratio != null &&
          (raceFilter === 'all' || pt.race === raceFilter);
      });
      if (!pts.length) return '';
      const W = 760, H = 260, PL = 52, PR = 24, PT = 22, PB = 34;
      const CW = W - PL - PR, CH = H - PT - PB;
      // Smooth sqrt-ish display mapping centered nicely around 1.0x so both 0.05x and 3.0x stay crystal clear
      const clampX = function (v) { return Math.max(0.2, Math.min(2.2, Number(v) || 0.2)); };
      const clampY = function (v) { return Math.max(0.0, Math.min(2.6, Number(v) || 0.0)); };
      const xOf = function (v) { return PL + ((clampX(v) - 0.2) / 2.0) * CW; };
      const yOf = function (v) { return PT + CH - (clampY(v) / 2.6) * CH; };
      const x1 = xOf(1.0), y1 = yOf(1.0);

      let qWinBoth = 0, qBothTot = 0, qDefLoss = 0, qDefTot = 0;
      pts.forEach(function (pt) {
        if (pt.min_ratio >= 1.0 && pt.trade_ratio >= 1.0) { qBothTot++; if (pt.result === 'win') qWinBoth++; }
        if (pt.min_ratio < 1.0 && pt.trade_ratio < 1.0) { qDefTot++; if (pt.result === 'loss') qDefLoss++; }
      });

      let svg = '<svg viewBox="0 0 ' + W + ' ' + H + '" class="obs-svg" data-obs-scatter="1" role="img" aria-label="4-quadrant Minerals Collected Ratio vs Trade Ratio scatter plot">';
      // Shaded quadrants (Top-right = win zone, bottom-left = deficit zone)
      svg += '<rect x="' + x1.toFixed(1) + '" y="' + PT + '" width="' + (W - PR - x1).toFixed(1) + '" height="' + (y1 - PT).toFixed(1) + '" fill="' + T.goodFill + '" />';
      svg += '<rect x="' + PL + '" y="' + y1.toFixed(1) + '" width="' + (x1 - PL).toFixed(1) + '" height="' + (H - PB - y1).toFixed(1) + '" fill="' + T.dangerFill + '" />';
      // Grid ticks
      [0.4, 0.7, 1.0, 1.3, 1.6, 1.9, 2.2].forEach(function (xv) {
        const xx = xOf(xv);
        svg += '<line x1="' + xx.toFixed(1) + '" y1="' + PT + '" x2="' + xx.toFixed(1) + '" y2="' + (H - PB) + '" stroke="' + (xv === 1.0 ? T.ink2 : T.gridSub) + '" stroke-width="' + (xv === 1.0 ? 1.4 : 0.8) + '"' + (xv === 1.0 ? ' stroke-dasharray="4 3"' : '') + ' />';
        svg += '<text x="' + xx.toFixed(1) + '" y="' + (H - PB + 14) + '" text-anchor="middle" fill="' + T.ink2 + '" font-size="9.5" font-family="var(--mono,monospace)">' + xv.toFixed(1) + '×</text>';
      });
      [0.0, 0.5, 1.0, 1.5, 2.0, 2.5].forEach(function (yv) {
        const yy = yOf(yv);
        svg += '<line x1="' + PL + '" y1="' + yy.toFixed(1) + '" x2="' + (W - PR) + '" y2="' + yy.toFixed(1) + '" stroke="' + (yv === 1.0 ? T.ink2 : T.gridSub) + '" stroke-width="' + (yv === 1.0 ? 1.4 : 0.8) + '"' + (yv === 1.0 ? ' stroke-dasharray="4 3"' : '') + ' />';
        svg += '<text x="' + (PL - 6) + '" y="' + (yy + 3.5).toFixed(1) + '" text-anchor="end" fill="' + T.muted + '" font-size="9.5" font-family="var(--mono,monospace)">' + yv.toFixed(1) + '×</text>';
      });
      // Axis titles
      svg += '<text x="' + (PL + CW / 2).toFixed(1) + '" y="' + (H - 4) + '" text-anchor="middle" fill="' + T.muted + '" font-size="10">Minerals Collected Ratio (Us / Opponent · capped at 2.2×)</text>';
      svg += '<text x="13" y="' + (PT + CH / 2).toFixed(1) + '" text-anchor="middle" fill="' + T.muted + '" font-size="10" transform="rotate(-90 13 ' + (PT + CH / 2).toFixed(1) + ')">Trade Ratio (K / L)</text>';
      // Points (rendered BEFORE quadrant labels so haloed labels stay 100% legible)
      pts.forEach(function (pt, idx) {
        const cx = xOf(pt.min_ratio), cy = yOf(pt.trade_ratio);
        const col = pt.result === 'win' ? T.good : (pt.result === 'loss' ? T.bad : T.warn);
        svg += '<circle class="obs-scat-pt" data-scat-idx="' + idx + '" cx="' + cx.toFixed(1) + '" cy="' + cy.toFixed(1) + '" r="4.8" fill="' + col + '" stroke="' + T.dotStroke + '" stroke-width="1.2" opacity="0.88" style="cursor:pointer" />';
      });
      // Quadrant labels on top with crisp card-background stroke halo
      const halo = ' style="paint-order:stroke;stroke:' + T.cardBg + ';stroke-width:3.8px;stroke-linejoin:round"';
      svg += '<text x="' + (W - PR - 8) + '" y="' + (y1 - 8).toFixed(1) + '" text-anchor="end" fill="' + T.good + '" font-size="10" font-weight="600"' + halo + '>Mine More + Trade Better (' + qWinBoth + '/' + qBothTot + ' W)</text>';
      svg += '<text x="' + (PL + 6) + '" y="' + (PT + 14) + '" text-anchor="start" fill="' + T.p + '" font-size="9.5" font-weight="500"' + halo + '>Efficient Trade, Behind on Econ</text>';
      svg += '<text x="' + (W - PR - 8) + '" y="' + (H - PB - 8) + '" text-anchor="end" fill="' + T.warn + '" font-size="9.5" font-weight="500"' + halo + '>Ahead on Econ, Bad Trades</text>';
      svg += '<text x="' + (PL + 6) + '" y="' + (y1 + 14).toFixed(1) + '" text-anchor="start" fill="' + T.bad + '" font-size="10" font-weight="600"' + halo + '>Out-Mined &amp; Out-Traded (' + qDefLoss + '/' + qDefTot + ' L)</text>';
      svg += '</svg>';

      return (
        '<article class="obs-card obs-span-2">' +
          '<div class="obs-card-head">' +
            '<div><span class="obs-card-title">North Star: Minerals Collected Ratio × Trade Ratio</span>' +
            '<div class="obs-card-sub">Every match plotted by resource economy (X) vs. combat trade efficiency (Y) · crosshairs at 1.0× even</div></div>' +
            '<span class="obs-badge">' + pts.length + ' matches · <span style="color:' + T.good + '">● Win</span> · <span style="color:' + T.bad + '">● Loss</span> · <span style="color:' + T.warn + '">● Tie</span></span>' +
          '</div>' +
          svg +
        '</article>'
      );
    }

    function renderTabMineTrade(bodyEl) {
      const seg = (data.curves && data.curves[state.race]) ? state.race : 'all';
      const segC = (data.curves && data.curves[seg]) || {};
      const segS = (data.summary && data.summary[seg]) || {};
      const buckets = data.buckets_sec || [];
      const tsList = [];
      let html = '';

      // Primary + Secondary KPI strip (when score summary is attached)
      const ms = data.mine_trade_summary;
      if (ms) {
        const rSlice = (state.race !== 'all' && ms.by_race && ms.by_race[state.race]) ? ms.by_race[state.race] : ms.overall;
        if (rSlice) {
          const t1 = rSlice.our_t1_pct != null ? Math.round(rSlice.our_t1_pct) : 0;
          const t2 = rSlice.our_t2_pct != null ? Math.round(rSlice.our_t2_pct) : 0;
          const t3 = rSlice.our_t3_pct != null ? Math.round(rSlice.our_t3_pct) : 0;
          html +=
            '<div class="obs-kpi-strip">' +
              '<div class="obs-kpi obs-kpi-primary"><span class="obs-kpi-lbl">Primary · Trade</span><strong>' + fmt(rSlice.trade_agg, 2) + '×</strong><span class="obs-kpi-sub">med ' + fmt(rSlice.trade_med, 2) + '×</span></div>' +
              '<div class="obs-kpi obs-kpi-primary"><span class="obs-kpi-lbl">Primary · Minerals</span><strong>' + fmt(rSlice.agg_min_ratio, 2) + '×</strong><span class="obs-kpi-sub">' + fmtInt(rSlice.our_min_collected_avg) + ' vs. ' + fmtInt(rSlice.opp_min_collected_avg) + ' avg</span></div>' +
              '<div class="obs-kpi"><span class="obs-kpi-lbl">Secondary · Gas</span><strong>' + fmt(rSlice.agg_gas_ratio, 2) + '×</strong><span class="obs-kpi-sub">' + fmtInt(rSlice.our_gas_collected_avg) + ' vs. ' + fmtInt(rSlice.opp_gas_collected_avg) + ' avg</span></div>' +
              '<div class="obs-kpi"><span class="obs-kpi-lbl">Secondary · Upgrades</span><strong>' + fmt(rSlice.our_upg_levels, 1) + ' / ' + fmt(rSlice.opp_upg_levels, 1) + '</strong><span class="obs-kpi-sub">us vs. opp (+1/+2/+3)</span></div>' +
              '<div class="obs-kpi"><span class="obs-kpi-lbl">Secondary · Tier Mix</span><strong>' + t1 + '/' + t2 + '/' + t3 + '%</strong><span class="obs-kpi-sub">T1 / T2 / T3 value share</span></div>' +
            '</div>';
        }
      }

      html += '<div class="obs-grid">';
      // 4-Quadrant Scatter Plot
      const scatPts = data.mine_trade_scatter || [];
      const filteredScat = scatPts.filter(function (pt) {
        return pt && pt.min_ratio != null && pt.trade_ratio != null && (state.race === 'all' || pt.race === state.race);
      });
      html += buildMineTradeScatter(scatPts, state.race);

      // Core 7 Curves (Graphs 1-7)
      CORE_SPECS.forEach(function (spec) {
        const mc = segC[spec.key] || {}, ms2 = segS[spec.key] || {};
        const useLog = !!(spec.scaleToggle && state.scale === 'log');
        const zoomPro = !!(spec.scaleToggle && state.scale === 'linear');
        const sM = ms2.mothman || {}, sP = ms2.pros || {}, sO = ms2.opponents || {};
        const badge = useLog ? 'Log scale' : (zoomPro ? ('Linear · Opp ' + fmt(sO.med) + ' off-scale') : (spec.spmNote ? 'Linear · Opp 0.0' : (spec.showPeak ? ('Peak ' + fmt(sM.peak) + ' / Pro ' + fmt(sP.peak)) : 'Linear')));
        const chartCfg = {
          svgKey: 'core_' + spec.key, title: spec.title,
          mPts: mc.mothman || [], pPts: mc.pros || [], oPts: mc.opponents || [],
          buckets: buckets, useLog: useLog, zoomPro: zoomPro, showBands: true,
          W: spec.spanFull ? 760 : 420, H: spec.spanFull ? 172 : 200,
        };
        tsList.push(chartCfg);
        html +=
          '<article class="obs-card' + (spec.spanFull ? ' obs-span-2' : '') + '">' +
            '<div class="obs-card-head"><span class="obs-card-title">' + esc(spec.title) + '</span><span class="obs-badge">' + esc(badge) + '</span></div>' +
            '<div class="obs-meds">' +
              '<span><span class="obs-dot" style="background:' + T.m + '"></span>Mothman ' + fmt(sM.med) + '</span>' +
              '<span><span class="obs-dot" style="background:' + T.p + '"></span>Pro ' + fmt(sP.med) + '</span>' +
              '<span><span class="obs-dot" style="background:' + T.o + '"></span>Opp ' + fmt(sO.med) + '</span>' +
            '</div>' +
            renderTimeSeriesSvg(chartCfg) +
          '</article>';
      });
      html += '</div>';

      // Graph 8: Key Build & Structure Timings Whisker Box
      html += buildMilestoneTimingsBox();
      bodyEl.innerHTML = html;

      // Wire scatter tooltips
      bodyEl.querySelectorAll('.obs-scat-pt').forEach(function (el) {
        const pt = filteredScat[parseInt(el.getAttribute('data-scat-idx'), 10)];
        if (!pt) return;
        const onH = function (evt) {
          const pe = evt.touches ? evt.touches[0] : evt;
          showTip(pe,
            '<div class="obs-tip-head">#' + esc(pt.id) + ' ' + esc(pt.matchup || pt.race) + ' vs ' + esc(pt.opp) + ' (' + esc((pt.result || '').toUpperCase()) + ')</div>' +
            '<div class="obs-tip-row"><span>Minerals Collected</span><span><strong>' + fmt(pt.min_ratio, 2) + '×</strong> (' + fmtInt(pt.our_min) + ' / ' + fmtInt(pt.opp_min) + ')</span></div>' +
            '<div class="obs-tip-row"><span>Trade Ratio</span><span><strong>' + fmt(pt.trade_ratio, 2) + '×</strong></span></div>' +
            (pt.gas_ratio != null ? '<div class="obs-tip-row"><span>Gas Collected</span><span>' + fmt(pt.gas_ratio, 2) + '×</span></div>' : '') +
            (pt.upg_lv != null ? '<div class="obs-tip-row"><span>Combat Upg Levels</span><span>' + pt.upg_lv + ' vs ' + (pt.opp_upg_lv != null ? pt.opp_upg_lv : '--') + '</span></div>' : '') +
            (pt.t1 != null ? '<div class="obs-tip-row"><span>Unit Tiers (T1/T2/T3)</span><span>' + Math.round(pt.t1) + '/' + Math.round(pt.t2) + '/' + Math.round(pt.t3) + '%</span></div>' : '')
          );
        };
        el.addEventListener('mousemove', onH);
        el.addEventListener('mouseleave', hideTip);
      });
      tsList.forEach(function (cfg) { wireTimeSeriesHover(bodyEl.querySelector('[data-obs-ts="' + cfg.svgKey + '"]'), cfg); });
      wireMilestoneTimings(bodyEl);
    }

    function buildMilestoneTimingsBox() {
      const rows = (data.timings && data.timings[state.timingRace]) || [];
      const filtered = state.timingKind === 'all' ? rows : rows.filter(function (r) { return r.kind === state.timingKind; });
      const maxSec = 900, W = 760, PL = 172, PR = 124, PT = 22, PB = 14, rowH = 29;
      const H = PT + Math.max(1, filtered.length) * rowH + PB, CW = W - PL - PR;
      const xOf = function (s) { return PL + (Math.max(0, Math.min(maxSec, s)) / maxSec) * CW; };
      let svg = '<svg viewBox="0 0 ' + W + ' ' + H + '" class="obs-svg" role="img" aria-label="Milestone timings">';
      [0, 180, 360, 540, 720, 900].forEach(function (sec) {
        const xx = xOf(sec);
        svg += '<line x1="' + xx.toFixed(1) + '" y1="' + PT + '" x2="' + xx.toFixed(1) + '" y2="' + (H - PB) + '" stroke="' + T.grid + '" stroke-width="1" />';
        svg += '<text x="' + xx.toFixed(1) + '" y="13" text-anchor="middle" fill="' + T.ink2 + '" font-size="10" font-family="var(--mono,monospace)">' + (sec / 60) + 'm</text>';
      });
      filtered.forEach(function (row, i) {
        const yTop = PT + i * rowH, yMid = yTop + rowH / 2;
        if (i > 0) svg += '<line x1="0" y1="' + yTop + '" x2="' + W + '" y2="' + yTop + '" stroke="' + T.gridSub + '" stroke-width="0.8" />';
        const lbl = String(row.label || '').replace(/\s*\(done\)$/i, '');
        svg += '<text x="6" y="' + (yMid + 3.5).toFixed(1) + '" fill="' + T.ink + '" font-size="10.5" font-weight="' + (row.kind === 'expansion' ? '600' : '500') + '">' + esc(lbl.length > 24 ? lbl.slice(0, 23) + '…' : lbl) + '</text>';
        [{ ck: 'mothman', dy: -5, col: T.m, r: 3.4 }, { ck: 'pros', dy: 1, col: T.p, r: 3.0 }, { ck: 'opponents', dy: 7, col: T.o, r: 2.8 }].forEach(function (ln) {
          const d = row[ln.ck] || {};
          if (d.med == null) return;
          const yy = yMid + ln.dy;
          svg += '<line x1="' + xOf(d.p25 != null ? d.p25 : d.med).toFixed(1) + '" y1="' + yy.toFixed(1) + '" x2="' + xOf(d.p75 != null ? d.p75 : d.med).toFixed(1) + '" y2="' + yy.toFixed(1) + '" stroke="' + ln.col + '" stroke-width="2" opacity="0.55" stroke-linecap="round" />';
          svg += '<circle cx="' + xOf(d.med).toFixed(1) + '" cy="' + yy.toFixed(1) + '" r="' + ln.r + '" fill="' + ln.col + '" stroke="' + T.dotStroke + '" stroke-width="0.8" />';
        });
        const m = row.mothman || {}, p = row.pros || {};
        const dStr = signedSec(m.med, p.med);
        const dCol = (m.med != null && p.med != null) ? (m.med - p.med > 30 ? T.bad : (m.med - p.med < -15 ? T.good : T.ink2)) : T.muted;
        svg += '<text x="' + (W - PR + 8) + '" y="' + (yMid - 1).toFixed(1) + '" fill="' + dCol + '" font-size="9.8" font-weight="600" font-family="var(--mono,monospace)">' + esc(dStr ? dStr + ' vs Pro' : (m.med == null ? 'not built' : mmss(m.med))) + '</text>';
        svg += '<text x="' + (W - PR + 8) + '" y="' + (yMid + 9.5).toFixed(1) + '" fill="' + T.muted + '" font-size="8.8" font-family="var(--mono,monospace)">M/P ' + Math.round(m.adopt_pct || 0) + '%/' + Math.round(p.adopt_pct || 0) + '%</text>';
        svg += '<rect class="obs-tm-hit" data-tm-idx="' + i + '" x="0" y="' + yTop + '" width="' + W + '" height="' + rowH + '" fill="transparent" style="cursor:pointer" />';
      });
      svg += '</svg>';
      return (
        '<div class="obs-card" style="margin-top:12px;">' +
          '<div class="obs-card-head">' +
            '<div><span class="obs-card-title">Chart 8 · Key Expansion, Structure &amp; Upgrade Timings</span>' +
            '<div class="obs-card-sub">25th–75th percentile whiskers with median dot · see Army Comp &amp; Upgrades tab for the exhaustive all-upgrade race</div></div>' +
            '<div class="obs-pills">' +
              ['Protoss', 'Terran', 'Zerg'].map(function (r) { return '<button type="button" class="obs-pill' + (state.timingRace === r ? ' is-active' : '') + '" data-obs-tm-race="' + r + '">' + r + '</button>'; }).join('') +
            '</div>' +
          '</div>' +
          '<div class="obs-pills" style="margin-bottom:8px;">' +
            [['all', 'All'], ['expansion', 'Expansions'], ['structure', 'Structures'], ['upgrade', 'Upgrades']].map(function (kv) {
              return '<button type="button" class="obs-pill' + (state.timingKind === kv[0] ? ' is-active' : '') + '" data-obs-tm-kind="' + kv[0] + '">' + kv[1] + '</button>';
            }).join('') +
          '</div>' +
          svg +
        '</div>'
      );
    }

    function wireMilestoneTimings(bodyEl) {
      bodyEl.querySelectorAll('[data-obs-tm-race]').forEach(function (b) {
        b.addEventListener('click', function () { state.timingRace = b.getAttribute('data-obs-tm-race'); render(); });
      });
      bodyEl.querySelectorAll('[data-obs-tm-kind]').forEach(function (b) {
        b.addEventListener('click', function () { state.timingKind = b.getAttribute('data-obs-tm-kind'); render(); });
      });
      const rows = ((data.timings && data.timings[state.timingRace]) || []).filter(function (r) { return state.timingKind === 'all' || r.kind === state.timingKind; });
      bodyEl.querySelectorAll('.obs-tm-hit').forEach(function (el) {
        const row = rows[parseInt(el.getAttribute('data-tm-idx'), 10)];
        if (!row) return;
        el.addEventListener('mousemove', function (evt) {
          const ln = function (col, name, d) {
            if (!d || d.med == null) return '<div class="obs-tip-row"><span><span class="obs-dot" style="background:' + col + '"></span>' + name + '</span><span>-- (' + Math.round((d && d.adopt_pct) || 0) + '%)</span></div>';
            return '<div class="obs-tip-row"><span><span class="obs-dot" style="background:' + col + '"></span>' + name + '</span><span><strong>' + esc(d.med_fmt || mmss(d.med)) + '</strong> (' + mmss(d.p25) + '–' + mmss(d.p75) + ') · ' + Math.round(d.adopt_pct || 0) + '%</span></div>';
          };
          showTip(evt, '<div class="obs-tip-head">' + esc(row.label) + ' (' + esc(state.timingRace) + ')</div>' + ln(T.m, 'Mothman', row.mothman) + ln(T.p, 'Pro GM', row.pros) + ln(T.o, 'Opponents', row.opponents));
        });
        el.addEventListener('mouseleave', hideTip);
      });
    }

    // ---------- TAB 2: COMBAT & POSITIONING (Graphs 9, 10, 15, 16, 17) ----------
    function renderConcaveSchematic(mStat, pStat, scopeLabel) {
      const W = 760, H = 225;
      function drawFormation(cx, cy, st, title, col, isPro) {
        const asp = (st && st.concave_aspect && st.concave_aspect.med) ? Number(st.concave_aspect.med) : 0.85;
        const lay = (st && st.layering_delta_tiles && st.layering_delta_tiles.med != null) ? Number(st.layering_delta_tiles.med) : 0.0;
        const clump = (st && st.splash_clump_pct && st.splash_clump_pct.mean != null) ? Number(st.splash_clump_pct.mean) : 25.0;
        const inv = (st && st.role_inversion_pct != null) ? Number(st.role_inversion_pct) : 45.0;
        const nCl = (st && st.clashes_measured) || 0;
        // Scale width vs depth cleanly from aspect ratio
        const rx = Math.max(38, Math.min(108, 66 * Math.sqrt(Math.max(0.35, Math.min(2.2, asp)))));
        const ry = Math.max(18, Math.min(54, rx / Math.max(0.45, Math.min(2.0, asp))));
        // Enemy reference point sits above at cy - 68
        const ey = cy - 68;
        let g = '<g>';
        g += '<text x="' + cx + '" y="18" text-anchor="middle" fill="' + T.ink + '" font-size="11.5" font-weight="700">' + esc(title) + ' (' + nCl + ' clashes)</text>';
        // Enemy target bar at top
        g += '<rect x="' + (cx - 42) + '" y="' + (ey - 10) + '" width="84" height="16" rx="4" fill="' + T.bad + '" opacity="0.16" stroke="' + T.bad + '" stroke-width="1" />';
        g += '<text x="' + cx + '" y="' + (ey + 1.5) + '" text-anchor="middle" fill="' + T.bad + '" font-size="9" font-weight="600">Enemy Front</text>';
        // Formation envelope ellipse
        g += '<ellipse cx="' + cx + '" cy="' + (cy + 8) + '" rx="' + rx.toFixed(1) + '" ry="' + ry.toFixed(1) + '" fill="' + col + '" opacity="0.08" stroke="' + col + '" stroke-width="1.2" stroke-dasharray="4 3" />';
        // Frontline melee arc vs backline ranged arc shifted by measured layering delta (negative = melee closer to enemy!)
        const shift = Math.max(-18, Math.min(18, lay * 5.2));
        const meleeY = cy + 2 + shift;
        const rangedY = cy + 16 - shift * 0.6;
        const curveDip = Math.max(6, Math.min(22, (asp - 0.5) * 20));
        // Splash clump highlight ring around center when high clump%
        if (clump >= 25) {
          g += '<circle cx="' + cx + '" cy="' + (cy + 8) + '" r="' + (14 + clump * 0.25).toFixed(1) + '" fill="' + T.warn + '" opacity="0.14" stroke="' + T.warn + '" stroke-width="1" stroke-dasharray="2 2" />';
        }
        // Draw 7 melee (squares) and 7 ranged (circles) along curved concave arc
        for (let i = -3; i <= 3; i++) {
          const frac = i / 3;
          const xM = cx + frac * rx * 0.82;
          const yM = meleeY - (1 - frac * frac) * 0 + (frac * frac) * (-curveDip * 0.55);
          g += '<rect x="' + (xM - 4).toFixed(1) + '" y="' + (yM - 4).toFixed(1) + '" width="8" height="8" rx="1.5" fill="' + col + '" stroke="' + T.dotStroke + '" stroke-width="1" />';
          const xR = cx + frac * rx * 0.90;
          const yR = rangedY + (frac * frac) * (-curveDip * 0.45);
          g += '<circle cx="' + xR.toFixed(1) + '" cy="' + yR.toFixed(1) + '" r="4.2" fill="' + (isPro ? T.p : T.o) + '" opacity="0.92" stroke="' + T.dotStroke + '" stroke-width="1" />';
        }
        // Bottom callouts
        const layCol = lay <= -0.5 ? T.good : (lay >= 0.3 ? T.bad : T.ink2);
        g += '<text x="' + cx + '" y="' + (H - 36) + '" text-anchor="middle" fill="' + T.ink + '" font-size="10" font-family="var(--mono,monospace)">Aspect ' + asp.toFixed(2) + ' · Splash Clump ' + clump.toFixed(0) + '%</text>';
        g += '<text x="' + cx + '" y="' + (H - 21) + '" text-anchor="middle" fill="' + layCol + '" font-size="10" font-weight="600" font-family="var(--mono,monospace)">Layering ' + (lay >= 0 ? '+' : '') + lay.toFixed(2) + 't · Inversion ' + inv.toFixed(0) + '%</text>';
        g += '</g>';
        return g;
      }
      return (
        '<svg viewBox="0 0 ' + W + ' ' + H + '" class="obs-svg" role="img" aria-label="Concave geometry and layering schematic comparison">' +
          '<line x1="' + (W / 2) + '" y1="12" x2="' + (W / 2) + '" y2="' + (H - 12) + '" stroke="' + T.grid + '" stroke-width="1" />' +
          drawFormation(W * 0.25, 118, mStat, 'Mothman · ' + scopeLabel, T.m, false) +
          drawFormation(W * 0.75, 118, pStat, 'Pro GM · ' + scopeLabel, T.p, true) +
          '<text x="' + (W / 2) + '" y="' + (H - 5) + '" text-anchor="middle" fill="' + T.muted + '" font-size="9">■ Frontline melee · ● Ranged / casters · Negative layering = melee screening in front of ranged</text>' +
        '</svg>'
      );
    }

    function renderEngageRetreatHistogram(erSeg) {
      const m = (erSeg && erSeg.mothman) || {}, p = (erSeg && erSeg.pros) || {};
      const mBins = m.bins_data || [], pBins = p.bins_data || [];
      if (!mBins.length) return '<div class="obs-empty">No engage/retreat clash data for this filter.</div>';
      const W = 760, H = 236, PL = 46, PR = 48, PT = 26, PB = 34;
      const CW = W - PL - PR, CH = H - PT - PB;
      const nB = mBins.length, slotW = CW / nB;
      const maxShare = Math.max(50, niceMax(Math.max.apply(null, mBins.concat(pBins).map(function (b) { return b.share_pct || 0; })) * 1.12, 30));
      const maxDis = 30;
      const ySh = function (v) { return PT + CH - (Math.min(maxShare, Number(v) || 0) / maxShare) * CH; };
      const yDis = function (v) { return PT + CH - (Math.min(maxDis, Number(v) || 0) / maxDis) * CH; };

      let svg = '<svg viewBox="0 0 ' + W + ' ' + H + '" class="obs-svg" role="img" aria-label="Engage vs Retreat Force Ratio Histogram">';
      // Shaded outnumbered danger zone covering bins 0 and 1 (<0.5x and 0.5-0.75x)
      svg += '<rect x="' + PL + '" y="' + PT + '" width="' + (slotW * 2).toFixed(1) + '" height="' + CH + '" fill="' + T.dangerFill + '" />';
      svg += '<text x="' + (PL + slotW).toFixed(1) + '" y="' + (PT + 12) + '" text-anchor="middle" fill="' + T.bad + '" font-size="9.5" font-weight="600">Outnumbered Zone (&lt;0.75×)</text>';
      [0, 0.25, 0.5, 0.75, 1].forEach(function (f) {
        const v = Math.round(maxShare * f), yy = ySh(v);
        svg += '<line x1="' + PL + '" y1="' + yy.toFixed(1) + '" x2="' + (W - PR) + '" y2="' + yy.toFixed(1) + '" stroke="' + T.grid + '" stroke-width="0.9" />';
        svg += '<text x="' + (PL - 6) + '" y="' + (yy + 3.5).toFixed(1) + '" text-anchor="end" fill="' + T.muted + '" font-size="9.5" font-family="var(--mono,monospace)">' + v + '%</text>';
      });
      [0, 10, 20, 30].forEach(function (dv) {
        const yy = yDis(dv);
        svg += '<text x="' + (W - PR + 6) + '" y="' + (yy + 3.5).toFixed(1) + '" text-anchor="start" fill="' + T.good + '" font-size="9" font-family="var(--mono,monospace)">' + dv + '%</text>';
      });
      const bw = Math.min(34, slotW * 0.30);
      const mLinePts = [], pLinePts = [];
      let barLabelsSvg = '';
      const halo = ' style="paint-order:stroke;stroke:' + T.cardBg + ';stroke-width:3.5px;stroke-linejoin:round"';
      mBins.forEach(function (mb, i) {
        const pb = pBins[i] || {};
        const cx = PL + slotW * (i + 0.5);
        const hm = Math.max(0, PT + CH - ySh(mb.share_pct || 0));
        const hp = Math.max(0, PT + CH - ySh(pb.share_pct || 0));
        svg += '<rect x="' + (cx - bw - 2).toFixed(1) + '" y="' + ySh(mb.share_pct || 0).toFixed(1) + '" width="' + bw.toFixed(1) + '" height="' + hm.toFixed(1) + '" rx="2" fill="' + T.m + '" opacity="0.86" />';
        svg += '<rect x="' + (cx + 2).toFixed(1) + '" y="' + ySh(pb.share_pct || 0).toFixed(1) + '" width="' + bw.toFixed(1) + '" height="' + hp.toFixed(1) + '" rx="2" fill="' + T.p + '" opacity="0.82" />';
        barLabelsSvg += '<text x="' + (cx - bw / 2 - 2).toFixed(1) + '" y="' + (ySh(mb.share_pct || 0) - 4).toFixed(1) + '" text-anchor="middle" fill="' + T.m + '" font-size="9" font-weight="600" font-family="var(--mono,monospace)"' + halo + '>' + Math.round(mb.share_pct || 0) + '%</text>';
        barLabelsSvg += '<text x="' + (cx + bw / 2 + 2).toFixed(1) + '" y="' + (ySh(pb.share_pct || 0) - 4).toFixed(1) + '" text-anchor="middle" fill="' + T.p + '" font-size="9" font-weight="600" font-family="var(--mono,monospace)"' + halo + '>' + Math.round(pb.share_pct || 0) + '%</text>';
        svg += '<text x="' + cx.toFixed(1) + '" y="' + (H - PB + 15) + '" text-anchor="middle" fill="' + T.ink + '" font-size="10" font-family="var(--mono,monospace)">' + esc(mb.bin) + '</text>';
        mLinePts.push(cx.toFixed(1) + ',' + yDis(mb.disengage_pct || 0).toFixed(1));
        pLinePts.push(cx.toFixed(1) + ',' + yDis(pb.disengage_pct || 0).toFixed(1));
      });
      // Overlaid Disengage Rate lines (right axis)
      svg += '<polyline points="' + pLinePts.join(' ') + '" fill="none" stroke="' + T.good + '" stroke-width="2" stroke-dasharray="4 3" />';
      svg += '<polyline points="' + mLinePts.join(' ') + '" fill="none" stroke="' + T.warn + '" stroke-width="2.2" />';
      mBins.forEach(function (mb, i) {
        const pb = pBins[i] || {};
        const cx = PL + slotW * (i + 0.5);
        svg += '<circle cx="' + cx.toFixed(1) + '" cy="' + yDis(pb.disengage_pct || 0).toFixed(1) + '" r="3.5" fill="' + T.good + '" stroke="' + T.dotStroke + '" stroke-width="1" />';
        svg += '<circle cx="' + cx.toFixed(1) + '" cy="' + yDis(mb.disengage_pct || 0).toFixed(1) + '" r="3.5" fill="' + T.warn + '" stroke="' + T.dotStroke + '" stroke-width="1" />';
      });
      // Draw bar % labels LAST with halo so lines never strike through numbers
      svg += barLabelsSvg;
      svg += '<text x="' + (PL + CW / 2).toFixed(1) + '" y="' + (H - 4) + '" text-anchor="middle" fill="' + T.muted + '" font-size="9.5">Bars = % of engagements taken at each local force ratio (Left) · Lines = Disengage % (Right: Pro green dashed, Mothman amber)</text>';
      svg += '</svg>';

      return (
        '<div class="obs-meds">' +
          '<span>Med Engage: <strong style="color:' + T.m + '">' + fmt(m.median_engage_ratio, 2) + '×</strong> vs Pro <strong style="color:' + T.p + '">' + fmt(p.median_engage_ratio, 2) + '×</strong></span>' +
          '<span>Outnumbered (&lt;0.75×): <strong style="color:' + T.bad + '">' + fmt(m.outnumbered_engage_pct, 1) + '%</strong> vs Pro <strong>' + fmt(p.outnumbered_engage_pct, 1) + '%</strong></span>' +
          '<span>Outnumbered Disengage: <strong>' + fmt(m.outnumbered_disengage_pct, 1) + '%</strong> vs Pro <strong style="color:' + T.good + '">' + fmt(p.outnumbered_disengage_pct, 1) + '%</strong></span>' +
        '</div>' + svg
      );
    }

    function renderBulletGauges(rows) {
      const W = 760, PL = 248, PR = 108, PT = 14, PB = 10, rowH = 40;
      const H = PT + rows.length * rowH + PB, CW = W - PL - PR;
      let svg = '<svg viewBox="0 0 ' + W + ' ' + H + '" class="obs-svg" role="img" aria-label="Rotation, multiprong, and backstab bullet gauges">';
      rows.forEach(function (r, i) {
        const yTop = PT + i * rowH, yMid = yTop + rowH / 2;
        if (i > 0) svg += '<line x1="0" y1="' + yTop + '" x2="' + W + '" y2="' + yTop + '" stroke="' + T.gridSub + '" stroke-width="0.8" />';
        const mx = Math.max(r.maxVal || 1, r.mVal || 0, r.pVal || 0, r.oVal || 0) * 1.1;
        const xOf = function (v) { return PL + (Math.max(0, Math.min(mx, Number(v) || 0)) / mx) * CW; };
        svg += '<text x="6" y="' + (yMid - 1).toFixed(1) + '" fill="' + T.ink + '" font-size="10.5" font-weight="600">' + esc(r.label) + '</text>';
        svg += '<text x="6" y="' + (yMid + 11).toFixed(1) + '" fill="' + T.muted + '" font-size="9">' + esc(r.sub || '') + '</text>';
        // Background track
        svg += '<rect x="' + PL + '" y="' + (yMid - 7).toFixed(1) + '" width="' + CW + '" height="14" rx="4" fill="' + T.surface + '" />';
        // Mothman bar
        const mw = Math.max(2, xOf(r.mVal) - PL);
        const goodBar = r.lowerBetter ? ((r.mVal || 999) <= (r.pVal || 0) * 1.15) : ((r.mVal || 0) >= (r.pVal || 1) * 0.85);
        svg += '<rect x="' + PL + '" y="' + (yMid - 5).toFixed(1) + '" width="' + mw.toFixed(1) + '" height="10" rx="3" fill="' + (goodBar ? T.good : T.m) + '" opacity="0.88" />';
        // Pro GM target marker line + diamond
        if (r.pVal != null) {
          const px = xOf(r.pVal);
          svg += '<line x1="' + px.toFixed(1) + '" y1="' + (yMid - 11).toFixed(1) + '" x2="' + px.toFixed(1) + '" y2="' + (yMid + 11).toFixed(1) + '" stroke="' + T.p + '" stroke-width="2.5" />';
          svg += '<circle cx="' + px.toFixed(1) + '" cy="' + (yMid - 11).toFixed(1) + '" r="2.8" fill="' + T.p + '" />';
        }
        // Opp marker dot
        if (r.oVal != null) {
          svg += '<circle cx="' + xOf(r.oVal).toFixed(1) + '" cy="' + yMid.toFixed(1) + '" r="3.2" fill="' + T.o + '" stroke="' + T.dotStroke + '" stroke-width="1" />';
        }
        svg += '<text x="' + (W - PR + 10) + '" y="' + (yMid - 1).toFixed(1) + '" fill="' + T.m + '" font-size="10.2" font-weight="700" font-family="var(--mono,monospace)">M ' + esc(r.fmt(r.mVal)) + '</text>';
        svg += '<text x="' + (W - PR + 10) + '" y="' + (yMid + 11).toFixed(1) + '" fill="' + T.p + '" font-size="9.5" font-family="var(--mono,monospace)">Pro ' + esc(r.fmt(r.pVal)) + '</text>';
      });
      svg += '</svg>';
      return svg;
    }

    function renderTabCombat(bodyEl) {
      const seg = state.race;
      const coh = data.army_cohesion || {};
      const cohSegC = (coh.curves && (coh.curves[seg] || coh.curves.all)) || {};
      const cohSegS = (coh.summary && (coh.summary[seg] || coh.summary.all)) || {};
      const erSeg = (data.engage_retreat && data.engage_retreat.by_segment && (data.engage_retreat.by_segment[seg] || data.engage_retreat.by_segment.all)) || {};
      const scope = state.combatScope;
      const isMu = MATCHUPS.indexOf(scope) >= 0;
      const concObj = isMu ? ((data.concave_layering && data.concave_layering.by_matchup && data.concave_layering.by_matchup[scope]) || {}) : ((data.concave_layering && data.concave_layering.by_segment && (data.concave_layering.by_segment[scope] || data.concave_layering.by_segment.all)) || {});
      const rotObj = isMu ? ((data.army_rotation && data.army_rotation.by_matchup && data.army_rotation.by_matchup[scope]) || {}) : ((data.army_rotation && data.army_rotation.by_segment && (data.army_rotation.by_segment[scope] || data.army_rotation.by_segment.all)) || {});
      const mpObj = isMu ? ((data.multiprong_backstabs && data.multiprong_backstabs.by_matchup && data.multiprong_backstabs.by_matchup[scope]) || {}) : ((data.multiprong_backstabs && data.multiprong_backstabs.by_segment && (data.multiprong_backstabs.by_segment[scope] || data.multiprong_backstabs.by_segment.all)) || {});

      const tsList = [];
      const fragCfg = {
        svgKey: 'g9_frag', title: 'Graph 9a · Army Fragmentation % (outside 14t main cluster)',
        mPts: (cohSegC.army_fragmentation_pct || {}).mothman || [],
        pPts: (cohSegC.army_fragmentation_pct || {}).pros || [],
        oPts: (cohSegC.army_fragmentation_pct || {}).opponents || [],
        buckets: coh.buckets_sec || [], maxT: 960, fixedYMax: 100, fixedTicks: [0, 25, 50, 75, 100],
        yFmt: function (v) { return Math.round(v) + '%'; },
      };
      const retCfg = {
        svgKey: 'g9_ret', title: 'Graph 9b · Army Retention Ratio (Alive / Cumulative Built)',
        mPts: (cohSegC.army_retention_ratio || {}).mothman || [],
        pPts: (cohSegC.army_retention_ratio || {}).pros || [],
        oPts: (cohSegC.army_retention_ratio || {}).opponents || [],
        buckets: coh.buckets_sec || [], maxT: 960, fixedYMax: 1.0, fixedTicks: [0, 0.25, 0.5, 0.75, 1.0],
        yFmt: function (v) { return Number(v).toFixed(2); },
      };
      tsList.push(fragCfg, retCfg);

      const rm = rotObj.mothman || {}, rp = rotObj.pros || {}, ro = rotObj.opponents || {};
      const mm = mpObj.mothman || {}, mp = mpObj.pros || {}, mo = mpObj.opponents || {};
      const gaugeRows = [
        { label: 'Defensive Rotation Response', sub: '% of base threats rotated to within 45s', mVal: rm.def_response_rate_pct, pVal: rp.def_response_rate_pct, oVal: ro.def_response_rate_pct, maxVal: 80, fmt: function (v) { return fmt(v, 1) + '%'; } },
        { label: 'Defensive Rotation Latency', sub: 'Median sec to move ≥10t toward base (lower = faster)', mVal: rm.def_latency_sec && rm.def_latency_sec.med, pVal: rp.def_latency_sec && rp.def_latency_sec.med, oVal: ro.def_latency_sec && ro.def_latency_sec.med, maxVal: 35, lowerBetter: true, fmt: function (v) { return fmt(v, 1) + 's'; } },
        { label: 'Offensive Base-to-Base Switch', sub: 'Base switches (≥25t within 45s) per 10m', mVal: rm.off_rotations_per_10m && rm.off_rotations_per_10m.mean, pVal: rp.off_rotations_per_10m && rp.off_rotations_per_10m.mean, oVal: ro.off_rotations_per_10m && ro.off_rotations_per_10m.mean, maxVal: 2.2, fmt: function (v) { return fmt(v, 2) + '/10m'; } },
        { label: 'Multiprong Pressure', sub: '≥2 enemy-half pockets within 15s (per 10m)', mVal: mm.multiprong_per_10m && mm.multiprong_per_10m.mean, pVal: mp.multiprong_per_10m && mp.multiprong_per_10m.mean, oVal: mo.multiprong_per_10m && mo.multiprong_per_10m.mean, maxVal: 1.5, fmt: function (v) { return fmt(v, 2) + '/10m'; } },
        { label: 'Counter-Backstabs / Runbys', sub: 'Enemy-base kills w/ opp army ≥30t away (/10m)', mVal: mm.backstab_per_10m && mm.backstab_per_10m.mean, pVal: mp.backstab_per_10m && mp.backstab_per_10m.mean, oVal: mo.backstab_per_10m && mo.backstab_per_10m.mean, maxVal: 2.0, fmt: function (v) { return fmt(v, 2) + '/10m'; } },
      ];

      const fS = cohSegS.army_fragmentation_pct || {}, rS = cohSegS.army_retention_ratio || {};
      const scopePills = ['all', 'Protoss', 'Terran', 'Zerg'].concat(MATCHUPS);
      bodyEl.innerHTML =
        '<div class="obs-grid">' +
          '<article class="obs-card">' +
            '<div class="obs-card-head"><span class="obs-card-title">Graph 9a · Army Fragmentation %</span><span class="obs-badge">14t cluster</span></div>' +
            '<div class="obs-meds"><span><span class="obs-dot" style="background:' + T.m + '"></span>M ' + fmt(fS.mothman && fS.mothman.med, 1) + '%</span><span><span class="obs-dot" style="background:' + T.p + '"></span>Pro ' + fmt(fS.pros && fS.pros.med, 1) + '%</span><span><span class="obs-dot" style="background:' + T.o + '"></span>Opp ' + fmt(fS.opponents && fS.opponents.med, 1) + '%</span></div>' +
            renderTimeSeriesSvg(fragCfg) +
          '</article>' +
          '<article class="obs-card">' +
            '<div class="obs-card-head"><span class="obs-card-title">Graph 9b · Army Retention (Alive / Cum)</span><span class="obs-badge">Survival</span></div>' +
            '<div class="obs-meds"><span><span class="obs-dot" style="background:' + T.m + '"></span>M ' + fmt(rS.mothman && rS.mothman.med, 2) + '</span><span><span class="obs-dot" style="background:' + T.p + '"></span>Pro ' + fmt(rS.pros && rS.pros.med, 2) + '</span><span><span class="obs-dot" style="background:' + T.o + '"></span>Opp ' + fmt(rS.opponents && rS.opponents.med, 2) + '</span></div>' +
            renderTimeSeriesSvg(retCfg) +
          '</article>' +
          '<article class="obs-card obs-span-2">' +
            '<div class="obs-card-head"><div><span class="obs-card-title">Graph 10 · When Pros Engage vs. Retreat (Force Ratio Bins)</span><div class="obs-card-sub">Local army value ratio within 22 tiles at clash start · Bars show fight share, lines show disengage rate</div></div><span class="obs-badge">' + esc(seg === 'all' ? 'All Races' : seg) + '</span></div>' +
            renderEngageRetreatHistogram(erSeg) +
          '</article>' +
          '<article class="obs-card obs-span-2">' +
            '<div class="obs-card-head"><div><span class="obs-card-title">Graph 15 · Concave Geometry &amp; Front-to-Back Layering</span><div class="obs-card-sub">Schematic scaled directly to measured lateral/depth aspect ratio, frontline-to-backline offset, and 2.5t splash clumping</div></div></div>' +
            '<div class="obs-pills" style="margin-bottom:8px;">' +
              scopePills.map(function (sp) { return '<button type="button" class="obs-pill' + (state.combatScope === sp ? ' is-active' : '') + '" data-obs-cscope="' + sp + '">' + (sp === 'all' ? 'All' : sp) + '</button>'; }).join('') +
            '</div>' +
            renderConcaveSchematic(concObj.mothman, concObj.pros, scope === 'all' ? 'All Races' : scope) +
          '</article>' +
          '<article class="obs-card obs-span-2">' +
            '<div class="obs-card-head"><div><span class="obs-card-title">Graphs 16–17 · Army Rotation, Multiprong &amp; Counter-Backstabs</span><div class="obs-card-sub">Bar = Mothman · Blue vertical target = Pro GM · Purple dot = Opponents (' + esc(scope === 'all' ? 'All Races' : scope) + ')</div></div></div>' +
            renderBulletGauges(gaugeRows) +
          '</article>' +
        '</div>';

      tsList.forEach(function (cfg) { wireTimeSeriesHover(bodyEl.querySelector('[data-obs-ts="' + cfg.svgKey + '"]'), cfg); });
      bodyEl.querySelectorAll('[data-obs-cscope]').forEach(function (b) {
        b.addEventListener('click', function () { state.combatScope = b.getAttribute('data-obs-cscope'); render(); });
      });
    }

    // ---------- TAB 3: BASES, GAS & PRODUCTION (Graphs 11, 12, 19) ----------
    function renderTimingDumbbell(rows, title, maxSec) {
      if (!rows || !rows.length) return '<div class="obs-empty">No timing data.</div>';
      const W = 760, PL = 224, PR = 132, PT = 22, PB = 14, rowH = 32;
      const H = PT + rows.length * rowH + PB, CW = W - PL - PR;
      const xOf = function (s) { return PL + (Math.max(0, Math.min(maxSec, s)) / maxSec) * CW; };
      let svg = '<svg viewBox="0 0 ' + W + ' ' + H + '" class="obs-svg" role="img" aria-label="' + esc(title) + '">';
      for (let s = 0; s <= maxSec; s += 240) {
        const xx = xOf(s);
        svg += '<line x1="' + xx.toFixed(1) + '" y1="' + PT + '" x2="' + xx.toFixed(1) + '" y2="' + (H - PB) + '" stroke="' + T.grid + '" stroke-width="0.9" />';
        svg += '<text x="' + xx.toFixed(1) + '" y="13" text-anchor="middle" fill="' + T.ink2 + '" font-size="9.5" font-family="var(--mono,monospace)">' + Math.round(s / 60) + 'm</text>';
      }
      rows.forEach(function (r, i) {
        const yTop = PT + i * rowH, yMid = yTop + rowH / 2;
        if (i > 0) svg += '<line x1="0" y1="' + yTop + '" x2="' + W + '" y2="' + yTop + '" stroke="' + T.gridSub + '" stroke-width="0.8" />';
        const m = r.mothman || {}, p = r.pros || {};
        const lblRaw = humanize(r.label);
        const lblShort = lblRaw.length > 34 ? lblRaw.slice(0, 33) + '…' : lblRaw;
        svg += '<text x="6" y="' + (yMid + 3.5).toFixed(1) + '" fill="' + T.ink + '" font-size="10" font-weight="600">' + esc(lblShort) + '</text>';
        if (m.med != null && p.med != null) {
          const xm = xOf(m.med), xp = xOf(p.med);
          const col = m.med <= p.med ? T.good : T.bad;
          svg += '<line x1="' + xm.toFixed(1) + '" y1="' + yMid.toFixed(1) + '" x2="' + xp.toFixed(1) + '" y2="' + yMid.toFixed(1) + '" stroke="' + col + '" stroke-width="2.4" opacity="0.7" />';
        }
        if (p.med != null) {
          const rp = 3.2 + Math.min(4.2, ((p.adopt_pct || 0) / 100) * 4.2);
          svg += '<circle cx="' + xOf(p.med).toFixed(1) + '" cy="' + yMid.toFixed(1) + '" r="' + rp.toFixed(1) + '" fill="' + T.p + '" stroke="' + T.dotStroke + '" stroke-width="1" />';
        }
        if (m.med != null) {
          const rm = 3.2 + Math.min(4.2, ((m.adopt_pct || 0) / 100) * 4.2);
          svg += '<circle cx="' + xOf(m.med).toFixed(1) + '" cy="' + yMid.toFixed(1) + '" r="' + rm.toFixed(1) + '" fill="' + T.m + '" stroke="' + T.dotStroke + '" stroke-width="1" />';
        }
        const dStr = signedSec(m.med, p.med);
        const dCol = (m.med != null && p.med != null) ? (m.med > p.med + 20 ? T.bad : (m.med < p.med - 10 ? T.good : T.ink2)) : T.muted;
        svg += '<text x="' + (W - PR + 8) + '" y="' + (yMid - 1).toFixed(1) + '" fill="' + dCol + '" font-size="9.6" font-weight="600" font-family="var(--mono,monospace)">' + esc(dStr ? dStr + ' vs Pro' : (m.med == null ? '0% built' : mmss(m.med))) + '</text>';
        svg += '<text x="' + (W - PR + 8) + '" y="' + (yMid + 10).toFixed(1) + '" fill="' + T.muted + '" font-size="8.8" font-family="var(--mono,monospace)">Adopt ' + Math.round(m.adopt_pct || 0) + '% vs ' + Math.round(p.adopt_pct || 0) + '%</text>';
      });
      svg += '</svg>';
      return svg;
    }

    function renderProdUtilCard(puRace, raceName) {
      if (!puRace) return '';
      const fgs = puRace.facility_groups || [];
      const uM = (puRace.utilization && puRace.utilization.mothman) || {};
      const uP = (puRace.utilization && puRace.utilization.pros) || {};
      const isZerg = raceName === 'Zerg';
      const W = 760, PL = 130, PR = 20, PT = 22, PB = 16, rowH = 40;
      const H = PT + Math.max(1, fgs.length) * rowH + PB;
      const midX = PL + (W - PL - PR) * 0.46;
      const capW = (midX - PL) - 24;
      const utilX = midX + 34, utilW = W - PR - utilX;
      let svg = '<svg viewBox="0 0 ' + W + ' ' + H + '" class="obs-svg" role="img" aria-label="Production facility capacity vs utilization">';
      svg += '<text x="' + (PL + capW / 2).toFixed(1) + '" y="13" text-anchor="middle" fill="' + T.ink2 + '" font-size="10" font-weight="600">Peak Facility Count (M vs Pro)</text>';
      svg += '<text x="' + (utilX + utilW / 2).toFixed(1) + '" y="13" text-anchor="middle" fill="' + T.ink2 + '" font-size="10" font-weight="600">' + (isZerg ? 'Larva / Hatch / Min &amp; Queens / Hatch' : 'Active Utilization % (M vs Pro)') + '</text>';
      fgs.forEach(function (fg, i) {
        const yTop = PT + i * rowH, yMid = yTop + rowH / 2;
        if (i > 0) svg += '<line x1="0" y1="' + yTop + '" x2="' + W + '" y2="' + yTop + '" stroke="' + T.gridSub + '" stroke-width="0.8" />';
        const pkM = (uM.by_facility_peak_count && uM.by_facility_peak_count[fg] && uM.by_facility_peak_count[fg].med) || 0;
        const pkP = (uP.by_facility_peak_count && uP.by_facility_peak_count[fg] && uP.by_facility_peak_count[fg].med) || 0;
        const maxPk = Math.max(4, pkM, pkP) * 1.15;
        svg += '<text x="6" y="' + (yMid + 4).toFixed(1) + '" fill="' + T.ink + '" font-size="11" font-weight="600">' + esc(humanize(fg)) + '</text>';
        // Capacity paired bars
        svg += '<rect x="' + PL + '" y="' + (yMid - 11).toFixed(1) + '" width="' + Math.max(2, (pkM / maxPk) * capW).toFixed(1) + '" height="9" rx="2" fill="' + T.m + '" />';
        svg += '<text x="' + (PL + Math.max(2, (pkM / maxPk) * capW) + 5).toFixed(1) + '" y="' + (yMid - 3).toFixed(1) + '" fill="' + T.m + '" font-size="9.5" font-family="var(--mono,monospace)">' + fmt(pkM, 1) + '</text>';
        svg += '<rect x="' + PL + '" y="' + (yMid + 1).toFixed(1) + '" width="' + Math.max(2, (pkP / maxPk) * capW).toFixed(1) + '" height="9" rx="2" fill="' + T.p + '" opacity="0.82" />';
        svg += '<text x="' + (PL + Math.max(2, (pkP / maxPk) * capW) + 5).toFixed(1) + '" y="' + (yMid + 9).toFixed(1) + '" fill="' + T.p + '" font-size="9.5" font-family="var(--mono,monospace)">' + fmt(pkP, 1) + '</text>';
        // Utilization paired bars
        let vM, vP, vMax, suf;
        if (isZerg) {
          if (fg === 'Hatchery') {
            vM = (uM.larva_spent_per_hatch_min && uM.larva_spent_per_hatch_min.med) || 0;
            vP = (uP.larva_spent_per_hatch_min && uP.larva_spent_per_hatch_min.med) || 0;
            vMax = 10; suf = '/h/m';
          } else {
            vM = (uM.queens_per_hatch_10m && uM.queens_per_hatch_10m.med) || 0;
            vP = (uP.queens_per_hatch_10m && uP.queens_per_hatch_10m.med) || 0;
            vMax = 2.5; suf = '/H';
          }
        } else {
          vM = (uM.by_facility_util_pct && uM.by_facility_util_pct[fg] && uM.by_facility_util_pct[fg].med) || 0;
          vP = (uP.by_facility_util_pct && uP.by_facility_util_pct[fg] && uP.by_facility_util_pct[fg].med) || 0;
          vMax = 100; suf = '%';
        }
        const uw = utilW - 44;
        svg += '<rect x="' + utilX + '" y="' + (yMid - 11).toFixed(1) + '" width="' + Math.max(2, (Math.min(vMax, vM) / vMax) * uw).toFixed(1) + '" height="9" rx="2" fill="' + (vM >= vP * 0.92 ? T.good : T.m) + '" />';
        svg += '<text x="' + (utilX + Math.max(2, (Math.min(vMax, vM) / vMax) * uw) + 5).toFixed(1) + '" y="' + (yMid - 3).toFixed(1) + '" fill="' + T.ink + '" font-size="9.5" font-family="var(--mono,monospace)">' + fmt(vM, 1) + suf + '</text>';
        svg += '<rect x="' + utilX + '" y="' + (yMid + 1).toFixed(1) + '" width="' + Math.max(2, (Math.min(vMax, vP) / vMax) * uw).toFixed(1) + '" height="9" rx="2" fill="' + T.p + '" opacity="0.82" />';
        svg += '<text x="' + (utilX + Math.max(2, (Math.min(vMax, vP) / vMax) * uw) + 5).toFixed(1) + '" y="' + (yMid + 9).toFixed(1) + '" fill="' + T.p + '" font-size="9.5" font-family="var(--mono,monospace)">' + fmt(vP, 1) + suf + '</text>';
      });
      svg += '</svg>';
      return svg;
    }

    function renderTabBasesProd(bodyEl) {
      const seg = state.race;
      const e4 = data.expansions_4plus || {}, g7 = data.gas_7plus || {}, pu = data.production_utilization || {};
      const thSeg = (e4.active_townhalls && (e4.active_townhalls[seg] || e4.active_townhalls.all)) || {};
      const r4Seg = (e4.reach_4plus && (e4.reach_4plus[seg] || e4.reach_4plus.all)) || {};
      const btSeg = (e4.base_timings && (e4.base_timings[seg] || e4.base_timings.all)) || [];
      const gsSeg = (g7.active_gas_geysers && (g7.active_gas_geysers[seg] || g7.active_gas_geysers.all)) || {};
      const gpbSeg = (g7.gas_per_base_4plus && (g7.gas_per_base_4plus[seg] || g7.gas_per_base_4plus.all)) || {};
      const gtSeg = (g7.gas_timings && (g7.gas_timings[seg] || g7.gas_timings.all)) || [];

      const tsList = [];
      const thCfg = {
        svgKey: 'g11_th', title: 'Graph 11 · Active Townhalls Over Time (0–18m)',
        mPts: thSeg.mothman || [], pPts: thSeg.pros || [], oPts: thSeg.opponents || [],
        buckets: e4.buckets_sec || [], maxT: 1080, valKey: 'mean', minYMax: 5,
        yFmt: function (v) { return Number(v).toFixed(1); },
      };
      const gasCfg = {
        svgKey: 'g12_gas', title: 'Graph 12 · Active Gas Geysers Over Time (0–18m)',
        mPts: gsSeg.mothman || [], pPts: gsSeg.pros || [], oPts: gsSeg.opponents || [],
        buckets: g7.buckets_sec || [], maxT: 1080, valKey: 'mean', minYMax: 8,
        yFmt: function (v) { return Number(v).toFixed(1); },
      };
      tsList.push(thCfg, gasCfg);

      const pRace = (seg !== 'all') ? seg : state.prodRace;
      const puRace = pu.by_race && pu.by_race[pRace];

      bodyEl.innerHTML =
        '<div class="obs-grid">' +
          '<article class="obs-card">' +
            '<div class="obs-card-head"><span class="obs-card-title">Graph 11 · Active Townhalls (0–18m)</span><span class="obs-badge">4+ Reach (≥10m): M ' + fmt(r4Seg.mothman && r4Seg.mothman.pct_ge10m, 0) + '% vs Pro ' + fmt(r4Seg.pros && r4Seg.pros.pct_ge10m, 0) + '%</span></div>' +
            '<div class="obs-meds"><span>≥14m 4+ Bases: <strong style="color:' + T.m + '">' + fmt(r4Seg.mothman && r4Seg.mothman.pct_ge14m, 0) + '%</strong> vs Pro <strong style="color:' + T.p + '">' + fmt(r4Seg.pros && r4Seg.pros.pct_ge14m, 0) + '%</strong></span></div>' +
            renderTimeSeriesSvg(thCfg) +
          '</article>' +
          '<article class="obs-card">' +
            '<div class="obs-card-head"><span class="obs-card-title">Graph 12 · Active Gas Geysers (0–18m)</span><span class="obs-badge">Gas/Base @4+: M ' + fmt(gpbSeg.mothman && gpbSeg.mothman.med, 2) + ' vs Pro ' + fmt(gpbSeg.pros && gpbSeg.pros.med, 2) + '</span></div>' +
            '<div class="obs-meds"><span>Peak Geysers (med): <strong style="color:' + T.m + '">' + fmt(gpbSeg.mothman && gpbSeg.mothman.peak_gas && gpbSeg.mothman.peak_gas.med, 0) + '</strong> vs Pro <strong style="color:' + T.p + '">' + fmt(gpbSeg.pros && gpbSeg.pros.peak_gas && gpbSeg.pros.peak_gas.med, 0) + '</strong></span></div>' +
            renderTimeSeriesSvg(gasCfg) +
          '</article>' +
          '<article class="obs-card obs-span-2">' +
            '<div class="obs-card-head"><div><span class="obs-card-title">Base #4–#6 &amp; Gas #7–#10 Timing Dumbbell &amp; Adoption Funnel</span><div class="obs-card-sub">Dot size scales with adoption % · Green = ahead of Pro · Red = behind Pro</div></div><span class="obs-badge">' + esc(seg === 'all' ? 'All Races' : seg) + '</span></div>' +
            renderTimingDumbbell(btSeg.concat(gtSeg), 'Base 4+ and Gas 7+ timings', 1080) +
          '</article>' +
          '<article class="obs-card obs-span-2">' +
            '<div class="obs-card-head"><div><span class="obs-card-title">Graph 19 · Production Capacity vs. Utilization</span><div class="obs-card-sub">Separates under-built facilities (left) from idle buildings (right)</div></div>' +
            '<div class="obs-pills">' + ['Protoss', 'Terran', 'Zerg'].map(function (r) { return '<button type="button" class="obs-pill' + (pRace === r ? ' is-active' : '') + '" data-obs-prace="' + r + '">' + r + '</button>'; }).join('') + '</div></div>' +
            renderProdUtilCard(puRace, pRace) +
          '</article>' +
        '</div>';

      tsList.forEach(function (cfg) { wireTimeSeriesHover(bodyEl.querySelector('[data-obs-ts="' + cfg.svgKey + '"]'), cfg); });
      bodyEl.querySelectorAll('[data-obs-prace]').forEach(function (b) {
        b.addEventListener('click', function () { state.prodRace = b.getAttribute('data-obs-prace'); render(); });
      });
    }

    // ---------- TAB 4: ARMY COMP & UPGRADES (Graphs 13, 18, 14) ----------
    function renderStackedArea(seriesPts, keys, colors, title, buckets) {
      const valid = (seriesPts || []).filter(function (pt) { return (pt.n || 0) >= 1; });
      if (valid.length < 2) return '<div class="obs-empty">Insufficient samples for ' + esc(title) + '.</div>';
      const W = 370, H = 188, PL = 36, PR = 12, PT = 14, PB = 26;
      const CW = W - PL - PR, CH = H - PT - PB;
      // Pin shared 2m..18m domain so side-by-side Mothman & Pro streamgraphs align timestamp-for-timestamp
      const minT = 120, maxT = 1080;
      const xOf = function (t) { return PL + (Math.max(0, Math.min(1, (t - minT) / (maxT - minT)))) * CW; };
      const yOf = function (pct) { return PT + CH - (Math.max(0, Math.min(100, pct)) / 100) * CH; };

      // Build cumulative bands (with optional __other__ remainder to complete 100%)
      const cum = valid.map(function () { return [0]; });
      keys.forEach(function (k) {
        valid.forEach(function (pt, idx) {
          const prev = cum[idx][cum[idx].length - 1];
          const val = k === '__other__'
            ? Math.max(0, 100 - prev)
            : (pt.shares ? (Number(pt.shares[k]) || 0) : (Number(pt[k]) || 0));
          cum[idx].push(Math.min(100, prev + val));
        });
      });

      let svg = '<svg viewBox="0 0 ' + W + ' ' + H + '" class="obs-svg" role="img" aria-label="' + esc(title) + '">';
      [0, 25, 50, 75, 100].forEach(function (pv) {
        const yy = yOf(pv);
        svg += '<line x1="' + PL + '" y1="' + yy.toFixed(1) + '" x2="' + (W - PR) + '" y2="' + yy.toFixed(1) + '" stroke="' + T.grid + '" stroke-width="0.8" />';
        svg += '<text x="' + (PL - 5) + '" y="' + (yy + 3.2).toFixed(1) + '" text-anchor="end" fill="' + T.muted + '" font-size="9" font-family="var(--mono,monospace)">' + pv + '%</text>';
      });
      [120, 360, 600, 840, 1080].forEach(function (ts) {
        const xx = xOf(ts);
        svg += '<line x1="' + xx.toFixed(1) + '" y1="' + PT + '" x2="' + xx.toFixed(1) + '" y2="' + (H - PB) + '" stroke="' + T.gridSub + '" stroke-width="0.7" stroke-dasharray="2 3" />';
      });
      keys.forEach(function (k, ki) {
        const top = valid.map(function (pt, i) { return xOf(pt.t).toFixed(1) + ',' + yOf(cum[i][ki + 1]).toFixed(1); }).join(' ');
        const bot = valid.slice().reverse().map(function (pt, ri) {
          const i = valid.length - 1 - ri;
          return xOf(pt.t).toFixed(1) + ',' + yOf(cum[i][ki]).toFixed(1);
        }).join(' ');
        svg += '<polygon points="' + top + ' ' + bot + '" fill="' + colors[ki % colors.length] + '" opacity="0.85" />';
      });
      [120, 360, 600, 840, 1080].forEach(function (ts) {
        svg += '<text x="' + xOf(ts).toFixed(1) + '" y="' + (H - PB + 14) + '" text-anchor="middle" fill="' + T.ink2 + '" font-size="9" font-family="var(--mono,monospace)">' + Math.round(ts / 60) + 'm</text>';
      });
      svg += '</svg>';
      return svg;
    }

    function renderTabCompUpgrades(bodyEl) {
      const tc = data.tier_composition || {};
      const tScope = state.tierScope;
      const tcPair = MATCHUPS.indexOf(tScope) >= 0
        ? ((tc.by_matchup && tc.by_matchup[tScope]) || {})
        : ((tc.by_segment && (tc.by_segment[tScope] || tc.by_segment.all)) || {});
      const tierKeys = ['t1_pct', 't2_pct', 't3_pct'];

      // Graph 18 Per-Matchup Unit-Type Clusters
      const ucc = data.unit_comp_clusters || {};
      const mu = state.matchup;
      const muData = (ucc.by_matchup && ucc.by_matchup[mu]) || {};
      const proClusters = (muData.pro_clustering && muData.pro_clustering.clusters) || [];
      const cIdx = Math.min(state.clusterIdx, Math.max(0, proClusters.length - 1));
      const selCl = proClusters[cIdx] || null;
      const mMatch = muData.mothman_match || {};
      const uKeysRaw = (muData.unit_types || []).slice(0, 7);
      const uKeys = uKeysRaw.concat(['__other__']);
      const uCols = T.units.slice(0, 7).concat([T.units[8] || T.muted]);

      // Graph 14 Exhaustive All Upgrades
      const au = data.all_upgrades || {};
      const uScope = state.upgScope;
      const uRowsAll = MATCHUPS.indexOf(uScope) >= 0
        ? ((au.by_matchup && au.by_matchup[uScope]) || [])
        : ((au.by_race && au.by_race[uScope]) || []);
      const uBuilt = uRowsAll.filter(function (r) { return r.mothman && r.mothman.med != null; }).slice(0, 18);
      const uMissing = uRowsAll.filter(function (r) { return (!r.mothman || r.mothman.med == null) && r.pros && (r.pros.adopt_pct || 0) >= 8; });

      const simObj = mMatch.nearest_pro_cluster || {};
      bodyEl.innerHTML =
        '<div class="obs-grid">' +
          '<article class="obs-card obs-span-2">' +
            '<div class="obs-card-head"><div><span class="obs-card-title">Graph 13 · T1 / T2 / T3 Unit Value Mix (2m–18m)</span><div class="obs-card-sub">100% stacked active combat value share · <span style="color:' + T.tiers[0] + '">■ T1</span> · <span style="color:' + T.tiers[1] + '">■ T2</span> · <span style="color:' + T.tiers[2] + '">■ T3</span></div></div></div>' +
            '<div class="obs-pills" style="margin-bottom:8px;">' +
              ['all', 'Protoss', 'Terran', 'Zerg'].concat(MATCHUPS).map(function (s) {
                return '<button type="button" class="obs-pill' + (tScope === s ? ' is-active' : '') + '" data-obs-tscope="' + s + '">' + (s === 'all' ? 'All' : s) + '</button>';
              }).join('') +
            '</div>' +
            '<div class="obs-split-2">' +
              '<div><div class="obs-mini-title">Mothman (' + esc(tScope === 'all' ? 'All' : tScope) + ')</div>' + renderStackedArea(tcPair.mothman, tierKeys, T.tiers, 'Mothman Tier Mix') + '</div>' +
              '<div><div class="obs-mini-title">Pro GM (' + esc(tScope === 'all' ? 'All' : tScope) + ')</div>' + renderStackedArea(tcPair.pros, tierKeys, T.tiers, 'Pro Tier Mix') + '</div>' +
            '</div>' +
          '</article>' +

          '<article class="obs-card obs-span-2">' +
            '<div class="obs-card-head"><div><span class="obs-card-title">Graph 18 · Per-Matchup Unit Composition &amp; Pro Archetype Clusters</span><div class="obs-card-sub">Nearest Pro Cluster: <strong>' + esc(simObj.label || '--') + '</strong> (cosine similarity <strong>' + fmt(simObj.cosine_similarity, 3) + '</strong>)</div></div></div>' +
            '<div class="obs-pills" style="margin-bottom:6px;">' +
              MATCHUPS.map(function (m) { return '<button type="button" class="obs-pill' + (mu === m ? ' is-active' : '') + '" data-obs-mu="' + m + '">' + m + '</button>'; }).join('') +
            '</div>' +
            '<div class="obs-pills" style="margin-bottom:8px;">' +
              proClusters.map(function (cl, idx) {
                return '<button type="button" class="obs-pill' + (cIdx === idx ? ' is-active' : '') + '" data-obs-cl="' + idx + '">' + esc(cl.label) + ' (' + Math.round(cl.share_pct || 0) + '% · ' + Math.round(cl.win_rate_pct || 0) + '% WR)</button>';
              }).join('') +
            '</div>' +
            '<div class="obs-meds">' +
              uKeys.map(function (uk, ui) { return '<span><span class="obs-dot" style="background:' + uCols[ui % uCols.length] + '"></span>' + esc(humanize(uk)) + '</span>'; }).join('') +
            '</div>' +
            '<div class="obs-split-2">' +
              '<div><div class="obs-mini-title">Mothman · ' + esc(mu) + ' (' + (mMatch.eligible_games || 0) + 'g · ' + fmt(mMatch.win_rate_pct, 0) + '% WR)</div>' + renderStackedArea(muData.curves && muData.curves.mothman, uKeys, uCols, 'Mothman ' + mu) + '</div>' +
              '<div><div class="obs-mini-title">Pro Cluster: ' + esc(selCl ? selCl.label : '--') + ' (' + (selCl ? selCl.n : 0) + 'g)</div>' + renderStackedArea(selCl && selCl.curve_2_18m, uKeys, uCols, 'Pro ' + mu) + '</div>' +
            '</div>' +
          '</article>' +

          '<article class="obs-card obs-span-2">' +
            '<div class="obs-card-head"><div><span class="obs-card-title">Graph 14 · Exhaustive All-Upgrades Timing Race (0–18m)</span><div class="obs-card-sub">Dot size = adoption % · Green = faster than Pro · Red = later than Pro</div></div></div>' +
            '<div class="obs-pills" style="margin-bottom:8px;">' +
              ['Protoss', 'Terran', 'Zerg'].concat(MATCHUPS).map(function (s) {
                return '<button type="button" class="obs-pill' + (uScope === s ? ' is-active' : '') + '" data-obs-uscope="' + s + '">' + s + '</button>';
              }).join('') +
            '</div>' +
            renderTimingDumbbell(uBuilt, 'All upgrades timing dumbbell', 1080) +
            (uMissing.length
              ? '<div class="obs-missing-box"><span class="obs-missing-lbl">Missing / 0% Adoption Upgrades (Pro ≥8%):</span> ' +
                uMissing.map(function (r) { return '<span class="obs-missing-pill">' + esc(humanize(r.label)) + ' <span style="opacity:.75">(Pro ' + Math.round((r.pros && r.pros.adopt_pct) || 0) + '% @ ' + esc((r.pros && r.pros.med_fmt) || mmss(r.pros && r.pros.med)) + ')</span></span>'; }).join(' ') +
                '</div>'
              : '') +
          '</article>' +
        '</div>';

      bodyEl.querySelectorAll('[data-obs-tscope]').forEach(function (b) {
        b.addEventListener('click', function () { state.tierScope = b.getAttribute('data-obs-tscope'); render(); });
      });
      bodyEl.querySelectorAll('[data-obs-mu]').forEach(function (b) {
        b.addEventListener('click', function () { state.matchup = b.getAttribute('data-obs-mu'); state.clusterIdx = 0; render(); });
      });
      bodyEl.querySelectorAll('[data-obs-cl]').forEach(function (b) {
        b.addEventListener('click', function () { state.clusterIdx = parseInt(b.getAttribute('data-obs-cl'), 10) || 0; render(); });
      });
      bodyEl.querySelectorAll('[data-obs-uscope]').forEach(function (b) {
        b.addEventListener('click', function () { state.upgScope = b.getAttribute('data-obs-uscope'); render(); });
      });
    }

    // ---------- TAB 5: ABILITIES, ENERGY & SPELLS (Graphs 20, 21, 22) ----------
    function renderPairedSplitBar(title, subtitle, keys, mShares, pShares) {
      const W = 760, H = 64, PL = 84, PR = 14, CW = W - PL - PR;
      function drawBar(y, lbl, shares) {
        let g = '<text x="6" y="' + (y + 14) + '" fill="' + T.ink + '" font-size="10.5" font-weight="600">' + esc(lbl) + '</text>';
        let x = PL;
        keys.forEach(function (k, i) {
          const pct = Number((shares && shares[k]) || 0);
          const w = (pct / 100) * CW;
          if (w > 0.5) {
            g += '<rect x="' + x.toFixed(1) + '" y="' + y + '" width="' + w.toFixed(1) + '" height="20" fill="' + T.split[i % T.split.length] + '" opacity="0.88" />';
            if (w >= 42) {
              g += '<text x="' + (x + w / 2).toFixed(1) + '" y="' + (y + 13.5) + '" text-anchor="middle" fill="#FFFFFF" font-size="9.5" font-weight="600">' + Math.round(pct) + '%</text>';
            }
          }
          x += w;
        });
        return g;
      }
      return (
        '<div style="margin-bottom:10px;">' +
          '<div class="obs-mini-title">' + esc(title) + ' <span style="font-weight:400;opacity:.75">' + esc(subtitle) + '</span></div>' +
          '<div class="obs-meds">' + keys.map(function (k, i) { return '<span><span class="obs-dot" style="background:' + T.split[i % T.split.length] + '"></span>' + esc(humanize(k)) + '</span>'; }).join('') + '</div>' +
          '<svg viewBox="0 0 ' + W + ' ' + H + '" class="obs-svg" role="img" aria-label="' + esc(title) + '">' +
            drawBar(8, 'Mothman', mShares) +
            drawBar(36, 'Pro GM', pShares) +
          '</svg>' +
        '</div>'
      );
    }

    function renderSpellsDiverging(spells, raceFilter) {
      const allRows = (spells || []).filter(function (s) {
        return (raceFilter === 'all' || s.race === raceFilter) && s.pros && s.pros.casts_per_10m_caster_games && (s.pros.casts_per_10m_caster_games.mean || 0) > 0.05;
      }).map(function (s) {
        const mRate = (s.mothman && s.mothman.casts_per_10m_caster_games && s.mothman.casts_per_10m_caster_games.mean) || 0;
        const pRate = (s.pros && s.pros.casts_per_10m_caster_games && s.pros.casts_per_10m_caster_games.mean) || 0.01;
        const ratio = s.mothman_vs_pro_ratio != null ? Number(s.mothman_vs_pro_ratio) : (mRate / pRate);
        return { s: s, mRate: mRate, pRate: pRate, ratio: ratio, mGames: (s.mothman && s.mothman.caster_games) || 0 };
      });
      // Separate active-caster rows (true cast-logic comparison) from 0-caster-built tech gaps at bottom
      const activeRows = allRows.filter(function (r) { return r.mGames > 0; }).sort(function (a, b) { return a.ratio - b.ratio; });
      const unbuiltRows = allRows.filter(function (r) { return r.mGames === 0; }).sort(function (a, b) { return b.pRate - a.pRate; });
      const rows = activeRows.concat(unbuiltRows);
      if (!rows.length) return '<div class="obs-empty">No combat spell records for this filter.</div>';

      const hasDivider = activeRows.length > 0 && unbuiltRows.length > 0;
      const divGap = hasDivider ? 20 : 0;
      const W = 760, PL = 196, PR = 132, PT = 22, PB = 14, rowH = 26;
      const H = PT + rows.length * rowH + divGap + PB, CW = W - PL - PR;
      // Log2 ratio scale centered at 1.0x (range 0.0x [left edge] .. 1.0x [mid] .. 6.5x [right])
      const x1 = PL + CW * 0.52;
      const xOf = function (rat) {
        if (rat <= 0) return PL;
        if (rat <= 1.0) return PL + rat * (x1 - PL);
        return x1 + Math.min(1, Math.log2(rat) / Math.log2(6.5)) * (PL + CW - x1);
      };
      let svg = '<svg viewBox="0 0 ' + W + ' ' + H + '" class="obs-svg" role="img" aria-label="Combat spell usage vs Pro GM">';
      const activeEndY = PT + activeRows.length * rowH;
      svg += '<line x1="' + x1.toFixed(1) + '" y1="' + PT + '" x2="' + x1.toFixed(1) + '" y2="' + (hasDivider ? activeEndY : (H - PB)) + '" stroke="' + T.p + '" stroke-width="1.6" stroke-dasharray="4 3" />';
      svg += '<text x="' + x1.toFixed(1) + '" y="13" text-anchor="middle" fill="' + T.p + '" font-size="9.5" font-weight="600">1.0× Pro Parity</text>';
      svg += '<text x="' + PL + '" y="13" text-anchor="start" fill="' + T.bad + '" font-size="9">0× Cast Blind Spot</text>';
      svg += '<text x="' + (PL + CW) + '" y="13" text-anchor="end" fill="' + T.warn + '" font-size="9">Overuse (4×–6×)</text>';
      rows.forEach(function (r, i) {
        const isUnbuilt = r.mGames === 0;
        const extraY = (hasDivider && i >= activeRows.length) ? divGap : 0;
        const yTop = PT + i * rowH + extraY, yMid = yTop + rowH / 2;
        if (hasDivider && i === activeRows.length) {
          const yDiv = PT + activeRows.length * rowH + 10;
          svg += '<line x1="0" y1="' + (yDiv - 6) + '" x2="' + W + '" y2="' + (yDiv - 6) + '" stroke="' + T.grid + '" stroke-width="1" stroke-dasharray="4 3" />';
          svg += '<text x="6" y="' + (yDiv + 5) + '" fill="' + T.muted + '" font-size="9" font-weight="600" font-family="var(--mono,monospace)">CASTER UNIT NOT BUILT IN THIS BENCHMARK (0 GAMES · TECH PATH GAP, NOT CAST LOGIC)</text>';
        } else if (i > 0) {
          svg += '<line x1="0" y1="' + yTop + '" x2="' + W + '" y2="' + yTop + '" stroke="' + T.gridSub + '" stroke-width="0.7" />';
        }
        svg += '<text x="6" y="' + (yMid + 3.5).toFixed(1) + '" fill="' + (isUnbuilt ? T.muted : T.ink) + '" font-size="10">' + esc(r.s.label + ' (' + r.s.race[0] + ')') + '</text>';
        if (isUnbuilt) {
          svg += '<rect x="' + PL + '" y="' + (yMid - 4.5).toFixed(1) + '" width="' + (x1 - PL).toFixed(1) + '" height="9" rx="2" fill="none" stroke="' + T.muted + '" stroke-width="1" stroke-dasharray="3 2" opacity="0.55" />';
          svg += '<text x="' + (W - PR + 8) + '" y="' + (yMid + 3.5).toFixed(1) + '" fill="' + T.muted + '" font-size="9" font-family="var(--mono,monospace)">0 casters (Pro ' + r.pRate.toFixed(1) + '/10m)</text>';
        } else {
          const rx = xOf(r.ratio);
          const col = r.ratio < 0.35 ? T.bad : (r.ratio > 2.5 ? T.warn : (r.ratio >= 0.7 ? T.good : T.m));
          const bx = Math.min(x1, rx), bw = Math.max(3, Math.abs(rx - x1));
          svg += '<rect x="' + bx.toFixed(1) + '" y="' + (yMid - 5.5).toFixed(1) + '" width="' + bw.toFixed(1) + '" height="11" rx="2" fill="' + col + '" opacity="0.86" />';
          svg += '<circle cx="' + rx.toFixed(1) + '" cy="' + yMid.toFixed(1) + '" r="3.2" fill="' + col + '" />';
          const lbl = r.ratio.toFixed(2) + '× (' + r.mRate.toFixed(1) + '/' + r.pRate.toFixed(1) + ')';
          svg += '<text x="' + (W - PR + 8) + '" y="' + (yMid + 3.5).toFixed(1) + '" fill="' + col + '" font-size="9.2" font-weight="600" font-family="var(--mono,monospace)">' + esc(lbl) + '</text>';
        }
      });
      svg += '</svg>';
      return svg;
    }

    function renderTabAbilities(bodyEl) {
      const ma = data.macro_abilities || {}, me = data.macro_energy || {}, cs = data.combat_spells || {};
      const br = ma.by_race || {};
      const pRaceObj = br.Protoss || {}, tRaceObj = br.Terran || {}, zRaceObj = br.Zerg || {};
      const hasPhaseSit = !!(pRaceObj.chrono_target_by_phase || tRaceObj.oc_energy_by_phase || zRaceObj.queen_energy_by_phase);
      const mSlice = state.macroSlice || 'overall';
      const ocCloak = state.ocCloak || 'inherit';

      function pickSplit(baseObj, phaseObj, sitObj, sliceKey) {
        if (sliceKey === 'overall' || !sliceKey) return baseObj;
        if ((sliceKey === 'peaceful' || sliceKey === 'under_pressure') && sitObj && sitObj[sliceKey]) return sitObj[sliceKey];
        if (phaseObj && phaseObj[sliceKey]) return phaseObj[sliceKey];
        return baseObj;
      }

      const pCh = pickSplit(pRaceObj.chrono_target_split, pRaceObj.chrono_target_by_phase, pRaceObj.chrono_target_by_situation, mSlice);
      const tOcBase = pickSplit(tRaceObj.oc_energy_split, tRaceObj.oc_energy_by_phase, tRaceObj.oc_energy_by_situation, mSlice);
      const tOc = (ocCloak !== 'inherit' && tRaceObj.oc_energy_by_cloak && tRaceObj.oc_energy_by_cloak[ocCloak]) ? tRaceObj.oc_energy_by_cloak[ocCloak] : tOcBase;
      const zQn = pickSplit(zRaceObj.queen_energy_split, zRaceObj.queen_energy_by_phase, zRaceObj.queen_energy_by_situation, mSlice);
      const zTum = zRaceObj.active_tumors_checkpoints;
      const zSpr = zRaceObj.creep_tumor_spread;
      const pRechPh = pRaceObj.energy_recharge_by_phase;

      const sliceLabels = {
        overall: 'Overall', '0-4m': '0–4m', '4-8m': '4–8m', '8-12m': '8–12m', '12m+': '12m+',
        peaceful: 'Peaceful', under_pressure: 'Under Pressure',
      };
      const sliceTag = sliceLabels[mSlice] || 'Overall';
      const ocTag = ocCloak === 'cloak_seen' ? 'Cloak Seen' : (ocCloak === 'no_cloak' ? 'No Cloak' : sliceTag);

      let rechHtml = '';
      if (pRechPh) {
        const phKeys = ['0-4m', '4-8m', '8-12m', '12m+'];
        rechHtml =
          '<div class="obs-meds" style="margin:-4px 0 10px;padding:5px 8px;border-radius:6px;background:' + T.surface + ';">' +
            '<span style="font-weight:600;color:' + T.ink + '">Nexus Energy Recharge (/min):</span>' +
            phKeys.map(function (pk) {
              const ph = pRechPh[pk] || {};
              const mv = ph.mothman && ph.mothman.casts_per_min != null ? Number(ph.mothman.casts_per_min).toFixed(2) : '0.00';
              const pv = ph.pros && ph.pros.casts_per_min != null ? Number(ph.pros.casts_per_min).toFixed(2) : '0.00';
              return '<span>' + pk + ': <strong style="color:' + T.m + '">' + mv + '</strong> vs Pro <strong style="color:' + T.p + '">' + pv + '</strong></span>';
            }).join('') +
          '</div>';
      }

      const tsList = [];
      const energyCards = ['Nexus', 'OrbitalCommand', 'Queen'].map(function (ck) {
        const obj = (me.by_caster && me.by_caster[ck]) || {};
        const m = obj.mothman || {}, p = obj.pros || {}, o = obj.opponents || {};
        const cfg = {
          svgKey: 'g21_' + ck, title: 'Graph 21 · ' + (ck === 'OrbitalCommand' ? 'Orbital Command' : ck) + ' Energy (0–200e)',
          mPts: m.mean_energy_curve_18m || [], pPts: p.mean_energy_curve_18m || [], oPts: o.mean_energy_curve_18m || [],
          buckets: me.buckets_sec || [], maxT: 1080, fixedYMax: 200, fixedTicks: [0, 50, 100, 150, 180, 200],
          dangerAbove: 180, dangerLabel: '≥180e Cap Waste', valKey: 'med',
          W: ck === 'Queen' ? 760 : 420, H: ck === 'Queen' ? 185 : 200,
          yFmt: function (v) { return Math.round(v) + 'e'; },
        };
        tsList.push(cfg);
        return (
          '<article class="obs-card' + (ck === 'Queen' ? ' obs-span-2' : '') + '">' +
            '<div class="obs-card-head"><span class="obs-card-title">' + esc(ck === 'OrbitalCommand' ? 'Orbital Command' : ck) + ' Energy</span>' +
            '<span class="obs-badge">Spend Eff: M ' + fmt(m.spend_efficiency_pct && m.spend_efficiency_pct.med, 1) + '% vs Pro ' + fmt(p.spend_efficiency_pct && p.spend_efficiency_pct.med, 1) + '%</span></div>' +
            '<div class="obs-meds"><span>Mean Energy: <strong style="color:' + T.m + '">' + fmt(m.mean_energy_overall && m.mean_energy_overall.med, 1) + 'e</strong> vs Pro <strong style="color:' + T.p + '">' + fmt(p.mean_energy_overall && p.mean_energy_overall.med, 1) + 'e</strong></span><span>Capped ≥180e: <strong>' + fmt(m.time_capped_180_pct && m.time_capped_180_pct.med, 1) + '%</strong> vs Pro ' + fmt(p.time_capped_180_pct && p.time_capped_180_pct.med, 1) + '%</span></div>' +
            renderTimeSeriesSvg(cfg) +
          '</article>'
        );
      }).join('');

      // Creep tumor spread callout
      let creepHtml = '';
      if (zTum && zSpr) {
        const tm = zTum.mothman || {}, tp = zTum.pros || {};
        const spCnt = (zSpr.mothman && zSpr.mothman.sum_casts) || 0;
        const mAd = (zSpr.mothman && zSpr.mothman.adopt_pct) || 0;
        const pAd = (zSpr.pros && zSpr.pros.adopt_pct) || 0;
        const creepCol = mAd >= pAd * 0.9 ? T.good : (mAd >= pAd * 0.5 ? T.m : T.bad);
        creepHtml =
          '<div class="obs-creep-strip" style="border-left-color:' + creepCol + ';">' +
            '<div><strong>Zerg Creep Tumor Spread:</strong> Mothman <strong style="color:' + creepCol + '">' + fmt(mAd, 1) + '%</strong> (' + fmtInt(spCnt) + (spCnt === 1 ? ' spread' : ' spreads') + ') vs. Pro GM <strong style="color:' + T.p + '">' + fmt(pAd, 1) + '%</strong> (' + fmt(zSpr.pros && zSpr.pros.per_min && zSpr.pros.per_min.mean, 2) + '/min)</div>' +
            '<div class="obs-meds" style="margin-top:4px;"><span>Active Tumors @6m: <strong>' + fmt(tm['6m'] && tm['6m'].med, 0) + '</strong> vs Pro ' + fmt(tp['6m'] && tp['6m'].med, 0) + '</span><span>@10m: <strong>' + fmt(tm['10m'] && tm['10m'].med, 0) + '</strong> vs Pro ' + fmt(tp['10m'] && tp['10m'].med, 0) + '</span><span>@14m: <strong>' + fmt(tm['14m'] && tm['14m'].med, 0) + '</strong> vs Pro ' + fmt(tp['14m'] && tp['14m'].med, 0) + '</span></div>' +
          '</div>';
      }

      const phasePillsHtml = hasPhaseSit
        ? '<div class="obs-toolbar" style="margin:2px 0 8px;">' +
            '<div class="obs-pills" role="group" aria-label="Filter macro abilities by game phase or situation">' +
              ['overall', '0-4m', '4-8m', '8-12m', '12m+', 'peaceful', 'under_pressure'].map(function (sk) {
                return '<button type="button" class="obs-pill' + (mSlice === sk ? ' is-active' : '') + '" data-obs-mslice="' + sk + '">' + esc(sliceLabels[sk]) + '</button>';
              }).join('') +
            '</div>' +
            (tRaceObj.oc_energy_by_cloak
              ? '<div class="obs-pills" role="group" aria-label="Terran OC cloak filter">' +
                  [
                    { k: 'inherit', l: 'OC: Match Phase' },
                    { k: 'no_cloak', l: 'OC: No Cloak' },
                    { k: 'cloak_seen', l: 'OC: Cloak Seen' },
                  ].map(function (o) {
                    return '<button type="button" class="obs-pill' + (ocCloak === o.k ? ' is-active' : '') + '" data-obs-occloak="' + o.k + '">' + esc(o.l) + '</button>';
                  }).join('') +
                '</div>'
              : '') +
          '</div>'
        : '';

      const spRace = state.race !== 'all' ? state.race : state.spellRace;
      bodyEl.innerHTML =
        '<div class="obs-grid">' +
          '<article class="obs-card obs-span-2">' +
            '<div class="obs-card-head"><div><span class="obs-card-title">Graph 20 · Macro Ability Targets &amp; Energy Allocation</span><div class="obs-card-sub">Paired 100% splits by game phase and combat pressure comparing Mothman vs. Grandmaster Pros</div></div><span class="obs-badge">' + esc(sliceTag) + '</span></div>' +
            phasePillsHtml +
            (pCh ? renderPairedSplitBar('Protoss Chrono Boost Targets · ' + sliceTag, '(Nexus vs. Tech Upgrades vs. Gateway vs. Robotics vs. Stargate)', ['Nexus', 'TechUpgrades', 'Gateway', 'Robo', 'Stargate'], pCh.mothman && pCh.mothman.shares_pct, pCh.pros && pCh.pros.shares_pct) : '') +
            rechHtml +
            (tOc ? renderPairedSplitBar('Terran Orbital Command Split · ' + ocTag, '(MULE vs. Scanner Sweep vs. Extra Supplies)', ['MULE', 'Scan', 'SupplyDrop'], tOc.mothman && tOc.mothman.shares_pct, tOc.pros && tOc.pros.shares_pct) : '') +
            (zQn ? renderPairedSplitBar('Zerg Queen Energy Split · ' + sliceTag, '(Inject Larva vs. Creep Tumor vs. Transfuse)', ['Inject', 'CreepTumor', 'Transfuse'], zQn.mothman && zQn.mothman.shares_pct, zQn.pros && zQn.pros.shares_pct) : '') +
            creepHtml +
          '</article>' +
          energyCards +
          '<article class="obs-card obs-span-2">' +
            '<div class="obs-card-head"><div><span class="obs-card-title">Graph 22 · Combat Spell &amp; Active Ability Usage vs. Pros</span><div class="obs-card-sub">Casts per 10m of games where the caster was built · sorted from 0× blind spots (top) to overuse (bottom)</div></div>' +
            '<div class="obs-pills">' + ['all', 'Protoss', 'Terran', 'Zerg'].map(function (r) { return '<button type="button" class="obs-pill' + (spRace === r ? ' is-active' : '') + '" data-obs-sprace="' + r + '">' + (r === 'all' ? 'All' : r) + '</button>'; }).join('') + '</div></div>' +
            renderSpellsDiverging(cs.all_flat, spRace) +
          '</article>' +
        '</div>';

      tsList.forEach(function (cfg) { wireTimeSeriesHover(bodyEl.querySelector('[data-obs-ts="' + cfg.svgKey + '"]'), cfg); });
      bodyEl.querySelectorAll('[data-obs-mslice]').forEach(function (b) {
        b.addEventListener('click', function () { state.macroSlice = b.getAttribute('data-obs-mslice'); render(); });
      });
      bodyEl.querySelectorAll('[data-obs-occloak]').forEach(function (b) {
        b.addEventListener('click', function () { state.ocCloak = b.getAttribute('data-obs-occloak'); render(); });
      });
      bodyEl.querySelectorAll('[data-obs-sprace]').forEach(function (b) {
        b.addEventListener('click', function () { state.spellRace = b.getAttribute('data-obs-sprace'); render(); });
      });
    }

    // ---------- Master Shell & Tab Dispatcher ----------
    const TABS = [
      { id: 'mine_trade', label: '1. Mine × Trade' },
      { id: 'combat', label: '2. Combat & Positioning' },
      { id: 'bases_prod', label: '3. Bases, Gas & Prod' },
      { id: 'comp_upg', label: '4. Army Comp & Upgrades' },
      { id: 'abilities', label: '5. Abilities & Energy' },
    ];

    function render() {
      const co = data.cohorts || {};
      const seg = state.race;
      const mN = seg === 'all' ? (co.mothman && co.mothman.games || 0) : ((co.mothman && co.mothman.by_race && co.mothman.by_race[seg]) || 0);
      const pN = seg === 'all' ? (co.pros && co.pros.games || 0) : ((co.pros && co.pros.by_race && co.pros.by_race[seg]) || 0);
      const oN = seg === 'all' ? (co.opponents && co.opponents.games || 0) : ((co.opponents && co.opponents.by_race && co.opponents.by_race[seg]) || 0);

      container.innerHTML =
        '<div class="obs-shell obs-theme-' + themeName + '">' +
          '<div class="obs-tabs" role="tablist" aria-label="Observatory views">' +
            TABS.map(function (tb) {
              return '<button type="button" role="tab" class="obs-tab' + (state.tab === tb.id ? ' is-active' : '') + '" data-obs-tab="' + tb.id + '" aria-selected="' + (state.tab === tb.id ? 'true' : 'false') + '">' + esc(tb.label) + '</button>';
            }).join('') +
          '</div>' +
          '<div class="obs-toolbar">' +
            '<div class="obs-pills" role="group" aria-label="Filter by race">' +
              ['all', 'Protoss', 'Terran', 'Zerg'].map(function (r) {
                return '<button type="button" class="obs-pill' + (state.race === r ? ' is-active' : '') + '" data-obs-race="' + r + '">' + (r === 'all' ? 'All Races' : r) + '</button>';
              }).join('') +
            '</div>' +
            (state.tab === 'mine_trade'
              ? '<div class="obs-pills" role="group" aria-label="APM/EPM Y-axis scale">' +
                  '<button type="button" class="obs-pill' + (state.scale === 'log' ? ' is-active' : '') + '" data-obs-scale="log">Log (All 3)</button>' +
                  '<button type="button" class="obs-pill' + (state.scale === 'linear' ? ' is-active' : '') + '" data-obs-scale="linear">Linear (vs. Pro)</button>' +
                '</div>'
              : '') +
          '</div>' +
          '<div class="obs-legend">' +
            '<span><span class="obs-line" style="background:' + T.m + '"></span>Mothman (' + mN + 'g)</span>' +
            '<span><span class="obs-line obs-dash" style="border-color:' + T.p + '"></span>Pro GM (' + pN + 'g)</span>' +
            '<span><span class="obs-line" style="background:' + T.o + '"></span>Opponents (' + oN + 'g)</span>' +
            '<span class="obs-leg-note">22 Pro-comparison graphs · Hover curves &amp; dots for exact values</span>' +
          '</div>' +
          '<div class="obs-body"></div>' +
        '</div>';

      const bodyEl = container.querySelector('.obs-body');
      if (state.tab === 'mine_trade') renderTabMineTrade(bodyEl);
      else if (state.tab === 'combat') renderTabCombat(bodyEl);
      else if (state.tab === 'bases_prod') renderTabBasesProd(bodyEl);
      else if (state.tab === 'comp_upg') renderTabCompUpgrades(bodyEl);
      else if (state.tab === 'abilities') renderTabAbilities(bodyEl);

      container.querySelectorAll('[data-obs-tab]').forEach(function (b) {
        b.addEventListener('click', function () { state.tab = b.getAttribute('data-obs-tab'); render(); });
      });
      container.querySelectorAll('[data-obs-race]').forEach(function (b) {
        b.addEventListener('click', function () {
          state.race = b.getAttribute('data-obs-race');
          if (['Protoss', 'Terran', 'Zerg'].indexOf(state.race) >= 0) {
            state.timingRace = state.race;
            state.prodRace = state.race;
            state.upgScope = state.race;
            state.combatScope = state.race;
            state.tierScope = state.race;
            state.spellRace = state.race;
            state.matchup = RACE_MATCHUPS[state.race][0];
            state.clusterIdx = 0;
          } else {
            state.combatScope = 'all';
            state.tierScope = 'all';
            state.spellRace = 'all';
          }
          render();
        });
      });
      container.querySelectorAll('[data-obs-scale]').forEach(function (b) {
        b.addEventListener('click', function () { state.scale = b.getAttribute('data-obs-scale'); render(); });
      });
    }

    render();
    return { setTab: function (t) { state.tab = t; render(); } };
  }

  global.MothmanObservatory = { mount: mount };
})(typeof window !== 'undefined' ? window : globalThis);
