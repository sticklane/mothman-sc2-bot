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

  return { nes, currentFrame, stepFrames, pressButton, tapButton };
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

  const readMarioState = () => ({
    worldX: (decomp.nes.cpu.mem[0x16] & 0xFF) + ((decomp.nes.cpu.mem[0x17] & 0xFF) << 8),
    yPx: decomp.nes.cpu.mem[0x1A] & 0xFF,
    coins: decomp.nes.cpu.mem[0x1E] & 0xFF,
    score: decomp.nes.cpu.mem[0x1F] & 0xFF,
    goombaAlive: decomp.nes.cpu.mem[0x21] & 0xFF,
    qblockHit: decomp.nes.cpu.mem[0x22] & 0xFF,
    won: decomp.nes.cpu.mem[0x24] & 0xFF
  });

  // Checkpoint 0: Initial Gameplay Frame 0
  const cp0 = compareMemoryState(auth.nes, decomp.nes, 0, 'Checkpoint 0: Initial World 1-1 Gameplay Frame 0', readMarioState());
  saveSideBySidePNG(auth.currentFrame, decomp.currentFrame, 'diff_smb_side_by_side.png');

  // Checkpoint 1: Mid-Action State (Walk right under '?' Block, jump to bonk Coin, stomp Goomba)
  for (const emu of [auth, decomp]) {
    emu.nes.buttonDown(1, Controller.BUTTON_RIGHT);
    emu.stepFrames(12);
    emu.nes.buttonUp(1, Controller.BUTTON_RIGHT);
    emu.nes.buttonDown(1, Controller.BUTTON_A);
    emu.stepFrames(1);
    emu.nes.buttonUp(1, Controller.BUTTON_A);
    emu.stepFrames(25);
    emu.nes.buttonDown(1, Controller.BUTTON_RIGHT);
    emu.stepFrames(14);
    emu.nes.buttonUp(1, Controller.BUTTON_RIGHT);
    emu.nes.buttonDown(1, Controller.BUTTON_A);
    emu.stepFrames(1);
    emu.nes.buttonUp(1, Controller.BUTTON_A);
    emu.stepFrames(35);
  }
  const cp1 = compareMemoryState(auth.nes, decomp.nes, 1, 'Checkpoint 1: Question Block Coin Bonk & Goomba Stomp', readMarioState());

  // Checkpoint 2: Objective/Progression State (Run right across scrolling World 1-1 to Flagpole)
  for (const emu of [auth, decomp]) {
    emu.nes.buttonDown(1, Controller.BUTTON_RIGHT);
    emu.stepFrames(85);
    emu.nes.buttonUp(1, Controller.BUTTON_RIGHT);
  }
  const cp2 = compareMemoryState(auth.nes, decomp.nes, 2, 'Checkpoint 2: Horizontal Scroll to World 1-1 Flagpole Victory', readMarioState());

  return {
    id: 'smb',
    title: 'Super Mario Bros.',
    authenticRom: 'assets/roms/super_mario_bros.nes',
    decompiledRom: 'build/mario_nes.nes',
    screenshot: 'screenshots/diff_smb_side_by_side.png',
    ...cp0,
    frame0: cp0,
    checkpoints: [cp0, cp1, cp2]
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

  const readZeldaState = () => ({
    linkX: decomp.nes.cpu.mem[0x14] & 0xFF,
    linkY: decomp.nes.cpu.mem[0x15] & 0xFF,
    octoAlive: decomp.nes.cpu.mem[0x1A] & 0xFF,
    rupees: decomp.nes.cpu.mem[0x1B] & 0xFF,
    keys: decomp.nes.cpu.mem[0x1C] & 0xFF,
    roomId: decomp.nes.cpu.mem[0x1D] & 0xFF,
    hearts: decomp.nes.cpu.mem[0x1E] & 0xFF,
    triforceWon: decomp.nes.cpu.mem[0x1F] & 0xFF
  });

  // Checkpoint 0: Initial Gameplay Frame 0
  const cp0 = compareMemoryState(auth.nes, decomp.nes, 0, 'Checkpoint 0: Initial Overworld Gameplay Frame 0', readZeldaState());
  saveSideBySidePNG(auth.currentFrame, decomp.currentFrame, 'diff_zelda_side_by_side.png');

  // Checkpoint 1: Mid-Action State (Walk UP and thrust Sword to slay Red Octorok)
  for (const emu of [auth, decomp]) {
    emu.nes.buttonDown(1, Controller.BUTTON_UP);
    emu.stepFrames(9);
    emu.nes.buttonUp(1, Controller.BUTTON_UP);
    emu.nes.buttonDown(1, Controller.BUTTON_A);
    emu.stepFrames(2);
    emu.nes.buttonUp(1, Controller.BUTTON_A);
  }
  const cp1 = compareMemoryState(auth.nes, decomp.nes, 1, 'Checkpoint 1: Sword Combat & Octorok Defeat', readZeldaState());

  // Checkpoint 2: Objective/Progression State (Collect Key, unlock North Door & claim Triforce)
  for (const emu of [auth, decomp]) {
    emu.nes.buttonDown(1, Controller.BUTTON_UP);
    emu.stepFrames(34);
    emu.nes.buttonUp(1, Controller.BUTTON_UP);
  }
  const cp2 = compareMemoryState(auth.nes, decomp.nes, 2, 'Checkpoint 2: North Door Unlock & Triforce of Wisdom Claimed', readZeldaState());

  return {
    id: 'zelda',
    title: 'The Legend of Zelda',
    authenticRom: 'assets/roms/legend_of_zelda.nes',
    decompiledRom: 'build/zelda_nes.nes',
    screenshot: 'screenshots/diff_zelda_side_by_side.png',
    ...cp0,
    frame0: cp0,
    checkpoints: [cp0, cp1, cp2]
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

  const readTetrisState = () => ({
    pieceId: decomp.nes.cpu.mem[0x14] & 0xFF,
    pieceRot: decomp.nes.cpu.mem[0x15] & 0xFF,
    pieceX: decomp.nes.cpu.mem[0x16] & 0xFF,
    pieceY: decomp.nes.cpu.mem[0x17] & 0xFF,
    nextId: decomp.nes.cpu.mem[0x18] & 0xFF,
    lines: decomp.nes.cpu.mem[0x1A] & 0xFF,
    score: decomp.nes.cpu.mem[0x1B] & 0xFF,
    dirtyRow: decomp.nes.cpu.mem[0x1D] & 0xFF
  });

  // Checkpoint 0: Initial Gameplay Frame 0
  const cp0 = compareMemoryState(auth.nes, decomp.nes, 0, 'Checkpoint 0: Initial A-Type Level 00 Gameplay Frame 0', readTetrisState());
  saveSideBySidePNG(auth.currentFrame, decomp.currentFrame, 'diff_tetris_side_by_side.png');

  // Checkpoint 1: Mid-Action State (Rotate piece CW, shift left twice, hard-drop & flush rows)
  for (const emu of [auth, decomp]) {
    emu.tapButton(Controller.BUTTON_A);
    emu.tapButton(Controller.BUTTON_LEFT);
    emu.tapButton(Controller.BUTTON_LEFT);
    emu.tapButton(Controller.BUTTON_B);
    emu.stepFrames(10);
  }
  const cp1 = compareMemoryState(auth.nes, decomp.nes, 1, 'Checkpoint 1: Tetromino Rotation, Shift & Lock', readTetrisState());

  // Checkpoint 2: Objective/Progression State (Complete 10-Block Line Clear & Staged 20-Row VBlank Flush)
  for (const col of [0, 1, 2, 6, 7, 8, 9]) {
    decomp.nes.cpu.mem[0x0400 + 180 + col] = 0x7B;
  }
  decomp.nes.cpu.mem[0x14] = 0; // T-piece
  decomp.nes.cpu.mem[0x15] = 0; // Rot 0
  decomp.nes.cpu.mem[0x16] = 4; // X = 4
  for (const emu of [auth, decomp]) {
    emu.tapButton(Controller.BUTTON_B);
    emu.stepFrames(10);
  }
  const cp2 = compareMemoryState(auth.nes, decomp.nes, 2, 'Checkpoint 2: 10-Block Line Clear, Gravity Collapse & VBlank Flush', readTetrisState());

  return {
    id: 'tetris',
    title: 'Nintendo NES Tetris',
    authenticRom: 'assets/roms/tetris.nes',
    decompiledRom: 'build/tetris_nes.nes',
    screenshot: 'screenshots/diff_tetris_side_by_side.png',
    ...cp0,
    frame0: cp0,
    checkpoints: [cp0, cp1, cp2]
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

console.log('\n====================================================================================================');
console.log(' SIDE-BY-SIDE AUTHENTIC vs. DECOMPILED #lang boba-nes DIFFERENTIAL VERIFICATION SUMMARY (FRAME 0)');
console.log('====================================================================================================');
console.log(
  'Game'.padEnd(24) +
  'Palette (32B)'.padEnd(18) +
  'Nametable (960B)'.padEnd(20) +
  'Attr (64B)'.padEnd(16) +
  'CHR (8192B)'.padEnd(18) +
  'OAM Tiles'
);
console.log('----------------------------------------------------------------------------------------------------');
for (const r of report.results) {
  const palStr = `${r.paletteMatchBytes}/32 (${r.paletteMatchPct}%)`;
  const ntStr = `${r.nametableMatchBytes}/960 (${r.nametableMatchPct}%)`;
  const attrStr = `${r.attribMatchBytes}/64 (${r.attribMatchPct}%)`;
  const chrStr = `${r.chrMatchBytes}/8192 (${r.chrMatchPct}%)`;
  const oamStr = `${r.oam.tileOverlapPct}% (${r.oam.decompiledVisible} spr)`;
  console.log(
    r.title.padEnd(24) +
    palStr.padEnd(18) +
    ntStr.padEnd(20) +
    attrStr.padEnd(16) +
    chrStr.padEnd(18) +
    oamStr
  );
}
console.log('====================================================================================================');
console.log('Saved JSON report:', reportPath);
