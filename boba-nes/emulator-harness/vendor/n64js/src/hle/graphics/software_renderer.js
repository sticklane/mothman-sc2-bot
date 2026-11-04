import * as gbi from './gbi.js';
import * as rdp_blend from './rdp_blend_constants.js';
import { RendererBase } from './renderer_base.js';
import { getTexturePaletteFormat } from './texture_format.js';

const G_IM_FMT_RGBA = 0;
const G_IM_FMT_YUV = 1;
const G_IM_FMT_CI = 2;
const G_IM_FMT_IA = 3;
const G_IM_FMT_I = 4;

const G_IM_SIZ_4b = 0;
const G_IM_SIZ_8b = 1;
const G_IM_SIZ_16b = 2;
const G_IM_SIZ_32b = 3;

const TLUT_NONE = 0;
const TLUT_RGBA16 = 2;
const TLUT_IA16 = 3;

function shiftFactor(shift) {
  if (shift <= 10) {
    return 1 / (1 << shift);
  }
  return 1 << (16 - shift);
}

function clamp01(v) {
  return v < 0 ? 0 : v > 1 ? 1 : v;
}

function clamp255(v) {
  return v < 0 ? 0 : v > 255 ? 255 : v | 0;
}

export class SoftwareRenderer extends RendererBase {
  constructor(state, width = 320, height = 240) {
    super(state);
    this.width = width;
    this.height = height;
    this.targets = new Map();
    this.fallback = this.createTarget(width, height);
    this.current = this.fallback;
    this.depthBuffer = new Float32Array(width * height);
    this.depthBuffer.fill(1.0);
    this.drawCount = 0;
    this.triCount = 0;
    this.texRectCount = 0;
    this.fillRectCount = 0;
    this.taskCount = 0;
    this.bestSnapshot = null;
  }

  createTarget(width = this.width, height = this.height) {
    return {
      width,
      height,
      pixels: new Uint8Array(width * height * 4),
      image: null,
      dirty: false,
      drawOps: 0,
    };
  }

  reset() {
    this.targets.clear();
    this.fallback = this.createTarget(this.width, this.height);
    this.current = this.fallback;
    this.depthBuffer.fill(1.0);
    this.drawCount = 0;
    this.triCount = 0;
    this.texRectCount = 0;
    this.fillRectCount = 0;
    this.taskCount = 0;
    this.bestSnapshot = null;
  }

  newFrame() {}

  scorePixels(pixels) {
    const colors = new Set();
    let nonBlack = 0;
    let nonWhite = 0;
    let transitions = 0;
    let prev = -1;
    const total = this.width * this.height;
    for (let i = 0; i < total; i++) {
      const o = i * 4;
      const r = pixels[o];
      const g = pixels[o + 1];
      const b = pixels[o + 2];
      const c = (r << 16) | (g << 8) | b;
      colors.add(c);
      if (r > 8 || g > 8 || b > 8) nonBlack++;
      if (r < 247 || g < 247 || b < 247) nonWhite++;
      if (prev !== -1 && c !== prev) transitions++;
      prev = c;
    }
    const activePixels = Math.min(nonBlack, nonWhite);
    const score = colors.size * 25 + Math.min(transitions, 40000) + Math.floor(activePixels * 0.25);
    return { uniqueColors: colors.size, activePixels, transitions, score };
  }

  onTaskComplete() {
    this.taskCount++;
    if (!this.current || this.current.drawOps === 0) return;
    const stats = this.scorePixels(this.current.pixels);
    if (stats.uniqueColors >= 2 && (!this.bestSnapshot || stats.score >= this.bestSnapshot.score)) {
      this.bestSnapshot = {
        width: this.width,
        height: this.height,
        pixels: new Uint8Array(this.current.pixels),
        image: this.current.image ? { ...this.current.image } : null,
        drawOps: this.current.drawOps,
        uniqueColors: stats.uniqueColors,
        activePixels: stats.activePixels,
        transitions: stats.transitions,
        score: stats.score,
        taskIndex: this.taskCount,
      };
    }
  }

  debugClear() {
    this.current.pixels.fill(0);
    this.depthBuffer.fill(1.0);
  }

  setColorImage(image) {
    if (
      image.format !== gbi.ImageFormat.G_IM_FMT_RGBA ||
      (image.size !== gbi.ImageSize.G_IM_SIZ_16b && image.size !== gbi.ImageSize.G_IM_SIZ_32b)
    ) {
      this.current = this.fallback;
      return;
    }
    const key = image.address;
    let target = this.targets.get(key);
    if (!target) {
      target = this.createTarget(this.width, this.height);
      target.image = { ...image };
      this.targets.set(key, target);
      if (this.targets.size > 12) {
        const oldest = this.targets.keys().next().value;
        this.targets.delete(oldest);
      }
    } else {
      target.image = { ...image };
    }
    this.current = target;
  }

  syncFramebufferToRAM(address, ramDV) {
    if (!ramDV) return;
    for (const target of this.targets.values()) {
      if (!target.dirty || !target.image) continue;
      const bytesPerPixel = target.image.size === gbi.ImageSize.G_IM_SIZ_32b ? 4 : 2;
      const byteLen = target.image.width * this.height * bytesPerPixel;
      if (address >= target.image.address && address < target.image.address + byteLen) {
        this.writeTargetToRAM(target, ramDV);
      }
    }
  }

