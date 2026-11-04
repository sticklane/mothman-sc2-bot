import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { NES, Controller } from './node_modules/jsnes/src/index.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const romsDir = path.resolve(__dirname, '../assets/roms');
const outDir = path.resolve(__dirname, '../assets/decompiled/top10');
fs.mkdirSync(outDir, { recursive: true });

export const TOP10_GAMES = [
  {
    id: 'donkey_kong',
    symbol: 'donkey-kong',
    title: 'Donkey Kong',
    romFile: 'donkey_kong.nes',
    bootPlan: [
      { wait: 60 },
      { btn: Controller.BUTTON_START, hold: 6, wait: 420 }
    ]
  },
  {
    id: 'mario_bros',
    symbol: 'mario-bros',
    title: 'Mario Bros.',
    romFile: 'mario_bros.nes',
    bootPlan: [
      { wait: 90 },
      { btn: Controller.BUTTON_START, hold: 4, wait: 300 }
    ]
  },
  {
    id: 'pac_man',
    symbol: 'pac-man',
    title: 'Pac-Man',
    romFile: 'pac_man.nes',
    oamPage: 0x0700,
    bootPlan: [
      { wait: 380 },
      { btn: Controller.BUTTON_START, hold: 6, wait: 340 }
    ]
  },
  {
    id: 'excitebike',
    symbol: 'excitebike',
    title: 'Excitebike',
    romFile: 'excitebike.nes',
    bootPlan: [
      { wait: 120 },
      { btn: Controller.BUTTON_START, hold: 4, wait: 60 },
      { btn: Controller.BUTTON_START, hold: 4, wait: 180 }
    ]
  },
  {
    id: 'balloon_fight',
    symbol: 'balloon-fight',
    title: 'Balloon Fight',
    romFile: 'balloon_fight.nes',
    bootPlan: [
      { wait: 90 },
      { btn: Controller.BUTTON_START, hold: 4, wait: 180 }
    ]
  },
  {
    id: 'ice_climber',
    symbol: 'ice-climber',
    title: 'Ice Climber',
    romFile: 'ice_climber.nes',
    bootPlan: [
      { wait: 120 },
      { btn: Controller.BUTTON_START, hold: 4, wait: 60 },
      { btn: Controller.BUTTON_START, hold: 4, wait: 45 }
    ]
  },
  {
    id: 'galaga',
    symbol: 'galaga',
    title: 'Galaga',
    romFile: 'galaga.nes',
    oamPage: 0x0700,
    bootPlan: [
      { wait: 240 },
      { btn: Controller.BUTTON_START, hold: 6, wait: 60 },
      { btn: Controller.BUTTON_START, hold: 6, wait: 420 }
    ]
  },
  {
    id: 'kung_fu',
    symbol: 'kung-fu',
    title: 'Kung Fu',
    romFile: 'kung_fu.nes',
    bootPlan: [
      { wait: 60 },
      { btn: Controller.BUTTON_START, hold: 6, wait: 540 },
      { btn: Controller.BUTTON_RIGHT, hold: 2, wait: 0 }
    ]
  },
  {
    id: 'battle_city',
    symbol: 'battle-city',
    title: 'Battle City',
    romFile: 'battle_city.nes',
    bootPlan: [
      { wait: 60 },
      { btn: Controller.BUTTON_START, hold: 4, wait: 40 },
      { btn: Controller.BUTTON_START, hold: 4, wait: 40 },
      { btn: Controller.BUTTON_START, hold: 4, wait: 180 }
    ]
  },
  {
    id: 'bomberman',
    symbol: 'bomberman',
    title: 'Bomberman',
    romFile: 'bomberman.nes',
    oamPage: 0x0700,
    bootPlan: [
      { wait: 90 },
      { btn: Controller.BUTTON_START, hold: 4, wait: 260 }
    ]
  }
];

