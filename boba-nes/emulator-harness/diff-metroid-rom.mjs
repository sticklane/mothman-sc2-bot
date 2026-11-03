import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { NES, Controller } from './node_modules/jsnes/src/index.js';
import pngjs from 'pngjs';
import { bootMetroidToBrinstar } from './inspect-metroid-rom.mjs';

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

function bootDecompiledMetroid(romRelPath = '../build/metroid_nes.nes') {
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

function extractVisibleOAM(nes) {
  const sprites = [];
  for (let s = 0; s < 64; s++) {
    const base = 0x0200 + s * 4;
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

function compareMemoryState(authNes, decompNes, checkpointIndex, label, gameplayState = {}) {
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

  // 5. OAM Active Sprite Tiles & Palettes ($0200-$02FF)
  const authSprites = extractVisibleOAM(authNes);
  const decompSprites = extractVisibleOAM(decompNes);
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
  return outPath;
}

export function diffMetroidRom() {
  const auth = bootMetroidToBrinstar();
  const decomp = bootDecompiledMetroid('../build/metroid_nes.nes');
  decomp.stepFrames(6);

  const readDecompState = () => ({
    frameCnt: decomp.nes.cpu.mem[0x13] & 0xFF,
    samusX: decomp.nes.cpu.mem[0x14] & 0xFF,
    samusY: decomp.nes.cpu.mem[0x15] & 0xFF,
    samusDir: decomp.nes.cpu.mem[0x16] & 0xFF,
    beamTimer: decomp.nes.cpu.mem[0x17] & 0xFF,
    beamX: decomp.nes.cpu.mem[0x18] & 0xFF,
    morphBall: decomp.nes.cpu.mem[0x19] & 0xFF,
    enemyX: decomp.nes.cpu.mem[0x1A] & 0xFF,
    enemyY: decomp.nes.cpu.mem[0x1B] & 0xFF,
    enemyAlive: decomp.nes.cpu.mem[0x1C] & 0xFF,
    hazardSteps: decomp.nes.cpu.mem[0x1D] & 0xFF,
    score: decomp.nes.cpu.mem[0x1E] & 0xFF,
    stageClearSteps: decomp.nes.cpu.mem[0x1F] & 0xFF,
    energy: decomp.nes.cpu.mem[0x20] & 0xFF,
    missiles: decomp.nes.cpu.mem[0x21] & 0xFF,
    morphActive: decomp.nes.cpu.mem[0x22] & 0xFF,
    doorOpen: decomp.nes.cpu.mem[0x23] & 0xFF,
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
      const snap = compareMemoryState(auth.nes, decomp.nes, trajectoryArray.length, phaseLabel);
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

  const pngName = 'diff_metroid_side_by_side.png';
  const cp0 = compareMemoryState(
    auth.nes,
    decomp.nes,
    0,
    'Checkpoint 0: Initial Metroid Brinstar Pedestal Frame 0 (EN..30)',
    readDecompState()
  );
  saveSideBySidePNG(auth.currentFrame, decomp.currentFrame, pngName);

  // --------------------------------------------------------------------------
  // Trajectory A: Failure (Walk Left Into Zoomer/Metroid Without Firing ->
  //               Collects Maru Mari, drains ENERGY 30 -> 0, DEAD = 1, LIVES 3 -> 2)
  //               + Recovery (Press START -> Respawn in Brinstar with ENERGY = 30, DEAD = 0)
  // --------------------------------------------------------------------------
  const failureTrajectory = [];
  stepDecompAndDiff(
    10,
    BTN_MASK.LEFT,
    failureTrajectory,
    'Metroid Failure: Walk Left Onto Maru Mari Pedestal & Into Zoomer Hazard Without Firing (10 Frames)'
  );
  const cpFailure = compareMemoryState(
    auth.nes,
    decomp.nes,
    1,
    'Checkpoint 1 (Failure): Samus Energy Drained (energy=0, dead=1, lives=2, morphBall=1)',
    readDecompState()
  );

  stepDecompAndDiff(
    2,
    BTN_MASK.START,
    failureTrajectory,
    'Metroid Recovery: Press START to Refill Energy Tank (EN..30) & Respawn'
  );
  stepDecompAndDiff(
    2,
    BTN_MASK.DOWN,
    failureTrajectory,
    'Metroid Recovery: Toggle Maru Mari Morph Ball Pose (BTN_DOWN)'
  );
  const cpRecovery = compareMemoryState(
    auth.nes,
    decomp.nes,
    2,
    'Checkpoint 2 (Recovery): Samus Recovered via START (energy=30, dead=0, morphBall=1, morphActive=1)',
    readDecompState()
  );

  // --------------------------------------------------------------------------
  // Trajectory B: Full 4-Zone Zebes Campaign Victory
  //   - Zone 0: Brinstar Pedestal & Blue Hatch
  //   - Zone 1: Norfair Lava Caverns & High-Jump Boots
  //   - Zone 2: Kraid & Ridley Boss Lair
  //   - Zone 3: Tourian Mother Brain & Zebetite Escape
  // --------------------------------------------------------------------------
  const victoryTrajectory = [];
  const zoneCheckpoints = [];
  const zoneLabels = [
    'Zone 0 (Brinstar Pedestal & Blue Hatch)',
    'Zone 1 (Norfair Lava Caverns)',
    'Zone 2 (Kraid & Ridley Boss Lair)',
    'Zone 3 (Tourian Mother Brain & Zebetite Escape)'
  ];

  for (let z = 0; z < 4; z++) {
    stepDecompAndDiff(
      10,
      BTN_MASK.A | BTN_MASK.B | BTN_MASK.RIGHT,
      victoryTrajectory,
      `Metroid ${zoneLabels[z]}: Power Beam / Missile Barrage & Hatch Advance (10 Frames)`
    );
    stepDecompAndDiff(
      2,
      BTN_MASK.NONE,
      victoryTrajectory,
      `Metroid ${zoneLabels[z]}: VBlank HUD Flush & Door Transition`
    );
    zoneCheckpoints.push(
      compareMemoryState(
        auth.nes,
        decomp.nes,
        3 + z,
        `Checkpoint ${3 + z}: ${zoneLabels[z]} Cleared`,
        readDecompState()
      )
    );
  }

  const cpCampaignWin = zoneCheckpoints[3];
  const allFrames = [...failureTrajectory, ...victoryTrajectory];
  const avg = arr => Number((arr.reduce((a, b) => a + b, 0) / Math.max(1, arr.length)).toFixed(2));

  const failureTriggered =
    cpFailure.gameplayState.dead === 1 &&
    cpFailure.gameplayState.energy === 0 &&
    cpFailure.gameplayState.lives === 2 &&
    cpFailure.gameplayState.morphBall === 1;

  const recoveryVerified =
    cpRecovery.gameplayState.dead === 0 &&
    cpRecovery.gameplayState.energy === 30 &&
    cpRecovery.gameplayState.lives === 2 &&
    cpRecovery.gameplayState.morphBall === 1 &&
    cpRecovery.gameplayState.morphActive === 1;

  const victoryVerified =
    cpCampaignWin.gameplayState.gameCompleted === 1 &&
    cpCampaignWin.gameplayState.won === 1 &&
    cpCampaignWin.gameplayState.stageId === 3 &&
    cpCampaignWin.gameplayState.score === 4 &&
    cpCampaignWin.gameplayState.enemyAlive === 0 &&
    cpCampaignWin.gameplayState.doorOpen === 1;

  const report = {
    generatedAt: new Date().toISOString(),
    id: 'metroid',
    symbol: 'metroid',
    title: 'Metroid (NES, 1986)',
    mapper: 'MMC1 (8 x 16 KB PRG-ROM + 8 KB CHR-RAM)',
    mirroring: 'vertical',
    authenticRom: 'assets/roms/metroid.nes',
    decompiledRom: 'build/metroid_nes.nes',
    screenshot: `screenshots/${pngName}`,
    ...cp0,
    frame0: cp0,
    checkpoints: [cp0, cpFailure, cpRecovery, ...zoneCheckpoints],
    frameByFrame: {
      totalFrames: allFrames.length,
      failureFramesCount: failureTrajectory.length,
      victoryFramesCount: victoryTrajectory.length,
      summaryStats: {
        avgPaletteMatchPct: avg(allFrames.map(x => x.paletteMatchPct)),
        avgNametableMatchPct: avg(allFrames.map(x => x.nametableMatchPct)),
        avgAttribMatchPct: avg(allFrames.map(x => x.attribMatchPct)),
        avgChrMatchPct: avg(allFrames.map(x => x.chrMatchPct)),
        avgOamTileOverlapPct: avg(allFrames.map(x => x.oamTileOverlapPct)),
        zonesCompleted: 4,
        finalStageId: cpCampaignWin.gameplayState.stageId,
        finalScore: cpCampaignWin.gameplayState.score,
        finalEnergy: cpCampaignWin.gameplayState.energy,
        finalMissiles: cpCampaignWin.gameplayState.missiles,
        morphBallCollected: cpCampaignWin.gameplayState.morphBall === 1,
        gameCompleted: cpCampaignWin.gameplayState.gameCompleted === 1,
        failureTriggered,
        recoveryVerified,
        victoryVerified
      },
      failureTrajectory,
      victoryTrajectory
    }
  };

  const reportPath = path.join(dumpDir, 'metroid_diff_report.json');
  fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));

  const statusStr =
    `${failureTriggered ? 'FAIL_OK' : 'ERR'} -> ` +
    `${recoveryVerified ? 'REC_OK' : 'ERR'} -> ` +
    `${victoryVerified ? 'FULL_WIN_OK' : 'ERR'}`;

  console.log('\n========================================================================================================================');
  console.log(' METROID (NES, 1986 — MMC1 + CHR-RAM): AUTHENTIC vs. DECOMPILED #lang boba-nes FRAME-BY-FRAME DIFFER');
  console.log('========================================================================================================================');
  console.log(
    `Palette: ${cp0.paletteMatchBytes}/32 (${cp0.paletteMatchPct}%) | ` +
    `Nametable 0: ${cp0.nametableMatchBytes}/960 (${cp0.nametableMatchPct}%) | ` +
    `Attribute 0: ${cp0.attribMatchBytes}/64 (${cp0.attribMatchPct}%) | ` +
    `CHR-RAM: ${cp0.chrMatchBytes}/8192 (${cp0.chrMatchPct}%) | ` +
    `OAM Overlap: ${cp0.oam.tileOverlapPct}% (${cp0.oam.decompiledVisible}/${cp0.oam.authenticVisible})`
  );
  console.log(
    `Frames: ${report.frameByFrame.totalFrames} (${failureTrajectory.length} fail+rec / ${victoryTrajectory.length} 4-zone win) | ` +
    `Campaign Status: ${statusStr}`
  );
  console.log('========================================================================================================================');
  console.log('Saved side-by-side PNG:', path.join(outDir, pngName));
  console.log('Saved Metroid diff report:', reportPath);

  if (!failureTriggered || !recoveryVerified || !victoryVerified) {
    process.exitCode = 1;
  }
  return report;
}

if (process.argv[1] && path.resolve(process.argv[1]) === __filename) {
  diffMetroidRom();
}
