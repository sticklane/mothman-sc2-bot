import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { NES, Controller } from './node_modules/jsnes/src/index.js';
import pngjs from 'pngjs';

const { PNG } = pngjs;
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const romPath = path.resolve(__dirname, '../assets/roms/metroid.nes');
const outDir = path.resolve(__dirname, '../screenshots');
const dumpDir = path.resolve(__dirname, '../assets/decompiled');
fs.mkdirSync(outDir, { recursive: true });
fs.mkdirSync(dumpDir, { recursive: true });

export function bootMetroidToBrinstar() {
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

  let totalFrames = 0;
  function step(n) {
    for (let i = 0; i < n; i++) {
      nes.frame();
      totalFrames++;
    }
  }

  function press(btn, hold = 6, wait = 60) {
    nes.buttonDown(1, btn);
    step(hold);
    nes.buttonUp(1, btn);
    step(wait);
  }

  // 1. Let Title Screen fade in
  step(180);
  // 2. Press START on Title Screen -> goes to START / CONTINUE screen
  press(Controller.BUTTON_START, 6, 90);
  // 3. Press START on START -> Samus materializes on the Brinstar pedestal!
  const startFrame = totalFrames;
  press(Controller.BUTTON_START, 6, 450);

  return { nes, currentFrame, romBytes, bootFrames: totalFrames, startFrame };
}

export function extractMetroidState() {
  const { nes, currentFrame, romBytes, bootFrames, startFrame } = bootMetroidToBrinstar();
  const vram = nes.ppu.vramMem;

  // Dump 8,192-byte CHR-RAM ($0000-$1FFF) uploaded by Metroid PRG-ROM
  const chr8k = Buffer.alloc(8192);
  let nonZeroChrBytes = 0;
  for (let i = 0; i < 8192; i++) {
    const b = vram[i] & 0xFF;
    chr8k[i] = b;
    if (b !== 0) nonZeroChrBytes++;
  }
  const chrOutPath = path.join(dumpDir, 'metroid_chr8k.bin');
  fs.writeFileSync(chrOutPath, chr8k);

  const palette32 = [];
  for (let i = 0; i < 32; i++) {
    palette32.push(vram[0x3F00 + i] & 0x3F);
  }

  const nametable960 = [];
  for (let i = 0; i < 960; i++) {
    nametable960.push(vram[0x2000 + i] & 0xFF);
  }

  const attrib64 = [];
  for (let i = 0; i < 64; i++) {
    attrib64.push(vram[0x23C0 + i] & 0xFF);
  }

  const nt0 = [...nametable960, ...attrib64];

  const nt1 = [];
  for (let i = 0; i < 1024; i++) {
    nt1.push(vram[0x2400 + i] & 0xFF);
  }

  const oam256 = [];
  const visibleSprites = [];
  for (let i = 0; i < 256; i++) {
    oam256.push(nes.cpu.mem[0x0200 + i] & 0xFF);
  }
  for (let s = 0; s < 64; s++) {
    const y = oam256[s * 4];
    const tile = oam256[s * 4 + 1];
    const attr = oam256[s * 4 + 2];
    const x = oam256[s * 4 + 3];
    if (y > 0 && y < 0xF0) {
      visibleSprites.push({ slot: s, x, y, tile, attr, palette: attr & 0x03 });
    }
  }

  const bgPt = nes.ppu.f_bgPatternTable ? 1 : 0;
  const spPt = nes.ppu.f_spPatternTable ? 1 : 0;
  const spSize = nes.ppu.f_spriteSize ? 1 : 0;
  const ppuctrl = 0x80 | (spSize ? 0x20 : 0x00) | (bgPt ? 0x10 : 0x00) | (spPt ? 0x08 : 0x00);
  const ppumask = 0x1E;
  const mirroring = nes.rom.mirroring === nes.rom.VERTICAL_MIRRORING ? 'vertical' : 'horizontal';

  const state = {
    id: 'metroid',
    symbol: 'metroid',
    title: 'Metroid',
    romFile: 'metroid.nes',
    mapper: 1,
    mapperName: 'MMC1',
    prgBanks: romBytes[4] & 0xFF,
    chrBanks: romBytes[5] & 0xFF,
    chrRamBytes: 8192,
    nonZeroChrBytes,
    mirroring,
    bgPatternTable: bgPt,
    spPatternTable: spPt,
    ppuctrl,
    ppumask,
    bootFrames,
    startFrame,
    palette32,
    nametable960,
    attrib64,
    nt0,
    nt1,
    oam256,
    visibleSpritesCount: visibleSprites.length,
    visibleSprites
  };

  const jsonOutPath = path.join(dumpDir, 'metroid_brinstar_state.json');
  fs.writeFileSync(jsonOutPath, JSON.stringify(state, null, 2));

  // Save reference screenshot
  const scale = 2;
  const png = new PNG({ width: 256 * scale, height: 240 * scale });
  for (let y = 0; y < 240; y++) {
    for (let x = 0; x < 256; x++) {
      const pixel = currentFrame[y * 256 + x];
      const r = pixel & 0xFF;
      const g = (pixel >> 8) & 0xFF;
      const b = (pixel >> 16) & 0xFF;
      for (let dy = 0; dy < scale; dy++) {
        for (let dx = 0; dx < scale; dx++) {
          const idx = ((y * scale + dy) * (256 * scale) + (x * scale + dx)) << 2;
          png.data[idx] = r;
          png.data[idx + 1] = g;
          png.data[idx + 2] = b;
          png.data[idx + 3] = 255;
        }
      }
    }
  }
  const pngOutPath = path.join(outDir, 'ref_authentic_metroid_brinstar.png');
  fs.writeFileSync(pngOutPath, PNG.sync.write(png));

  console.log(`[metroid] CHR-RAM non-zero=${nonZeroChrBytes}/8192 mir=${mirroring} BG_PT=${bgPt} SP_PT=${spPt} PPUCTRL=0x${ppuctrl.toString(16)}`);
  console.log(`[metroid] visibleSprites=${visibleSprites.length}`, visibleSprites);
  console.log(`[metroid] palette32:`, palette32.map(x => '0x' + x.toString(16).padStart(2, '0')).join(', '));
  return state;
}

if (process.argv[1] && path.resolve(process.argv[1]) === __filename) {
  extractMetroidState();
}