export function bootToGameplay(gameSpec) {
  const romPath = path.join(romsDir, gameSpec.romFile);
  const romBytes = fs.readFileSync(romPath);
  const romData = romBytes.toString('binary');
  const currentFrame = new Uint32Array(256 * 240);

  const flags6 = romBytes[6] & 0xFF;
  const prgBanks = romBytes[4] & 0xFF;
  const chrBanks = romBytes[5] & 0xFF;
  const mirroring = (flags6 & 0x01) !== 0 ? 'vertical' : 'horizontal';

  const nes = new NES({
    onFrame: function(buffer) {
      for (let i = 0; i < 256 * 240; i++) {
        currentFrame[i] = buffer[i];
      }
    },
    onAudioSample: function() {}
  });

  nes.loadROM(romData);

  for (const step of gameSpec.bootPlan) {
    if (step.btn !== undefined) {
      nes.buttonDown(1, step.btn);
      for (let i = 0; i < (step.hold || 4); i++) nes.frame();
      nes.buttonUp(1, step.btn);
    }
    for (let i = 0; i < (step.wait || 0); i++) nes.frame();
  }

  for (let i = 0; i < 256; i++) {
    const b = nes.ppu.spriteMem[i] & 0xFF;
    nes.cpu.mem[0x0200 + i] = b;
    if (gameSpec.oamPage && gameSpec.oamPage !== 0x0200) {
      nes.cpu.mem[gameSpec.oamPage + i] = b;
    }
  }

  return { nes, currentFrame, romBytes, mirroring, prgBanks, chrBanks };
}

export function extractGameState(gameSpec) {
  const { nes, romBytes, mirroring, prgBanks, chrBanks } = bootToGameplay(gameSpec);
  const vram = nes.ppu.vramMem;

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

  const nt0_1024 = [...nametable960, ...attrib64];

  const nt1Base = mirroring === 'horizontal' ? 0x2800 : 0x2400;
  const nt1_1024 = [];
  for (let i = 0; i < 1024; i++) {
    nt1_1024.push(vram[nt1Base + i] & 0xFF);
  }

  const oam256 = [];
  const visibleSprites = [];
  for (let i = 0; i < 256; i++) {
    oam256.push(nes.ppu.spriteMem[i] & 0xFF);
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
  const baseNt = ((nes.ppu.regV & 1) << 1) | (nes.ppu.regH & 1);
  const ppuctrl = 0x80 | (spSize ? 0x20 : 0x00) | (bgPt ? 0x10 : 0x00) | (spPt ? 0x08 : 0x00) | baseNt;
  const scrollX = ((nes.ppu.regHT & 0x1F) << 3) | (nes.ppu.regFH & 0x07);
  const scrollY = ((nes.ppu.regVT & 0x1F) << 3) | (nes.ppu.regFV & 0x07);

  const state = {
    id: gameSpec.id,
    symbol: gameSpec.symbol,
    title: gameSpec.title,
    romFile: gameSpec.romFile,
    prgBanks,
    chrBanks,
    mirroring,
    bgPatternTable: bgPt,
    spPatternTable: spPt,
    baseNt,
    ppuctrl,
    scrollX,
    scrollY,
    palette32,
    nametable960,
    attrib64,
    nt0: nt0_1024,
    nt1: nt1_1024,
    oam256,
    visibleSpritesCount: visibleSprites.length,
    visibleSprites
  };

  const outPath = path.join(outDir, `${gameSpec.id}_state.json`);
  fs.writeFileSync(outPath, JSON.stringify(state, null, 2));
  console.log(
    `[${gameSpec.id.padEnd(14)}] mir=${mirroring.padEnd(10)} BG_PT=${bgPt} SP_PT=${spPt} PPUCTRL=0x${ppuctrl.toString(16)} ` +
    `scroll=(${scrollX},${scrollY}) visOAM=${String(visibleSprites.length).padStart(2)} pal0..3=[${palette32.slice(0, 4).map(x => '0x' + x.toString(16).padStart(2, '0')).join(',')}]`
  );
  return state;
}

if (process.argv[1] && path.resolve(process.argv[1]) === __filename) {
  for (const g of TOP10_GAMES) {
    extractGameState(g);
  }
}
