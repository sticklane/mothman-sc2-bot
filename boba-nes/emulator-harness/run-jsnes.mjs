import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { NES, Controller } from './node_modules/jsnes/src/index.js';
import pngjs from 'pngjs';
const { PNG } = pngjs;

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const romPath = path.resolve(__dirname, '../build/boba_is_you.nes');
const outDir = path.resolve(__dirname, '../screenshots');
fs.mkdirSync(outDir, { recursive: true });

const romBytes = fs.readFileSync(romPath);
const romData = romBytes.toString('binary');

let currentFrame = new Uint32Array(256 * 240);

const nes = new NES({
  onFrame: function(buffer) {
    for (let i = 0; i < 256 * 240; i++) {
      currentFrame[i] = buffer[i];
    }
  },
  onAudioSample: function(left, right) {}
});

nes.loadROM(romData);

// Save current 256x240 frame scaled 2x (512x480) nearest-neighbor for crisp viewing
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

function tapButton(btn) {
  nes.buttonDown(1, btn);
  nes.frame();
  nes.frame();
  nes.buttonUp(1, btn);
  nes.frame();
  nes.frame();
}

// Run warm-up frames after boot
for (let i = 0; i < 5; i++) nes.frame();
saveScreenshot('01_stage1_initial.png');

// Solve Stage 1 in jsnes:
tapButton(Controller.BUTTON_DOWN);
tapButton(Controller.BUTTON_LEFT);
tapButton(Controller.BUTTON_LEFT);
tapButton(Controller.BUTTON_LEFT);
tapButton(Controller.BUTTON_UP); // Breaks WALL IS STOP!
saveScreenshot('02_stage1_wall_stop_broken.png');

// Walk through the WALL at y=6 into the top room
tapButton(Controller.BUTTON_RIGHT);
tapButton(Controller.BUTTON_RIGHT);
tapButton(Controller.BUTTON_RIGHT);
tapButton(Controller.BUTTON_UP);
tapButton(Controller.BUTTON_UP); // Standing on WALL at (7,6)!
saveScreenshot('03_stage1_walking_through_wall.png');

tapButton(Controller.BUTTON_UP);
tapButton(Controller.BUTTON_RIGHT);
tapButton(Controller.BUTTON_RIGHT);
tapButton(Controller.BUTTON_UP);
tapButton(Controller.BUTTON_UP);
tapButton(Controller.BUTTON_LEFT); // Pushes WIN into FLAG IS WIN!
saveScreenshot('04_stage1_flag_is_win_formed.png');

tapButton(Controller.BUTTON_RIGHT);
tapButton(Controller.BUTTON_RIGHT); // Touches FLAG -> WIN!
saveScreenshot('05_stage1_victory.png');

// Advance to Stage 2 (WALL IS YOU)
tapButton(Controller.BUTTON_START);
saveScreenshot('06_stage2_wall_is_you.png');

// Advance to Stage 3 (ROCK IS PUSH, SKULL IS DEFEAT)
tapButton(Controller.BUTTON_START);
tapButton(Controller.BUTTON_UP); // Push 2-rock chain!
saveScreenshot('07_stage3_rock_push_chain.png');

// Advance to Stage 4 (Single-IS Crossword)
tapButton(Controller.BUTTON_START);
tapButton(Controller.BUTTON_UP); // Form BOBA IS YOU + FLAG IS WIN crossword!
saveScreenshot('08_stage4_crossword_is.png');

// Advance to Stage 5 (World Event: WALL IS BOBA)
tapButton(Controller.BUTTON_START);
saveScreenshot('09_stage5_before_world_event.png');
tapButton(Controller.BUTTON_LEFT); // Push BOBA into WALL IS BOBA!
saveScreenshot('10_stage5_after_wall_is_boba.png');
