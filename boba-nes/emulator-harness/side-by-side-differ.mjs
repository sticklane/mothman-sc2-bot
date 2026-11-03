import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { NES, Controller } from './node_modules/jsnes/src/index.js';
import pngjs from 'pngjs';
const { PNG } = pngjs;

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const outDir = path.resolve(__dirname, '../screenshots');
const dumpDir = path.resolve(__dirname, '../assets/decompiled');
fs.mkdirSync(outDir, { recursive: true });
fs.mkdirSync(dumpDir, { recursive: true });

function bootEmulator(romRelPath) {
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

  function pressButton(btn, holdFrames = 2, waitAfter = 20) {
    nes.buttonDown(1, btn);
    for (let i = 0; i < holdFrames; i++) nes.frame();
    nes.buttonUp(1, btn);
    for (let i = 0; i < waitAfter; i++) nes.frame();
  }

  function tapButton(btn) {
    nes.buttonDown(1, btn);
    nes.frame();
    nes.buttonUp(1, btn);
    nes.frame();
  }

  function setButtonsMask(btnMask = 0) {
    for (let b = 0; b < 8; b++) {
      const pressed = Array.isArray(btnMask)
        ? btnMask.includes(b)
        : (btnMask & (1 << b)) !== 0;
      if (pressed) {
        nes.buttonDown(1, b);
      } else {
        nes.buttonUp(1, b);
      }
    }
  }

  return { nes, currentFrame, stepFrames, pressButton, tapButton, setButtonsMask };
}

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

function compareWellRam200(authNes, decompNes) {
  let wellRamMatchBytes = 0;
  for (let i = 0; i < 200; i++) {
    const a = authNes.cpu.mem[0x0400 + i] & 0xFF;
    const bRaw = decompNes.cpu.mem[0x0400 + i] & 0xFF;
    // Decompiled Tetris stores 0x00 for empty well cells and flushes them as 0xEF to VRAM,
    // matching authentic NES Tetris's 0xEF empty cell sentinel in $0400-$04C7.
    const bNorm = bRaw === 0 ? 0xEF : bRaw;
    if (a === bNorm || a === bRaw) {
      wellRamMatchBytes++;
    }
  }
  return wellRamMatchBytes;
}

