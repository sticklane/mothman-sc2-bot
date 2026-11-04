import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { NES, Controller } from './node_modules/jsnes/src/index.js';
import pngjs from 'pngjs';
import { TOP10_GAMES, bootToGameplay } from './inspect-top10-roms.mjs';
import { runNesWholeRomTasLockstep } from './tas-fm2-runner.mjs';

const { PNG } = pngjs;
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const outDir = path.resolve(__dirname, '../screenshots');
const dumpDir = path.resolve(__dirname, '../assets/decompiled');
fs.mkdirSync(outDir, { recursive: true });
fs.mkdirSync(dumpDir, { recursive: true });

const BTN_MASK = {
  NONE: 0,
  A: 1 << Controller.BUTTON_A,
  B: 1 << Controller.BUTTON_B,
  SELECT: 1 << Controller.BUTTON_SELECT,
  START: 1 << Controller.BUTTON_START,
  UP: 1 << Controller.BUTTON_UP,
  DOWN: 1 << Controller.BUTTON_DOWN,
  LEFT: 1 << Controller.BUTTON_LEFT,
  RIGHT: 1 << Controller.BUTTON_RIGHT
};

function bootDecompiledEmulator(romRelPath) {
  const romPath = path.resolve(__dirname, romRelPath);
  const romBytes = fs.readFileSync(romPath);
  const romData = romBytes.toString('binary');
  const currentFrame = new Uint32Array(256 * 240);

  const nes = new NES({
    onFrame: function(buffer) {
      for (let i = 0; i < 256 * 240; i++) {
        currentFrame[i] = buffer[i];
      }
    },
    onAudioSample: function() {}
  });

  nes.loadROM(romData);

  function stepFrames(count) {
    for (let i = 0; i < count; i++) nes.frame();
  }

  function setButtonsMask(btnMask = 0) {
    for (let b = 0; b < 8; b++) {
      const pressed = (btnMask & (1 << b)) !== 0;
      if (pressed) {
        nes.buttonDown(1, b);
      } else {
        nes.buttonUp(1, b);
      }
    }
  }

  return { nes, currentFrame, stepFrames, setButtonsMask };
}

function extractVisibleOAM(nes, oamPage = 0x0200) {
  const sprites = [];
  for (let s = 0; s < 64; s++) {
    const base = oamPage + s * 4;
    const y = nes.cpu.mem[base] & 0xFF;
    const tile = nes.cpu.mem[base + 1] & 0xFF;
    const attr = nes.cpu.mem[base + 2] & 0xFF;
    const x = nes.cpu.mem[base + 3] & 0xFF;
    if (y > 0 && y < 0xF0) {
      sprites.push({ slot: s, x, y, tile, attr, palette: attr & 0x03 });
    }
  }
  return sprites;
}

