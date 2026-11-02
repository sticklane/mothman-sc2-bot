import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { NES, Controller } from './node_modules/jsnes/src/index.js';
import pngjs from 'pngjs';
const { PNG } = pngjs;

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const outDir = path.resolve(__dirname, '../screenshots');
fs.mkdirSync(outDir, { recursive: true });

function createHarness(romRelPath) {
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

  return { nes, saveScreenshot };
}

// ============================================================================
// 1. Super Mario Bros. (World 1-1) in jsnes
// ============================================================================
{
  const { nes, saveScreenshot } = createHarness('../build/mario_nes.nes');
  for (let i = 0; i < 6; i++) nes.frame();

  // Walk right under the '?' Question Block and jump to bonk a Coin!
  nes.buttonDown(1, Controller.BUTTON_RIGHT);
  for (let i = 0; i < 12; i++) nes.frame();
  nes.buttonUp(1, Controller.BUTTON_RIGHT);

  nes.buttonDown(1, Controller.BUTTON_A);
  nes.frame();
  nes.buttonUp(1, Controller.BUTTON_A);
  for (let i = 0; i < 12; i++) nes.frame();
  saveScreenshot('11_mario_world1_1_qblock_coin.png');

  // Land, then run right across the scrolling world toward the Flagpole & Castle!
  for (let i = 0; i < 18; i++) nes.frame();
  nes.buttonDown(1, Controller.BUTTON_RIGHT);
  for (let i = 0; i < 54; i++) nes.frame();
  nes.buttonUp(1, Controller.BUTTON_RIGHT);
  saveScreenshot('12_mario_scrolling_flagpole.png');
}

// ============================================================================
// 2. The Legend of Zelda (Overworld & Triforce Sanctum) in jsnes
// ============================================================================
{
  const { nes, saveScreenshot } = createHarness('../build/zelda_nes.nes');
  for (let i = 0; i < 6; i++) nes.frame();

  // Walk Link UP toward the Red Octorok and thrust the Sword ('A' button)!
  nes.buttonDown(1, Controller.BUTTON_UP);
  for (let i = 0; i < 7; i++) nes.frame();
  nes.buttonUp(1, Controller.BUTTON_UP);

  nes.buttonDown(1, Controller.BUTTON_A);
  nes.frame();
  nes.frame();
  nes.buttonUp(1, Controller.BUTTON_A);
  saveScreenshot('13_zelda_sword_combat_octorok.png');

  // Defeat Octorok, pick up the dropped Key, and unlock the North Door into the Sanctum!
  nes.buttonDown(1, Controller.BUTTON_UP);
  for (let i = 0; i < 2; i++) nes.frame();
  nes.buttonUp(1, Controller.BUTTON_UP);
  nes.buttonDown(1, Controller.BUTTON_A);
  nes.frame();
  nes.buttonUp(1, Controller.BUTTON_A);
  nes.buttonDown(1, Controller.BUTTON_UP);
  for (let i = 0; i < 22; i++) nes.frame();
  nes.buttonUp(1, Controller.BUTTON_UP);
  saveScreenshot('14_zelda_triforce_sanctum.png');
}

// ============================================================================
// 3. Nintendo NES Tetris (10x20 Well, Rotation & VBlank Row Copier) in jsnes
// ============================================================================
{
  const { nes, saveScreenshot } = createHarness('../build/tetris_nes.nes');
  for (let i = 0; i < 6; i++) nes.frame();

  // Lock 3 pieces at the bottom of the 10x20 well and show an active falling piece + NEXT preview!
  // Piece 1 (T-piece): shift left twice and hard-drop ('B')
  for (let s = 0; s < 2; s++) {
    nes.buttonDown(1, Controller.BUTTON_LEFT);
    nes.frame();
    nes.buttonUp(1, Controller.BUTTON_LEFT);
    nes.frame();
  }
  nes.buttonDown(1, Controller.BUTTON_B);
  nes.frame();
  nes.buttonUp(1, Controller.BUTTON_B);
  for (let i = 0; i < 12; i++) nes.frame();

  // Piece 2 (O-piece): shift right twice and hard-drop ('B')
  for (let s = 0; s < 2; s++) {
    nes.buttonDown(1, Controller.BUTTON_RIGHT);
    nes.frame();
    nes.buttonUp(1, Controller.BUTTON_RIGHT);
    nes.frame();
  }
  nes.buttonDown(1, Controller.BUTTON_B);
  nes.frame();
  nes.buttonUp(1, Controller.BUTTON_B);
  for (let i = 0; i < 12; i++) nes.frame();

  // Rotate active piece ('A') and let it descend partway down the well
  nes.buttonDown(1, Controller.BUTTON_A);
  nes.frame();
  nes.buttonUp(1, Controller.BUTTON_A);
  for (let i = 0; i < 6; i++) {
    nes.buttonDown(1, Controller.BUTTON_DOWN);
    nes.frame();
    nes.buttonUp(1, Controller.BUTTON_DOWN);
    nes.frame();
  }
  saveScreenshot('15_tetris_nes_gameplay.png');
}