  writeTargetToRAM(target, ramDV) {
    if (!target || !target.image || !ramDV) return;
    const img = target.image;
    const imgW = Math.min(img.width || 320, 640);
    const imgH = Math.min(this.nativeTransform.viHeight || 240, 480);
    const pixels = target.pixels;
    const w = this.width;
    const h = this.height;

    if (img.size === gbi.ImageSize.G_IM_SIZ_32b) {
      for (let y = 0; y < imgH; y++) {
        const sy = Math.min(h - 1, Math.floor((y * h) / imgH));
        for (let x = 0; x < imgW; x++) {
          const sx = Math.min(w - 1, Math.floor((x * w) / imgW));
          const src = (sy * w + sx) * 4;
          const dst = img.address + (y * img.width + x) * 4;
          if (dst >= 0 && dst + 4 <= ramDV.byteLength) {
            ramDV.setUint32(
              dst,
              ((pixels[src] << 24) | (pixels[src + 1] << 16) | (pixels[src + 2] << 8) | pixels[src + 3]) >>> 0
            );
          }
        }
      }
    } else {
      for (let y = 0; y < imgH; y++) {
        const sy = Math.min(h - 1, Math.floor((y * h) / imgH));
        for (let x = 0; x < imgW; x++) {
          const sx = Math.min(w - 1, Math.floor((x * w) / imgW));
          const src = (sy * w + sx) * 4;
          const dst = img.address + (y * img.width + x) * 2;
          if (dst >= 0 && dst + 2 <= ramDV.byteLength) {
            const r5 = pixels[src] >>> 3;
            const g5 = pixels[src + 1] >>> 3;
            const b5 = pixels[src + 2] >>> 3;
            const a1 = pixels[src + 3] >>> 7;
            ramDV.setUint16(dst, (r5 << 11) | (g5 << 6) | (b5 << 1) | a1);
          }
        }
      }
    }
    target.dirty = false;
  }

  flushAllTargetsToRAM(ramDV) {
    if (!ramDV) return;
    if (this.current && this.current.dirty && this.current.image) {
      this.writeTargetToRAM(this.current, ramDV);
    }
  }

  getBestTargetForVI(viAddress) {
    let candidate = null;
    const cleanAddr = viAddress & 0x00fffffe;
    if (cleanAddr) {
      for (const [addr, target] of this.targets.entries()) {
        if (Math.abs(addr - cleanAddr) <= 0x2000 && target.drawOps > 0) {
          candidate = target;
          break;
        }
      }
    }
    if (!candidate) {
      candidate = this.current;
      for (const target of this.targets.values()) {
        if (target.drawOps >= (candidate?.drawOps || 0)) {
          candidate = target;
        }
      }
    }
    if (this.bestSnapshot) {
      const candScore = candidate ? this.scorePixels(candidate.pixels).score : 0;
      if (this.bestSnapshot.score > candScore) {
        return this.bestSnapshot;
      }
    }
    return candidate || this.fallback;
  }

  observeGraphicsMode() {
    if (this.onGraphicsMode) {
      this.onGraphicsMode({
        otherModeH: this.state.rdpOtherModeH & 0x00ffffff,
        otherModeL: this.state.rdpOtherModeL >>> 0,
        combineHi: this.state.combine.hi >>> 0,
        combineLo: this.state.combine.lo >>> 0,
      });
    }
  }

  getScissorBounds() {
    const { viWidth, viHeight } = this.nativeTransform;
    const vw = viWidth > 0 ? viWidth : 320;
    const vh = viHeight > 0 ? viHeight : 240;
    const { x0, y0, x1, y1 } = this.state.scissor;
    const left = Math.max(0, Math.min(this.width, Math.round((x0 * this.width) / vw)));
    const right = Math.max(0, Math.min(this.width, Math.round((x1 * this.width) / vw)));
    const top = Math.max(0, Math.min(this.height, Math.round((y0 * this.height) / vh)));
    const bottom = Math.max(0, Math.min(this.height, Math.round((y1 * this.height) / vh)));
    return { left, top, right, bottom, vw, vh };
  }

  clearDepth(depth = 1.0) {
    this.observeGraphicsMode();
    const { left, top, right, bottom } = this.getScissorBounds();
    const w = this.width;
    for (let y = top; y < bottom; y++) {
      const row = y * w;
      for (let x = left; x < right; x++) {
        this.depthBuffer[row + x] = depth;
      }
    }
  }

  clearColor(color) {
    this.observeGraphicsMode();
    const { left, top, right, bottom } = this.getScissorBounds();
    const r = clamp255(Math.round(color.r * 255));
    const g = clamp255(Math.round(color.g * 255));
    const b = clamp255(Math.round(color.b * 255));
    const a = clamp255(Math.round(color.a * 255));
    const pixels = this.current.pixels;
    const w = this.width;
    for (let y = top; y < bottom; y++) {
      for (let x = left; x < right; x++) {
        const idx = (y * w + x) * 4;
        pixels[idx] = r;
        pixels[idx + 1] = g;
        pixels[idx + 2] = b;
        pixels[idx + 3] = a;
      }
    }
    this.current.dirty = true;
    this.current.drawOps++;
    this.drawCount++;
  }

  fillRect(x0, y0, x1, y1, color) {
    this.observeGraphicsMode();
    const { left, top, right, bottom, vw, vh } = this.getScissorBounds();
    const sx0 = Math.max(left, Math.floor((x0 * this.width) / vw));
    const sy0 = Math.max(top, Math.floor((y0 * this.height) / vh));
    const sx1 = Math.min(right, Math.ceil((x1 * this.width) / vw));
    const sy1 = Math.min(bottom, Math.ceil((y1 * this.height) / vh));
    if (sx1 <= sx0 || sy1 <= sy0) return;

    const cycleType = this.state.getCycleType();
    let r, g, b, a;
    if (cycleType === gbi.CycleType.G_CYC_FILL) {
      r = clamp255(Math.round(color.r * 255));
      g = clamp255(Math.round(color.g * 255));
      b = clamp255(Math.round(color.b * 255));
      a = 255;
    } else {
      const comb = this.evaluateCombiner(1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 1);
      r = clamp255(Math.round(comb[0] * 255));
      g = clamp255(Math.round(comb[1] * 255));
      b = clamp255(Math.round(comb[2] * 255));
      a = clamp255(Math.round(comb[3] * 255));
    }

    const pixels = this.current.pixels;
    const w = this.width;
    const blendMode = this.getBlendMode();
    for (let y = sy0; y < sy1; y++) {
      for (let x = sx0; x < sx1; x++) {
        const idx = (y * w + x) * 4;
        this.writeBlendedPixel(pixels, idx, r, g, b, a, blendMode);
      }
    }
    this.current.dirty = true;
    this.current.drawOps++;
    this.fillRectCount++;
    this.drawCount++;
  }