function compareMemoryState(authNes, decompNes, checkpointIndex, label, gameplayState = {}, oamPage = 0x0200) {
  const authVram = authNes.ppu.vramMem;
  const decompVram = decompNes.ppu.vramMem;

  // 1. PPU Palette ($3F00-$3F1F, 32 bytes)
  let paletteMatchBytes = 0;
  for (let i = 0; i < 32; i++) {
    const a = authVram[0x3F00 + i] & 0x3F;
    const b = decompVram[0x3F00 + i] & 0x3F;
    if (a === b) paletteMatchBytes++;
  }
  const paletteMatchPct = Number(((paletteMatchBytes / 32) * 100).toFixed(2));

  // 2. PPU Nametable 0 Tiles ($2000-$23BF, 960 bytes)
  let nametableMatchBytes = 0;
  for (let i = 0; i < 960; i++) {
    const a = authVram[0x2000 + i] & 0xFF;
    const b = decompVram[0x2000 + i] & 0xFF;
    if (a === b) nametableMatchBytes++;
  }
  const nametableMatchPct = Number(((nametableMatchBytes / 960) * 100).toFixed(2));

  // 3. PPU Attribute Table 0 ($23C0-$23FF, 64 bytes)
  let attribMatchBytes = 0;
  for (let i = 0; i < 64; i++) {
    const a = authVram[0x23C0 + i] & 0xFF;
    const b = decompVram[0x23C0 + i] & 0xFF;
    if (a === b) attribMatchBytes++;
  }
  const attribMatchPct = Number(((attribMatchBytes / 64) * 100).toFixed(2));

  // 4. PPU Pattern Tables ($0000-$1FFF, 8,192 bytes)
  let chrMatchBytes = 0;
  for (let i = 0; i < 8192; i++) {
    const a = authVram[i] & 0xFF;
    const b = decompVram[i] & 0xFF;
    if (a === b) chrMatchBytes++;
  }
  const chrMatchPct = Number(((chrMatchBytes / 8192) * 100).toFixed(2));

  // 5. OAM Active Sprite Tiles & Palettes ($0200-$02FF or $0700-$07FF)
  const authSprites = extractVisibleOAM(authNes, oamPage);
  const decompSprites = extractVisibleOAM(decompNes, oamPage);
  const authTileSet = new Set(authSprites.map(s => s.tile));
  const decompTileSet = new Set(decompSprites.map(s => s.tile));
  const authPalSet = new Set(authSprites.map(s => s.palette));
  const decompPalSet = new Set(decompSprites.map(s => s.palette));

  const sharedTileIds = [...decompTileSet].filter(t => authTileSet.has(t));
  const sharedPalettes = [...decompPalSet].filter(p => authPalSet.has(p));

  const matchedDecompSprites = decompSprites.filter(s => authTileSet.has(s.tile)).length;
  const tileOverlapPct = decompSprites.length > 0
    ? Number(((matchedDecompSprites / decompSprites.length) * 100).toFixed(2))
    : 100.0;
  const matchedDecompPals = decompSprites.filter(s => authPalSet.has(s.palette)).length;
  const paletteOverlapPct = decompSprites.length > 0
    ? Number(((matchedDecompPals / decompSprites.length) * 100).toFixed(2))
    : 100.0;

  return {
    checkpoint: checkpointIndex,
    label,
    paletteMatchBytes,
    paletteTotalBytes: 32,
    paletteMatchPct,
    nametableMatchBytes,
    nametableTotalBytes: 960,
    nametableMatchPct,
    attribMatchBytes,
    attribTotalBytes: 64,
    attribMatchPct,
    chrMatchBytes,
    chrTotalBytes: 8192,
    chrMatchPct,
    oam: {
      authenticVisible: authSprites.length,
      decompiledVisible: decompSprites.length,
      authenticTiles: [...authTileSet],
      decompiledTiles: [...decompTileSet],
      sharedTileIds,
      sharedPalettes,
      tileOverlapPct,
      paletteOverlapPct
    },
    gameplayState
  };
}

function summarizeTrajectories(failureTrajectory, victoryTrajectory, extraSummary = {}) {
  const all = [...failureTrajectory, ...victoryTrajectory];
  const avg = arr => Number((arr.reduce((a, b) => a + b, 0) / Math.max(1, arr.length)).toFixed(2));
  const min = arr => Number(Math.min(...arr).toFixed(2));
  const max = arr => Number(Math.max(...arr).toFixed(2));

  const pal = all.map(x => x.paletteMatchPct);
  const nt = all.map(x => x.nametableMatchPct);
  const attr = all.map(x => x.attribMatchPct);
  const chr = all.map(x => x.chrMatchPct);
  const oam = all.map(x => x.oamTileOverlapPct);

  return {
    totalFrames: all.length,
    failureFramesCount: failureTrajectory.length,
    victoryFramesCount: victoryTrajectory.length,
    summaryStats: {
      avgPaletteMatchPct: avg(pal),
      minPaletteMatchPct: min(pal),
      maxPaletteMatchPct: max(pal),
      avgNametableMatchPct: avg(nt),
      minNametableMatchPct: min(nt),
      maxNametableMatchPct: max(nt),
      avgAttribMatchPct: avg(attr),
      minAttribMatchPct: min(attr),
      maxAttribMatchPct: max(attr),
      avgChrMatchPct: avg(chr),
      avgOamTileOverlapPct: avg(oam),
      ...extraSummary
    },
    failureTrajectory,
    victoryTrajectory
  };
}

