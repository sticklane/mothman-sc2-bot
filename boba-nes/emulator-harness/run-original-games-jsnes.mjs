import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { NES, Controller } from './node_modules/jsnes/src/index.js';
import pngjs from 'pngjs';
const { PNG } = pngjs;

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const outDir = path.resolve(__dirname, '../screenshots');
const reportDir = path.resolve(__dirname, '../assets/decompiled');
fs.mkdirSync(outDir, { recursive: true });
fs.mkdirSync(reportDir, { recursive: true });

// Pinned Zero-Page Addresses matching compiler/original-dsl-games.rkt
const ZP = {
  BUTTONS: 0x10,
  FRAME_CNT: 0x13,
  X: 0x14,
  Y: 0x15,
  VY: 0x16,
  SPECIAL: 0x17, // FUEL / FREEZE_TIMER / POLARITY
  BOMB_TIMER: 0x1A,
  ENEMY_X: 0x1B,
  ENEMY_ALIVE: 0x1C,
  ENEMY_Y: 0x1D,
  SCORE: 0x1E,
  PODS: 0x1F, // PODS / RELICS / NODES
  WALL_INTACT: 0x20,
  WON: 0x24,
  LIVES: 0x25,
  DEAD: 0x26,
  STAGE_DIRTY: 0x27,
  STAGE_ID: 0x28,
  GAME_COMPLETED: 0x29
};

function createGameHarness(romRelPath) {
  const romPath = path.resolve(__dirname, romRelPath);
  const romBytes = fs.readFileSync(romPath);
  const romData = romBytes.toString('binary');
  const currentFrame = new Uint32Array(256 * 240);
  let audioSamples = 0;

  const nes = new NES({
    onFrame: function(buffer) {
      for (let i = 0; i < 256 * 240; i++) {
        currentFrame[i] = buffer[i];
      }
    },
    onAudioSample: function() {
      audioSamples++;
    }
  });

  nes.loadROM(romData);

  function stepFrames(n = 1) {
    for (let i = 0; i < n; i++) nes.frame();
  }

  function pressButtons(buttons, holdFrames = 1, settleFrames = 1) {
    const btnList = Array.isArray(buttons) ? buttons : [buttons];
    for (const b of btnList) nes.buttonDown(1, b);
    for (let i = 0; i < holdFrames; i++) nes.frame();
    for (const b of btnList) nes.buttonUp(1, b);
    for (let i = 0; i < settleFrames; i++) nes.frame();
  }

  function readState(checkpointLabel) {
    const mem = nes.cpu.mem;
    const vram = nes.ppu.vramMem;
    let visibleSprites = 0;
    for (let s = 0; s < 64; s++) {
      const y = mem[0x0200 + s * 4] & 0xFF;
      if (y > 0 && y < 0xF0) visibleSprites++;
    }
    const colorSet = new Set();
    let nonBlackPixels = 0;
    for (let i = 0; i < 256 * 240; i++) {
      const px = currentFrame[i] & 0xFFFFFF;
      colorSet.add(px);
      if (px !== 0x000000) nonBlackPixels++;
    }
    return {
      checkpoint: checkpointLabel,
      frameCnt: mem[ZP.FRAME_CNT] & 0xFF,
      x: mem[ZP.X] & 0xFF,
      y: mem[ZP.Y] & 0xFF,
      vy: mem[ZP.VY] & 0xFF,
      special: mem[ZP.SPECIAL] & 0xFF,
      enemyAlive: mem[ZP.ENEMY_ALIVE] & 0xFF,
      score: mem[ZP.SCORE] & 0xFF,
      pods: mem[ZP.PODS] & 0xFF,
      lives: mem[ZP.LIVES] & 0xFF,
      dead: mem[ZP.DEAD] & 0xFF,
      stageId: mem[ZP.STAGE_ID] & 0xFF,
      gameCompleted: mem[ZP.GAME_COMPLETED] & 0xFF,
      hudStageDigitTile: vram[0x204A] & 0xFF,
      hudPodsDigitTile: vram[0x2052] & 0xFF,
      hudLivesDigitTile: vram[0x205B] & 0xFF,
      stageAccentColor: vram[0x3F02] & 0x3F,
      spritePal0Color1: vram[0x3F11] & 0x3F,
      visibleSprites,
      distinctRgbColors: colorSet.size,
      nonBlackPixels,
      audioSamples
    };
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
    console.log('Saved screenshot:', filename);
    return `screenshots/${filename}`;
  }

  return { nes, romBytes, stepFrames, pressButtons, readState, saveScreenshot };
}