  // TMEM physical byte & texel decoding (matches shaders/tmem.glsl)
  readTMEM8(address) {
    return this.state.tmem.tmemData[address & 0xfff];
  }

  readTMEM16(address) {
    const tmem = this.state.tmem.tmemData;
    return (tmem[address & 0xfff] << 8) | tmem[(address + 1) & 0xfff];
  }

  decodeRGBA16(value, out) {
    const r5 = (value >>> 11) & 31;
    const g5 = (value >>> 6) & 31;
    const b5 = (value >>> 1) & 31;
    out[0] = (r5 << 3) | (r5 >>> 2);
    out[1] = (g5 << 3) | (g5 >>> 2);
    out[2] = (b5 << 3) | (b5 >>> 2);
    out[3] = (value & 1) * 255;
  }

  decodeIA16(value, out) {
    const i = (value >>> 8) & 0xff;
    out[0] = i;
    out[1] = i;
    out[2] = i;
    out[3] = value & 0xff;
  }

  fetchTMEMTexel(coordX, coordY, tile, tlutMode, paletteBank, out) {
    const row = (tile.tmem << 3) + coordY * (tile.line << 3);
    const swizzle = (coordY & 1) << 2;
    const format = tile.format;
    const size = tile.size;

    if (format === G_IM_FMT_YUV && size === G_IM_SIZ_16b) {
      const pair = ((row + (coordX & ~1)) ^ swizzle) & 2047;
      const luma = (((row + coordX) ^ swizzle) & 2047) | 2048;
      out[0] = this.readTMEM8(pair);
      out[1] = this.readTMEM8(pair + 1);
      out[2] = this.readTMEM8(luma);
      out[3] = 255;
      return;
    }
    if (format === G_IM_FMT_RGBA && size === G_IM_SIZ_32b) {
      const address = ((row + coordX * 2) ^ swizzle) & 2047;
      out[0] = this.readTMEM8(address);
      out[1] = this.readTMEM8(address + 1);
      out[2] = this.readTMEM8(address | 2048);
      out[3] = this.readTMEM8((address | 2048) + 1);
      return;
    }
    if (size === G_IM_SIZ_16b) {
      const value = this.readTMEM16(((row + coordX * 2) ^ swizzle) & 4095);
      if (format === G_IM_FMT_RGBA) {
        this.decodeRGBA16(value, out);
        return;
      }
      if (format === G_IM_FMT_IA) {
        this.decodeIA16(value, out);
        return;
      }
    }
    if (size <= G_IM_SIZ_8b) {
      const address = (row + (size === G_IM_SIZ_4b ? coordX >> 1 : coordX)) ^ swizzle;
      let value = this.readTMEM8(address & (tlutMode !== TLUT_NONE ? 2047 : 4095));
      if (size === G_IM_SIZ_4b) {
        value = (value >>> ((1 - (coordX & 1)) * 4)) & 15;
      }
      if (tlutMode !== TLUT_NONE) {
        const index = size === G_IM_SIZ_4b ? (tile.palette << 4) | value : value;
        const entry = this.readTMEM16(2048 + index * 8 + paletteBank * 2);
        if (tlutMode === TLUT_IA16) {
          this.decodeIA16(entry, out);
        } else {
          this.decodeRGBA16(entry, out);
        }
        return;
      }
      if (format === G_IM_FMT_IA) {
        if (size === G_IM_SIZ_4b) {
          let i = value >>> 1;
          i = (i << 5) | (i << 2) | (i >>> 1);
          out[0] = i;
          out[1] = i;
          out[2] = i;
          out[3] = (value & 1) * 255;
          return;
        }
        const i = (value >>> 4) * 17;
        out[0] = i;
        out[1] = i;
        out[2] = i;
        out[3] = (value & 15) * 17;
        return;
      }
      if (format === G_IM_FMT_RGBA || format === G_IM_FMT_I) {
        const i = size === G_IM_SIZ_4b ? value * 17 : value;
        out[0] = i;
        out[1] = i;
        out[2] = i;
        out[3] = i;
        return;
      }
    }
    out[0] = 0;
    out[1] = 0;
    out[2] = 0;
    out[3] = 255;
  }

  clampCoord(coord, high, last, mode) {
    if ((mode & 2) === 0) return coord;
    return coord >= high ? last : Math.max(coord, 0.0);
  }

  maskCoord(coord, mask, mode) {
    if (mask === 0) return coord;
    const period = 1 << Math.min(mask, 10);
    if ((mode & 1) !== 0 && (coord & period) !== 0) {
      coord = ~coord;
    }
    return coord & (period - 1);
  }