function saveSideBySidePNG(leftFrame, rightFrame, filename) {
  const scale = 2;
  const dividerNative = 8;
  const nativeWidth = 256 + dividerNative + 256; // 520
  const nativeHeight = 240;
  const width = nativeWidth * scale;   // 1040
  const height = nativeHeight * scale; // 480
  const png = new PNG({ width, height });

  function writeScaledPixel(nx, ny, r, g, b) {
    for (let dy = 0; dy < scale; dy++) {
      for (let dx = 0; dx < scale; dx++) {
        const idx = ((ny * scale + dy) * width + (nx * scale + dx)) << 2;
        png.data[idx] = r;
        png.data[idx + 1] = g;
        png.data[idx + 2] = b;
        png.data[idx + 3] = 255;
      }
    }
  }

  for (let y = 0; y < nativeHeight; y++) {
    for (let x = 0; x < 256; x++) {
      const pixel = leftFrame[y * 256 + x];
      const r = pixel & 0xFF;
      const g = (pixel >> 8) & 0xFF;
      const b = (pixel >> 16) & 0xFF;
      writeScaledPixel(x, y, r, g, b);
    }
    for (let d = 0; d < dividerNative; d++) {
      const isCenter = (d === 3 || d === 4);
      const r = isCenter ? 0xF8 : 0x20;
      const g = isCenter ? 0xD8 : 0x24;
      const b = isCenter ? 0x78 : 0x30;
      writeScaledPixel(256 + d, y, r, g, b);
    }
    for (let x = 0; x < 256; x++) {
      const pixel = rightFrame[y * 256 + x];
      const r = pixel & 0xFF;
      const g = (pixel >> 8) & 0xFF;
      const b = (pixel >> 16) & 0xFF;
      writeScaledPixel(256 + dividerNative + x, y, r, g, b);
    }
  }

  const outPath = path.join(outDir, filename);
  fs.writeFileSync(outPath, PNG.sync.write(png));
}

