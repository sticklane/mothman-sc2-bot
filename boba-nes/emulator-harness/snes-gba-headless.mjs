import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const SNESJS_DIR = path.join(__dirname, 'vendor', 'snesjs', 'snes');
const GBAJS2_DIR = path.join(__dirname, 'vendor', 'gbajs2');

// ============================================================================
// 1. Headless SnesJs Context & Wrapper (256x224 RGB24 + Joypad Input)
// ============================================================================

const SNES_FILES = [
  'cart.js',
  'dsp.js',
  'spc.js',
  'apu.js',
  'pipu.js',
  'cpu.js',
  'snes.js',
];

const snesSourceBundle =
  SNES_FILES.map((f) => fs.readFileSync(path.join(SNESJS_DIR, f), 'utf8')).join('\n') +
  '\nglobalThis.Snes = Snes;\n';

export const SNES_BUTTONS = {
  B: 0,
  Y: 1,
  SELECT: 2,
  START: 3,
  UP: 4,
  DOWN: 5,
  LEFT: 6,
  RIGHT: 7,
  A: 8,
  X: 9,
  L: 10,
  R: 11,
};

export function detectSnesHiRom(romBuf) {
  let raw = romBuf;
  if ((raw.length - 512) % 0x8000 === 0) {
    raw = raw.subarray(512);
  }
  const scoreHeader = (off, expectHi) => {
    if (off + 0x40 > raw.length) return -999;
    let score = 0;
    const mapMode = raw[off + 0x15];
    const isHiBit = (mapMode & 1) === 1;
    if (isHiBit === expectHi) score += 4;
    const romSizeByte = raw[off + 0x17];
    if (romSizeByte >= 7 && romSizeByte <= 13) score += 2;
    const comp = raw[off + 0x1c] | (raw[off + 0x1d] << 8);
    const chk = raw[off + 0x1e] | (raw[off + 0x1f] << 8);
    if (((comp ^ chk) & 0xffff) === 0xffff) score += 6;
    const resetVec = raw[off + 0x3c] | (raw[off + 0x3d] << 8);
    if (resetVec >= 0x8000) score += 4;
    let ascii = 0;
    for (let i = 0; i < 21; i++) {
      const c = raw[off + i];
      if (c >= 0x20 && c <= 0x7e) ascii++;
    }
    if (ascii >= 14) score += 3;
    return score;
  };
  const loScore = scoreHeader(0x7fc0, false);
  const hiScore = scoreHeader(0xffc0, true);
  return hiScore > loScore;
}

export class HeadlessSnes {
  constructor() {
    const sandbox = {
      Uint8Array,
      Uint16Array,
      Int16Array,
      Int32Array,
      Float64Array,
      Array,
      Math,
      String,
      header: undefined,
      log: () => {},
      getByteRep: (v) => ('0' + (v & 0xff).toString(16)).slice(-2).toUpperCase(),
      getWordRep: (v) => ('000' + (v & 0xffff).toString(16)).slice(-4).toUpperCase(),
      getLongRep: (v) => ('00000' + (v & 0xffffff).toString(16)).slice(-6).toUpperCase(),
      clearArray: (arr) => arr.fill(0),
    };
    sandbox.globalThis = sandbox;
    vm.createContext(sandbox);
    vm.runInContext(snesSourceBundle, sandbox);
    this.snes = new sandbox.Snes();
    this.isHirom = false;
  }

  loadRom(romBuf, forceHirom = null) {
    const arr = new Uint8Array(romBuf.buffer, romBuf.byteOffset, romBuf.byteLength);
    this.isHirom = forceHirom !== null ? forceHirom : detectSnesHiRom(romBuf);
    const ok = this.snes.loadRom(arr, this.isHirom);
    if (!ok) {
      throw new Error(`SnesJs failed to load ROM (${romBuf.length} bytes)`);
    }
    this.snes.reset(true);
    return true;
  }

  setButtons(mask) {
    this.snes.joypad1State = mask & 0xfff;
  }

  pressButtons(buttonNames = []) {
    let mask = 0;
    for (const name of buttonNames) {
      if (SNES_BUTTONS[name] !== undefined) {
        mask |= 1 << SNES_BUTTONS[name];
      }
    }
    this.setButtons(mask);
  }

  stepFrame(noPpu = false) {
    this.snes.runFrame(noPpu);
  }

  extractRgb24() {
    const rgb = Buffer.alloc(256 * 224 * 3);
    const out = this.snes.ppu.pixelOutput;
    let dst = 0;
    for (let y = 0; y < 224; y++) {
      const lineBase = (y + 1) * 1536;
      for (let x = 0; x < 256; x++) {
        const pOff = lineBase + x * 6;
        const r = (out[pOff] + out[pOff + 3]) >> 1;
        const g = (out[pOff + 1] + out[pOff + 4]) >> 1;
        const b = (out[pOff + 2] + out[pOff + 5]) >> 1;
        rgb[dst++] = r & 0xff;
        rgb[dst++] = g & 0xff;
        rgb[dst++] = b & 0xff;
      }
    }
    return rgb;
  }
}

// ============================================================================
// 2. Headless gbajs2 Context & Wrapper (240x160 RGB24 + Keypad Input)
// ============================================================================