  sampleTile(u, v, tile, texGenEnabled, out) {
    if (!tile || tile.format < 0) {
      out[0] = 0;
      out[1] = 0;
      out[2] = 0;
      out[3] = 1;
      return;
    }
    const scaleS = shiftFactor(tile.shiftS) * (texGenEnabled ? tile.width : 1);
    const scaleT = shiftFactor(tile.shiftT) * (texGenEnabled ? tile.height : 1);
    const offsetS = texGenEnabled ? 0 : tile.left;
    const offsetT = texGenEnabled ? 0 : tile.top;

    const clampBoundaryS = tile.right - tile.left;
    const clampBoundaryT = tile.bottom - tile.top;
    const clampTexelS = ((tile.lrs >>> 2) - (tile.uls >>> 2)) & 0x3ff;
    const clampTexelT = ((tile.lrt >>> 2) - (tile.ult >>> 2)) & 0x3ff;

    const copy = this.state.getCycleType() === gbi.CycleType.G_CYC_COPY;
    const modeS = copy ? tile.cmS & gbi.G_TX_MIRROR : tile.cmS | (tile.maskS === 0 ? gbi.G_TX_CLAMP : 0);
    const modeT = copy ? tile.cmT & gbi.G_TX_MIRROR : tile.cmT | (tile.maskT === 0 ? gbi.G_TX_CLAMP : 0);

    let coordX = Math.floor((u * scaleS - offsetS) * 32.0) / 32.0;
    let coordY = Math.floor((v * scaleT - offsetT) * 32.0) / 32.0;
    coordX = this.clampCoord(coordX, clampBoundaryS, clampTexelS, modeS);
    coordY = this.clampCoord(coordY, clampBoundaryT, clampTexelT, modeT);

    const baseX = Math.floor(coordX);
    const baseY = Math.floor(coordY);
    const tlutMode = getTexturePaletteFormat(tile, this.state.getTextureLUTType()) >>> gbi.G_MDSFT_TEXTLUT;

    const filter = copy ? gbi.TextureFilter.G_TF_POINT : this.state.getTextureFilterType();
    const filterMode = filter >>> gbi.G_MDSFT_TEXTFILT;

    const t00 = [0, 0, 0, 255];
    if (filterMode < 2) {
      const mx = this.maskCoord(baseX, tile.maskS, modeS);
      const my = this.maskCoord(baseY, tile.maskT, modeT);
      this.fetchTMEMTexel(mx, my, tile, tlutMode, 0, t00);
      out[0] = t00[0] / 255.0;
      out[1] = t00[1] / 255.0;
      out[2] = t00[2] / 255.0;
      out[3] = t00[3] / 255.0;
    } else {
      const wx = (coordX - baseX) * 32.0;
      const wy = (coordY - baseY) * 32.0;
      const bankXor = wx + wy >= 32.0 ? 3 : 0;
      const t10 = [0, 0, 0, 255];
      const t01 = [0, 0, 0, 255];
      this.fetchTMEMTexel(
        this.maskCoord(baseX + 1, tile.maskS, modeS),
        this.maskCoord(baseY, tile.maskT, modeT),
        tile,
        tlutMode,
        1 ^ bankXor,
        t10
      );
      this.fetchTMEMTexel(
        this.maskCoord(baseX, tile.maskS, modeS),
        this.maskCoord(baseY + 1, tile.maskT, modeT),
        tile,
        tlutMode,
        2 ^ bankXor,
        t01
      );
      if ( wx + wy < 32.0) {
        this.fetchTMEMTexel(
          this.maskCoord(baseX, tile.maskS, modeS),
          this.maskCoord(baseY, tile.maskT, modeT),
          tile,
          tlutMode,
          bankXor,
          t00
        );
        for (let c = 0; c < 4; c++) {
          const val = t00[c] + ((t10[c] - t00[c]) * wx + (t01[c] - t00[c]) * wy) / 32.0;
          out[c] = Math.floor(val + 0.5) / 255.0;
        }
      } else {
        const t11 = [0, 0, 0, 255];
        this.fetchTMEMTexel(
          this.maskCoord(baseX + 1, tile.maskS, modeS),
          this.maskCoord(baseY + 1, tile.maskT, modeT),
          tile,
          tlutMode,
          3 ^ bankXor,
          t11
        );
        for (let c = 0; c < 4; c++) {
          const val = t11[c] + ((t01[c] - t11[c]) * (32.0 - wx) + (t10[c] - t11[c]) * (32.0 - wy)) / 32.0;
          out[c] = Math.floor(val + 0.5) / 255.0;
        }
      }
    }

    if (tile.format === G_IM_FMT_YUV) {
      const k = this.state.convert;
      const uChroma = out[0] * 255.0 - 128.0;
      const vChroma = out[1] * 255.0 - 128.0;
      const yLuma = out[2] * 255.0;
      const c0 = (k[0] * 2 + 1) / 256.0;
      const c1 = (k[1] * 2 + 1) / 256.0;
      const c2 = (k[2] * 2 + 1) / 256.0;
      const c3 = (k[3] * 2 + 1) / 256.0;
      out[0] = (yLuma + Math.floor(c0 * vChroma + 0.5)) / 255.0;
      out[1] = (yLuma + Math.floor(c1 * uChroma + c2 * vChroma + 0.5)) / 255.0;
      out[2] = (yLuma + Math.floor(c3 * uChroma + 0.5)) / 255.0;
      out[3] = yLuma / 255.0;
    }
  }