function assertCond(cond, msg) {
  if (!cond) {
    throw new Error(`Play-test assertion failed: ${msg}`);
  }
}

const report = {
  suite: '#lang boba-nes Original Minimal-Size NES Games End-to-End Play-Test',
  games: {}
};

// ============================================================================
// 1. Star Courier: Kestral Run (build/star_courier.nes)
// ============================================================================
{
  const h = createGameHarness('../build/star_courier.nes');
  h.stepFrames(4);
  const cpBoot = h.readState('boot_sector_0');
  assertCond(cpBoot.lives === 3 && cpBoot.dead === 0 && cpBoot.stageId === 0, 'Star Courier boot state');

  // Thrust upward ('A') to collect energy pod and clear plasma drone
  h.pressButtons(Controller.BUTTON_A, 2, 1);
  const cpThrust = h.readState('thrust_and_pod_pickup');
  assertCond(cpThrust.pods >= 1 && cpThrust.enemyAlive === 0, 'Star Courier thrust & pod pickup');

  // Crash into lunar canyon hazard ('LEFT') -> DEAD = 1, LIVES = 2
  h.pressButtons(Controller.BUTTON_LEFT, 1, 1);
  const cpCrash = h.readState('hull_breach_hazard');
  assertCond(cpCrash.dead === 1 && cpCrash.lives === 2, 'Star Courier hull breach failure');

  // In-sector recovery via 'START' -> DEAD = 0, ENEMY_ALIVE = 1
  h.pressButtons(Controller.BUTTON_START, 1, 1);
  const cpRecover = h.readState('in_sector_recovery');
  assertCond(cpRecover.dead === 0 && cpRecover.enemyAlive === 1, 'Star Courier START recovery');

  // Land on Sector 0 Beacon ('RIGHT' + 'A') -> advance to Sector 1 (Ion Cavern)
  h.pressButtons([Controller.BUTTON_RIGHT, Controller.BUTTON_A], 1, 1);
  const cpSector1 = h.readState('sector_1_ion_cavern');
  assertCond(cpSector1.stageId === 1, 'Star Courier advance to Sector 1');

  // Land on Sector 1 Beacon ('RIGHT' + 'A') -> advance to Sector 2 (Core Reactor) & Victory!
  h.pressButtons([Controller.BUTTON_RIGHT, Controller.BUTTON_A], 1, 1);
  // Thrust once in Sector 2 for an active screenshot pose
  h.pressButtons(Controller.BUTTON_A, 1, 1);
  const cpVictory = h.readState('sector_2_delivery_victory');
  assertCond(cpVictory.stageId === 2 && cpVictory.gameCompleted === 1, 'Star Courier 3-sector victory');

  const screenshotPath = h.saveScreenshot('orig_star_courier.png');
  report.games.star_courier = {
    title: 'Star Courier: Kestral Run',
    romSizeBytes: h.romBytes.length,
    screenshot: screenshotPath,
    checkpoints: [cpBoot, cpThrust, cpCrash, cpRecover, cpSector1, cpVictory],
    verified: true
  };
}