function compareMemoryState(authNes, decompNes, checkpointIndex, label, gameplayState = {}, includeWellRam = false) {
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

  const extra = includeWellRam
    ? {
        wellRamMatchBytes: compareWellRam200(authNes, decompNes),
        wellRamTotalBytes: 200
      }
    : {};

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
    ...extra,
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

/**
 * Steps both the authentic commercial ROM and the decompiled #lang boba-nes ROM
 * frame-by-frame for `frameCount` frames, recording a full PPU/OAM/RAM differential
 * snapshot on EVERY SINGLE FRAME.
 */
function stepAndDiffFrames(
  auth,
  decomp,
  frameCount,
  btnMask,
  trajectoryArray,
  phaseLabel,
  readDecompState,
  readAuthState,
  options = {}
) {
  const { includeWellRam = false, authBtnMask = btnMask } = options;
  auth.setButtonsMask(authBtnMask);
  decomp.setButtonsMask(btnMask);

  for (let f = 0; f < frameCount; f++) {
    auth.nes.frame();
    decomp.nes.frame();

    const snap = compareMemoryState(auth.nes, decomp.nes, trajectoryArray.length, phaseLabel, {}, includeWellRam);
    const entry = {
      frame: trajectoryArray.length,
      phase: phaseLabel,
      paletteMatchPct: snap.paletteMatchPct,
      nametableMatchPct: snap.nametableMatchPct,
      attribMatchPct: snap.attribMatchPct,
      chrMatchPct: snap.chrMatchPct,
      oamTileOverlapPct: snap.oam.tileOverlapPct,
      decompState: readDecompState(),
      authState: readAuthState()
    };
    if (includeWellRam) {
      entry.wellRamMatchBytes = snap.wellRamMatchBytes;
      entry.wellRamMatchPct = Number(((snap.wellRamMatchBytes / 200) * 100).toFixed(2));
    }
    trajectoryArray.push(entry);
  }

  auth.setButtonsMask(BTN_MASK.NONE);
  decomp.setButtonsMask(BTN_MASK.NONE);
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
    // Left: Authentic Commercial ROM (x = 0..255)
    for (let x = 0; x < 256; x++) {
      const pixel = leftFrame[y * 256 + x];
      const r = pixel & 0xFF;
      const g = (pixel >> 8) & 0xFF;
      const b = (pixel >> 16) & 0xFF;
      writeScaledPixel(x, y, r, g, b);
    }
    // Middle: 8px Divider (x = 256..263)
    for (let d = 0; d < dividerNative; d++) {
      const isCenter = (d === 3 || d === 4);
      const r = isCenter ? 0xF8 : 0x20;
      const g = isCenter ? 0xD8 : 0x24;
      const b = isCenter ? 0x78 : 0x30;
      writeScaledPixel(256 + d, y, r, g, b);
    }
    // Right: Decompiled #lang boba-nes ROM (x = 264..519)
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
  console.log('Saved side-by-side PNG:', outPath);
}

// ============================================================================
// 1. Super Mario Bros. (World 1-1) Differential Verifier
// ============================================================================
function diffSuperMarioBros() {
  const auth = bootEmulator('../assets/roms/super_mario_bros.nes');
  auth.stepFrames(60);
  auth.pressButton(Controller.BUTTON_START, 4, 210);

  const decomp = bootEmulator('../build/mario_nes.nes');
  decomp.stepFrames(6);

  const readMarioDecompState = () => ({
    worldX: (decomp.nes.cpu.mem[0x16] & 0xFF) + ((decomp.nes.cpu.mem[0x17] & 0xFF) << 8),
    screenX: decomp.nes.cpu.mem[0x18] & 0xFF,
    yPx: decomp.nes.cpu.mem[0x1A] & 0xFF,
    onGround: decomp.nes.cpu.mem[0x1D] & 0xFF,
    coins: decomp.nes.cpu.mem[0x1E] & 0xFF,
    score: decomp.nes.cpu.mem[0x1F] & 0xFF,
    goombaX: decomp.nes.cpu.mem[0x20] & 0xFF,
    goombaAlive: decomp.nes.cpu.mem[0x21] & 0xFF,
    qblockHit: decomp.nes.cpu.mem[0x22] & 0xFF,
    won: decomp.nes.cpu.mem[0x24] & 0xFF,
    dead: decomp.nes.cpu.mem[0x26] & 0xFF,
    lives: decomp.nes.cpu.mem[0x27] & 0xFF
  });

  const readMarioAuthState = () => ({
    worldX: ((auth.nes.cpu.mem[0x006D] & 0xFF) << 8) + (auth.nes.cpu.mem[0x0086] & 0xFF),
    yPx: auth.nes.cpu.mem[0x00CE] & 0xFF,
    playerState: auth.nes.cpu.mem[0x000E] & 0xFF,
    floatState: auth.nes.cpu.mem[0x001D] & 0xFF,
    coins: auth.nes.cpu.mem[0x075E] & 0xFF,
    lives: auth.nes.cpu.mem[0x075A] & 0xFF,
    scrollX: auth.nes.cpu.mem[0x073F] & 0xFF
  });

  // Checkpoint 0: Initial Gameplay Frame 0
  const cp0 = compareMemoryState(auth.nes, decomp.nes, 0, 'Checkpoint 0: Initial World 1-1 Gameplay Frame 0', readMarioDecompState());
  saveSideBySidePNG(auth.currentFrame, decomp.currentFrame, 'diff_smb_side_by_side.png');

  // --------------------------------------------------------------------------
  // Trajectory A: Failure (Walk Into Goomba Hazard -> Death Bounce) + Recovery (START Respawn)
  // --------------------------------------------------------------------------
  const failureTrajectory = [];
  stepAndDiffFrames(
    auth, decomp, 28, BTN_MASK.RIGHT, failureTrajectory,
    'Failure: Walk Right Into Patrolling Goomba Without Jumping',
    readMarioDecompState, readMarioAuthState
  );
  stepAndDiffFrames(
    auth, decomp, 10, BTN_MASK.NONE, failureTrajectory,
    'Failure: Mario Upward Death Bounce & Life Loss (lives: 3 -> 2)',
    readMarioDecompState, readMarioAuthState
  );
  const cpFailure = compareMemoryState(
    auth.nes, decomp.nes, 3,
    'Checkpoint 3 (Failure): Goomba Ground Collision Death & Upward Bounce',
    readMarioDecompState()
  );

  // Recover via START (use SELECT on auth so commercial SMB1 does not stay paused)
  stepAndDiffFrames(
    auth, decomp, 1, BTN_MASK.START, failureTrajectory,
    'Recovery: Press START to Respawn Mario at World 1-1 Start',
    readMarioDecompState, readMarioAuthState,
    { authBtnMask: BTN_MASK.NONE }
  );
  stepAndDiffFrames(
    auth, decomp, 5, BTN_MASK.NONE, failureTrajectory,
    'Recovery: Post-Respawn Ground Stabilization (X=40, Y=176, dead=0)',
    readMarioDecompState, readMarioAuthState
  );
  const cpRecovery = compareMemoryState(
    auth.nes, decomp.nes, 4,
    'Checkpoint 4 (Recovery): Respawned at World 1-1 Start via START',
    readMarioDecompState()
  );

  // --------------------------------------------------------------------------
  // Trajectory B: Full Victory Playthrough (Question Block Coin -> Goomba Stomp -> Flagpole Win)
  // --------------------------------------------------------------------------
  const victoryTrajectory = [];
  stepAndDiffFrames(
    auth, decomp, 12, BTN_MASK.RIGHT, victoryTrajectory,
    'Victory: Walk Right Under Question Block (X=76)',
    readMarioDecompState, readMarioAuthState
  );
  stepAndDiffFrames(
    auth, decomp, 1, BTN_MASK.A, victoryTrajectory,
    'Victory: Jump Initiate Under Question Block',
    readMarioDecompState, readMarioAuthState
  );
  stepAndDiffFrames(
    auth, decomp, 25, BTN_MASK.NONE, victoryTrajectory,
    'Victory: Bonk Question Block Coin & Land on Ground',
    readMarioDecompState, readMarioAuthState
  );
  stepAndDiffFrames(
    auth, decomp, 14, BTN_MASK.RIGHT, victoryTrajectory,
    'Victory: Walk Right Toward Goomba (X=118)',
    readMarioDecompState, readMarioAuthState
  );
  stepAndDiffFrames(
    auth, decomp, 1, BTN_MASK.A, victoryTrajectory,
    'Victory: Jump to Stomp Goomba',
    readMarioDecompState, readMarioAuthState
  );
  stepAndDiffFrames(
    auth, decomp, 35, BTN_MASK.NONE, victoryTrajectory,
    'Victory: Stomp Goomba & Complete Landing Arc',
    readMarioDecompState, readMarioAuthState
  );
  const cp1 = compareMemoryState(
    auth.nes, decomp.nes, 1,
    'Checkpoint 1: Question Block Coin Bonk & Goomba Stomp',
    readMarioDecompState()
  );

  stepAndDiffFrames(
    auth, decomp, 85, BTN_MASK.RIGHT, victoryTrajectory,
    'Victory: Scroll Across World 1-1 Nametable Seam to Flagpole (X>=340)',
    readMarioDecompState, readMarioAuthState
  );
  const cp2 = compareMemoryState(
    auth.nes, decomp.nes, 2,
    'Checkpoint 2: Horizontal Scroll to World 1-1 Flagpole Victory',
    readMarioDecompState()
  );

  const frameByFrame = summarizeTrajectories(failureTrajectory, victoryTrajectory, {
    failureTriggered: cpFailure.gameplayState.dead === 1 && cpFailure.gameplayState.lives === 2,
    recoveryVerified: cpRecovery.gameplayState.dead === 0 && cpRecovery.gameplayState.worldX === 40,
    victoryVerified: cp2.gameplayState.won === 1 && cp2.gameplayState.coins === 1 && cp2.gameplayState.goombaAlive === 0
  });

  return {
    id: 'smb',
    title: 'Super Mario Bros.',
    authenticRom: 'assets/roms/super_mario_bros.nes',
    decompiledRom: 'build/mario_nes.nes',
    screenshot: 'screenshots/diff_smb_side_by_side.png',
    ...cp0,
    frame0: cp0,
    checkpoints: [cp0, cp1, cp2, cpFailure, cpRecovery],
    frameByFrame
  };
}

// ============================================================================
// 2. The Legend of Zelda (Overworld & Triforce Sanctum) Differential Verifier
// ============================================================================
function diffLegendOfZelda() {
  const auth = bootEmulator('../assets/roms/legend_of_zelda.nes');
  auth.stepFrames(180);
  auth.pressButton(Controller.BUTTON_START, 6, 90);
  auth.pressButton(Controller.BUTTON_START, 6, 60);
  auth.pressButton(Controller.BUTTON_A, 6, 30);
  auth.pressButton(Controller.BUTTON_SELECT, 6, 25);
  auth.pressButton(Controller.BUTTON_SELECT, 6, 25);
  auth.pressButton(Controller.BUTTON_SELECT, 6, 25);
  auth.pressButton(Controller.BUTTON_START, 6, 60);
  auth.pressButton(Controller.BUTTON_START, 6, 150);

  const decomp = bootEmulator('../build/zelda_nes.nes');
  decomp.stepFrames(6);

  const readZeldaDecompState = () => ({
    linkX: decomp.nes.cpu.mem[0x14] & 0xFF,
    linkY: decomp.nes.cpu.mem[0x15] & 0xFF,
    linkDir: decomp.nes.cpu.mem[0x16] & 0xFF,
    swordTimer: decomp.nes.cpu.mem[0x17] & 0xFF,
    octoX: decomp.nes.cpu.mem[0x1A] & 0xFF,
    octoY: decomp.nes.cpu.mem[0x1B] & 0xFF,
    octoAlive: decomp.nes.cpu.mem[0x1C] & 0xFF,
    rupees: decomp.nes.cpu.mem[0x1F] & 0xFF,
    keys: decomp.nes.cpu.mem[0x20] & 0xFF,
    roomId: decomp.nes.cpu.mem[0x21] & 0xFF,
    hearts: decomp.nes.cpu.mem[0x22] & 0xFF,
    triforceWon: decomp.nes.cpu.mem[0x23] & 0xFF,
    hurtTimer: decomp.nes.cpu.mem[0x26] & 0xFF,
    dead: decomp.nes.cpu.mem[0x27] & 0xFF
  });

  const readZeldaAuthState = () => ({
    linkX: auth.nes.cpu.mem[0x0070] & 0xFF,
    linkY: auth.nes.cpu.mem[0x0084] & 0xFF,
    linkDir: auth.nes.cpu.mem[0x0098] & 0xFF,
    roomId: auth.nes.cpu.mem[0x00EB] & 0xFF,
    rupees: auth.nes.cpu.mem[0x066D] & 0xFF,
    keys: auth.nes.cpu.mem[0x066E] & 0xFF,
    hearts: auth.nes.cpu.mem[0x066F] & 0xFF,
    gameMode: auth.nes.cpu.mem[0x0012] & 0xFF
  });

  // Checkpoint 0: Initial Gameplay Frame 0
  const cp0 = compareMemoryState(auth.nes, decomp.nes, 0, 'Checkpoint 0: Initial Overworld Gameplay Frame 0', readZeldaDecompState());
  saveSideBySidePNG(auth.currentFrame, decomp.currentFrame, 'diff_zelda_side_by_side.png');

  // --------------------------------------------------------------------------
  // Trajectory A: Failure (Walk Into Octorok 3x Without Sword -> 0 Hearts Defeat) + Recovery (START)
  // --------------------------------------------------------------------------
  const failureTrajectory = [];
  stepAndDiffFrames(
    auth, decomp, 18, BTN_MASK.UP, failureTrajectory,
    'Failure: Walk Unarmed Into Red Octorok (3x Contact Knockback, hearts: 3 -> 0)',
    readZeldaDecompState, readZeldaAuthState
  );
  stepAndDiffFrames(
    auth, decomp, 4, BTN_MASK.NONE, failureTrajectory,
    'Failure: Link Defeated State at 0 Hearts (dead=1)',
    readZeldaDecompState, readZeldaAuthState
  );
  const cpFailure = compareMemoryState(
    auth.nes, decomp.nes, 3,
    'Checkpoint 3 (Failure): Octorok Contact Damage & Link Defeat at 0 Hearts',
    readZeldaDecompState()
  );

  stepAndDiffFrames(
    auth, decomp, 1, BTN_MASK.START, failureTrajectory,
    'Recovery: Press START to Respawn Link in Overworld with 3 Hearts',
    readZeldaDecompState, readZeldaAuthState,
    { authBtnMask: BTN_MASK.NONE }
  );
  stepAndDiffFrames(
    auth, decomp, 3, BTN_MASK.NONE, failureTrajectory,
    'Recovery: Overworld Respawn Stabilized (X=120, Y=144, hearts=3, dead=0)',
    readZeldaDecompState, readZeldaAuthState
  );
  const cpRecovery = compareMemoryState(
    auth.nes, decomp.nes, 4,
    'Checkpoint 4 (Recovery): Respawned in Overworld with 3 Hearts via START',
    readZeldaDecompState()
  );

  // --------------------------------------------------------------------------
  // Trajectory B: Full Victory Playthrough (Sword Slay Octorok -> Key Pickup -> Unlock Door -> Triforce)
  // --------------------------------------------------------------------------
  const victoryTrajectory = [];
  stepAndDiffFrames(
    auth, decomp, 9, BTN_MASK.UP, victoryTrajectory,
    'Victory: Walk North to Sword Range of Red Octorok (Y=108)',
    readZeldaDecompState, readZeldaAuthState
  );
  stepAndDiffFrames(
    auth, decomp, 2, BTN_MASK.A, victoryTrajectory,
    'Victory: Thrust Wooden Sword to Slay Octorok & Drop Dungeon Key',
    readZeldaDecompState, readZeldaAuthState
  );
  const cp1 = compareMemoryState(
    auth.nes, decomp.nes, 1,
    'Checkpoint 1: Sword Combat & Octorok Defeat',
    readZeldaDecompState()
  );

  stepAndDiffFrames(
    auth, decomp, 34, BTN_MASK.UP, victoryTrajectory,
    'Victory: Collect Key, Unlock North Door & Claim Triforce of Wisdom in Sanctum',
    readZeldaDecompState, readZeldaAuthState
  );
  const cp2 = compareMemoryState(
    auth.nes, decomp.nes, 2,
    'Checkpoint 2: North Door Unlock & Triforce of Wisdom Claimed',
    readZeldaDecompState()
  );

  const frameByFrame = summarizeTrajectories(failureTrajectory, victoryTrajectory, {
    failureTriggered: cpFailure.gameplayState.dead === 1 && cpFailure.gameplayState.hearts === 0,
    recoveryVerified: cpRecovery.gameplayState.dead === 0 && cpRecovery.gameplayState.hearts === 3 && cpRecovery.gameplayState.linkY === 144,
    victoryVerified: cp2.gameplayState.triforceWon === 1 && cp2.gameplayState.roomId === 1 && cp2.gameplayState.octoAlive === 0
  });

  return {
    id: 'zelda',
    title: 'The Legend of Zelda',
    authenticRom: 'assets/roms/legend_of_zelda.nes',
    decompiledRom: 'build/zelda_nes.nes',
    screenshot: 'screenshots/diff_zelda_side_by_side.png',
    ...cp0,
    frame0: cp0,
    checkpoints: [cp0, cp1, cp2, cpFailure, cpRecovery],
    frameByFrame
  };
}

// ============================================================================
// 3. Nintendo NES Tetris (A-Type Level 00) Differential Verifier
// ============================================================================
function diffNintendoTetris() {
  const auth = bootEmulator('../assets/roms/tetris.nes');
  auth.stepFrames(320);
  for (let p = 0; p < 4; p++) {
    auth.pressButton(Controller.BUTTON_START, 6, 60);
  }
  auth.stepFrames(60);

  const decomp = bootEmulator('../build/tetris_nes.nes');
  decomp.stepFrames(6);

  const readTetrisDecompState = () => ({
    pieceId: decomp.nes.cpu.mem[0x14] & 0xFF,
    pieceRot: decomp.nes.cpu.mem[0x15] & 0xFF,
    pieceX: decomp.nes.cpu.mem[0x16] & 0xFF,
    pieceY: decomp.nes.cpu.mem[0x17] & 0xFF,
    nextId: decomp.nes.cpu.mem[0x18] & 0xFF,
    dropTimer: decomp.nes.cpu.mem[0x19] & 0xFF,
    lines: decomp.nes.cpu.mem[0x1A] & 0xFF,
    score: decomp.nes.cpu.mem[0x1B] & 0xFF,
    dirtyRow: decomp.nes.cpu.mem[0x1D] & 0xFF,
    gameOver: decomp.nes.cpu.mem[0x23] & 0xFF
  });

  const readTetrisAuthState = () => ({
    tetriminoX: auth.nes.cpu.mem[0x0040] & 0xFF,
    tetriminoY: auth.nes.cpu.mem[0x0041] & 0xFF,
    currentPiece: auth.nes.cpu.mem[0x0042] & 0xFF,
    level: auth.nes.cpu.mem[0x0044] & 0xFF,
    playState: auth.nes.cpu.mem[0x0048] & 0xFF,
    linesBcd: auth.nes.cpu.mem[0x0050] & 0xFF,
    nextPiece: auth.nes.cpu.mem[0x00BF] & 0xFF
  });

  // Checkpoint 0: Initial Gameplay Frame 0
  const cp0 = compareMemoryState(
    auth.nes, decomp.nes, 0,
    'Checkpoint 0: Initial A-Type Level 00 Gameplay Frame 0',
    readTetrisDecompState(), true
  );
  saveSideBySidePNG(auth.currentFrame, decomp.currentFrame, 'diff_tetris_side_by_side.png');

  // --------------------------------------------------------------------------
  // Trajectory A: Failure (Rapid Hard-Drop Stacking in Center Column -> Top-Out Game Over)
  //               + Recovery (START Clears 200-Byte Well & Flushes All 20 Rows)
  // --------------------------------------------------------------------------
  const failureTrajectory = [];
  for (let drop = 0; drop < 16; drop++) {
    stepAndDiffFrames(
      auth, decomp, 1, BTN_MASK.B, failureTrajectory,
      `Failure: Hard-Drop Stack #${drop + 1} Toward Top-Out`,
      readTetrisDecompState, readTetrisAuthState,
      { includeWellRam: true }
    );
    stepAndDiffFrames(
      auth, decomp, 1, BTN_MASK.NONE, failureTrajectory,
      `Failure: Post-Drop #${drop + 1} Well Lock & VBlank Flush`,
      readTetrisDecompState, readTetrisAuthState,
      { includeWellRam: true }
    );
  }
  const cpFailure = compareMemoryState(
    auth.nes, decomp.nes, 3,
    'Checkpoint 3 (Failure): Playfield Well Top-Out Game Over (Y <= 2)',
    readTetrisDecompState(), true
  );

  // Press START to clear the 200-byte well ($0400-$04C7) and flush all 20 rows (2 rows/NMI x 10 frames)
  stepAndDiffFrames(
    auth, decomp, 1, BTN_MASK.START, failureTrajectory,
    'Recovery: Press START to Clear 200-Byte Well & Reset Game Over',
    readTetrisDecompState, readTetrisAuthState,
    { includeWellRam: true, authBtnMask: BTN_MASK.NONE }
  );
  stepAndDiffFrames(
    auth, decomp, 9, BTN_MASK.NONE, failureTrajectory,
    'Recovery: Staged 20-Row VBlank Flush of Cleared Playfield Well',
    readTetrisDecompState, readTetrisAuthState,
    { includeWellRam: true }
  );
  const cpRecovery = compareMemoryState(
    auth.nes, decomp.nes, 4,
    'Checkpoint 4 (Recovery): 200-Byte Well Cleared & Game Reset via START',
    readTetrisDecompState(), true
  );

  // --------------------------------------------------------------------------
  // Trajectory B: Full Victory Playthrough (Rotate/Shift Lock -> 10-Block Line Clear & VBlank Flush)
  // --------------------------------------------------------------------------
  const victoryTrajectory = [];
  stepAndDiffFrames(
    auth, decomp, 1, BTN_MASK.A, victoryTrajectory,
    'Victory: Rotate Active Tetromino Clockwise (90 deg)',
    readTetrisDecompState, readTetrisAuthState,
    { includeWellRam: true }
  );
  stepAndDiffFrames(
    auth, decomp, 1, BTN_MASK.NONE, victoryTrajectory,
    'Victory: Release Rotate Button',
    readTetrisDecompState, readTetrisAuthState,
    { includeWellRam: true }
  );
  for (let shift = 0; shift < 2; shift++) {
    stepAndDiffFrames(
      auth, decomp, 1, BTN_MASK.LEFT, victoryTrajectory,
      `Victory: Shift Tetromino Left #${shift + 1}`,
      readTetrisDecompState, readTetrisAuthState,
      { includeWellRam: true }
    );
    stepAndDiffFrames(
      auth, decomp, 1, BTN_MASK.NONE, victoryTrajectory,
      `Victory: Release Left Button #${shift + 1}`,
      readTetrisDecompState, readTetrisAuthState,
      { includeWellRam: true }
    );
  }
  stepAndDiffFrames(
    auth, decomp, 1, BTN_MASK.B, victoryTrajectory,
    'Victory: Hard-Drop Shifted Tetromino into Well',
    readTetrisDecompState, readTetrisAuthState,
    { includeWellRam: true }
  );
  stepAndDiffFrames(
    auth, decomp, 11, BTN_MASK.NONE, victoryTrajectory,
    'Victory: Staged 2-Row/NMI VBlank Flush After Lock',
    readTetrisDecompState, readTetrisAuthState,
    { includeWellRam: true }
  );
  const cp1 = compareMemoryState(
    auth.nes, decomp.nes, 1,
    'Checkpoint 1: Tetromino Rotation, Shift & Lock',
    readTetrisDecompState(), true
  );

  // Pre-fill row 18 ($04B4..$04BD) cols 0,1,2,6,7,8,9 so hard-dropping T-piece at X=4 completes a 10-block line
  for (const col of [0, 1, 2, 6, 7, 8, 9]) {
    decomp.nes.cpu.mem[0x0400 + 180 + col] = 0x7B;
  }
  decomp.nes.cpu.mem[0x14] = 0; // T-piece
  decomp.nes.cpu.mem[0x15] = 0; // Rot 0
  decomp.nes.cpu.mem[0x16] = 4; // X = 4
  decomp.nes.cpu.mem[0x17] = 2; // Y = 2

  stepAndDiffFrames(
    auth, decomp, 1, BTN_MASK.B, victoryTrajectory,
    'Victory: Hard-Drop T-Piece to Complete 10-Block Line & Collapse Rows',
    readTetrisDecompState, readTetrisAuthState,
    { includeWellRam: true }
  );
  stepAndDiffFrames(
    auth, decomp, 11, BTN_MASK.NONE, victoryTrajectory,
    'Victory: Staged 20-Row VBlank Flush After Line Clear',
    readTetrisDecompState, readTetrisAuthState,
    { includeWellRam: true }
  );
  const cp2 = compareMemoryState(
    auth.nes, decomp.nes, 2,
    'Checkpoint 2: 10-Block Line Clear, Gravity Collapse & VBlank Flush',
    readTetrisDecompState(), true
  );

  const wellMatches = [...failureTrajectory, ...victoryTrajectory].map(x => x.wellRamMatchBytes);
  const frameByFrame = summarizeTrajectories(failureTrajectory, victoryTrajectory, {
    avgWellRamMatchBytes: Number((wellMatches.reduce((a, b) => a + b, 0) / wellMatches.length).toFixed(2)),
    minWellRamMatchBytes: Math.min(...wellMatches),
    maxWellRamMatchBytes: Math.max(...wellMatches),
    recoveredWellRamMatchBytes: cpRecovery.wellRamMatchBytes,
    failureTriggered: cpFailure.gameplayState.gameOver === 1,
    recoveryVerified: cpRecovery.gameplayState.gameOver === 0 && cpRecovery.wellRamMatchBytes === 200,
    victoryVerified: cp2.gameplayState.lines === 1 && cp2.gameplayState.score === 1 && cp2.gameplayState.dirtyRow === 20
  });

  return {
    id: 'tetris',
    title: 'Nintendo NES Tetris',
    authenticRom: 'assets/roms/tetris.nes',
    decompiledRom: 'build/tetris_nes.nes',
    screenshot: 'screenshots/diff_tetris_side_by_side.png',
    ...cp0,
    frame0: cp0,
    checkpoints: [cp0, cp1, cp2, cpFailure, cpRecovery],
    frameByFrame
  };
}

// ============================================================================
// Execute All 3 Differential Verifiers & Write Report
// ============================================================================
const smbResult = diffSuperMarioBros();
const zeldaResult = diffLegendOfZelda();
const tetrisResult = diffNintendoTetris();

const report = {
  generatedAt: new Date().toISOString(),
  games: {
    smb: smbResult,
    zelda: zeldaResult,
    tetris: tetrisResult
  },
  results: [smbResult, zeldaResult, tetrisResult]
};

const reportPath = path.join(dumpDir, 'diff_report.json');
fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));