  // Evaluates the N64 RDP 1-cycle / 2-cycle / Copy / Fill color combiner
  evaluateCombiner(sr, sg, sb, sa, t0r, t0g, t0b, t0a, t1r, t1g, t1b, t1a) {
    const cycleType = this.state.getCycleType();
    if (cycleType === gbi.CycleType.G_CYC_FILL) {
      return [sr, sg, sb, sa];
    }
    if (cycleType === gbi.CycleType.G_CYC_COPY) {
      return [t0r, t0g, t0b, t0a];
    }

    const mux0 = this.state.combine.hi >>> 0;
    const mux1 = this.state.combine.lo >>> 0;

    const prim = this.state.primColor >>> 0;
    const pr = ((prim >>> 24) & 0xff) / 255.0;
    const pg = ((prim >>> 16) & 0xff) / 255.0;
    const pb = ((prim >>> 8) & 0xff) / 255.0;
    const pa = (prim & 0xff) / 255.0;
    const plod = (this.state.primLodFrac & 0xff) / 255.0;

    const env = this.state.envColor >>> 0;
    const er = ((env >>> 24) & 0xff) / 255.0;
    const eg = ((env >>> 16) & 0xff) / 255.0;
    const eb = ((env >>> 8) & 0xff) / 255.0;
    const ea = (env & 0xff) / 255.0;

    const k4 = this.state.convert[4] / 255.0;
    const k5 = this.state.convert[5] / 256.0;

    let cr = 0, cg = 0, cb = 0, ca = 1;

    const getRGB = (sel, cycle, isSubB, isMul) => {
      const tx0r = cycle === 0 ? t0r : t1r;
      const tx0g = cycle === 0 ? t0g : t1g;
      const tx0b = cycle === 0 ? t0b : t1b;
      const tx0a = cycle === 0 ? t0a : t1a;
      const tx1r = cycle === 0 ? t1r : t0r;
      const tx1g = cycle === 0 ? t1g : t0g;
      const tx1b = cycle === 0 ? t1b : t0b;
      const tx1a = cycle === 0 ? t1a : t0a;

      switch (sel) {
        case 0: return [cr, cg, cb];
        case 1: return [tx0r, tx0g, tx0b];
        case 2: return [tx1r, tx1g, tx1b];
        case 3: return [pr, pg, pb];
        case 4: return [sr, sg, sb];
        case 5: return [er, eg, eb];
        case 6: return [1, 1, 1];
        case 7:
          if (isMul) return [ca, ca, ca];
          if (isSubB) return [k4, k4, k4];
          return [0, 0, 0];
        case 8: return isMul ? [tx0a, tx0a, tx0a] : [0, 0, 0];
        case 9: return isMul ? [tx1a, tx1a, tx1a] : [0, 0, 0];
        case 10: return isMul ? [pa, pa, pa] : [0, 0, 0];
        case 11: return isMul ? [sa, sa, sa] : [0, 0, 0];
        case 12: return isMul ? [ea, ea, ea] : [0, 0, 0];
        case 13: return [0, 0, 0]; // lod_frac
        case 14: return isMul ? [plod, plod, plod] : [0, 0, 0];
        case 15: return isMul ? [k5, k5, k5] : [0, 0, 0];
        default: return [0, 0, 0];
      }
    };

    const getA = (sel, cycle, isMul) => {
      const tx0a = cycle === 0 ? t0a : t1a;
      const tx1a = cycle === 0 ? t1a : t0a;
      switch (sel) {
        case 0: return isMul ? 0 : ca;
        case 1: return tx0a;
        case 2: return tx1a;
        case 3: return pa;
        case 4: return sa;
        case 5: return ea;
        case 6: return isMul ? plod : 1;
        default: return 0;
      }
    };

    const aRGB0 = (mux0 >>> 20) & 0x0f;
    const bRGB0 = (mux1 >>> 28) & 0x0f;
    const cRGB0 = (mux0 >>> 15) & 0x1f;
    const dRGB0 = (mux1 >>> 15) & 0x07;
    const aA0 = (mux0 >>> 12) & 0x07;
    const bA0 = (mux1 >>> 12) & 0x07;
    const cA0 = (mux0 >>> 9) & 0x07;
    const dA0 = (mux1 >>> 9) & 0x07;

    const A0 = getRGB(aRGB0, 0, false, false);
    const B0 = getRGB(bRGB0, 0, true, false);
    const C0 = getRGB(cRGB0, 0, false, true);
    const D0 = getRGB(dRGB0, 0, false, false);
    const nr0 = (A0[0] - B0[0]) * C0[0] + D0[0];
    const ng0 = (A0[1] - B0[1]) * C0[1] + D0[1];
    const nb0 = (A0[2] - B0[2]) * C0[2] + D0[2];
    const na0 = (getA(aA0, 0, false) - getA(bA0, 0, false)) * getA(cA0, 0, true) + getA(dA0, 0, false);

    cr = nr0;
    cg = ng0;
    cb = nb0;
    ca = na0;

    if (cycleType === gbi.CycleType.G_CYC_2CYCLE) {
      const aRGB1 = (mux0 >>> 5) & 0x0f;
      const bRGB1 = (mux1 >>> 24) & 0x0f;
      const cRGB1 = (mux0 >>> 0) & 0x1f;
      const dRGB1 = (mux1 >>> 6) & 0x07;
      const aA1 = (mux1 >>> 21) & 0x07;
      const bA1 = (mux1 >>> 3) & 0x07;
      const cA1 = (mux1 >>> 18) & 0x07;
      const dA1 = (mux1 >>> 0) & 0x07;

      const A1 = getRGB(aRGB1, 1, false, false);
      const B1 = getRGB(bRGB1, 1, true, false);
      const C1 = getRGB(cRGB1, 1, false, true);
      const D1 = getRGB(dRGB1, 1, false, false);
      const nr1 = (A1[0] - B1[0]) * C1[0] + D1[0];
      const ng1 = (A1[1] - B1[1]) * C1[1] + D1[1];
      const nb1 = (A1[2] - B1[2]) * C1[2] + D1[2];
      const na1 = (getA(aA1, 1, false) - getA(bA1, 1, false)) * getA(cA1, 1, true) + getA(dA1, 1, false);
      cr = nr1;
      cg = ng1;
      cb = nb1;
      ca = na1;
    }

    return [clamp01(cr), clamp01(cg), clamp01(cb), clamp01(ca)];
  }

  getBlendMode() {
    const cycleType = this.state.getCycleType();
    if (cycleType === gbi.CycleType.G_CYC_FILL || cycleType === gbi.CycleType.G_CYC_COPY) {
      return 1; // Opaque
    }
    const cvgXAlpha = this.state.getCoverageTimesAlpha();
    const alphaCvgSel = this.state.getAlphaCoverageSelect();
    const blendMode = this.state.rdpOtherModeL >> gbi.G_MDSFT_BLENDER;
    const activeBlendMode = (cycleType === gbi.CycleType.G_CYC_2CYCLE ? blendMode : blendMode >>> 2) & 0x3333;

    switch (activeBlendMode) {
      case rdp_blend.kIncomingColorWithSourceAlpha:
      case rdp_blend.kIncomingColorWithMemoryAlpha:
        if (!alphaCvgSel || cvgXAlpha) {
          return 2; // AlphaTrans
        }
        return 1;
      case rdp_blend.kZeroIncomingWithFramebuffer:
      case rdp_blend.kZeroFramebufferWithFramebuffer:
        return 3; // Fade
      default:
        return 1; // Opaque
    }
  }

  passesAlphaTest(alphaFloat) {
    const enableAlphaThreshold = (this.state.getAlphaCompareType() & gbi.AlphaCompare.G_AC_THRESHOLD) !== 0;
    const enableAlphaCvgKill = this.state.getAntiAliasEnabled() && this.state.getCoverageTimesAlpha();
    if (enableAlphaThreshold) {
      const thresh = ((this.state.blendColor >>> 0) & 0xff) / 255.0;
      const cmp = this.state.getAlphaCompareType() === gbi.AlphaCompare.G_AC_THRESHOLD;
      if (cmp ? alphaFloat < thresh : alphaFloat <= thresh) return false;
    }
    if (enableAlphaCvgKill && alphaFloat <= 0.0) {
      return false;
    }
    return true;
  }

