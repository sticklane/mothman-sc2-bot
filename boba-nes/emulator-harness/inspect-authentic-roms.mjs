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

function bootROM(romRelPath) {
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
    onAudioSample: function(left, right) {}
  });

  nes.loadROM(romData);

  function pressButton(btn, holdFrames = 2, waitAfter = 20) {
    nes.buttonDown(1, btn);
    for (let i = 0; i < holdFrames; i++) nes.frame();
    nes.buttonUp(1, btn);
    for (let i = 0; i < waitAfter; i++) nes.frame();
  }

  function saveScreenshot(filename) {
    const scale = 2;
    const width = 256 * scale;
    const height = 240 * scale;
    const png = new PNG({ width, height });
    for (let y = 0; y < 240; y++) {
      for (let x = 0; x < 256; x++) {
        const pixel = currentFrame[y * 256 + x];
        const r = pixel & 0xFF;
        const g = (pixel >> 8) & 0xFF;
        const b = (pixel >> 16) & 0xFF;
        for (let dy = 0; dy < scale; dy++) {
          for (let dx = 0; dx < scale; dx++) {
            const idx = ((y * scale + dy) * width + (x * scale + dx)) << 2;
            png.data[idx] = r;
            png.data[idx + 1] = g;
            png.data[idx + 2] = b;
            png.data[idx + 3] = 255;
          }
        }
      }
    }
    const outPath = path.join(outDir, filename);
    fs.writeFileSync(outPath, PNG.sync.write(png));
    console.log('Saved screenshot:', outPath);
  }

  function dumpPPUState(tag) {
    const vram = nes.ppu.vramMem;
    const palette = [];
    for (let i = 0; i < 32; i++) {
      palette.push(vram[0x3F00 + i] & 0x3F);
    }
    const nt0 = [];
    for (let i = 0; i < 1024; i++) {
      nt0.push(vram[0x2000 + i] & 0xFF);
    }
    const nt1 = [];
    for (let i = 0; i < 1024; i++) {
      nt1.push(vram[0x2400 + i] & 0xFF);
    }
    const oam = [];
    for (let i = 0; i < 256; i++) {
      oam.push(nes.cpu.mem[0x0200 + i] & 0xFF);
    }
    const state = {
      tag,
      f_bgPatternTable: nes.ppu.f_bgPatternTable,
      f_spPatternTable: nes.ppu.f_spPatternTable,
      palette,
      nt0,
      nt1,
      oam
    };
    fs.writeFileSync(path.join(dumpDir, `${tag}_ppu_state.json`), JSON.stringify(state, null, 2));
    console.log(`[${tag}] BG PT=${nes.ppu.f_bgPatternTable} SP PT=${nes.ppu.f_spPatternTable}`);
    console.log(`[${tag}] Palette:`, palette.map(b => '0x' + b.toString(16).padStart(2, '0')).join(', '));
    return state;
  }

  return { nes, pressButton, saveScreenshot, dumpPPUState };
}

// 1. Authentic Super Mario Bros.
{
  const { nes, pressButton, saveScreenshot, dumpPPUState } = bootROM('../assets/roms/super_mario_bros.nes');
  for (let i = 0; i < 60; i++) nes.frame();
  // Title screen -> press START to start 1 Player Game
  pressButton(Controller.BUTTON_START, 4, 210);
  saveScreenshot('ref_authentic_smb_w1_1.png');
  dumpPPUState('smb_w1_1');
}

// 2. Authentic The Legend of Zelda
{
  const { nes, pressButton, saveScreenshot, dumpPPUState } = bootROM('../assets/roms/legend_of_zelda.nes');
  for (let i = 0; i < 180; i++) nes.frame();
  // Title screen -> - S E L E C T -
  pressButton(Controller.BUTTON_START, 6, 90);
  // - S E L E C T - (cursor starts on REGISTER YOUR NAME when slots are empty) -> REGISTER YOUR NAME
  pressButton(Controller.BUTTON_START, 6, 60);
  // Press A to put 'A' in slot 1
  pressButton(Controller.BUTTON_A, 6, 30);
  // Press SELECT 3 times on REGISTER YOUR NAME (Slot1 -> Slot2 -> Slot3 -> REGISTER/END)
  pressButton(Controller.BUTTON_SELECT, 6, 25);
  pressButton(Controller.BUTTON_SELECT, 6, 25);
  pressButton(Controller.BUTTON_SELECT, 6, 25);
  // Press START on REGISTER/END to return to File Select, then START to begin game on Slot 1!
  pressButton(Controller.BUTTON_START, 6, 60);
  pressButton(Controller.BUTTON_START, 6, 150);
  saveScreenshot('ref_authentic_zelda_overworld.png');
  dumpPPUState('zelda_overworld');
}

// 3. Authentic Nintendo NES Tetris
{
  const { nes, pressButton, saveScreenshot, dumpPPUState } = bootROM('../assets/roms/tetris.nes');
  for (let i = 0; i < 320; i++) nes.frame();
  // Legal screen -> Title screen -> Menu -> A-Type -> Level 0 Gameplay (4 START presses)
  for (let p = 0; p < 4; p++) {
    pressButton(Controller.BUTTON_START, 6, 60);
  }
  for (let i = 0; i < 60; i++) nes.frame();
  saveScreenshot('ref_authentic_tetris_gameplay.png');
  dumpPPUState('tetris_gameplay');
}