const GBA_FILES = [
  'js/util.js',
  'js/core.js',
  'js/arm.js',
  'js/thumb.js',
  'js/mmu.js',
  'js/io.js',
  'js/audio.js',
  'js/video.js',
  'js/video/software.js',
  'js/irq.js',
  'js/keypad.js',
  'js/sio.js',
  'js/savedata.js',
  'js/gpio.js',
  'js/gba.js',
];

const gbaSourceBundle =
  GBA_FILES.map((f) => fs.readFileSync(path.join(GBAJS2_DIR, f), 'utf8')).join('\n') +
  '\nglobalThis.GameBoyAdvance = GameBoyAdvance;\n';

const gbaBiosBuf = fs.readFileSync(path.join(GBAJS2_DIR, 'resources', 'bios.bin'));
const gbaBiosArrayBuffer = gbaBiosBuf.buffer.slice(
  gbaBiosBuf.byteOffset,
  gbaBiosBuf.byteOffset + gbaBiosBuf.byteLength
);

export const GBA_BUTTONS = {
  A: 0,
  B: 1,
  SELECT: 2,
  START: 3,
  RIGHT: 4,
  LEFT: 5,
  UP: 6,
  DOWN: 7,
  R: 8,
  L: 9,
};

export class HeadlessGba {
  constructor() {
    const windowStub = {
      addEventListener: () => {},
      removeEventListener: () => {},
      setTimeout,
      clearTimeout,
      URL: {},
      atob: (s) => Buffer.from(s, 'base64').toString('binary'),
      btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
    };
    const sandbox = {
      window: windowStub,
      document: {
        createElement: () => ({
          setAttribute: () => {},
          getContext: () => null,
        }),
      },
      navigator: {
        getGamepads: () => [],
      },
      localStorage: {
        getItem: () => null,
        setItem: () => {},
      },
      console: {
        log: () => {},
        warn: () => {},
        error: () => {},
      },
      ArrayBuffer,
      DataView,
      Uint8Array,
      Uint8ClampedArray,
      Int8Array,
      Uint16Array,
      Int16Array,
      Uint32Array,
      Int32Array,
      Float32Array,
      Float64Array,
      Array,
      Object,
      Math,
      String,
      Number,
      Boolean,
      Date,
      Error,
      setTimeout,
      clearTimeout,
      atob: windowStub.atob,
      btoa: windowStub.btoa,
    };
    sandbox.globalThis = sandbox;
    sandbox.self = sandbox;
    vm.createContext(sandbox);
    vm.runInContext(gbaSourceBundle, sandbox);

    this.gba = new sandbox.GameBoyAdvance();
    this.gba.logLevel = 0;

    this.pixelData = {
      width: 240,
      height: 160,
      data: new Uint8ClampedArray(240 * 160 * 4),
    };
    const mockContext = {
      createImageData: () => this.pixelData,
      putImageData: () => {},
    };
    this.gba.setCanvasDirect({
      getContext: () => mockContext,
    });
    this.gba.setBios(gbaBiosArrayBuffer);
  }

  loadRom(romBuf) {
    const ab = romBuf.buffer.slice(romBuf.byteOffset, romBuf.byteOffset + romBuf.byteLength);
    const ok = this.gba.setRom(ab);
    if (!ok) {
      throw new Error(`gbajs2 failed to load ROM (${romBuf.length} bytes)`);
    }
    return true;
  }

  setButtons(mask) {
    // GBA KEYINPUT is active-low (0 = pressed, 1 = released) across bits 0..9
    this.gba.keypad.currentDown = (~mask) & 0x03ff;
  }

  pressButtons(buttonNames = []) {
    let mask = 0;
    for (const name of buttonNames) {
      if (GBA_BUTTONS[name] !== undefined) {
        mask |= 1 << GBA_BUTTONS[name];
      }
    }
    this.setButtons(mask);
  }

  stepFrame() {
    this.gba.advanceFrame();
  }

  extractRgb24() {
    const rgb = Buffer.alloc(240 * 160 * 3);
    const rgba = this.pixelData.data;
    let dst = 0;
    for (let i = 0; i < 240 * 160 * 4; i += 4) {
      rgb[dst++] = rgba[i];
      rgb[dst++] = rgba[i + 1];
      rgb[dst++] = rgba[i + 2];
    }
    return rgb;
  }
}

export function analyzeRgb24(rgb, width, height) {
  const colors = new Set();
  let transitions = 0;
  let nonBlack = 0;
  let nonWhite = 0;
  const total = width * height;
  for (let i = 0; i < total; i++) {
    const off = i * 3;
    const r = rgb[off];
    const g = rgb[off + 1];
    const b = rgb[off + 2];
    const key = (r << 16) | (g << 8) | b;
    colors.add(key);
    if (r > 8 || g > 8 || b > 8) nonBlack++;
    if (r < 247 || g < 247 || b < 247) nonWhite++;
    if (i > 0) {
      const pOff = (i - 1) * 3;
      if (rgb[pOff] !== r || rgb[pOff + 1] !== g || rgb[pOff + 2] !== b) {
        transitions++;
      }
    }
  }
  return {
    uniqueColors: colors.size,
    transitions,
    nonBlackPct: Number(((nonBlack / total) * 100).toFixed(1)),
    nonWhitePct: Number(((nonWhite / total) * 100).toFixed(1)),
  };
}