  writeBlendedPixel(pixels, idx, r, g, b, a, blendMode) {
    if (blendMode === 2) {
      const invA = 255 - a;
      pixels[idx] = (r * a + pixels[idx] * invA) >>> 8;
      pixels[idx + 1] = (g * a + pixels[idx + 1] * invA) >>> 8;
      pixels[idx + 2] = (b * a + pixels[idx + 2] * invA) >>> 8;
      pixels[idx + 3] = 255;
    } else if (blendMode === 3) {
      const invA = 255 - a;
      pixels[idx] = (pixels[idx] * invA) >>> 8;
      pixels[idx + 1] = (pixels[idx + 1] * invA) >>> 8;
      pixels[idx + 2] = (pixels[idx + 2] * invA) >>> 8;
      pixels[idx + 3] = 255;
    } else {
      pixels[idx] = r;
      pixels[idx + 1] = g;
      pixels[idx + 2] = b;
      pixels[idx + 3] = 255;
    }
  }

  texRect(tileIdx, x0, y0, x1, y1, s0, t0, s1, t1, flip) {
    this.observeGraphicsMode();
    this.observeTextureUse(tileIdx);
    if (x1 === x0 || y1 === y0) return;

    const { left, top, right, bottom, vw, vh } = this.getScissorBounds();
    const sx0 = Math.max(left, Math.floor((x0 * this.width) / vw));
    const sy0 = Math.max(top, Math.floor((y0 * this.height) / vh));
    const sx1 = Math.min(right, Math.ceil((x1 * this.width) / vw));
    const sy1 = Math.min(bottom, Math.ceil((y1 * this.height) / vh));
    if (sx1 <= sx0 || sy1 <= sy0) return;

    const dsdx = (s1 - s0) / (flip ? y1 - y0 : x1 - x0);
    const dtdy = (t1 - t0) / (flip ? x1 - x0 : y1 - y0);

    const tile0 = this.state.tiles[tileIdx & 7];
    const singleLevelLOD =
      (this.state.rdpOtherModeH & gbi.G_TL_MASK) !== 0 &&
      this.state.texture.level === 0 &&
      (this.state.rdpOtherModeH & gbi.TextureDetail.G_TD_DETAIL) === 0;
    const tile1 =
      this.getTextureTileCount() === 2 ? this.state.tiles[(tileIdx + (singleLevelLOD ? 0 : 1)) & 7] : null;

    const copy = this.state.getCycleType() === gbi.CycleType.G_CYC_COPY;
    const origX = copy ? Math.floor(x0) : x0;
    const origY = Math.floor(y0);

    const depthSourcePrim = (this.state.rdpOtherModeL & gbi.DepthSource.G_ZS_PRIM) !== 0;
    const zCmp = depthSourcePrim && (this.state.rdpOtherModeL & gbi.RenderMode.Z_CMP) !== 0;
    const zUpd = depthSourcePrim && (this.state.rdpOtherModeL & gbi.RenderMode.Z_UPD) !== 0;
    const primZ = this.state.primDepth / 0x8000;

    const blendMode = this.getBlendMode();
    const pixels = this.current.pixels;
    const w = this.width;
    const tex0 = [0, 0, 0, 1];
    const tex1 = [0, 0, 0, 1];

    for (let py = sy0; py < sy1; py++) {
      const n64Y = Math.floor((py * vh) / this.height);
      const dy = n64Y - origY;
      for (let px = sx0; px < sx1; px++) {
        const pIdx = py * w + px;
        if (zCmp && primZ > this.depthBuffer[pIdx] + 1e-4) continue;

        const n64X = Math.floor((px * vw) / this.width);
        const dx = n64X - origX;
        const u = s0 + (flip ? dy * dsdx : dx * dsdx);
        const v = t0 + (flip ? dx * dtdy : dy * dtdy);

        this.sampleTile(u, v, tile0, false, tex0);
        if (tile1) {
          this.sampleTile(u, v, tile1, false, tex1);
        }

        const comb = this.evaluateCombiner(
          1, 1, 1, 1,
          tex0[0], tex0[1], tex0[2], tex0[3],
          tex1[0], tex1[1], tex1[2], tex1[3]
        );
        if (!this.passesAlphaTest(comb[3])) continue;
        if (zUpd) this.depthBuffer[pIdx] = primZ;

        const r = clamp255(Math.round(comb[0] * 255));
        const g = clamp255(Math.round(comb[1] * 255));
        const b = clamp255(Math.round(comb[2] * 255));
        const a = clamp255(Math.round(comb[3] * 255));
        this.writeBlendedPixel(pixels, pIdx * 4, r, g, b, a, blendMode);
      }
    }
    this.current.dirty = true;
    this.current.drawOps++;
    this.texRectCount++;
    this.drawCount++;
  }

  texRectRot(tileIdx, x0, y0, x1, y1, x2, y2, x3, y3, s0, t0, s1, t1) {
    const vertices = this.nativeTransform.calculateRectVerticesRot(x0, y0, x1, y1, x2, y2, x3, y3, 0);
    const uvs = [s0, t0, s1, t0, s0, t1, s1, t1];
    const colours = [0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff];
    this.lleRect(tileIdx, vertices, uvs, colours);
  }