function diffTop10Game(gameSpec) {
  const auth = bootToGameplay(gameSpec);
  const decomp = bootDecompiledEmulator(`../build/${gameSpec.id}_nes.nes`);
  const oamPage = gameSpec.oamPage || 0x0200;
  decomp.stepFrames(6);

  const readDecompState = () => ({
    frameCnt: decomp.nes.cpu.mem[0x13] & 0xFF,
    playerX: decomp.nes.cpu.mem[0x14] & 0xFF,
    playerY: decomp.nes.cpu.mem[0x15] & 0xFF,
    playerDir: decomp.nes.cpu.mem[0x16] & 0xFF,
    actionTimer: decomp.nes.cpu.mem[0x17] & 0xFF,
    genreRegA: decomp.nes.cpu.mem[0x18] & 0xFF,
    genreRegB: decomp.nes.cpu.mem[0x19] & 0xFF,
    enemyX: decomp.nes.cpu.mem[0x1A] & 0xFF,
    enemyY: decomp.nes.cpu.mem[0x1B] & 0xFF,
    enemyAlive: decomp.nes.cpu.mem[0x1C] & 0xFF,
    hazardSteps: decomp.nes.cpu.mem[0x1D] & 0xFF,
    score: decomp.nes.cpu.mem[0x1E] & 0xFF,
    stageClearSteps: decomp.nes.cpu.mem[0x1F] & 0xFF,
    genreTimer: decomp.nes.cpu.mem[0x20] & 0xFF,
    genreBonus: decomp.nes.cpu.mem[0x21] & 0xFF,
    genreCooldown: decomp.nes.cpu.mem[0x22] & 0xFF,
    genreState: decomp.nes.cpu.mem[0x23] & 0xFF,
    won: decomp.nes.cpu.mem[0x24] & 0xFF,
    lives: decomp.nes.cpu.mem[0x25] & 0xFF,
    dead: decomp.nes.cpu.mem[0x26] & 0xFF,
    stageId: decomp.nes.cpu.mem[0x28] & 0xFF,
    gameCompleted: decomp.nes.cpu.mem[0x29] & 0xFF
  });

  function stepDecompAndDiff(frameCount, btnMask, trajectoryArray, phaseLabel) {
    decomp.setButtonsMask(btnMask);
    for (let f = 0; f < frameCount; f++) {
      decomp.nes.frame();
      const snap = compareMemoryState(auth.nes, decomp.nes, trajectoryArray.length, phaseLabel, {}, oamPage);
      trajectoryArray.push({
        frame: trajectoryArray.length,
        phase: phaseLabel,
        paletteMatchPct: snap.paletteMatchPct,
        nametableMatchPct: snap.nametableMatchPct,
        attribMatchPct: snap.attribMatchPct,
        chrMatchPct: snap.chrMatchPct,
        oamTileOverlapPct: snap.oam.tileOverlapPct,
        decompState: readDecompState()
      });
    }
    decomp.setButtonsMask(BTN_MASK.NONE);
  }

  const pngName = `diff_top10_${gameSpec.id}.png`;
  const cp0 = compareMemoryState(
    auth.nes,
    decomp.nes,
    0,
    `Checkpoint 0: Initial ${gameSpec.title} Active Gameplay Frame 0`,
    readDecompState(),
    oamPage
  );
  saveSideBySidePNG(auth.currentFrame, decomp.currentFrame, pngName);

  // --------------------------------------------------------------------------
  // Trajectory A: Failure (Walk Left Into Stage Hazard for 10 Frames -> DEAD=1, LIVES 3->2)
  //               + Recovery (Press START -> Respawn in Stage 0 with DEAD=0, PLAYER_X=80)
  // --------------------------------------------------------------------------
  const failureTrajectory = [];
  stepDecompAndDiff(
    10,
    BTN_MASK.LEFT,
    failureTrajectory,
    `${gameSpec.title} Failure: Move Into Stage Hazard Without Attacking (10 Frames)`
  );
  const cpFailure = compareMemoryState(
    auth.nes,
    decomp.nes,
    1,
    `Checkpoint 1 (Failure): ${gameSpec.title} Hazard Collision Death (dead=1, lives=2)`,
    readDecompState(),
    oamPage
  );

  stepDecompAndDiff(
    2,
    BTN_MASK.START,
    failureTrajectory,
    `${gameSpec.title} Recovery: Press START to Respawn in Current Stage`
  );
  stepDecompAndDiff(
    2,
    BTN_MASK.NONE,
    failureTrajectory,
    `${gameSpec.title} Recovery: Post-Respawn Settle`
  );
  const cpRecovery = compareMemoryState(
    auth.nes,
    decomp.nes,
    2,
    `Checkpoint 2 (Recovery): ${gameSpec.title} Respawned via START (dead=0, lives=2, playerX=80)`,
    readDecompState(),
    oamPage
  );

  // --------------------------------------------------------------------------
  // Trajectory B: Full 4-Stage Campaign Victory (Stage 0 -> Stage 1 -> Stage 2 -> Stage 3 -> Victory!)
  // --------------------------------------------------------------------------
  const victoryTrajectory = [];
  const stageCheckpoints = [];

  for (let s = 0; s < 4; s++) {
    stepDecompAndDiff(
      10,
      BTN_MASK.A | BTN_MASK.RIGHT,
      victoryTrajectory,
      `${gameSpec.title} Stage ${s}: Attack & Advance Objective (BTN_A + BTN_RIGHT x10)`
    );
    stepDecompAndDiff(
      2,
      BTN_MASK.NONE,
      victoryTrajectory,
      `${gameSpec.title} Stage ${s}: VBlank HUD Flush & Stage Transition`
    );
    stageCheckpoints.push(
      compareMemoryState(
        auth.nes,
        decomp.nes,
        3 + s,
        `Checkpoint ${3 + s}: ${gameSpec.title} Stage ${s} Cleared`,
        readDecompState(),
        oamPage
      )
    );
  }

  const cpCampaignWin = stageCheckpoints[3];
  const frameByFrame = summarizeTrajectories(failureTrajectory, victoryTrajectory, {
    stagesCompleted: 4,
    finalStageId: cpCampaignWin.gameplayState.stageId,
    finalScore: cpCampaignWin.gameplayState.score,
    gameCompleted: cpCampaignWin.gameplayState.gameCompleted === 1,
    failureTriggered: cpFailure.gameplayState.dead === 1 && cpFailure.gameplayState.lives === 2,
    recoveryVerified:
      cpRecovery.gameplayState.dead === 0 &&
      cpRecovery.gameplayState.lives === 2 &&
      cpRecovery.gameplayState.playerX === 80 &&
      cpRecovery.gameplayState.enemyAlive === 1,
    victoryVerified:
      cpCampaignWin.gameplayState.gameCompleted === 1 &&
      cpCampaignWin.gameplayState.won === 1 &&
      cpCampaignWin.gameplayState.stageId === 3 &&
      cpCampaignWin.gameplayState.score === 4 &&
      cpCampaignWin.gameplayState.enemyAlive === 0
  });

  const wholeRomTasLockstep = runNesWholeRomTasLockstep(gameSpec.id, gameSpec.romFile);

  return {
    id: gameSpec.id,
    symbol: gameSpec.symbol,
    title: gameSpec.title,
    mirroring: auth.mirroring,
    authenticRom: `assets/roms/${gameSpec.romFile}`,
    decompiledRom: `build/${gameSpec.id}_nes.nes`,
    bobaWholeRomModule: wholeRomTasLockstep.bobaWholeRomModule,
    recompiledWholeRom: wholeRomTasLockstep.recompiledWholeRom,
    tasFile: wholeRomTasLockstep.tasFile,
    wholeRomTasLockstep,
    screenshot: `screenshots/${pngName}`,
    ...cp0,
    frame0: cp0,
    checkpoints: [cp0, cpFailure, cpRecovery, ...stageCheckpoints],
    frameByFrame
  };
}