// ============================================================================
// 2. Crypt Sweep: Chronomancer's Vault (build/crypt_sweep.nes)
// ============================================================================
{
  const h = createGameHarness('../build/crypt_sweep.nes');
  h.stepFrames(4);
  const cpBoot = h.readState('boot_vault_0');
  assertCond(cpBoot.lives === 3 && cpBoot.dead === 0 && cpBoot.stageId === 0, 'Crypt Sweep boot state');

  // Activate Time-Freeze Pulse ('A') and detonate Arcane Bomb ('B') to clear Wraith & Cracked Wall
  h.pressButtons(Controller.BUTTON_A, 1, 1);
  h.pressButtons(Controller.BUTTON_B, 1, 1);
  h.pressButtons(Controller.BUTTON_UP, 1, 1);
  const cpBombFreeze = h.readState('time_freeze_and_arcane_bomb');
  assertCond(cpBombFreeze.special === 12 && cpBombFreeze.enemyAlive === 0 && cpBombFreeze.pods >= 1,
             'Crypt Sweep time-freeze & arcane bomb');

  // Wraith contact hazard ('LEFT') -> DEAD = 1, LIVES = 2
  h.pressButtons(Controller.BUTTON_LEFT, 1, 1);
  const cpHazard = h.readState('wraith_contact_defeat');
  assertCond(cpHazard.dead === 1 && cpHazard.lives === 2, 'Crypt Sweep Wraith defeat');

  // In-vault recovery via 'START' -> DEAD = 0
  h.pressButtons(Controller.BUTTON_START, 1, 1);
  const cpRecover = h.readState('in_vault_recovery');
  assertCond(cpRecover.dead === 0 && cpRecover.enemyAlive === 1, 'Crypt Sweep START recovery');

  // Advance through Sanctum Portals across Vault 0 -> Vault 1 -> Vault 2
  h.pressButtons(Controller.BUTTON_RIGHT, 1, 1);
  const cpVault1 = h.readState('vault_1_obsidian_hall');
  assertCond(cpVault1.stageId === 1, 'Crypt Sweep advance to Vault 1');

  h.pressButtons(Controller.BUTTON_RIGHT, 1, 1);
  const cpVictory = h.readState('vault_2_chronomancer_victory');
  assertCond(cpVictory.stageId === 2 && cpVictory.gameCompleted === 1, 'Crypt Sweep 3-vault victory');

  const screenshotPath = h.saveScreenshot('orig_crypt_sweep.png');
  report.games.crypt_sweep = {
    title: "Crypt Sweep: Chronomancer's Vault",
    romSizeBytes: h.romBytes.length,
    screenshot: screenshotPath,
    checkpoints: [cpBoot, cpBombFreeze, cpHazard, cpRecover, cpVault1, cpVictory],
    verified: true
  };
}

// ============================================================================
// 3. Neon Strider: Cyber Grid 1989 (build/neon_strider.nes)
// ============================================================================
{
  const h = createGameHarness('../build/neon_strider.nes');
  h.stepFrames(4);
  const cpBoot = h.readState('boot_zone_0');
  assertCond(cpBoot.lives === 3 && cpBoot.dead === 0 && cpBoot.stageId === 0 && cpBoot.special === 0,
             'Neon Strider boot state');

  // 8.8 Cyber-Jump ('A') and Phase Polarity Toggle ('B' -> shifts polarity 0 -> 1, $3F11 -> #x24 Magenta)
  h.pressButtons(Controller.BUTTON_A, 1, 1);
  h.pressButtons(Controller.BUTTON_B, 1, 1);
  const cpPolarity = h.readState('jump_and_polarity_shift');
  assertCond(cpPolarity.special === 1 && cpPolarity.spritePal0Color1 === 0x24,
             'Neon Strider polarity toggle to Magenta #x24');

  // Laser barrier hazard when polarity mismatches ('LEFT') -> DEAD = 1, LIVES = 2
  h.pressButtons(Controller.BUTTON_LEFT, 1, 1);
  const cpHazard = h.readState('laser_barrier_overload');
  assertCond(cpHazard.dead === 1 && cpHazard.lives === 2, 'Neon Strider laser barrier hazard');

  // In-zone recovery via 'START' -> DEAD = 0
  h.pressButtons(Controller.BUTTON_START, 1, 1);
  const cpRecover = h.readState('in_zone_recovery');
  assertCond(cpRecover.dead === 0 && cpRecover.enemyAlive === 1, 'Neon Strider START recovery');

  // Matching Polarity Sprint ('B' + 'RIGHT') across Zone 0 -> Zone 1 -> Zone 2
  h.pressButtons([Controller.BUTTON_B, Controller.BUTTON_RIGHT], 1, 1);
  const cpZone1 = h.readState('zone_1_firewall_relay');
  assertCond(cpZone1.stageId === 1, 'Neon Strider advance to Zone 1');

  h.pressButtons([Controller.BUTTON_B, Controller.BUTTON_RIGHT], 1, 1);
  const cpVictory = h.readState('zone_2_mainframe_victory');
  assertCond(cpVictory.stageId === 2 && cpVictory.gameCompleted === 1, 'Neon Strider 3-zone victory');

  const screenshotPath = h.saveScreenshot('orig_neon_strider.png');
  report.games.neon_strider = {
    title: 'Neon Strider: Cyber Grid 1989',
    romSizeBytes: h.romBytes.length,
    screenshot: screenshotPath,
    checkpoints: [cpBoot, cpPolarity, cpHazard, cpRecover, cpZone1, cpVictory],
    verified: true
  };
}

const reportPath = path.join(reportDir, 'original_games_report.json');
fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
console.log('Saved original games report:', reportPath);