  lleRect(tileIdx, vertices, uvs, colours, textureRect = null) {
    this.observeGraphicsMode();
    this.observeTextureUse(tileIdx);
    if (textureRect) {
      const { x0, y0, s0, t0, dsdx, dtdy, flip } = textureRect;
      const { viWidth, viHeight } = this.nativeTransform;
      const x1 = ((vertices[4] + 1) * 0.5) * viWidth;
      const y1 = ((1 - vertices[9]) * 0.5) * viHeight;
      const s1 = s0 + dsdx * (flip ? y1 - y0 : x1 - x0);
      const t1 = t0 + dtdy * (flip ? x1 - x0 : y1 - y0);
      this.texRect(tileIdx, x0, y0, x1, y1, s0, t0, s1, t1, flip);
      return;
    }
    // Triangle strip of 4 vertices -> 2 triangles (0,1,2) and (2,1,3)
    const idxPairs = [
      [0, 1, 2],
      [2, 1, 3],
    ];
    for (const [i0, i1, i2] of idxPairs) {
      this.rasterizeClipSpaceTri(
        vertices, i0 * 4, i1 * 4, i2 * 4,
        colours[i0], colours[i1], colours[i2],
        uvs[i0 * 2], uvs[i0 * 2 + 1],
        uvs[i1 * 2], uvs[i1 * 2 + 1],
        uvs[i2 * 2], uvs[i2 * 2 + 1],
        true,
        false,
        tileIdx,
        true
      );
    }
    this.current.dirty = true;
    this.current.drawOps++;
    this.texRectCount++;
    this.drawCount++;
  }

  flushTris(tb, { lines = false, affineUV = false } = {}) {
    if (tb.empty()) return;
    this.observeGraphicsMode();

    const textureEnabled = !lines && Boolean(this.state.geometryMode.texture);
    const texGenEnabled = !lines && Boolean(this.state.geometryMode.lighting && this.state.geometryMode.textureGen);
    if (textureEnabled) {
      this.observeTextureUse(this.state.texture.tile);
    }

    if (textureEnabled && (this.state.rdpOtherModeH & gbi.G_TP_MASK) === 0) {
      for (let i = 0; i < tb.numTris * 6; i++) {
        tb.coords[i] *= 0.5;
      }
    }

    const pos = tb.positions;
    const cols = tb.colours;
    const uvs = tb.coords;
    const tileIdx = this.state.texture.tile;

    for (let t = 0; t < tb.numTris; t++) {
      const pBase = t * 12;
      const cBase = t * 3;
      const uBase = t * 6;
      this.rasterizeClipSpaceTri(
        pos, pBase, pBase + 4, pBase + 8,
        cols[cBase], cols[cBase + 1], cols[cBase + 2],
        uvs[uBase], uvs[uBase + 1],
        uvs[uBase + 2], uvs[uBase + 3],
        uvs[uBase + 4], uvs[uBase + 5],
        textureEnabled,
        texGenEnabled,
        tileIdx,
        affineUV
      );
    }

    this.current.dirty = true;
    this.current.drawOps++;
    this.triCount += tb.numTris;
    this.drawCount++;
    tb.reset();
  }

  rasterizeClipSpaceTri(
    pos, i0, i1, i2,
    col0, col1, col2,
    s0, t0, s1, t1, s2, t2,
    textureEnabled, texGenEnabled, tileIdx, affineUV
  ) {
    const unpackCol = (c) => [
      (c & 0xff) / 255.0,
      ((c >>> 8) & 0xff) / 255.0,
      ((c >>> 16) & 0xff) / 255.0,
      ((c >>> 24) & 0xff) / 255.0,
    ];
    const c0 = unpackCol(col0);
    const c1 = unpackCol(col1);
    const c2 = unpackCol(col2);

    let poly = [
      { x: pos[i0], y: pos[i0 + 1], z: pos[i0 + 2], w: pos[i0 + 3], r: c0[0], g: c0[1], b: c0[2], a: c0[3], s: s0, t: t0 },
      { x: pos[i1], y: pos[i1 + 1], z: pos[i1 + 2], w: pos[i1 + 3], r: c1[0], g: c1[1], b: c1[2], a: c1[3], s: s1, t: t1 },
      { x: pos[i2], y: pos[i2 + 1], z: pos[i2 + 2], w: pos[i2 + 3], r: c2[0], g: c2[1], b: c2[2], a: c2[3], s: s2, t: t2 },
    ];

    // Near plane clip: w >= 0.001
    const clipPlane = (verts, distFn) => {
      const out = [];
      for (let i = 0; i < verts.length; i++) {
        const a = verts[i];
        const b = verts[(i + 1) % verts.length];
        const da = distFn(a);
        const db = distFn(b);
        if (da >= 0) out.push(a);
        if ((da >= 0 && db < 0) || (da < 0 && db >= 0)) {
          const t = da / (da - db);
          out.push({
            x: a.x + t * (b.x - a.x),
            y: a.y + t * (b.y - a.y),
            z: a.z + t * (b.z - a.z),
            w: a.w + t * (b.w - a.w),
            r: a.r + t * (b.r - a.r),
            g: a.g + t * (b.g - a.g),
            b: a.b + t * (b.b - a.b),
            a: a.a + t * (b.a - a.a),
            s: a.s + t * (b.s - a.s),
            t: a.t + t * (b.t - a.t),
          });
        }
      }
      return out;
    };

    poly = clipPlane(poly, (v) => v.w - 0.001);
    if (!this.state.noNearClipping) {
      poly = clipPlane(poly, (v) => v.z + v.w);
    }
    if (poly.length < 3) return;

    for (let k = 1; k + 1 < poly.length; k++) {
      this.rasterizeProjectedTri(
        poly[0],
        poly[k],
        poly[k + 1],
        textureEnabled,
        texGenEnabled,
        tileIdx,
        affineUV
      );
    }
  }