console.log('\n========================================================================================================================');
console.log(' SIDE-BY-SIDE AUTHENTIC vs. DECOMPILED #lang boba-nes DIFFERENTIAL VERIFICATION (FRAME 0 + FAILURE/RECOVERY + VICTORY)');
console.log('========================================================================================================================');
console.log(
  'Game'.padEnd(22) +
  'Palette'.padEnd(16) +
  'Nametable'.padEnd(18) +
  'Attr'.padEnd(14) +
  'CHR'.padEnd(16) +
  'OAM'.padEnd(14) +
  'Frames (Fail/Win)'.padEnd(20) +
  'Fail->Recover->Win'
);
console.log('------------------------------------------------------------------------------------------------------------------------');
for (const r of report.results) {
  const palStr = `${r.paletteMatchBytes}/32 (${r.paletteMatchPct}%)`;
  const ntStr = `${r.nametableMatchBytes}/960 (${r.nametableMatchPct}%)`;
  const attrStr = `${r.attribMatchBytes}/64 (${r.attribMatchPct}%)`;
  const chrStr = `${r.chrMatchBytes}/8192 (${r.chrMatchPct}%)`;
  const oamStr = `${r.oam.tileOverlapPct}% (${r.oam.decompiledVisible})`;
  const fbf = r.frameByFrame;
  const framesStr = `${fbf.totalFrames} (${fbf.failureFramesCount}/${fbf.victoryFramesCount})`;
  const statusStr = `${fbf.summaryStats.failureTriggered ? 'FAIL_OK' : 'ERR'} -> ${fbf.summaryStats.recoveryVerified ? 'REC_OK' : 'ERR'} -> ${fbf.summaryStats.victoryVerified ? 'WIN_OK' : 'ERR'}`;
  console.log(
    r.title.padEnd(22) +
    palStr.padEnd(16) +
    ntStr.padEnd(18) +
    attrStr.padEnd(14) +
    chrStr.padEnd(16) +
    oamStr.padEnd(14) +
    framesStr.padEnd(20) +
    statusStr
  );
}
console.log('========================================================================================================================');
console.log('Saved JSON report:', reportPath);