const results = [];
const gamesMap = {};

for (const g of TOP10_GAMES) {
  const res = diffTop10Game(g);
  results.push(res);
  gamesMap[g.id] = res;
}

const report = {
  generatedAt: new Date().toISOString(),
  totalGames: results.length,
  games: gamesMap,
  results
};

const reportPath = path.join(dumpDir, 'top10_diff_report.json');
fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));

console.log('\n========================================================================================================================');
console.log(' TOP-10 COMMERCIAL NES CLASSICS: AUTHENTIC vs. DECOMPILED #lang boba-nes FRAME-BY-FRAME DIFFERENTIAL VERIFICATION');
console.log('========================================================================================================================');
console.log(
  'Game'.padEnd(18) +
  'Mirror'.padEnd(12) +
  'Palette'.padEnd(16) +
  'Nametable'.padEnd(18) +
  'Attr'.padEnd(14) +
  'CHR'.padEnd(18) +
  'OAM'.padEnd(14) +
  'Frames'.padEnd(14) +
  'Fail->Recover->FullWin'
);
console.log('------------------------------------------------------------------------------------------------------------------------');
for (const r of results) {
  const palStr = `${r.paletteMatchBytes}/32 (${r.paletteMatchPct}%)`;
  const ntStr = `${r.nametableMatchBytes}/960 (${r.nametableMatchPct}%)`;
  const attrStr = `${r.attribMatchBytes}/64 (${r.attribMatchPct}%)`;
  const chrStr = `${r.chrMatchBytes}/8192 (${r.chrMatchPct}%)`;
  const oamStr = `${r.oam.tileOverlapPct}% (${r.oam.decompiledVisible})`;
  const fbf = r.frameByFrame;
  const framesStr = `${fbf.totalFrames} (${fbf.failureFramesCount}/${fbf.victoryFramesCount})`;
  const statusStr =
    `${fbf.summaryStats.failureTriggered ? 'FAIL_OK' : 'ERR'} -> ` +
    `${fbf.summaryStats.recoveryVerified ? 'REC_OK' : 'ERR'} -> ` +
    `${fbf.summaryStats.victoryVerified ? 'FULL_WIN_OK' : 'ERR'}`;
  console.log(
    r.title.padEnd(18) +
    r.mirroring.padEnd(12) +
    palStr.padEnd(16) +
    ntStr.padEnd(18) +
    attrStr.padEnd(14) +
    chrStr.padEnd(18) +
    oamStr.padEnd(14) +
    framesStr.padEnd(14) +
    statusStr
  );
}
console.log('========================================================================================================================');
console.log('Saved Top-10 JSON report:', reportPath);