  rasterizeProjectedTri(v0, v1, v2, textureEnabled, texGenEnabled, tileIdx, affineUV) {
    const w = this.width;
    const h = this.height;
    const invW0 = 1.0 / v0.w;
    const invW1 = 1.0 / v1.w;
    const invW2 = 1.0 / v2.w;

    const sx0 = (v0.x * invW0 + 1.0) * 0.5 * w;
    const sy0 = (1.0 - v0.y * invW0) * 0.5 * h;
    const sx1 = (v1.x * invW1 + 1.0) * 0.5 * w;
    const sy1 = (1.0 - v1.y * invW1) * 0.5 * h;
    const sx2 = (v2.x * invW2 + 1.0) * 0.5 * w;
    const sy2 = (1.0 - v2.y * invW2) * 0.5 * h;

    // Signed area in top-down screen coords:
    // In bottom-up NDC, CCW has positive area; in top-down screen space, CCW has negative area.
    const area = (sx1 - sx0) * (sy2 - sy0) - (sy1 - sy0) * (sx2 - sx0);
    if (Math.abs(area) < 1e-5) return;

    if (this.state.geometryMode.cullBack && area > 0) return;
    if (this.state.geometryMode.cullFront && area < 0) return;

    const { left, top, right, bottom } = this.getScissorBounds();
    const minX = Math.max(left, Math.floor(Math.min(sx0, sx1, sx2)));
    const maxX = Math.min(right, Math.ceil(Math.max(sx0, sx1, sx2)));
    const minY = Math.max(top, Math.floor(Math.min(sy0, sy1, sy2)));
    const maxY = Math.min(bottom, Math.ceil(Math.max(sy0, sy1, sy2)));
    if (minX >= maxX || minY >= maxY) return;

    const depthSourcePrim = (this.state.rdpOtherModeL & gbi.DepthSource.G_ZS_PRIM) !== 0;
    const primZ = this.state.primDepth / 0x8000;
    const z0 = depthSourcePrim ? primZ : clamp01(v0.z * invW0 * 0.5 + 0.5);
    const z1 = depthSourcePrim ? primZ : clamp01(v1.z * invW1 * 0.5 + 0.5);
    const z2 = depthSourcePrim ? primZ : clamp01(v2.z * invW2 * 0.5 + 0.5);

    const zGeomMode = this.state.geometryMode.zbuffer !== 0;
    const zCmpRenderMode = (this.state.rdpOtherModeL & gbi.RenderMode.Z_CMP) !== 0;
    const zUpdRenderMode = (this.state.rdpOtherModeL & gbi.RenderMode.Z_UPD) !== 0;
    const zCompare = (zGeomMode || depthSourcePrim) && zCmpRenderMode;
    const isDecal = (this.state.rdpOtherModeL & 0x0c00) === 0x0c00;
    const zBias = isDecal ? 2e-3 : 2e-4;

    let tile0 = null;
    let tile1 = null;
    if (textureEnabled) {
      const tileIdx0 = tileIdx & 7;
      const singleLevelLOD =
        (this.state.rdpOtherModeH & gbi.G_TL_MASK) !== 0 &&
        this.state.texture.level === 0 &&
        (this.state.rdpOtherModeH & gbi.TextureDetail.G_TD_DETAIL) === 0;
      const tileIdx1 = (tileIdx + (singleLevelLOD ? 0 : 1)) & 7;
      tile0 = this.state.tiles[tileIdx0];
      tile1 = this.getTextureTileCount() === 2 ? this.state.tiles[tileIdx1] : null;
    }

    const invArea = 1.0 / area;
    const blendMode = this.getBlendMode();
    const pixels = this.current.pixels;
    const tex0 = [0, 0, 0, 1];
    const tex1 = [0, 0, 0, 1];

    const s0w = affineUV ? v0.s : v0.s * invW0;
    const t0w = affineUV ? v0.t : v0.t * invW0;
    const s1w = affineUV ? v1.s : v1.s * invW1;
    const t1w = affineUV ? v1.t : v1.t * invW1;
    const s2w = affineUV ? v2.s : v2.s * invW2;
    const t2w = affineUV ? v2.t : v2.t * invW2;

    for (let py = minY; py < maxY; py++) {
      const cy = py + 0.5;
      for (let px = minX; px < maxX; px++) {
        const cx = px + 0.5;
        const w0 = ((sx1 - cx) * (sy2 - cy) - (sy1 - cy) * (sx2 - cx)) * invArea;
        const w1 = ((sx2 - cx) * (sy0 - cy) - (sy2 - cy) * (sx0 - cx)) * invArea;
        const w2 = 1.0 - w0 - w1;
        if (w0 < -1e-4 || w1 < -1e-4 || w2 < -1e-4) continue;

        const pIdx = py * w + px;
        const z = w0 * z0 + w1 * z1 + w2 * z2;
        if (zCompare && z > this.depthBuffer[pIdx] + zBias) continue;

        // RDP shade RGBA is affine in screen space
        const sr = w0 * v0.r + w1 * v1.r + w2 * v2.r;
        const sg = w0 * v0.g + w1 * v1.g + w2 * v2.g;
        const sb = w0 * v0.b + w1 * v1.b + w2 * v2.b;
        const sa = clamp01(w0 * v0.a + w1 * v1.a + w2 * v2.a);

        if (textureEnabled && tile0) {
          let u, v;
          if (affineUV) {
            u = w0 * s0w + w1 * s1w + w2 * s2w;
            v = w0 * t0w + w1 * t1w + w2 * t2w;
          } else {
            const invW = w0 * invW0 + w1 * invW1 + w2 * invW2;
            const recW = invW > 1e-8 ? 1.0 / invW : 1.0;
            u = (w0 * s0w + w1 * s1w + w2 * s2w) * recW;
            v = (w0 * t0w + w1 * t1w + w2 * t2w) * recW;
          }
          this.sampleTile(u, v, tile0, texGenEnabled, tex0);
          if (tile1) {
            this.sampleTile(u, v, tile1, texGenEnabled, tex1);
          }
        }

        const comb = this.evaluateCombiner(
          sr, sg, sb, sa,
          tex0[0], tex0[1], tex0[2], tex0[3],
          tex1[0], tex1[1], tex1[2], tex1[3]
        );

        if (!this.passesAlphaTest(comb[3])) continue;
        if (zUpdRenderMode && !isDecal) {
          this.depthBuffer[pIdx] = z;
        }

        const r = clamp255(Math.round(comb[0] * 255));
        const g = clamp255(Math.round(comb[1] * 255));
        const b = clamp255(Math.round(comb[2] * 255));
        const a = clamp255(Math.round(comb[3] * 255));
        this.writeBlendedPixel(pixels, pIdx * 4, r, g, b, a, blendMode);
      }
    }
  }
}
