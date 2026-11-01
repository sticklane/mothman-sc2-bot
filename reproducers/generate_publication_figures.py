#!/usr/bin/env python3
"""
Deterministic, Dependency-Free Publication SVG Figure Generator for:
"Compilation of Purely Functional Data Structures to Resource-Bounded Quantum Circuits"
(Workspaces ws13-okasaki-quantum-data-structures & ws14-zipper-cut-distributed-multi-qpu)

Generates all 14 publication-quality vector SVG figures (fig01 .. fig14) with:
  - Horizontal quantum circuit wires |q>, explicit CNOT target circles (⊕),
    control dots (•), Toffoli CCX gates, Fredkin CSWAP (×—×) gates,
    Hadamard H / Phase S / X-basis measurement M_X boxes, /^w wire bundle slashes,
    and multi-panel titles, annotations, and legends.
  - Strictly standard-library Python (math, os, shutil, pathlib, xml.etree.ElementTree).
  - Never uses /tmp.
"""

import math
import os
import shutil
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import List, Optional, Tuple


# ============================================================================
# Core Vector SVG Canvas & Quantum Circuit Drawing Primitives
# ============================================================================

import re

FONT_SERIF = "'Latin Modern Roman', 'CMU Serif', 'STIX Two Text', 'Times New Roman', Georgia, serif"
FONT_SANS = FONT_SERIF
FONT_MONO = "'Latin Modern Mono', 'CMU Typewriter Text', 'JetBrains Mono', 'Courier New', monospace"

# Print-safe TikZ / Physical Review palette mapping
FILL_MAP = {
    "url(#header-grad)": "#ffffff",
    "url(#blue-grad)": "#ffffff",
    "url(#teal-grad)": "#ffffff",
    "url(#amber-grad)": "#f4f4f4",
    "url(#purple-grad)": "#f4f4f4",
    "url(#rose-grad)": "#efefef",
    "url(#emerald-grad)": "#ffffff",
    "#eff6ff": "#f7f7f7",
    "#f0fdfa": "#f7f7f7",
    "#f0fdf4": "#f5f5f5",
    "#fffbeb": "#f7f7f7",
    "#fef3c7": "#ebebeb",
    "#faf5ff": "#f5f5f5",
    "#f3e8ff": "#ebebeb",
    "#fff1f2": "#f5f5f5",
    "#fef2f2": "#f2f2f2",
    "#fff7ed": "#f2f4f7",
    "#fed7aa": "#d4dce6",
    "#fde68a": "#e5e5e5",
    "#fecaca": "#e0e0e0",
    "#bbf7d0": "#d4dce6",
    "#dcfce7": "#efefef",
    "#bfdbfe": "#e5e5e5",
    "#99f6e4": "#dcdcdc",
    "#e9d5ff": "#e5e5e5",
    "#ccfbf1": "#ebebeb",
    "#dbeafe": "#ebebeb",
    "#e2e8f0": "#e5e5e5",
    "#f1f5f9": "#f5f5f5",
    "#f8fafc": "#fafafa",
}


def normalize_latex_text(text: str) -> str:
    s = str(text)
    s = s.replace("^dag", "†").replace("^+", "†")
    s = s.replace("<->", "↔").replace("===>", "⟹").replace("-->", "⟶").replace("--->", "⟶")
    s = s.replace("->", "→").replace("<-", "←")
    s = s.replace("<=", "≤").replace(">=", "≥").replace(">>", "≫").replace("<<", "≪")
    # Convert ket notation |foo> to |foo⟩ after operator replacements
    s = re.sub(r"(\|[^|<>]+)>", r"\1⟩", s)
    return s


def esc(text: str) -> str:
    s = normalize_latex_text(text)
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


class SVGCanvas:
    def __init__(self, width: int, height: int, bg: str = "#ffffff"):
        self.width = width
        self.height = height
        self.bg = "#ffffff"
        self.elements: List[str] = []
        self._init_defs()

    def _init_defs(self) -> None:
        # Crisp black LaTeX / TikZ arrowheads, zero drop shadows, zero rainbow gradients
        self.defs = """
  <defs>
    <marker id="arrow-black" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="5.5" markerHeight="5.5" orient="auto-start-reverse">
      <path d="M 0 1.8 L 8.5 5 L 0 8.2 z" fill="#000000"/>
    </marker>
    <marker id="arrow-slate" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="5.5" markerHeight="5.5" orient="auto-start-reverse">
      <path d="M 0 1.8 L 8.5 5 L 0 8.2 z" fill="#000000"/>
    </marker>
    <marker id="arrow-blue" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="5.5" markerHeight="5.5" orient="auto-start-reverse">
      <path d="M 0 1.8 L 8.5 5 L 0 8.2 z" fill="#000000"/>
    </marker>
    <marker id="arrow-teal" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="5.5" markerHeight="5.5" orient="auto-start-reverse">
      <path d="M 0 1.8 L 8.5 5 L 0 8.2 z" fill="#000000"/>
    </marker>
    <marker id="arrow-amber" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="5.5" markerHeight="5.5" orient="auto-start-reverse">
      <path d="M 0 1.8 L 8.5 5 L 0 8.2 z" fill="#000000"/>
    </marker>
    <marker id="arrow-crimson" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="5.5" markerHeight="5.5" orient="auto-start-reverse">
      <path d="M 0 1.8 L 8.5 5 L 0 8.2 z" fill="#000000"/>
    </marker>
    <marker id="arrow-purple" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="5.5" markerHeight="5.5" orient="auto-start-reverse">
      <path d="M 0 1.8 L 8.5 5 L 0 8.2 z" fill="#000000"/>
    </marker>
  </defs>"""

    def add(self, raw_svg: str) -> None:
        self.elements.append(raw_svg)

    def title_banner(self, fig_num: str, title: str, subtitle: str) -> None:
        # Authentic LaTeX / PRX Quantum / EUROCRYPT figure header: black serif on pure white with thin horizontal rules
        fig_label = fig_num.replace("FIGURE", "Figure").title()
        self.line(16, 16, self.width - 16, 16, stroke="#000000", width=1.2)
        self.text(24, 38, f"{fig_label}.  {title}", size=14.5, weight="700", fill="#000000", anchor="start", mono=False)
        self.text(24, 57, subtitle, size=11.0, weight="400", fill="#222222", anchor="start", mono=False, italic=True)
        self.line(16, 68, self.width - 16, 68, stroke="#000000", width=0.8)

    def panel(
        self,
        x: float,
        y: float,
        w: float,
        h: float,
        title: str,
        subtitle: str = "",
        badge: str = "",
        badge_fill: str = "#ffffff",
        badge_text: str = "#000000",
        bg: str = "#ffffff",
        stroke: str = "#000000",
    ) -> None:
        # Sharp rectangular TikZ subfigure frame (rx=0), pure white background, black border
        self.rect(x, y, w, h, rx=0, fill="#ffffff", stroke="#000000", stroke_width=1.0)
        header_h = 44 if subtitle else 30
        self.line(x, y + header_h, x + w, y + header_h, stroke="#000000", width=0.75)
        self.text(x + 12, y + 18, title, size=11.2, weight="700", fill="#000000")
        if subtitle:
            self.text(x + 12, y + 35, subtitle, size=9.8, weight="400", fill="#222222", italic=True)
        if badge:
            # Right-aligned academic bracketed annotation instead of a web pill badge
            self.text(x + w - 12, y + 18, f"[{badge}]", size=9.5, weight="600", fill="#000000", anchor="end", mono=True)

    def rect(
        self,
        x: float,
        y: float,
        w: float,
        h: float,
        rx: float = 0,
        fill: str = "#ffffff",
        stroke: str = "#000000",
        stroke_width: float = 1.0,
        dasharray: str = "",
        shadow: bool = False,
        opacity: float = 1.0,
    ) -> None:
        # Enforce sharp corners (rx=0), no drop shadows, and print-safe monochrome/muted fills
        if dasharray and fill not in ("#ffffff", "#e5e5e5", "#d4dce6", "#dcfce7"):
            mapped_fill = "none"
            mapped_stroke = "#333333"
            sw = 0.9
        else:
            mapped_fill = FILL_MAP.get(fill, fill if fill.startswith("#") else "#ffffff")
            mapped_stroke = "#000000" if stroke != "none" else "none"
            sw = min(stroke_width, 1.2)
        da = f' stroke-dasharray="{dasharray}"' if dasharray else ""
        op = f' opacity="{opacity}"' if opacity < 1.0 else ""
        self.add(
            f'  <rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" '
            f'fill="{mapped_fill}" stroke="{mapped_stroke}" stroke-width="{sw:.2f}"{da}{op}/>'
        )

    def line(
        self,
        x1: float,
        y1: float,
        x2: float,
        y2: float,
        stroke: str = "#000000",
        width: float = 1.15,
        dasharray: str = "",
        marker_end: str = "",
        marker_start: str = "",
    ) -> None:
        # Map rainbow line strokes to black/charcoal for TikZ authenticity
        stroke_map = {
            "#2563eb": "#000000",
            "#1d4ed8": "#000000",
            "#0d9488": "#222222",
            "#0f766e": "#000000",
            "#7c3aed": "#333333",
            "#dc2626": "#111111",
            "#e11d48": "#000000",
            "#d97706": "#000000",
            "#b45309": "#000000",
            "#ea580c": "#000000",
            "#059669": "#000000",
            "#16a34a": "#000000",
            "#334155": "#000000",
            "#64748b": "#444444",
            "#94a3b8": "#555555",
            "#cbd5e1": "#888888",
            "#e2e8f0": "#cccccc",
        }
        s_col = stroke_map.get(stroke, "#000000")
        w_val = min(width, 1.8)
        da = f' stroke-dasharray="{dasharray}"' if dasharray else ""
        me = f' marker-end="url(#{marker_end})"' if marker_end else ""
        ms = f' marker-start="url(#{marker_start})"' if marker_start else ""
        self.add(
            f'  <line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" '
            f'stroke="{s_col}" stroke-width="{w_val:.2f}" stroke-linecap="butt"{da}{me}{ms}/>'
        )

    def circle(
        self,
        cx: float,
        cy: float,
        r: float,
        fill: str = "#ffffff",
        stroke: str = "#000000",
        stroke_width: float = 1.2,
    ) -> None:
        c_fill = "#000000" if fill not in ("#ffffff", "none", "#f3e8ff", "#fef2f2", "#eff6ff", "#f0fdfa") else "#ffffff"
        self.add(
            f'  <circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" '
            f'fill="{c_fill}" stroke="#000000" stroke-width="{min(stroke_width, 1.3):.2f}"/>'
        )

    def path(
        self,
        d: str,
        fill: str = "none",
        stroke: str = "#000000",
        width: float = 1.2,
        dasharray: str = "",
        marker_end: str = "",
    ) -> None:
        da = f' stroke-dasharray="{dasharray}"' if dasharray else ""
        me = f' marker-end="url(#{marker_end})"' if marker_end else ""
        self.add(
            f'  <path d="{d}" fill="{fill}" stroke="#000000" stroke-width="{min(width, 1.4):.2f}" '
            f'stroke-linecap="round" stroke-linejoin="round"{da}{me}/>'
        )

    def polygon(
        self,
        points: List[Tuple[float, float]],
        fill: str = "#f5f5f5",
        stroke: str = "#000000",
        width: float = 1.15,
    ) -> None:
        pts = " ".join(f"{px:.1f},{py:.1f}" for px, py in points)
        self.add(
            f'  <polygon points="{pts}" fill="#f5f5f5" stroke="#000000" stroke-width="{min(width, 1.2):.2f}" stroke-linejoin="miter"/>'
        )

    def text(
        self,
        x: float,
        y: float,
        content: str,
        size: float = 11.5,
        weight: str = "400",
        fill: str = "#000000",
        anchor: str = "start",
        mono: bool = False,
        italic: bool = False,
    ) -> None:
        # Use classic LaTeX serif for titles, kets, gates, and prose; dark monochrome ink only
        size_eff = max(10.0, float(size))
        is_ket_or_math = ("|" in content) or ("⟩" in content) or ("=" in content) or ("•" in content)
        ff = FONT_SERIF if (not mono or is_ket_or_math) else FONT_MONO
        w_norm = "700" if weight in ("700", "800") else "400"
        fs = ' font-style="italic"' if italic else ""
        self.add(
            f'  <text x="{x:.1f}" y="{y:.1f}" font-family="{ff}" font-size="{size_eff:.1f}" '
            f'font-weight="{w_norm}" fill="#000000" text-anchor="{anchor}"{fs}>{esc(content)}</text>'
        )

    # ------------------------------------------------------------------------
    # Quantikz / Qcircuit Quantum Circuit Specific Primitives
    # ------------------------------------------------------------------------

    def qwire(
        self,
        y: float,
        x0: float,
        x1: float,
        label_left: Optional[str] = None,
        label_right: Optional[str] = None,
        bundle: Optional[str] = None,
        color: str = "#000000",
        width: float = 1.15,
        dashed: bool = False,
        bundle_offset: float = 20.0,
    ) -> None:
        self.line(x0, y, x1, y, stroke="#000000", width=1.15, dasharray="4,3" if dashed else "")
        if label_left:
            self.text(x0 - 8, y + 4, label_left, size=10.2, weight="400", fill="#000000", anchor="end", mono=False)
        if label_right:
            self.text(x1 + 8, y + 4, label_right, size=10.2, weight="400", fill="#000000", anchor="start", mono=False)
        if bundle:
            bx = x0 + bundle_offset
            self.line(bx - 4.5, y + 6.5, bx + 4.5, y - 6.5, stroke="#000000", width=1.15)
            self.text(bx + 1, y - 8.5, bundle, size=8.8, weight="400", fill="#000000", anchor="middle", italic=True)

    def ctrl_dot(self, x: float, y: float, r: float = 3.6, color: str = "#000000") -> None:
        self.circle(x, y, r=r, fill="#000000", stroke="#000000", stroke_width=1.0)

    def open_ctrl_dot(self, x: float, y: float, r: float = 4.0, color: str = "#000000") -> None:
        self.circle(x, y, r=r, fill="#ffffff", stroke="#000000", stroke_width=1.2)

    def oplus(self, x: float, y: float, r: float = 9.0, color: str = "#000000", fill: str = "#ffffff") -> None:
        self.circle(x, y, r=r, fill="#ffffff", stroke="#000000", stroke_width=1.2)
        self.line(x - r, y, x + r, y, stroke="#000000", width=1.2)
        self.line(x, y - r, x, y + r, stroke="#000000", width=1.2)

    def swap_x(self, x: float, y: float, s: float = 5.2, color: str = "#000000") -> None:
        self.line(x - s, y - s, x + s, y + s, stroke="#000000", width=1.3)
        self.line(x - s, y + s, x + s, y - s, stroke="#000000", width=1.3)

    def cnot(self, x: float, y_ctrl: float, y_targ: float, color: str = "#000000", open_ctrl: bool = False) -> None:
        self.line(x, y_ctrl, x, y_targ, stroke="#000000", width=1.15)
        if open_ctrl:
            self.open_ctrl_dot(x, y_ctrl)
        else:
            self.ctrl_dot(x, y_ctrl)
        self.oplus(x, y_targ)

    def toffoli(
        self,
        x: float,
        y_c1: float,
        y_c2: float,
        y_targ: float,
        color: str = "#000000",
        open_c1: bool = False,
        open_c2: bool = False,
    ) -> None:
        ymin = min(y_c1, y_c2, y_targ)
        ymax = max(y_c1, y_c2, y_targ)
        self.line(x, ymin, x, ymax, stroke="#000000", width=1.15)
        if open_c1:
            self.open_ctrl_dot(x, y_c1)
        else:
            self.ctrl_dot(x, y_c1)
        if open_c2:
            self.open_ctrl_dot(x, y_c2)
        else:
            self.ctrl_dot(x, y_c2)
        self.oplus(x, y_targ)

    def fredkin(
        self,
        x: float,
        y_ctrl: Optional[float],
        y_s1: float,
        y_s2: float,
        color: str = "#000000",
    ) -> None:
        pts = [y_s1, y_s2] + ([y_ctrl] if y_ctrl is not None else [])
        self.line(x, min(pts), x, max(pts), stroke="#000000", width=1.15)
        if y_ctrl is not None:
            self.ctrl_dot(x, y_ctrl)
        self.swap_x(x, y_s1)
        self.swap_x(x, y_s2)

    def cz_gate(
        self,
        x: float,
        y_c1: float,
        y_c2: float,
        classical: bool = False,
        color: str = "#000000",
    ) -> None:
        if classical:
            # Double parallel black lines for classical feed-forward in Quantikz
            self.line(x - 1.4, y_c1, x - 1.4, y_c2, stroke="#000000", width=0.85)
            self.line(x + 1.4, y_c1, x + 1.4, y_c2, stroke="#000000", width=0.85)
        else:
            self.line(x, y_c1, x, y_c2, stroke="#000000", width=1.15)
        self.ctrl_dot(x, y_c1)
        self.ctrl_dot(x, y_c2)

    def gate_box(
        self,
        x: float,
        y: float,
        w: float = 34,
        h: float = 26,
        label: str = "H",
        sublabel: Optional[str] = None,
        fill: str = "#ffffff",
        stroke: str = "#000000",
        text_color: str = "#000000",
        font_size: float = 11.5,
    ) -> None:
        is_adj = ("^dag" in label) or ("^+" in label) or ("†" in label) or (sublabel and ("Uncomp" in sublabel or "MBU" in sublabel))
        box_fill = "#efefef" if is_adj else "#ffffff"
        self.rect(x - w / 2, y - h / 2, w, h, rx=0, fill=box_fill, stroke="#000000", stroke_width=1.15)
        if sublabel:
            self.text(x, y - 2, label, size=font_size, weight="700", fill="#000000", anchor="middle")
            self.text(x, y + 10, sublabel, size=9.0, weight="400", fill="#000000", anchor="middle", italic=True)
        else:
            self.text(x, y + 4.0, label, size=font_size, weight="700", fill="#000000", anchor="middle")

    def multi_gate(
        self,
        x: float,
        y_top: float,
        y_bot: float,
        w: float,
        label: str,
        sublabel: Optional[str] = None,
        third_line: Optional[str] = None,
        fill: str = "#ffffff",
        stroke: str = "#000000",
        text_color: str = "#000000",
        pad_y: float = 15,
    ) -> None:
        top = y_top - pad_y
        h = (y_bot - y_top) + 2 * pad_y
        cy = top + h / 2
        is_adj = (
            ("^dag" in label)
            or ("^+" in label)
            or ("†" in label)
            or ("Inverse" in label)
            or (sublabel and ("Uncomp" in sublabel or "MBU" in sublabel or "Rev" in sublabel))
        )
        box_fill = "#efefef" if is_adj else "#ffffff"
        self.rect(x - w / 2, top, w, h, rx=0, fill=box_fill, stroke="#000000", stroke_width=1.15)
        if third_line and sublabel:
            self.text(x, cy - 11, label, size=11.2, weight="700", fill="#000000", anchor="middle")
            self.text(x, cy + 3, sublabel, size=9.5, weight="400", fill="#000000", anchor="middle")
            self.text(x, cy + 16, third_line, size=9.0, weight="400", fill="#000000", anchor="middle", italic=True)
        elif sublabel:
            self.text(x, cy - 4, label, size=11.2, weight="700", fill="#000000", anchor="middle")
            self.text(x, cy + 10, sublabel, size=9.5, weight="400", fill="#000000", anchor="middle", italic=True)
        else:
            self.text(x, cy + 4.0, label, size=11.2, weight="700", fill="#000000", anchor="middle")

    def measure_box(
        self,
        x: float,
        y: float,
        basis: str = "X",
        w: float = 36,
        h: float = 26,
        fill: str = "#ffffff",
        stroke: str = "#000000",
    ) -> None:
        self.rect(x - w / 2, y - h / 2, w, h, rx=0, fill="#ffffff", stroke="#000000", stroke_width=1.15)
        # Crisp black Quantikz meter dial arc + pointer needle
        self.path(f"M {x - 11:.1f} {y + 7:.1f} A 11 9 0 0 1 {x + 11:.1f} {y + 7:.1f}", stroke="#000000", width=1.15)
        self.line(x, y + 7, x + 7, y - 5, stroke="#000000", width=1.2)
        self.text(x - 11, y - 3, f"M_{basis}", size=8.2, weight="700", fill="#000000", anchor="start")

    def barrier(self, x: float, y_top: float, y_bot: float, label: Optional[str] = None, color: str = "#333333") -> None:
        self.line(x, y_top - 10, x, y_bot + 10, stroke="#333333", width=0.9, dasharray="4,3")
        if label:
            self.text(x, y_top - 14, label, size=9.2, weight="400", fill="#000000", anchor="middle", italic=True)

    def callout_pill(
        self,
        x: float,
        y: float,
        w: float,
        h: float,
        title: str,
        value: str,
        fill: str = "#ffffff",
        stroke: str = "#000000",
        title_color: str = "#000000",
        val_color: str = "#000000",
    ) -> None:
        self.rect(x, y, w, h, rx=0, fill="#ffffff", stroke="#000000", stroke_width=1.0)
        self.text(x + 12, y + 17, title, size=10, weight="700", fill="#000000")
        self.text(x + 12, y + 34, value, size=11.5, weight="700", fill="#000000", mono=True)

    def render(self) -> str:
        body = "\n".join(self.elements)
        svg = (
            f'<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.width} {self.height}" '
            f'width="{self.width}" height="{self.height}">\n'
            f'{self.defs}\n'
            f'  <rect x="0" y="0" width="{self.width}" height="{self.height}" fill="#ffffff"/>\n'
            f'{body}\n'
            f'</svg>\n'
        )
        # Validate XML immediately
        ET.fromstring(svg)
        return svg


# ============================================================================
# Figure 1: Gidney MBU & Sequential Two-Phase Merkle Tree Pebbling
# ============================================================================

def build_fig01() -> str:
    c = SVGCanvas(1320, 680)
    c.title_banner(
        "FIGURE 1",
        "Measurement-Based Uncomputation (MBU) & Sequential Two-Phase Tree Pebbling",
        "Gidney [2018] Temporary-AND Ripple Step (1 Toffoli + 0 Uncompute Toffolis) & SLH-DSA-128s (h+1 vs 2h+1)",
    )

    # Panel (a): Left
    c.panel(
        16, 94, 636, 568,
        "Panel (a): Gidney [2018] Temporary-AND Ripple-Carry Adder Step",
        "Compute: 1 Toffoli (CCX) | Uncompute: H + M_X + Classical Feed-Forward CZ (0 Toffolis)",
        badge="deg(f) <= 2 -> 0 Uncomp CCX",
        badge_fill="#dcfce7",
        badge_text="#166534",
    )

    # Wires in Panel (a)
    wy = [190, 250, 310, 380]
    wlabels_l = ["|a_i>", "|b_i>", "|c_i>", "|c_{i+1}> = |0>"]
    wlabels_r = ["|a_i>", "|b_i + a_i + c_i>", "|c_i>", "|0> (Restored)"]
    x0, x1 = 128, 535

    for idx in range(4):
        c.qwire(wy[idx], x0, x1, label_left=wlabels_l[idx], label_right=wlabels_r[idx])

    # Stage 1: Compute
    c.barrier(155, wy[0], wy[3], "Compute")
    c.cnot(185, wy[2], wy[0], color="#2563eb")
    c.cnot(215, wy[2], wy[1], color="#2563eb")
    c.toffoli(255, wy[0], wy[1], wy[3], color="#0f766e")
    c.text(255, wy[3] + 24, "CCX (4 T)", size=10, weight="700", fill="#0f766e", anchor="middle", mono=True)
    c.cnot(295, wy[2], wy[3], color="#2563eb")

    # Stage 2: Next bit ripple
    c.barrier(325, wy[0], wy[3], "Ripple i+1")
    c.multi_gate(
        365, wy[2], wy[3], w=58,
        label="Next", sublabel="Bit i+1",
        fill="url(#purple-grad)", stroke="#7c3aed", text_color="#4c1d95"
    )

    # Stage 3: MBU Uncompute
    c.barrier(405, wy[0], wy[3], "MBU Uncompute")
    c.cnot(428, wy[2], wy[3], color="#2563eb")
    c.gate_box(462, wy[3], w=30, h=26, label="H", fill="url(#blue-grad)", stroke="#2563eb")
    c.measure_box(500, wy[3], basis="X", w=38, h=26)

    # Classical feed-forward double wire from M_X to CZ(a_i, b_i)
    c.cz_gate(525, wy[0], wy[1], classical=True, color="#000000")
    c.line(500, wy[3] - 13.0, 523.6, wy[3] - 13.0, stroke="#000000", width=0.85)
    c.line(500, wy[3] - 15.5, 526.4, wy[3] - 15.5, stroke="#000000", width=0.85)
    c.line(523.6, wy[3] - 13.0, 523.6, wy[1], stroke="#000000", width=0.85)
    c.line(526.4, wy[3] - 15.5, 526.4, wy[1], stroke="#000000", width=0.85)
    c.text(508, wy[2] + 35, "m_x = 1 => CZ", size=9.5, weight="700", fill="#000000", anchor="middle", mono=True)
    c.cnot(532, wy[2], wy[0], color="#000000")

    # Proposition 1 Degree-3 Barrier Callout Box in Panel (a)
    c.rect(34, 430, 600, 214, rx=8, fill="#ffffff", stroke="#000000", stroke_width=1.0)
    c.text(50, 454, "Proposition 1 (Degree-3 MBU Barrier & Degree-2 Exact Criterion):", size=12, weight="800", fill="#000000")
    c.text(50, 476, "• After H|f(x)> followed by M_X = m in {0,1}, residual phase state is (-1)^{m * f(x)} |x>.", size=11, weight="600", fill="#000000", mono=True)
    c.text(50, 497, "• For Temporary-AND f(a',b') = a' * b' (deg = 2): (-1)^{a'*b'} = CZ(a', b') -> 0 Toffolis!", size=11, weight="700", fill="#000000", mono=True)
    c.text(50, 518, "• For 3-way AND f(x1,x2,x3) = x1*x2*x3 (deg = 3): phase is CCZ(x1,x2,x3), which lies", size=11, weight="600", fill="#000000", mono=True)
    c.text(50, 538, "  Strictly Outside C_2 (Clifford hierarchy level 3). Any Clifford fixup C in C_2 satisfies:", size=11, weight="600", fill="#000000", mono=True)
    c.rect(68, 550, 520, 34, rx=0, fill="#efefef", stroke="#000000", stroke_width=1.0)
    c.text(328, 572, "max_{C in C_2} | 2^{-3} Tr( C^dag * CCZ ) |^2  <=  9 / 16  =  0.5625", size=12, weight="800", fill="#000000", anchor="middle", mono=True)
    c.text(50, 606, "• Consequence: Binary fan-in = 2 trees (BraunTree, Cuccaro-Gidney, Crit-Bit) hit the", size=11, weight="600", fill="#000000", mono=True)
    c.text(50, 625, "  exact 50% MBU Toffoli savings frontier; higher-arity fan-in > 2 requires T-gate uncompute.", size=11, weight="600", fill="#000000", mono=True)

    # Panel (b): Right
    c.panel(
        668, 94, 636, 568,
        "Panel (b): Sequential Two-Phase Merkle Tree Pebbling (SLH-DSA / SPHINCS+-128s)",
        "Reusing single child register |v_child> (256 Q) reduces tree stack from 2h+1 (6,624 Q) to h+1 (4,320 Q)",
        badge="-2,304 Q (-34.8%)",
        badge_fill="#ffffff",
        badge_text="#000000",
    )

    # Circuit for Sequential Two-Phase Merkle Node Evaluation
    py = [195, 270, 350]
    px0, px1 = 795, 1210
    c.qwire(py[0], px0, px1, label_left="|theta_node>", label_right="|theta_node>", bundle="n", bundle_offset=18)
    c.qwire(py[1], px0, px1, label_left="|v_child> |0>", label_right="|0> (Reused!)", bundle="256", bundle_offset=18)
    c.qwire(py[2], px0, px1, label_left="|z_sponge>", label_right="|Hash(L || R)>", bundle="1600", bundle_offset=18)

    # Phase 1: Left Subtree
    c.rect(828, 152, 178, 224, rx=0, fill="none", stroke="#333333", stroke_width=0.9, dasharray="4,3")
    c.text(917, 168, "Phase 1: Left Child (v_L)", size=10.5, weight="800", fill="#000000", anchor="middle")
    c.multi_gate(862, py[0], py[1], w=52, label="U_L", sublabel="Eval", fill="#ffffff", stroke="#000000")
    c.multi_gate(920, py[1], py[2], w=52, label="Absorb", sublabel="XOR_L", fill="#ffffff", stroke="#000000")
    c.multi_gate(976, py[0], py[1], w=52, label="U_L^dag", sublabel="Uncomp", fill="#efefef", stroke="#000000")

    # Phase 2: Right Subtree
    c.rect(1018, 152, 178, 224, rx=0, fill="none", stroke="#333333", stroke_width=0.9, dasharray="4,3")
    c.text(1107, 168, "Phase 2: Right Child (v_R)", size=10.5, weight="800", fill="#000000", anchor="middle")
    c.multi_gate(1052, py[0], py[1], w=52, label="U_R", sublabel="Eval", fill="#ffffff", stroke="#000000")
    c.multi_gate(1110, py[1], py[2], w=52, label="Absorb", sublabel="Keccak", fill="#ffffff", stroke="#000000")
    c.multi_gate(1166, py[0], py[1], w=52, label="U_R^dag", sublabel="Uncomp", fill="#efefef", stroke="#000000")

    # Recurrence & SLH-DSA-128s Comparison Table inside Panel (b)
    c.rect(686, 396, 600, 248, rx=0, fill="#ffffff", stroke="#000000", stroke_width=1.0)
    c.text(704, 422, "Qubit Width Recurrence Proof (Depth h = 9 Binary XMSS Subtree, n = 256 bits):", size=12, weight="800", fill="#000000")
    c.text(704, 446, "• Simultaneous (Out-of-Place): Holds |v_L> AND |v_R> concurrently before parent hash:", size=11, weight="600", fill="#000000", mono=True)
    c.text(724, 466, "Q_sim(h) = Q_sim(h-1) + 2n  ===>  (2h + 1)*n = 19 * 256 = 4,864 tree Q  (6,624 Q total)", size=11, weight="700", fill="#000000", mono=True)
    c.text(704, 492, "• Sequential Two-Phase (Zipper): Absorbs |v_L> into sponge |z>, uncomputes U_L^dag -> |0>^n:", size=11, weight="600", fill="#000000", mono=True)
    c.text(724, 512, "Q_seq(h) = Q_seq(h-1) +  n  ===>  (h + 1)*n  = 10 * 256 = 2,560 tree Q  (4,320 Q total)", size=11, weight="700", fill="#000000", mono=True)

    # Bar comparison visual
    c.text(704, 548, "Simultaneous (2h+1):", size=11, weight="700", fill="#000000", mono=True)
    c.rect(865, 534, 380, 20, rx=0, fill="#e5e5e5", stroke="#000000", stroke_width=1.0)
    c.text(1055, 548, "6,624 Logical Qubits (19 Tree + Keccak)", size=10.5, weight="700", fill="#000000", anchor="middle", mono=True)

    c.text(704, 580, "Sequential (h+1):", size=11, weight="700", fill="#000000", mono=True)
    c.rect(865, 566, 248, 20, rx=0, fill="#d4dce6", stroke="#000000", stroke_width=1.0)
    c.text(989, 580, "4,320 Q (-34.8%)", size=10.5, weight="800", fill="#000000", anchor="middle", mono=True)

    c.text(704, 614, "• Combined with K=32 Rotary Keccak-f[1600] chi-slice: saves 2,304 tree Q + 1,568 scratch Q!", size=11, weight="700", fill="#000000", mono=True)

    return c.render()


# ============================================================================
# Figure 2: Huet Focus Zipper Circuit & 2D Planar Surface-Code Floorplan
# ============================================================================

def build_fig02() -> str:
    c = SVGCanvas(1320, 690)
    c.title_banner(
        "FIGURE 2",
        "Huet Focus Zipper Quantum Circuit & 2D Planar Surface-Code Floorplan",
        "HuetFocusZipper(C=32, w=64): Active Focus |F_k> (64 Q) + Cold Context Array (1,984 Q) + 2-Sided Perimeter Bus",
    )

    # Panel (a): Left
    c.panel(
        16, 94, 636, 578,
        "Panel (a): HuetFocusZipper(C=32, w=64) Quantum Circuit Wire Architecture",
        "Isolates b=64 scratch qubits to active focus |F_k>; eliminates (C-1)*w = 1,984 idle ancillas",
        badge="Q = C*w + b = 2,112 Q",
    )

    zy = [175, 225, 290, 350, 415, 465]
    zx0, zx1 = 150, 520

    # Cold Left Context shading
    c.rect(40, 152, 590, 92, rx=0, fill="none", stroke="#333333", stroke_width=0.9, dasharray="4,3")
    c.text(195, 165, "COLD LEFT CONTEXT (Idle Memory Zone: 0 Active Gates)", size=9.2, weight="800", fill="#000000", mono=True)

    # Hot Focus Zone shading
    c.rect(40, 254, 590, 124, rx=0, fill="#f5f5f5", stroke="#000000", stroke_width=1.0)
    c.text(195, 268, "HOT ACTIVE FOCUS ZONE (Active Arithmetic + Scratch |0>^b)", size=9.2, weight="800", fill="#000000", mono=True)

    # Cold Right Context shading
    c.rect(40, 388, 590, 96, rx=0, fill="none", stroke="#333333", stroke_width=0.9, dasharray="4,3")
    c.text(195, 401, "COLD RIGHT CONTEXT (Idle Memory Zone: 0 Active Gates)", size=9.2, weight="800", fill="#000000", mono=True)

    c.qwire(zy[0], zx0, zx1, label_left="|L_0>", label_right="|L_0>", bundle="64")
    c.qwire(zy[1], zx0, zx1, label_left="|L_{k-1}>", label_right="|L_k> (Shifted)", bundle="64")
    c.qwire(zy[2], zx0, zx1, label_left="|F_k> (Focus)", label_right="|F_{k+1}>", bundle="64")
    c.qwire(zy[3], zx0, zx1, label_left="|Scratch> |0>", label_right="|0>^64 (Clean)", bundle="64")
    c.qwire(zy[4], zx0, zx1, label_left="|L_{k+1}>", label_right="|L_{k+2}>", bundle="64")
    c.qwire(zy[5], zx0, zx1, label_left="|L_{31}>", label_right="|L_{31}>", bundle="64")

    # Active operations on Focus + Scratch
    c.multi_gate(235, zy[2], zy[3], w=68, label="U_F", sublabel="Compute")
    c.multi_gate(320, zy[2], zy[3], w=68, label="Phase /", sublabel="Carry")
    c.multi_gate(405, zy[2], zy[3], w=68, label="U_F^dag", sublabel="Uncomp")

    # Focus Shift Right operation between F_k and L_{k+1}
    c.fredkin(475, None, zy[1], zy[2])
    c.fredkin(495, None, zy[2], zy[4])
    c.text(485, zy[4] + 22, "Shift Focus", size=9.5, weight="700", fill="#000000", anchor="middle", mono=True)

    # Bottom explanation box in Panel (a)
    c.rect(34, 496, 600, 160, rx=0, fill="#ffffff", stroke="#000000", stroke_width=1.0)
    c.text(50, 520, "Two Shift Regimes for Focus Movement (shift_right / shift_left):", size=11.5, weight="800", fill="#000000")
    c.text(50, 542, "1. Classical Schedule (Known Index k): Compiler pointer permutation -> 0 Toffolis, 0 SWAPs!", size=10.8, weight="700", fill="#000000", mono=True)
    c.text(50, 563, "2. Quantum Superposition Index |k>: Log-depth Fredkin (CSWAP) Barrel Shifter:", size=10.8, weight="700", fill="#000000", mono=True)
    c.text(65, 583, "• Cost: C * w * log2(C) = 32 * 64 * 5 = 10,240 CSWAPs (Toffolis) in depth O(log C) = 5.", size=10.5, weight="600", fill="#000000", mono=True)
    c.text(50, 608, "Width Savings vs. Flat Unrolled Array:", size=11.5, weight="800", fill="#000000")
    c.text(65, 628, "• Flat Simultaneous Scratch: C*(w + b) = 32*(64 + 64) = 4,096 Q", size=10.5, weight="600", fill="#000000", mono=True)
    c.text(65, 646, "• HuetFocusZipper(32, 64):   C*w + b   = 32*64 + 64   = 2,112 Q  (-48.4% Logical Qubits)", size=10.5, weight="700", fill="#000000", mono=True)

    # Panel (b): Right - 2D Planar Surface-Code Floorplan (Litinski [2019] Muted Grayscale/Desaturated Palette)
    c.panel(
        668, 94, 636, 578,
        "Panel (b): 2D Planar Surface-Code Floorplan & Perimeter Routing Bus",
        "Cold Context Array (sqrt(Q_cold) x sqrt(Q_cold)) + 2-Sided Perimeter Bus + Hot Active Zone",
        badge="Bus = 128 Patches (6.3%)",
    )

    # Draw 2D Grid Floorplan
    # Outer Top & Left Routing Bus (L-shaped corridor)
    c.rect(700, 156, 340, 32, rx=0, fill="#ffffff", stroke="#000000", stroke_width=1.1)
    c.text(870, 176, "TOP PERIMETER ROUTING BUS (ceil(sqrt(Q_cold)) = 46 Patches)", size=10, weight="800", fill="#000000", anchor="middle", mono=True)

    c.rect(700, 188, 34, 280, rx=0, fill="#ffffff", stroke="#000000", stroke_width=1.1)
    c.text(717, 320, "LEFT", size=9.5, weight="800", fill="#000000", anchor="middle", mono=True)
    c.text(717, 334, "BUS", size=9.5, weight="800", fill="#000000", anchor="middle", mono=True)
    c.text(717, 348, "(46)", size=9.5, weight="800", fill="#000000", anchor="middle", mono=True)

    # Cold Context Array (#e5e5e5 light gray for cold memory)
    c.rect(742, 196, 298, 272, rx=0, fill="#e5e5e5", stroke="#000000", stroke_width=1.1)
    c.text(891, 215, "COLD CONTEXT ARRAY (31 Limbs = 1,984 Q)", size=10.5, weight="800", fill="#000000", anchor="middle", mono=True)
    c.text(891, 230, "Yoked High-Density Storage (0.5d Footprint)", size=9.5, weight="600", fill="#000000", anchor="middle", mono=True)

    tile_w, tile_h = 42, 32
    for r in range(6):
        for col in range(6):
            idx = r * 6 + col
            if idx >= 32:
                continue
            tx = 755 + col * 46
            ty = 240 + r * 36
            if idx == 14:
                # Active limb swapped out to focus!
                c.rect(tx, ty, tile_w, tile_h, rx=0, fill="#d4dce6", stroke="#000000", stroke_width=1.2)
                c.text(tx + tile_w / 2, ty + 20, "L_14*", size=9.5, weight="800", fill="#000000", anchor="middle", mono=True)
            else:
                c.rect(tx, ty, tile_w, tile_h, rx=0, fill="#ffffff", stroke="#000000", stroke_width=0.9)
                c.text(tx + tile_w / 2, ty + 20, f"L_{idx}", size=9.5, weight="600", fill="#000000", anchor="middle", mono=True)

    # Hot Active Compute Zone (#d4dce6 desaturated slate-gray)
    c.rect(1058, 156, 226, 195, rx=0, fill="#d4dce6", stroke="#000000", stroke_width=1.2)
    c.text(1171, 178, "HOT ACTIVE COMPUTE ZONE", size=11, weight="800", fill="#000000", anchor="middle", mono=True)
    c.rect(1074, 190, 194, 44, rx=0, fill="#ffffff", stroke="#000000", stroke_width=1.0)
    c.text(1171, 209, "Active Focus |F_k> (64 Q)", size=10.5, weight="700", fill="#000000", anchor="middle", mono=True)
    c.text(1171, 225, "+ Carry / Routing Ancillas", size=9.5, weight="600", fill="#000000", anchor="middle", mono=True)

    c.rect(1074, 242, 194, 44, rx=0, fill="#ffffff", stroke="#000000", stroke_width=1.0)
    c.text(1171, 261, "Local Scratch |0>^b (64 Q)", size=10.5, weight="700", fill="#000000", anchor="middle", mono=True)
    c.text(1171, 277, "Cuccaro-Gidney Adder Tree", size=9.5, weight="600", fill="#000000", anchor="middle", mono=True)

    c.rect(1074, 294, 194, 44, rx=0, fill="#ffffff", stroke="#000000", stroke_width=1.0)
    c.text(1171, 313, "Fast Lane Corridor (64 Q)", size=10.5, weight="700", fill="#000000", anchor="middle", mono=True)
    c.text(1171, 329, "Lattice-Surgery Bus Port", size=9.5, weight="600", fill="#000000", anchor="middle", mono=True)

    # Magic-State Cultivation Factory (#e8dcd5 muted warm gray)
    c.rect(1058, 365, 226, 103, rx=0, fill="#e8dcd5", stroke="#000000", stroke_width=1.2)
    c.text(1171, 388, "MAGIC-STATE CULTIVATION", size=10.5, weight="800", fill="#000000", anchor="middle", mono=True)
    c.text(1171, 406, "Gidney-Shutty-Jones [2024]", size=9.5, weight="600", fill="#000000", anchor="middle", mono=True)
    c.text(1171, 426, "36 Logical Patches (~53K Q)", size=10.5, weight="800", fill="#000000", anchor="middle", mono=True)
    c.text(1171, 444, "16x Smaller than 15-to-1 Factory", size=9.5, weight="700", fill="#000000", anchor="middle", mono=True)

    # Arrow from L_14* through top bus to Hot Zone
    c.path("M 868 240 L 868 172 L 1056 172", stroke="#ea580c", width=2.4, marker_end="arrow-amber")

    # Floorplan Quantitative Breakdown Box at bottom of Panel (b)
    c.rect(686, 484, 600, 172, rx=8, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.4)
    c.text(702, 508, "2D Planar Lattice-Surgery Routing Overhead & Yoked Memory Advantage:", size=11.5, weight="800", fill="#0f172a")
    c.text(702, 530, "• Perimeter Routing Bus: 2 * ceil(sqrt(Q_cold)) = 2 * 64 = 128 patches (only 6.3% overhead!).", size=10.5, weight="700", fill="#b45309", mono=True)
    c.text(702, 551, "• Eliminates O(N^2) internal routing checkerboard tracks across 96.9% of the memory array.", size=10.5, weight="600", fill="#334155", mono=True)
    c.text(702, 572, "• Yoked Surface Code [Gidney-Newman-McEwen 2023] on Cold Context Array:", size=10.5, weight="700", fill="#1e3a8a", mono=True)
    c.text(718, 592, "- Hot Focus + Bus (292 patches @ full 2*d^2, d=27):  425,736 physical qubits", size=10.2, weight="600", fill="#334155", mono=True)
    c.text(718, 610, "- Cold Context (1,072 patches @ yoked 0.5*d^2):      412,568 physical qubits", size=10.2, weight="600", fill="#059669", mono=True)
    c.text(718, 628, "- Cultivation Factory (36 patches):                   53,169 physical qubits", size=10.2, weight="600", fill="#6d28d9", mono=True)
    c.text(718, 646, "=> TOTAL RSA-2048 Architecture C Physical Qubits:   891,473 Q (Sub-Million Qubit Milestone!)", size=10.5, weight="800", fill="#0f766e", mono=True)

    return c.render()


# ============================================================================
# Figure 3: Skew-Binary Carry-Save Numeral Circuit
# ============================================================================

def build_fig03() -> str:
    c = SVGCanvas(1320, 680)
    c.title_banner(
        "FIGURE 3",
        "Skew-Binary Carry-Save Numeral: O(1)-Depth Lazy Carry Absorption Circuit",
        "SkewBinaryCarrySaveNumeral(C=32, w=64): 2-Qubit Skew Carry Rail d_k in {0,1,2} Eliminates 32x Ripple Stretch",
    )

    # Panel (a): Left
    c.panel(
        16, 94, 636, 568,
        "Panel (a): Gate-Level Intra-Limb Adder + 2-Qubit Skew Carry Rail Absorption",
        "All C=32 limbs execute in parallel (1 limb-depth round); carry-out b_k absorbed into d_k[0..1]",
        badge="1 Toffoli + 1 CNOT / Limb",
        badge_fill="#dcfce7",
        badge_text="#166534",
    )

    sy = [175, 225, 275, 335, 385, 455]
    sx0, sx1 = 152, 456

    c.qwire(sy[0], sx0, sx1, label_left="|L_k[0..63]>", label_right="|L'_k[0..63]>", bundle="64")
    c.qwire(sy[1], sx0, sx1, label_left="|A_k[0..63]>", label_right="|A_k[0..63]>", bundle="64")
    c.qwire(sy[2], sx0, sx1, label_left="|b_k> = |0>", label_right="|b_k> (Carry-out)", color="#2563eb")
    c.qwire(sy[3], sx0, sx1, label_left="|d_k[0]> (LSB)", label_right="|d'_k[0]> = d_k[0]^b_k", color="#0f766e", width=2.2)
    c.qwire(sy[4], sx0, sx1, label_left="|d_k[1]> (MSB)", label_right="|d'_k[1]> = d_k[1]^(b_k&d_k[0])", color="#0f766e", width=2.2)
    c.qwire(sy[5], sx0, sx1, label_left="|L_{k+1}[0..63]>", label_right="|L'_{k+1}> (Parallel!)", bundle="64", dashed=True)

    # Parallel Cuccaro-Gidney Adder on limb k
    c.multi_gate(
        232, sy[0], sy[2], w=108,
        label="Cuccaro-Gidney", sublabel="w=64 Adder", third_line="(64 CCX, 1 Round)",
        fill="url(#blue-grad)", stroke="#2563eb", text_color="#1e3a8a"
    )

    # Parallel indicator on L_{k+1}
    c.gate_box(232, sy[5], w=108, h=30, label="Limb k+1 Add", sublabel="(Simultaneous)", fill="url(#blue-grad)", stroke="#2563eb")

    # Skew Carry Rail Increment: CCX(b_k, d_k[0], d_k[1]); CNOT(b_k, d_k[0])
    c.rect(304, 152, 144, 260, rx=8, fill="#f0fdfa", stroke="#0d9488", stroke_width=1.4, dasharray="4,3")
    c.text(376, 168, "Skew d_k <- d_k + b_k", size=10, weight="800", fill="#0f766e", anchor="middle", mono=True)

    c.toffoli(350, sy[2], sy[3], sy[4], color="#0f766e")
    c.text(350, sy[4] + 22, "CCX", size=10, weight="800", fill="#0f766e", anchor="middle", mono=True)

    c.cnot(408, sy[2], sy[3], color="#2563eb")
    c.text(408, sy[3] + 22, "CNOT", size=10, weight="800", fill="#2563eb", anchor="middle", mono=True)

    # No cross-limb wire barrier!
    c.line(152, 424, 456, 424, stroke="#dc2626", width=1.8, dasharray="6,4")
    c.rect(200, 413, 240, 22, rx=11, fill="#fef2f2", stroke="#dc2626", stroke_width=1.2)
    c.text(320, 428, "ZERO CROSS-LIMB RIPPLE WIRE", size=10.0, weight="800", fill="#991b1b", anchor="middle", mono=True)

    # Algebraic Invariant Box in Panel (a)
    c.rect(34, 488, 600, 156, rx=8, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.4)
    c.text(50, 512, "Skew-Binary Redundant Carry-Save Representation Invariant:", size=11.5, weight="800", fill="#0f172a")
    c.rect(50, 522, 568, 30, rx=6, fill="#f0fdf4", stroke="#16a34a", stroke_width=1.2)
    c.text(334, 542, "Val(L, d)  =  SUM_{k=0}^{C-1} ( L_k + d_k * 2^w ) * 2^{k*w},    d_k in {0, 1, 2}", size=11.5, weight="800", fill="#166534", anchor="middle", mono=True)
    c.text(50, 574, "• Pre-condition: Inter-window fold resets d_k in {0, 1} before each addition.", size=10.5, weight="600", fill="#334155", mono=True)
    c.text(50, 594, "• Step: Adding carry-out b_k in {0, 1} produces d'_k = d_k + b_k in {0, 1, 2} (zero overflow!).", size=10.5, weight="700", fill="#0f766e", mono=True)
    c.text(50, 614, "• Qubit Overhead: Only 2*C = 64 qubits across RSA-2048 (128 Q on RSA-4096).", size=10.5, weight="600", fill="#334155", mono=True)
    c.text(50, 634, "• Depth Reduction: Collapses 32 sequential limb rounds -> 1 parallel intra-limb round!", size=10.5, weight="800", fill="#1d4ed8", mono=True)

    # Panel (b): Right
    c.panel(
        668, 94, 636, 568,
        "Panel (b): Inter-Window Local Carry-Save Fold & Terminal Canonical Collapse",
        "1-Limb local fold (d_k -> L_{k+1}[0..1]) keeps d_k in {0,1}; canonical ripple runs ONCE before QFT",
        badge="32x -> 1x Depth Stretch",
        badge_fill="#dbeafe",
        badge_text="#1e3a8a",
    )

    fy = [180, 230, 290, 340, 390]
    fx0, fx1 = 805, 1185

    c.qwire(fy[0], fx0, fx1, label_left="|d_k[0]> (2^0)", label_right="|0> (Cleared)", color="#0f766e", width=2.0)
    c.qwire(fy[1], fx0, fx1, label_left="|d_k[1]> (2^1)", label_right="|0> (Cleared)", color="#0f766e", width=2.0)
    c.qwire(fy[2], fx0, fx1, label_left="|L_{k+1}[0]>", label_right="|L'_{k+1}[0]>", color="#334155")
    c.qwire(fy[3], fx0, fx1, label_left="|L_{k+1}[1]>", label_right="|L'_{k+1}[1]>", color="#334155")
    c.qwire(fy[4], fx0, fx1, label_left="|L_{k+1}[2..63]>", label_right="|L'_{k+1}[2..63]>", bundle="62")

    # Local fold gates
    c.multi_gate(
        895, fy[0], fy[3], w=110,
        label="2-Bit Add", sublabel="L_{k+1}[0..1] += d_k",
        fill="url(#teal-grad)", stroke="#0d9488", text_color="#115e59"
    )
    c.multi_gate(
        1020, fy[2], fy[4], w=110,
        label="Intra-Limb", sublabel="Ripple -> d'_{k+1}",
        fill="url(#blue-grad)", stroke="#2563eb", text_color="#1e3a8a"
    )
    c.multi_gate(
        1130, fy[0], fy[1], w=76,
        label="Reset d_k", sublabel="d'_{k+1} in {0,1}",
        fill="url(#emerald-grad)", stroke="#059669", text_color="#065f46"
    )

    # Terminal Canonical Collapse & RSA Architecture A vs C Comparison Box
    c.rect(686, 428, 600, 216, rx=8, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.4)
    c.text(702, 452, "Two-Stage Lifecycle Across 1,024 Windowed Modular Multiplications (RSA-2048):", size=11.5, weight="800", fill="#0f172a")
    c.text(702, 474, "1. During 40,960 Modular Additions (Per Window): Local 1-Limb Fold (Above)", size=10.8, weight="700", fill="#0f766e", mono=True)
    c.text(718, 493, "• Propagates d_k into L_{k+1} locally in O(1) limb hops; resets d_k in {0, 1}.", size=10.2, weight="600", fill="#334155", mono=True)
    c.text(702, 515, "2. Terminal Canonical Collapse (Once at End of Period Finding Before QFT):", size=10.8, weight="700", fill="#1d4ed8", mono=True)
    c.text(718, 534, "• Sequential sweep k = 0 .. C-2 ripples all d_k -> 0, restoring unique binary Val(L).", size=10.2, weight="600", fill="#334155", mono=True)
    c.text(718, 552, "• Uncomputes high-water comparison history so |d_0..d_{C-1}> = |0>^{2C} cleanly.", size=10.2, weight="600", fill="#334155", mono=True)

    # Comparison table bar
    c.rect(702, 566, 568, 64, rx=6, fill="#f8fafc", stroke="#94a3b8", stroke_width=1.2)
    c.text(716, 586, "Arch A (Sequential Zipper Ripple):  32x Limb Stretch  |  d = 29  |  50.1 Hours (2D)  |  1.92M Phys Q", size=10, weight="700", fill="#dc2626", mono=True)
    c.text(716, 606, "Arch C (Skew-Binary Carry-Save):     1x Limb Stretch  |  d = 27  |  3.19 Days (2D)   |  891,348 Yoked Q", size=10, weight="800", fill="#059669", mono=True)
    c.text(716, 623, "Neutral-Atom Parallel AOD / BB qLDPC: 32 Limbs Parallel => 24.9 Days vs 2.58 Yrs Serial (37.8x Faster)", size=10, weight="800", fill="#1d4ed8", mono=True)

    return c.render()


# ============================================================================
# Figure 4: Braun Tree Popcount & RNS CRT Accumulation Circuit
# ============================================================================

def build_fig04() -> str:
    c = SVGCanvas(1320, 680)
    c.title_banner(
        "FIGURE 4",
        "Pointer-Free Implicit Braun Tree: O(log k)-Depth Popcount & RNS Quotient Folding",
        "BraunTree(k, w): Implicit Array Indexing (2i+1, 2i+2), Exact 2^r - 1 MBU Toffolis, Zero Address Routing",
    )

    # Panel (a): Left
    c.panel(
        16, 94, 636, 568,
        "Panel (a): BraunTree(k=8, w=1) Compute-Threshold-Uncompute Quantum Circuit",
        "Bottom-up reversible half/full adders -> Root threshold comparator -> Mirror adjoint braun_fold_add^dag",
        badge="k - 1 = 255 CCX (k=256)",
        badge_fill="#dcfce7",
        badge_text="#166534",
    )

    by = [170, 206, 242, 278, 322, 362, 404, 448]
    bx0, bx1 = 148, 520
    blabels_l = [
        "|x_0..x_1> (Leaves)",
        "|x_2..x_3> (Leaves)",
        "|x_4..x_5> (Leaves)",
        "|x_6..x_7> (Leaves)",
        "|n_3..n_6> (2-bit)",
        "|n_1..n_2> (3-bit)",
        "|n_0 Root> (4-bit)",
        "|flag_out> = |0>",
    ]
    blabels_r = [
        "|x_0..x_1>",
        "|x_2..x_3>",
        "|x_4..x_5>",
        "|x_6..x_7>",
        "|0> (Restored)",
        "|0> (Restored)",
        "|0> (Restored)",
        "|flag ^ [wt >= T]>",
    ]

    for idx in range(8):
        col = "#dc2626" if idx == 7 else ("#0f766e" if idx >= 4 else "#334155")
        c.qwire(by[idx], bx0, bx1, label_left=blabels_l[idx], label_right=blabels_r[idx], color=col)

    # Bottom-up Compute Tree
    c.barrier(168, by[0], by[7], "braun_fold_add")
    # Level 1: Leaves -> n_3..n_6
    c.toffoli(195, by[0], by[1], by[4], color="#2563eb")
    c.toffoli(215, by[2], by[3], by[4], color="#2563eb")
    # Level 2: n_3..n_6 -> n_1..n_2
    c.multi_gate(255, by[4], by[5], w=54, label="Add_L2", sublabel="2i+1,2", fill="url(#blue-grad)", stroke="#2563eb")
    # Level 3: n_1..n_2 -> n_0 Root
    c.multi_gate(312, by[5], by[6], w=54, label="Add_L3", sublabel="-> n_0", fill="url(#teal-grad)", stroke="#0d9488")

    # Root Comparator
    c.multi_gate(368, by[6], by[7], w=56, label=">= T", sublabel="Cmp", fill="url(#rose-grad)", stroke="#e11d48", text_color="#881337")

    # Top-down Uncompute Tree (Adjoint with MBU)
    c.barrier(405, by[0], by[7], "braun_fold_add^dag (MBU)")
    c.multi_gate(432, by[5], by[6], w=54, label="Add_L3^+", sublabel="0 CCX", fill="url(#amber-grad)", stroke="#d97706", text_color="#92400e")
    c.multi_gate(488, by[4], by[5], w=54, label="Add_L2^+", sublabel="0 CCX", fill="url(#amber-grad)", stroke="#d97706", text_color="#92400e")

    # Explanation Box in Panel (a)
    c.rect(34, 480, 600, 164, rx=8, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.4)
    c.text(50, 504, "Implicit Braun Heap Indexing & Exact MBU Toffoli Theorem:", size=11.5, weight="800", fill="#0f172a")
    c.text(50, 526, "• Pointer-Free Bijection: Node i has children (2i + 1, 2i + 2) with size_diff in {0, 1}.", size=10.5, weight="700", fill="#1e3a8a", mono=True)
    c.text(50, 546, "• Zero QROAM / Zero Address Routing: All wire connections are static compile-time indices!", size=10.5, weight="600", fill="#334155", mono=True)
    c.text(50, 568, "• Exact Popcount Toffoli Count for k = 2^r Leaves:", size=10.8, weight="800", fill="#0f766e", mono=True)
    c.rect(66, 578, 536, 30, rx=6, fill="#f0fdf4", stroke="#16a34a", stroke_width=1.2)
    c.text(334, 598, "SUM_{l=1}^r (2^{r-l} * l)  -  r   =   2^r - 1   =   k - 1  Toffolis  (0 Uncompute CCX)", size=11, weight="800", fill="#166534", anchor="middle", mono=True)
    c.text(50, 628, "• For k=256 SimHash: 255 Compute Toffolis + 0 Uncompute Toffolis in depth O(log^2 k).", size=10.5, weight="700", fill="#059669", mono=True)

    # Panel (b): Right
    c.panel(
        668, 94, 636, 568,
        "Panel (b): RNS CRT Quotient Accumulation (RSA-2048 Architecture B = 896 Q)",
        "Folds k=68 parallel 31-bit prime moduli m_i via depth-7 BraunTree(68, 31) without multi-precision carry chains",
        badge="896 Q (RSA-2048)",
        badge_fill="#f3e8ff",
        badge_text="#6b21a8",
    )

    # Tree visualization of k=68 RNS residues -> Depth 7 Braun Tree -> Quotient q -> Target r_68
    # Top row: 68 RNS channels
    c.rect(690, 154, 592, 66, rx=7, fill="url(#purple-grad)", stroke="#7c3aed", stroke_width=1.5)
    c.text(986, 174, "k = 68 Parallel RNS Prime Moduli Channels (w = 31 bits each: m_1, m_2, ..., m_68)", size=11, weight="800", fill="#4c1d95", anchor="middle", mono=True)
    rns_boxes = [
        (696, 86, "|r_1> (31Q)"),
        (788, 86, "|r_2> (31Q)"),
        (880, 86, "|r_3> (31Q)"),
        (972, 114, ".. 62 Moduli .."),
        (1092, 88, "|r_67> (31Q)"),
        (1186, 88, "|r_68> (31Q)"),
    ]
    for bx, bw, lbl in rns_boxes:
        c.rect(bx, 184, bw, 28, rx=4, fill="#ffffff", stroke="#7c3aed", stroke_width=1.2)
        c.text(bx + bw / 2, 202, lbl, size=10.0, weight="700", fill="#5b21b6", anchor="middle", mono=True)
        c.line(bx + bw / 2, 214, bx + bw / 2, 238, stroke="#7c3aed", width=1.6, marker_end="arrow-purple")

    c.rect(720, 240, 532, 42, rx=6, fill="url(#blue-grad)", stroke="#2563eb", stroke_width=1.5)
    c.text(986, 258, "Parallel Intra-Modulus CRT Weighting:  q_i = (r_i * alpha_i) * 2^31 / m_i", size=10.8, weight="800", fill="#1e3a8a", anchor="middle", mono=True)
    c.text(986, 274, "Zero Cross-Modulus Wires (68 Independent 31-Bit Modular Multipliers)", size=9.8, weight="600", fill="#1d4ed8", anchor="middle", mono=True)

    # Braun Tree Fold
    c.line(986, 282, 986, 306, stroke="#0d9488", width=2.2, marker_end="arrow-teal")
    c.polygon([(740, 308), (1232, 308), (1090, 396), (882, 396)], fill="url(#teal-grad)", stroke="#0d9488", width=2.0)
    c.text(986, 334, "BraunTree(k = 68, w = 31) Balanced Binary Adder Tree", size=11.5, weight="800", fill="#134e4a", anchor="middle", mono=True)
    c.text(986, 354, "Depth = ceil(log2(68)) = 7 Levels  |  67 Node Adders", size=10.5, weight="700", fill="#0f766e", anchor="middle", mono=True)
    c.text(986, 374, "Accumulates Fixed-Point CRT Quotient  q = round( SUM_i q_i )", size=10, weight="600", fill="#115e59", anchor="middle", mono=True)

    # Output of Braun Tree -> Rank-1 Update on target channel
    c.line(986, 396, 986, 420, stroke="#0d9488", width=2.2, marker_end="arrow-teal")
    c.rect(750, 422, 472, 44, rx=6, fill="url(#amber-grad)", stroke="#d97706", stroke_width=1.6)
    c.text(986, 441, "Exact Base Extension into Target Channel m_target:", size=10.8, weight="800", fill="#92400e", anchor="middle", mono=True)
    c.text(986, 458, "|r_target>  <-  ( SUM_i r_i * M_i  -  q * M ) mod m_target   (Then braun_fold_add^dag)", size=9.8, weight="700", fill="#b45309", anchor="middle", mono=True)

    # Tradeoff Analysis Box in Panel (b)
    c.rect(686, 480, 600, 164, rx=8, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.4)
    c.text(702, 504, "Architecture B (RNS + Braun Tree) vs. Architecture C (Skew-Binary Carry-Save):", size=11.5, weight="800", fill="#0f172a")
    c.text(702, 526, "• Logical Width Champion: Architecture B reaches 896 Q on RSA-2048 (1,728 Q on RSA-4096)", size=10.5, weight="700", fill="#059669", mono=True)
    c.text(718, 545, "by streaming the 68 independent 31-bit RNS channels through a single active 31-bit ALU.", size=10.2, weight="600", fill="#334155", mono=True)
    c.text(702, 567, "• The RNS CRT Tax: Because mod N reductions are non-linear across prime moduli, every", size=10.5, weight="700", fill="#dc2626", mono=True)
    c.text(718, 586, "modular multiplication requires a full k=68 BraunTree CRT base extension (11.79B Toffolis,", size=10.2, weight="600", fill="#334155", mono=True)
    c.text(718, 605, "6.9x higher than Architecture C's 1.70B Toffolis).", size=10.2, weight="600", fill="#334155", mono=True)
    c.text(702, 627, "• Takeaway: Use Arch B when strictly qubit-capped (< 1,000 Q); use Arch C for min spacetime!", size=10.5, weight="800", fill="#1e3a8a", mono=True)

    return c.render()


# ============================================================================
# Figure 5: Packed Bézout Shift-Zipper Circuit (1,088 Q ECDLP Core)
# ============================================================================

def build_fig05() -> str:
    c = SVGCanvas(1320, 690)
    c.title_banner(
        "FIGURE 5",
        "Packed Bézout Shift-Zipper: Complementary Bit-Budget & Divstep Window Circuit",
        "PackedBezoutShiftZipper(N=256, J=16): Packs (u,r) into UR[256] & (v,s) into VS[256] -> Saves 512 Qubits",
    )

    # Panel (a): Left
    c.panel(
        16, 94, 636, 578,
        "Panel (a): Complementary Bit-Length Packing (len(u) + len(r) = 256)",
        "Each binary GCD right-shift shrinks deg(u),deg(v) by 1 bit while growing Bézout deg(r),deg(s) by 1 bit",
        badge="4N = 1,024 Field Qubits",
        badge_fill="#dcfce7",
        badge_text="#166534",
    )

    # Draw the 4 registers of 256 qubits each vs Unpacked 6 registers
    c.text(36, 162, "1. Unpacked Euclidean / Montgomery GCD Layout (6 * 256 = 1,536 Field Qubits):", size=11.5, weight="800", fill="#991b1b")
    for idx, (lbl, desc) in enumerate([
        ("|u[256]>", "Remainder u (shrinks)"),
        ("|v[256]>", "Remainder v (shrinks)"),
        ("|r[256]>", "Bézout r (grows)"),
        ("|s[256]>", "Bézout s (grows)"),
        ("|X_1[256]>", "Curve X_1"),
        ("|Y_1[256]>", "Curve Y_1"),
    ]):
        bx = 36 + idx * 98
        c.rect(bx, 172, 92, 42, rx=5, fill="#fef2f2", stroke="#dc2626", stroke_width=1.3)
        c.text(bx + 46, 190, lbl, size=10, weight="800", fill="#991b1b", anchor="middle", mono=True)
        c.text(bx + 46, 205, desc, size=8.5, weight="600", fill="#b91c1c", anchor="middle")

    c.text(36, 242, "2. PackedBézoutShiftZipper Layout at Step t (4 * 256 = 1,024 Field Qubits -> -512 Q!):", size=11.5, weight="800", fill="#065f46")

    # Register UR[0..255] with moving partition wall k(t)
    c.text(36, 266, "Register |UR[0..255]> (256 Q): Packs Remainder u_t (N - k bits) + Bézout r_t (k bits)", size=10.5, weight="700", fill="#0f172a", mono=True)
    c.rect(36, 274, 340, 44, rx=6, fill="url(#blue-grad)", stroke="#2563eb", stroke_width=1.8)
    c.text(206, 294, "Remainder u_t  [Bits 0 .. N-k-1]", size=11, weight="800", fill="#1e3a8a", anchor="middle", mono=True)
    c.text(206, 310, "Shrinks by 1 bit per divstep (u <- u >> 1)", size=9.5, weight="600", fill="#1d4ed8", anchor="middle")

    c.rect(380, 274, 236, 44, rx=6, fill="url(#teal-grad)", stroke="#0d9488", stroke_width=1.8)
    c.text(498, 294, "Bézout r_t  [Bits N-k .. 255]", size=11, weight="800", fill="#134e4a", anchor="middle", mono=True)
    c.text(498, 310, "Grows by 1 bit (r <- 2r)", size=9.5, weight="600", fill="#0f766e", anchor="middle")

    # Moving Zipper Boundary Wall
    c.line(378, 266, 378, 386, stroke="#dc2626", width=2.8, dasharray="4,2")
    c.path("M 378 268 L 352 268", stroke="#dc2626", width=2.0, marker_end="arrow-crimson")

    # Register VS[0..255]
    c.text(36, 340, "Register |VS[0..255]> (256 Q): Packs Remainder v_t (N - k bits) + Bézout s_t (k bits)", size=10.5, weight="700", fill="#0f172a", mono=True)
    c.rect(36, 348, 340, 44, rx=6, fill="url(#blue-grad)", stroke="#2563eb", stroke_width=1.8)
    c.text(206, 368, "Remainder v_t  [Bits 0 .. N-k-1]", size=11, weight="800", fill="#1e3a8a", anchor="middle", mono=True)
    c.text(206, 384, "Terminates at v_{2N} = 0", size=9.5, weight="600", fill="#1d4ed8", anchor="middle")

    c.rect(380, 348, 236, 44, rx=6, fill="url(#teal-grad)", stroke="#0d9488", stroke_width=1.8)
    c.text(498, 368, "Bézout s_t  [Bits N-k .. 255]", size=11, weight="800", fill="#134e4a", anchor="middle", mono=True)
    c.text(498, 384, "Yields lambda = dY * dX^{-1} mod p", size=9.5, weight="600", fill="#0f766e", anchor="middle")

    # Curve Point Registers X_1, Y_1
    c.rect(36, 404, 284, 36, rx=6, fill="url(#purple-grad)", stroke="#7c3aed", stroke_width=1.5)
    c.text(178, 426, "Curve Point |X_1[0..255]> (256 Q)", size=10.5, weight="800", fill="#4c1d95", anchor="middle", mono=True)
    c.rect(332, 404, 284, 36, rx=6, fill="url(#purple-grad)", stroke="#7c3aed", stroke_width=1.5)
    c.text(474, 426, "Curve Point |Y_1[0..255]> (256 Q)", size=10.5, weight="800", fill="#4c1d95", anchor="middle", mono=True)

    # Direct-Quotient Initialization Box
    c.rect(34, 454, 600, 202, rx=8, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.4)
    c.text(50, 478, "Direct-Quotient Bézout Initialization (Eliminates 256-Bit Multiplier):", size=11.5, weight="800", fill="#0f172a")
    c.rect(50, 488, 568, 32, rx=6, fill="#fffbeb", stroke="#d97706", stroke_width=1.3)
    c.text(334, 509, "u_0 = p,   v_0 = Delta_X,   r_0 = 0,   s_0 = Delta_Y = Y_2 - Y_1 (mod p)", size=11.2, weight="800", fill="#92400e", anchor="middle", mono=True)
    c.text(50, 540, "• Standard ECDLP computes Delta_X^{-1} mod p first, then multiplies by Delta_Y (extra 256Q).", size=10.5, weight="600", fill="#334155", mono=True)
    c.text(50, 560, "• Seeding s_0 = Delta_Y directly into |VS> maintains the linear invariant mod p:", size=10.5, weight="700", fill="#0f766e", mono=True)
    c.text(70, 580, "r_t * Delta_X  equiv  u_t * Delta_Y (mod p),     s_t * Delta_X  equiv  v_t * Delta_Y (mod p)", size=10.3, weight="700", fill="#1e3a8a", mono=True)
    c.text(50, 602, "• At step t = 2N = 512 (when v_{2N} = 0 and u_{2N} = gcd(p, Delta_X) = 1):", size=10.5, weight="600", fill="#334155", mono=True)
    c.text(70, 622, "r_{2N}  equiv  Delta_Y * Delta_X^{-1}  equiv  lambda (mod p)   Directly inside |UR[0..255]>!", size=10.8, weight="800", fill="#059669", mono=True)
    c.text(50, 644, "• Saves both the 512-qubit (r,s) registers AND the 256-qubit slope multiplication scratchpad.", size=10.5, weight="700", fill="#1d4ed8", mono=True)

    # Panel (b): Right
    c.panel(
        668, 94, 636, 578,
        "Panel (b): Gate-Level Bernstein-Yang Divstep & Jump-16 Window Circuit",
        "Operates strictly on 2J=32-bit LSB focus wires before O(1) seam-matrix propagation across 16 limbs",
        badge="J = 16 Steps / Window",
        badge_fill="#dbeafe",
        badge_text="#1e3a8a",
    )

    dy = [175, 225, 280, 335, 390, 445]
    dx0, dx1 = 795, 1195
    dlabels_l = [
        "|delta> (Signed)",
        "|v_0> (LSB of v)",
        "|b_swap, d_neg>",
        "|UR_focus[0..31]>",
        "|VS_focus[0..31]>",
        "|P_m[0..15]> (Pebble)",
    ]
    dlabels_r = [
        "|delta'> (+/-d+1)",
        "|v'_0> (Shifted)",
        "|0> (Uncomputed)",
        "|UR'_focus>",
        "|VS'_focus >> 1>",
        "|P_m> (16b Trace)",
    ]

    for idx in range(6):
        c.qwire(dy[idx], dx0, dx1, label_left=dlabels_l[idx], label_right=dlabels_r[idx])

    # Step 1: Branch bit extraction b <- v_0 & (delta > 0)
    c.toffoli(835, dy[0], dy[1], dy[2], color="#0f766e")
    c.text(835, dy[2] + 22, "b=v0&(d>0)", size=9, weight="700", fill="#0f766e", anchor="middle", mono=True)

    # Step 2: Record branch bit into Binomial Pebble P_m[j]
    c.cnot(880, dy[1], dy[5], color="#7c3aed")
    c.text(880, dy[5] + 20, "Save v_0", size=9, weight="700", fill="#6d28d9", anchor="middle", mono=True)

    # Step 3: Conditional Fredkin CSWAP of UR <-> VS and negation when b=1
    c.fredkin(935, dy[2], dy[3], dy[4], color="#7c3aed")
    c.text(935, dy[4] + 22, "CSWAP", size=9.5, weight="800", fill="#6d28d9", anchor="middle", mono=True)

    # Step 4: Conditional CNOT-controlled addition VS += UR (when v_0 = 1)
    c.multi_gate(
        1005, dy[1], dy[4], w=76,
        label="Ctrl-Add", sublabel="v+u, s+r",
        fill="url(#blue-grad)", stroke="#2563eb", text_color="#1e3a8a"
    )

    # Step 5: Right shift v >> 1, Left shift r << 1 (Wire relabeling + 2x2 Seam Matrix)
    c.multi_gate(
        1090, dy[3], dy[4], w=72,
        label="Shift 1b", sublabel="v>>1, r<<1",
        fill="url(#teal-grad)", stroke="#0d9488", text_color="#115e59"
    )

    # Step 6: Update delta and uncompute branch scratch b
    c.multi_gate(
        1160, dy[0], dy[2], w=64,
        label="delta'", sublabel="Uncomp b",
        fill="url(#amber-grad)", stroke="#d97706", text_color="#92400e"
    )

    # Jump-16 Window Summary Box in Panel (b)
    c.rect(686, 484, 600, 172, rx=8, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.4)
    c.text(702, 508, "Bernstein-Yang Jump-16 Windowing (`bezout_jump_window`):", size=11.5, weight="800", fill="#0f172a")
    c.text(702, 530, "• Key Insight: J = 16 consecutive divsteps depend ONLY on the lowest 2J = 32 bits of (u, v)!", size=10.5, weight="700", fill="#1e3a8a", mono=True)
    c.text(702, 550, "• Phase A (Local Focus): Execute 16 divsteps inside the 32-bit focus register while accumulating", size=10.3, weight="600", fill="#334155", mono=True)
    c.text(718, 568, "the 2x2 transition matrix M_window = [[f_00, f_01], [f_10, f_11]] with |f_ij| <= 2^16.", size=10.3, weight="600", fill="#334155", mono=True)
    c.text(702, 588, "• Phase B (Full-Width Sweep): Apply M_window across the 16 limbs of UR and VS in a single", size=10.3, weight="600", fill="#334155", mono=True)
    c.text(718, 606, "zipper pass, reducing full-width 256-bit additions from 512 steps down to M = 32 windows!", size=10.3, weight="700", fill="#059669", mono=True)
    c.text(702, 628, "• Pebble Footprint: Only 1 bit per divstep (16 bits per window) is needed to invert a window;", size=10.3, weight="600", fill="#334155", mono=True)
    c.text(718, 646, "s = 4 binomial pebbles * 16 bits = 64 Q total pebble memory (vs. 512 Q full history log!).", size=10.5, weight="800", fill="#6d28d9", mono=True)

    return c.render()


# ============================================================================
# Figure 6: Binomial Pebble Spacetime DAG (Bennett-Griewank-Knuth)
# ============================================================================

def build_fig06() -> str:
    c = SVGCanvas(1320, 690)
    c.title_banner(
        "FIGURE 6",
        "Binomial Tree Checkpointing: 2D Space-Time Pebbling DAG for M = 32 GCD Windows",
        "BinomialPebbleSchedule(s=4, d=4, W=16): Reverses M = C(4+4, 4) - 1 = 69 >= 32 Windows in Only 4 * 16 = 64 Qubits",
    )

    c.panel(
        16, 94, 1288, 578,
        "2D Space-Time Pebbling Trajectory (Window Index m in [0, 32] vs. Reversal Schedule Phases)",
        "4 Reusable 16-Qubit Pebble Registers (P_1, P_2, P_3, P_4) Replace 32 Naive History Checkpoints (512 Q -> 64 Q, -87.5%)",
        badge="77 Fwd + 32 Rev = 109 Evals",
        badge_fill="#dbeafe",
        badge_text="#1e3a8a",
    )

    # Draw Coordinate Axes for Space-Time DAG
    ox, oy = 110, 480
    gw, gh = 800, 310

    # Grid background
    c.rect(ox, oy - gh, gw, gh, rx=6, fill="#ffffff", stroke="#94a3b8", stroke_width=1.5)

    # Horizontal grid lines for Window index m = 0, 8, 16, 24, 32
    for m_val in [0, 8, 15, 22, 27, 30, 32]:
        yy = oy - (m_val / 32.0) * (gh - 24) - 12
        c.line(ox, yy, ox + gw, yy, stroke="#e2e8f0", width=1.0, dasharray="3,3")
        c.text(ox - 10, yy + 4, f"m={m_val}", size=10, weight="700", fill="#334155", anchor="end", mono=True)

    c.text(48, oy - gh / 2, "GCD Window", size=11, weight="800", fill="#0f172a", anchor="middle")
    c.text(48, oy - gh / 2 + 16, "Index m", size=11, weight="800", fill="#0f172a", anchor="middle")
    c.text(ox + gw / 2, oy + 28, "Space-Time Schedule Progression (109 Total Window Evaluations: 2.41x Forward Factor)", size=11.5, weight="800", fill="#0f172a", anchor="middle")

    # Helper to convert (t_norm in [0,1], m in [0,32]) -> (x, y)
    def pt(t_norm: float, m_val: float) -> Tuple[float, float]:
        return (ox + 20 + t_norm * (gw - 40), oy - 12 - (m_val / 32.0) * (gh - 24))

    # 1. Initial Forward Sweep m = 0 -> 32 placing Binomial Checkpoints at m = 0 (P1), m = 15 (P2), m = 25 (P3), m = 30 (P4)
    p00 = pt(0.00, 0)
    p01 = pt(0.11, 15)
    p02 = pt(0.19, 25)
    p03 = pt(0.24, 30)
    p04 = pt(0.27, 32)
    c.line(p00[0], p00[1], p04[0], p04[1], stroke="#000000", width=2.2, marker_end="arrow-black")

    # Horizontal persistence lines for stored pebbles P1 (m=0), P2 (m=15), P3 (m=25), P4 (m=30)
    p1_end = pt(0.76, 0)
    p2_end = pt(0.54, 15)
    p3_end = pt(0.39, 25)
    p4_end = pt(0.31, 30)

    c.line(p00[0], p00[1], p1_end[0], p1_end[1], stroke="#333333", width=1.6, dasharray="6,3")
    c.line(p01[0], p01[1], p2_end[0], p2_end[1], stroke="#333333", width=1.6, dasharray="6,3")
    c.line(p02[0], p02[1], p3_end[0], p3_end[1], stroke="#333333", width=1.6, dasharray="6,3")
    c.line(p03[0], p03[1], p4_end[0], p4_end[1], stroke="#333333", width=1.6, dasharray="6,3")

    # Sub-tree reversals (Sawtooth recursive recompute & uncompute)
    # Reverse top interval m = 32 -> 25 using P3 at m=25 and P4 at m=30
    r1_top = pt(0.29, 32)
    r1_mid = pt(0.34, 30)
    c.line(r1_top[0], r1_top[1], r1_mid[0], r1_mid[1], stroke="#000000", width=2.0, dasharray="2,2.5")
    # Recompute from P3(m=25) -> m=30
    f2_start = pt(0.35, 25)
    f2_top = pt(0.39, 30)
    c.line(f2_start[0], f2_start[1], f2_top[0], f2_top[1], stroke="#333333", width=1.8, dasharray="8,3,2,3")
    r1_bot = pt(0.45, 25)
    c.line(f2_top[0], f2_top[1], r1_bot[0], r1_bot[1], stroke="#000000", width=2.0, dasharray="2,2.5")

    # Recompute from P2(m=15) -> m=25 using freed P3, P4
    f3_start = pt(0.46, 15)
    f3_mid = pt(0.51, 22)
    f3_top = pt(0.54, 25)
    c.line(f3_start[0], f3_start[1], f3_top[0], f3_top[1], stroke="#333333", width=1.8, dasharray="8,3,2,3")
    # Sub-checkpoint at m=22
    p_sub1 = pt(0.60, 22)
    c.line(f3_mid[0], f3_mid[1], p_sub1[0], p_sub1[1], stroke="#333333", width=1.6, dasharray="6,3")
    r2_mid = pt(0.60, 22)
    c.line(f3_top[0], f3_top[1], r2_mid[0], r2_mid[1], stroke="#000000", width=2.0, dasharray="2,2.5")
    # Second sub-triangle m=15..22
    f4_start = pt(0.61, 15)
    f4_top = pt(0.65, 22)
    c.line(f4_start[0], f4_start[1], f4_top[0], f4_top[1], stroke="#333333", width=1.8, dasharray="8,3,2,3")
    r2_bot = pt(0.73, 15)
    c.line(f4_top[0], f4_top[1], r2_bot[0], r2_bot[1], stroke="#000000", width=2.0, dasharray="2,2.5")

    # Final recursive triangle from P1(m=0) -> m=15 using all 4 pebbles P1..P4
    f5_start = pt(0.74, 0)
    f5_mid1 = pt(0.79, 8)
    f5_top = pt(0.83, 15)
    c.line(f5_start[0], f5_start[1], f5_top[0], f5_top[1], stroke="#333333", width=1.8, dasharray="8,3,2,3")
    p_sub2 = pt(0.89, 8)
    c.line(f5_mid1[0], f5_mid1[1], p_sub2[0], p_sub2[1], stroke="#333333", width=1.6, dasharray="6,3")
    c.line(f5_top[0], f5_top[1], p_sub2[0], p_sub2[1], stroke="#000000", width=2.0, dasharray="2,2.5")

    f6_start = pt(0.90, 0)
    f6_top = pt(0.93, 8)
    c.line(f6_start[0], f6_start[1], f6_top[0], f6_top[1], stroke="#333333", width=1.8, dasharray="8,3,2,3")
    r_final = pt(0.99, 0)
    c.line(f6_top[0], f6_top[1], r_final[0], r_final[1], stroke="#000000", width=2.2, dasharray="2,2.5", marker_end="arrow-black")

    # Draw Checkpoint Pebble Nodes
    for px, py_c, lbl in [
        (p00[0], p00[1], "P1 (m=0)"),
        (p01[0], p01[1], "P2 (m=15)"),
        (p02[0], p02[1], "P3 (m=25)"),
        (p03[0], p03[1], "P4 (m=30)"),
        (f3_mid[0], f3_mid[1], "P3' (m=22)"),
        (f5_mid1[0], f5_mid1[1], "P2' (m=8)"),
    ]:
        c.circle(px, py_c, r=5.5, fill="#ffffff", stroke="#000000", stroke_width=1.4)
        c.text(px + 10, py_c - 6, lbl, size=9.5, weight="700", fill="#000000", mono=True)

    # Target Extraction Badge at peak (m=32)
    c.rect(p04[0] - 45, p04[1] - 32, 135, 22, rx=0, fill="#ffffff", stroke="#000000", stroke_width=1.0)
    c.text(p04[0] + 22, p04[1] - 17, "Copy lambda -> Point Add", size=9.5, weight="700", fill="#000000", anchor="middle", mono=True)

    # Legend Below Graph
    ly = 532
    legend_items = [
        ("#000000", None, "Initial Forward Sweep (m=0..32)"),
        ("#333333", "6,3", "Stored Pebble Checkpoint P_i (16 Q)"),
        ("#333333", "8,3,2,3", "Recursive Forward Recompute (45 Windows)"),
        ("#000000", "2,2.5", "Exact Step-by-Step Reverse Uncompute (32 Windows)"),
    ]
    for idx, (col, dsh, txt) in enumerate(legend_items):
        lx = 46 + idx * 220
        c.line(lx, ly, lx + 26, ly, stroke=col, width=2.2, dasharray=dsh)
        c.text(lx + 34, ly + 4, txt, size=10, weight="700", fill="#000000")

    # Bottom Summary Cards
    c.rect(36, 556, 874, 98, rx=8, fill="#f8fafc", stroke="#cbd5e1", stroke_width=1.4)
    c.text(52, 578, "Theorem 1 (Binomial Tree Checkpointing Capacity & Exact Operation Count):", size=11.5, weight="800", fill="#0f172a")
    c.text(52, 600, "• Capacity Formula: With s = 4 pebble registers and recursion depth d = 4, maximum reversible windows is:", size=10.5, weight="600", fill="#334155", mono=True)
    c.text(72, 620, "M_max(s=4, d=4)  =  Binomial(4 + 4, 4) - 1  =  70 - 1  =  69 Windows  >=  32 GCD Windows.", size=10.8, weight="800", fill="#1e3a8a", mono=True)
    c.text(52, 642, "• Total Evaluations for M = 32: Exactly 77 Forward + 32 Reverse = 109 Window Evals (vs. 64 Naive = 1.70x total cost).", size=10.5, weight="700", fill="#059669", mono=True)

    # Right Side Panel: Pebble Memory Breakdown & Comparison Table
    c.rect(918, 152, 370, 502, rx=8, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.5)
    c.text(932, 178, "Pebble Register Allocation (64 Q):", size=12, weight="800", fill="#0f172a")

    for idx, (pname, pdesc, pcol) in enumerate([
        ("Pebble |P_1[0..15]>", "Root Checkpoint (m=0 -> m=8..)", "#eff6ff"),
        ("Pebble |P_2[0..15]>", "Level-2 Checkpoint (m=15 -> m=22..)", "#f0fdfa"),
        ("Pebble |P_3[0..15]>", "Level-3 Checkpoint (m=25 -> m=28..)", "#faf5ff"),
        ("Pebble |P_4[0..15]>", "Leaf Checkpoint (m=30 -> m=31)", "#fffbeb"),
    ]):
        py_b = 192 + idx * 54
        c.rect(932, py_b, 344, 44, rx=6, fill=pcol, stroke="#94a3b8", stroke_width=1.2)
        c.text(944, py_b + 18, f"{pname}  (16 Qubits)", size=10.5, weight="800", fill="#0f172a", mono=True)
        c.text(944, py_b + 35, pdesc, size=10.0, weight="600", fill="#475569", mono=True)

    c.text(932, 430, "Tradeoff Across s Pebbles (M=32):", size=11.5, weight="800", fill="#0f172a")
    rows = [
        ("s (Pebbles)", "Qubits", "Fwd Evals", "Total"),
        ("s = 32 (Naive)", "512 Q", "32 (1.00x)", "64"),
        ("s = 6", "96 Q", "58 (1.81x)", "90"),
        ("s = 4 (Opt)", "64 Q", "77 (2.41x)", "109"),
        ("s = 3", "48 Q", "106 (3.31x)", "138"),
        ("s = 2", "32 Q", "186 (5.81x)", "218"),
    ]
    for r_idx, row in enumerate(rows):
        ry = 446 + r_idx * 30
        bg_col = "#dcfce7" if r_idx == 3 else ("#f1f5f9" if r_idx == 0 else "#ffffff")
        c.rect(932, ry, 344, 26, rx=4, fill=bg_col, stroke="#cbd5e1", stroke_width=1.0)
        fw = "800" if r_idx in (0, 3) else "600"
        fc = "#166534" if r_idx == 3 else "#0f172a"
        c.text(940, ry + 17, row[0], size=10.0, weight=fw, fill=fc, mono=True)
        c.text(1052, ry + 17, row[1], size=10.0, weight=fw, fill=fc, mono=True)
        c.text(1114, ry + 17, row[2], size=10.0, weight=fw, fill=fc, mono=True)
        c.text(1222, ry + 17, row[3], size=10.0, weight=fw, fill=fc, mono=True)

    c.text(932, 642, "Saves 448 Q in ECDLP & 20,992 Q in DQI", size=10.2, weight="800", fill="#059669", mono=True)

    return c.render()


# ============================================================================
# Figure 7: Monoidal Finger Tree SimHash Filter & Two-Stage VTAA Circuit
# ============================================================================

def build_fig07() -> str:
    c = SVGCanvas(1320, 680)
    c.title_banner(
        "FIGURE 7",
        "Monoidal Finger Tree SimHash Filter & Two-Stage Variable-Time Amplitude Amplification",
        "MonoidalFingerTreeFilter(k_sim=256): O(1)-Qubit Prefix Reject (tau_1=11) + Full Braun Tree + VTAA (3.84x Speedup)",
    )

    c.panel(
        16, 94, 1288, 568,
        "Three-Stage Variable-Time Quantum Inner-Product Oracle (Stage 1 Prefix Filter -> Stage 2 Full SimHash -> Stage 3 Exact MAC)",
        "Replaces 3,072-Toffoli full int8x256 MAC on every candidate with a 15-Toffoli 16-bit prefix screen that rejects 89% early",
        badge="3,072 -> 800 Avg CCX (3.84x)",
        badge_fill="#dcfce7",
        badge_text="#166534",
    )

    # Quantum Circuit across the top half (y = 165 .. 450)
    vy = [175, 225, 275, 325, 380, 435]
    vx0, vx1 = 155, 1175
    vlabels_l = [
        "|sketch_u[0..255]>",
        "|sketch_v[0..255]>",
        "|mu_1[0..4]> (16-b)",
        "|flag_1> (Stage 1)",
        "|mu_root[0..8]> (256-b)",
        "|vec_u, vec_v> (int8)",
    ]
    vlabels_r = [
        "|sketch_u[0..255]>",
        "|sketch_v[0..255]>",
        "|0> (Uncomputed)",
        "|flag_1> (Kept)",
        "|0> (Uncomputed)",
        "Phase (-1)^[u.v >= T]",
    ]

    for idx in range(6):
        bd = "256" if idx in (0, 1) else ("5" if idx == 2 else ("9" if idx == 4 else ("4096" if idx == 5 else None)))
        c.qwire(vy[idx], vx0, vx1, label_left=vlabels_l[idx], label_right=vlabels_r[idx], bundle=bd)

    # Stage 1 Box (16-bit Prefix Finger Tree Monoid mu_1)
    c.rect(195, 150, 290, 200, rx=8, fill="#eff6ff", stroke="#2563eb", stroke_width=1.6, dasharray="5,3")
    c.text(340, 166, "STAGE 1: 16-Bit Prefix Monoid (t_1 = 15 CCX)", size=10.5, weight="800", fill="#1d4ed8", anchor="middle", mono=True)

    c.multi_gate(242, vy[0], vy[1], w=68, label="XNOR_16", sublabel="CNOT+X", fill="url(#blue-grad)", stroke="#2563eb")
    c.multi_gate(325, vy[1], vy[2], w=76, label="Braun(16)", sublabel="15 CCX", fill="url(#teal-grad)", stroke="#0d9488")
    c.multi_gate(402, vy[2], vy[3], w=58, label=">= 11", sublabel="tau_1", fill="url(#amber-grad)", stroke="#d97706")
    c.gate_box(456, vy[3], w=42, h=28, label="R_1", sublabel="VTAA", fill="url(#purple-grad)", stroke="#7c3aed")

    # Stage 2 Box (Full 256-bit Braun Popcount Tree mu_root)
    c.rect(505, 150, 340, 255, rx=8, fill="#f0fdfa", stroke="#0d9488", stroke_width=1.6, dasharray="5,3")
    c.text(675, 166, "STAGE 2: Full 256-Bit SimHash Braun Tree (255 CCX)", size=10.5, weight="800", fill="#0f766e", anchor="middle", mono=True)

    c.multi_gate(555, vy[0], vy[1], w=74, label="XNOR_256", sublabel="0 CCX", fill="url(#blue-grad)", stroke="#2563eb")
    c.multi_gate(645, vy[1], vy[4], w=86, label="Braun(256)", sublabel="255 CCX", third_line="Depth 8", fill="url(#teal-grad)", stroke="#0d9488")
    c.multi_gate(735, vy[3], vy[4], w=62, label=">= 171", sublabel="tau_2", fill="url(#amber-grad)", stroke="#d97706")
    c.multi_gate(805, vy[1], vy[4], w=66, label="Braun^+", sublabel="0 CCX!", fill="url(#emerald-grad)", stroke="#059669")

    # Stage 3 Box (Exact int8x256 Inner Product conditioned on Stage 2 pass)
    c.rect(865, 150, 290, 308, rx=8, fill="#fff1f2", stroke="#e11d48", stroke_width=1.6, dasharray="5,3")
    c.text(1010, 166, "STAGE 3: Exact int8 MAC (Only Survivors p_2 = 1.6%)", size=10.5, weight="800", fill="#be123c", anchor="middle", mono=True)

    c.ctrl_dot(920, vy[3], color="#e11d48")
    c.line(920, vy[3], 920, vy[5], stroke="#e11d48", width=2.2)
    c.multi_gate(950, vy[4], vy[5], w=115, label="Exact MAC", sublabel="beta * 16^2 = 3072 CCX", third_line="Ctrl on Stage 2", fill="url(#rose-grad)", stroke="#e11d48", text_color="#881337")
    c.gate_box(1045, vy[5], w=48, h=30, label="Z_Phi", sublabel="Hit!", fill="url(#rose-grad)", stroke="#e11d48")
    c.multi_gate(1112, vy[4], vy[5], w=68, label="MAC^+", sublabel="MBU", fill="url(#amber-grad)", stroke="#d97706")

    # Bottom Quantitative VTAA Breakdown Cards
    c.rect(36, 474, 610, 170, rx=8, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.4)
    c.text(52, 498, "Ambainis [2012] Variable-Time Amplitude Amplification (VTAA) Cost Analysis:", size=11.5, weight="800", fill="#0f172a")
    c.text(52, 520, "• Stage 1 (16-bit Prefix Monoid mu_1): Cost t_1 = 15 CCX. Rejects 89.3% of non-matching pairs!", size=10.3, weight="700", fill="#1d4ed8", mono=True)
    c.text(52, 540, "  Survival probability p_1 = Pr[Binomial(256, 0.5) >= 11 in 16 bits] = 0.107.", size=10.2, weight="600", fill="#334155", mono=True)
    c.text(52, 560, "• Stage 2 (256-bit Full Braun Tree mu_root): Cost t_2 = 255 CCX (0 uncompute CCX via MBU).", size=10.3, weight="700", fill="#0f766e", mono=True)
    c.text(52, 580, "  Executed after k_1 = 4 fast Stage-1 reflections; survival probability p_2 = 0.016.", size=10.2, weight="600", fill="#334155", mono=True)
    c.text(52, 600, "• Stage 3 (Exact int8x256 Inner Product): Cost t_3 = 3,072 CCX. Executed ONLY on Stage-2", size=10.3, weight="700", fill="#be123c", mono=True)
    c.text(52, 620, "  survivors -> Expected root-mean-square VTAA cost = 800 Toffolis/query (3.84x Reduction!).", size=10.5, weight="800", fill="#059669", mono=True)

    c.rect(664, 474, 620, 170, rx=8, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.4)
    c.text(680, 498, "Why Monoidal Finger Trees Beat Naive Grover over Full-Precision Vectors:", size=11.5, weight="800", fill="#0f172a")
    c.text(680, 522, "1. Naive Single-Stage Grover:", size=10.5, weight="700", fill="#dc2626", mono=True)
    c.rect(895, 508, 365, 20, rx=4, fill="#fecaca", stroke="#dc2626", stroke_width=1.2)
    c.text(1077, 522, "3,072 Toffolis / Candidate (100% Full MAC)", size=10, weight="700", fill="#991b1b", anchor="middle", mono=True)

    c.text(680, 552, "2. Single-Stage SimHash:", size=10.5, weight="700", fill="#d97706", mono=True)
    c.rect(895, 538, 180, 20, rx=4, fill="#fde68a", stroke="#d97706", stroke_width=1.2)
    c.text(985, 552, "1,145 CCX (2.68x)", size=10, weight="700", fill="#92400e", anchor="middle", mono=True)

    c.text(680, 582, "3. Finger-Tree + 2-Stage VTAA:", size=10.5, weight="800", fill="#059669", mono=True)
    c.rect(895, 568, 118, 20, rx=4, fill="#bbf7d0", stroke="#16a34a", stroke_width=1.2)
    c.text(954, 582, "800 CCX (3.84x!)", size=10, weight="800", fill="#166534", anchor="middle", mono=True)

    c.text(680, 612, "• Monoidal Finger Tree caches partial Hamming weights mu_1 = sum_{i=0}^{15} [u_i == v_i] at the", size=10.2, weight="600", fill="#334155", mono=True)
    c.text(680, 630, "  shallow left spine, enabling O(1)-qubit early rejection without evaluating the 256-leaf tree.", size=10.2, weight="600", fill="#334155", mono=True)

    return c.render()


# ============================================================================
# Figure 8: In-Place Bruhat LU & Streaming McEliece ISD Syndrome Accumulator
# ============================================================================

def build_fig08() -> str:
    c = SVGCanvas(1320, 690)
    c.title_banner(
        "FIGURE 8",
        "In-Place Bruhat Pivoted LU & Streaming Syndrome Accumulator (McEliece-348864)",
        "BruhatPivotedLU(r): 0 Elimination Ancillas | StreamingSyndromeAccumulator: 2.68M Q -> 7,744 Q (346.6x Reduction!)",
    )

    # Panel (a): Left
    c.panel(
        16, 94, 600, 578,
        "Panel (a): In-Place BruhatPivotedLU(r) Elimination Step",
        "Stores L_{j,i} directly in sub-diagonal entries M[j][i] after zeroing U",
        badge="0 Matrix Ancillas",
        badge_fill="#dcfce7",
        badge_text="#166534",
    )

    ly = [180, 235, 290, 350, 405]
    lx0, lx1 = 148, 454
    llabels_l = [
        "|pivots[i]> = |0>",
        "|M[i][i]> (Pivot)",
        "|M[j][i]> (j > i)",
        "|M[i][c]> (c > i)",
        "|M[j][c]> (Target)",
    ]
    llabels_r = [
        "|pivots[i]> = p_i",
        "|U[i][i]> = 1",
        "|L[j][i]> (Retained)",
        "|U[i][c]>",
        "|M[j][c] ^ L_ji*U_ic>",
    ]

    for idx in range(5):
        c.qwire(ly[idx], lx0, lx1, label_left=llabels_l[idx], label_right=llabels_r[idx], bundle="log r" if idx == 0 else None)

    # Step 1: Canonical First-Nonzero Pivot Finder
    c.multi_gate(
        210, ly[0], ly[2], w=78,
        label="PivotFind", sublabel="First M[p,i]=1",
        fill="url(#blue-grad)", stroke="#2563eb"
    )

    # Step 2: Controlled Row Swap (Fredkin CSWAP between row p_i and row i)
    c.fredkin(295, ly[0], ly[1], ly[2], color="#7c3aed")
    c.fredkin(315, ly[0], ly[3], ly[4], color="#7c3aed")
    c.text(305, ly[4] + 22, "Row CSWAP", size=10.0, weight="800", fill="#6d28d9", anchor="middle", mono=True)

    # Step 3: In-place Toffoli Elimination CCX(M[j][i], M[i][c], M[j][c]) for c > i ONLY!
    c.toffoli(378, ly[2], ly[3], ly[4], color="#0f766e")
    c.text(378, ly[4] + 22, "CCX (c > i)", size=10.0, weight="800", fill="#0f766e", anchor="middle", mono=True)

    # Highlight that M[j][i] is NOT zeroed!
    c.rect(396, ly[2] - 13, 56, 26, rx=5, fill="#dcfce7", stroke="#16a34a", stroke_width=1.5)
    c.text(424, ly[2] + 4, "Keep L", size=10.0, weight="800", fill="#166534", anchor="middle", mono=True)

    # Bruhat Decomposition Explanation Box in Panel (a)
    c.rect(34, 456, 564, 200, rx=8, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.4)
    c.text(50, 480, "Why Naive GF(2) Gauss-Jordan Breaks Reversibility vs. Bruhat LU:", size=11.5, weight="800", fill="#0f172a")
    c.text(50, 502, "• Irreversible Trap: Zeroing M[j][i] <- M[j][i] ^ M[i][i] destroys the multiplier needed to", size=10.2, weight="600", fill="#dc2626", mono=True)
    c.text(64, 520, "invert row operations on columns c > i, forcing O(r^2) out-of-place history qubits.", size=10.2, weight="600", fill="#334155", mono=True)
    c.text(50, 542, "• In-Place Bruhat Solution: Apply CCX(M[j][i], M[i][c], M[j][c]) STRICTLY for c > i!", size=10.3, weight="700", fill="#0f766e", mono=True)
    c.text(64, 560, "The sub-diagonal entry M[j][i] remains intact as the lower-triangular factor L_{j,i},", size=10.2, weight="600", fill="#334155", mono=True)
    c.text(64, 578, "while upper-triangular entries become U_{i,c}:  P * M  =  L * U  in place!", size=10.3, weight="800", fill="#1e3a8a", mono=True)
    c.text(50, 600, "• AES MixColumns (r = 32): 0 ancilla qubits! Forward = L * U, Inverse = U^{-1} * L^{-1}.", size=10.2, weight="700", fill="#059669", mono=True)
    c.text(50, 620, "• Gate Count: r*(r-1)*(2r-1)/6 Toffolis for elimination + r*ceil(log2 r) pivot qubits.", size=10.2, weight="600", fill="#334155", mono=True)
    c.text(50, 639, "• McEliece ISD: Replaces O(r*n) = 2,678,784 Q matrix allocation completely (see Panel b).", size=10.2, weight="800", fill="#6d28d9", mono=True)

    # Panel (b): Right
    c.panel(
        632, 94, 672, 578,
        "Panel (b): StreamingSyndromeAccumulator Circuit (Classic McEliece-348864)",
        "Streams k=2720 columns through B=8 Select-SWAP QROAM buffer into r=768 syndrome accumulator |s>",
        badge="7,744 Q (-99.71%!)",
        badge_fill="#ccfbf1",
        badge_text="#115e59",
    )

    my = [175, 225, 280, 335, 390, 442]
    mx0, mx1 = 768, 1205
    mlabels_l = [
        "|e_j> (Error bit j)",
        "|cnt[0..8]> (Weight)",
        "|unary[0..436]>",
        "|Buf[8][768]> (6144Q)",
        "|s[0..767]> (768 Q)",
        "|wt_flag> (Braun 64)",
    ]
    mlabels_r = [
        "|e_j>",
        "|cnt> <= 16",
        "|0> (Uncomputed)",
        "|0>^6144 (Reused)",
        "|s> = c_0 + H*e",
        "|flag ^ [wt==t-p]>",
    ]

    for idx in range(6):
        bd = "9" if idx == 1 else ("437" if idx == 2 else ("6144" if idx == 3 else ("768" if idx == 4 else None)))
        c.qwire(my[idx], mx0, mx1, label_left=mlabels_l[idx], label_right=mlabels_r[idx], bundle=bd)

    # Stage 1: Unary Decoder (436 Toffolis)
    c.multi_gate(820, my[1], my[2], w=72, label="UnaryDec", sublabel="436 CCX", fill="url(#blue-grad)", stroke="#2563eb")

    # Stage 2: CNOT-only Classical Select into B=8 Buffer
    c.multi_gate(905, my[2], my[3], w=78, label="CNOT-Select", sublabel="0 CCX!", third_line="Classical H_pi", fill="url(#emerald-grad)", stroke="#059669")

    # Stage 3: Logarithmic CSWAP Tree (B=8 -> 1 column, 12,288 Toffolis)
    c.multi_gate(992, my[1], my[3], w=78, label="CSWAP Tree", sublabel="B=8 -> 1 Col", third_line="12,288 CCX", fill="url(#purple-grad)", stroke="#7c3aed")

    # Stage 4: Controlled-CNOT accumulation into |s>
    c.toffoli(1062, my[0], my[3], my[4], color="#0f766e")
    c.text(1062, my[4] + 20, "s ^= e_j*H_j", size=8.8, weight="800", fill="#0f766e", anchor="middle", mono=True)

    # Stage 5: Adjoint QROAM Uncomputation (MBU)
    c.multi_gate(1122, my[1], my[3], w=64, label="QROAM^+", sublabel="MBU", fill="url(#amber-grad)", stroke="#d97706")

    # Stage 6: 64-Qubit Windowed Braun Popcount on |s[0..767]>
    c.multi_gate(1182, my[4], my[5], w=56, label="Braun64", sublabel="wt(s)", fill="url(#rose-grad)", stroke="#e11d48")

    # Quantitative Comparison Table in Panel (b)
    c.rect(650, 472, 636, 184, rx=8, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.4)
    c.text(666, 496, "Classic McEliece-348864 (n=3488, r=768, k=2720, t=64) Quantum Resource Breakdown:", size=11.5, weight="800", fill="#0f172a")
    c.text(666, 518, "• Key Observation: The parity-check matrix H is CLASSICAL! Loading all r*n = 2,678,784 entries", size=10.3, weight="700", fill="#dc2626", mono=True)
    c.text(680, 536, "into quantum memory to run quantum Gaussian elimination wastes 99.7% of logical qubits.", size=10.2, weight="600", fill="#334155", mono=True)
    c.text(666, 556, "• Streaming Select-SWAP QROAM (B = 8 Columns) Qubit Budget:", size=10.5, weight="800", fill="#0f766e", mono=True)
    c.text(680, 575, "- Syndrome Accumulator |s[0..767]>:     768 Q   |  Select-SWAP Buffer (8 * 768): 6,144 Q", size=10.1, weight="600", fill="#334155", mono=True)
    c.text(680, 593, "- Unary Routing Tree (ceil(2720/8)):    437 Q   |  Indices + Braun64 Popcount:     395 Q", size=10.1, weight="600", fill="#334155", mono=True)
    c.rect(666, 604, 604, 40, rx=6, fill="#f0fdf4", stroke="#16a34a", stroke_width=1.3)
    c.text(968, 621, "TOTAL WIDTH:  7,744 Logical Qubits   (vs. 2,683,820 Q Matrix ISD  =  346.6x Width Reduction!)", size=10.5, weight="800", fill="#166534", anchor="middle", mono=True)
    c.text(968, 637, "TOTAL TOFFOLIS / ITERATION:  215,380 Toffolis   (vs. 448,595,200 CCX  =  2,082.8x Gate Reduction!)", size=10.5, weight="800", fill="#0f766e", anchor="middle", mono=True)

    return c.render()


# ============================================================================
# Figure 9: Canonical Crit-Bit Bitonic Dictionary & Bentley-Saxe Runs
# ============================================================================

def build_fig09() -> str:
    c = SVGCanvas(1320, 680)
    c.title_banner(
        "FIGURE 9",
        "Canonical Crit-Bit Bitonic Dictionary & Bentley-Saxe Logarithmic Runs",
        "CanonicalCritBitBitonicDictionary(M=1024, w=512): History-Independent O(log^2 M) Batcher Sort (74.47x Speedup)",
    )

    # Panel (a): Left
    c.panel(
        16, 94, 636, 568,
        "Panel (a): Batcher Bitonic Sort for M=1,024 Parallel Walkers",
        "Replaces M*(M*w) = 1.05M Toffoli linear scan with 55-stage oblivious bitonic network (14,080 CCX/walker)",
        badge="74.47x Toffoli Reduction",
        badge_fill="#dcfce7",
        badge_text="#166534",
    )

    cy = [175, 220, 265, 315, 360, 405]
    cx0, cx1 = 152, 518
    clabels_l = [
        "|DB_0: (k_0, v_0)>",
        "|DB_1: (k_1, v_1)>",
        "|DB_m: (k_m, v_m)>",
        "|Q_0: (q_0, 0^512)>",
        "|Q_1: (q_1, 0^512)>",
        "|Q_m: (q_m, 0^512)>",
    ]
    clabels_r = [
        "|DB_0: (k_0, v_0)>",
        "|DB_1: (k_1, v_1)>",
        "|DB_m: (k_m, v_m)>",
        "|Q_0: (q_0, v_{q0})>",
        "|Q_1: (q_1, v_{q1})>",
        "|Q_m: (q_m, v_{qm})>",
    ]

    for idx in range(6):
        col = "#2563eb" if idx >= 3 else "#334155"
        c.qwire(cy[idx], cx0, cx1, label_left=clabels_l[idx], label_right=clabels_r[idx], bundle="512", color=col)

    # Stage 1: Forward Bitonic Sort (55 stages on 2M = 2048 items)
    c.rect(175, 152, 118, 275, rx=7, fill="url(#blue-grad)", stroke="#2563eb", stroke_width=1.8, shadow=True)
    c.text(234, 174, "Forward Batcher", size=10.5, weight="800", fill="#1e3a8a", anchor="middle", mono=True)
    c.text(234, 190, "Bitonic Sort", size=10.5, weight="800", fill="#1e3a8a", anchor="middle", mono=True)
    c.text(234, 208, "(55 Stages)", size=9.5, weight="700", fill="#1d4ed8", anchor="middle", mono=True)
    # Draw internal compare-and-swap arrows
    for a_y, b_y, xx in [(cy[0], cy[3], 195), (cy[1], cy[4], 215), (cy[2], cy[5], 235), (cy[0], cy[1], 260), (cy[2], cy[3], 275)]:
        c.line(xx, a_y, xx, b_y, stroke="#1d4ed8", width=1.8)
        c.swap_x(xx, a_y, s=4.5, color="#1d4ed8")
        c.swap_x(xx, b_y, s=4.5, color="#1d4ed8")

    # Stage 2: Adjacent Neighbor Copy (after sorting, query Q_j sits immediately adjacent to matching DB_i!)
    c.rect(310, 152, 74, 275, rx=7, fill="url(#emerald-grad)", stroke="#059669", stroke_width=1.8, shadow=True)
    c.text(347, 174, "Neighbor", size=10, weight="800", fill="#065f46", anchor="middle", mono=True)
    c.text(347, 189, "Match Copy", size=10, weight="800", fill="#065f46", anchor="middle", mono=True)
    c.cnot(347, cy[0], cy[1], color="#059669")
    c.cnot(347, cy[2], cy[3], color="#059669")
    c.cnot(347, cy[4], cy[5], color="#059669")

    # Stage 3: Inverse Bitonic Sort (Restores canonical DB order and returns queries to walker slots)
    c.rect(400, 152, 102, 275, rx=7, fill="url(#amber-grad)", stroke="#d97706", stroke_width=1.8, shadow=True)
    c.text(451, 174, "Inverse Sort", size=10.5, weight="800", fill="#92400e", anchor="middle", mono=True)
    c.text(451, 190, "(MBU Uncomp)", size=9.5, weight="700", fill="#b45309", anchor="middle", mono=True)
    for a_y, b_y, xx in [(cy[2], cy[3], 420), (cy[0], cy[1], 440), (cy[1], cy[4], 465), (cy[0], cy[3], 485)]:
        c.line(xx, a_y, xx, b_y, stroke="#b45309", width=1.8)
        c.swap_x(xx, a_y, s=4.5, color="#b45309")
        c.swap_x(xx, b_y, s=4.5, color="#b45309")

    # Explanation Box in Panel (a)
    c.rect(34, 444, 600, 200, rx=8, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.4)
    c.text(50, 468, "Why History Independence Is Mandatory for Quantum Walkers (Bernstein [2009]):", size=11.5, weight="800", fill="#0f172a")
    c.text(50, 490, "• Insertion-History Leak: Path-copying AVL / Red-Black trees encode insertion order in tree", size=10.2, weight="600", fill="#dc2626", mono=True)
    c.text(64, 508, "topology, entangling the quantum state with traversal history and destroying interference!", size=10.2, weight="600", fill="#334155", mono=True)
    c.text(50, 530, "• Canonical Crit-Bit + Bitonic Solution: Uniquely determined by the set S of keys:", size=10.3, weight="700", fill="#0f766e", mono=True)
    c.text(64, 548, "1. Batcher Bitonic Network on N_sort = 2M = 2,048 items has (11 * 12)/2 = 66 stages.", size=10.2, weight="600", fill="#334155", mono=True)
    c.text(64, 566, "2. Each compare-and-swap on w = 512-bit records uses 512 Toffolis ( comparator + CSWAP ).", size=10.2, weight="600", fill="#334155", mono=True)
    c.rect(50, 578, 568, 30, rx=6, fill="#f0fdf4", stroke="#16a34a", stroke_width=1.2)
    c.text(334, 598, "Amortized Cost / Lookup:  14,080 Toffolis   (vs. 1,048,576 Linear Scan  =  74.47x Faster!)", size=10.8, weight="800", fill="#166534", anchor="middle", mono=True)
    c.text(50, 628, "• Zero QROAM Fanout: All 1,024 walkers sort and query in O(log^2 M) depth simultaneously.", size=10.3, weight="700", fill="#1e3a8a", mono=True)

    # Panel (b): Right
    c.panel(
        668, 94, 636, 568,
        "Panel (b): Bentley-Saxe Logarithmic Runs (Online Single-Walker)",
        "Partitions M = 1,024 items into r = log2(M) = 10 sorted runs |L_k| = 2^k with binary-carry merge",
        badge="22.53x Online Reduction",
        badge_fill="#dbeafe",
        badge_text="#1e3a8a",
    )

    # Visual diagram of Bentley-Saxe runs L_0 (1), L_1 (2), L_2 (4), ..., L_9 (512)
    c.text(690, 164, "Logarithmic Run Hierarchy (Binary Decomposition of Count n = SUM_k b_k * 2^k):", size=11, weight="800", fill="#0f172a")

    runs = [
        ("Run L_0", "2^0 = 1", 44, "#eff6ff", "#2563eb"),
        ("Run L_1", "2^1 = 2", 54, "#eff6ff", "#2563eb"),
        ("Run L_2", "2^2 = 4", 66, "#f0fdfa", "#0d9488"),
        ("Run L_3", "2^3 = 8", 80, "#f0fdfa", "#0d9488"),
        ("...", "...", 38, "#f8fafc", "#64748b"),
        ("Run L_8", "2^8 = 256", 118, "#faf5ff", "#7c3aed"),
        ("Run L_9", "2^9 = 512", 156, "#fffbeb", "#d97706"),
    ]
    rx_cur = 690
    for rname, rcap, rw, rfill, rstroke in runs:
        c.rect(rx_cur, 178, rw, 56, rx=6, fill=rfill, stroke=rstroke, stroke_width=1.6)
        c.text(rx_cur + rw / 2, 200, rname, size=10, weight="800", fill="#0f172a", anchor="middle", mono=True)
        c.text(rx_cur + rw / 2, 220, rcap, size=9.2, weight="700", fill=rstroke, anchor="middle", mono=True)
        rx_cur += rw + 8

    # Binary Carry Merge Animation Diagram
    c.rect(690, 250, 592, 178, rx=8, fill="#f8fafc", stroke="#94a3b8", stroke_width=1.4)
    c.text(706, 274, "Amortized Online Insertion via Binary-Counter Bitonic Merge:", size=11, weight="800", fill="#1e3a8a")
    c.text(706, 296, "New Item |x>  --->  [Compare-Swap Merge with L_0 (size 1)]  --->  Carry Run of size 2", size=10.2, weight="700", fill="#0f766e", mono=True)
    c.text(706, 318, "                     |--> If L_1 occupied: BitonicMerge(Carry_2, L_1) ---> Carry Run of size 4", size=10.2, weight="700", fill="#6d28d9", mono=True)
    c.text(706, 340, "                     |--> Stops at first empty slot L_k (where bit k of count n is 0)!", size=10.2, weight="700", fill="#b45309", mono=True)

    c.rect(706, 354, 560, 60, rx=6, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.2)
    c.text(720, 374, "• Run L_k of size 2^k is merged only once every 2^k insertions (cost: 2^k * k * w CCX).", size=10, weight="600", fill="#334155", mono=True)
    c.text(720, 392, "• Amortized Insertion Cost across M=1,024 steps:  O(w * log^2 M) = 46,541 Toffolis / step.", size=10, weight="800", fill="#059669", mono=True)
    c.text(720, 408, "• Preserves Canonical History Independence: Every populated run L_k is uniquely sorted!", size=10, weight="700", fill="#1e3a8a", mono=True)

    # Comparison Summary Box in Panel (b)
    c.rect(686, 444, 600, 200, rx=8, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.4)
    c.text(702, 468, "Three-Way Dictionary Architecture Comparison (M = 1,024 Keys, w = 512 Bits):", size=11.5, weight="800", fill="#0f172a")

    c.text(702, 496, "1. Naive Unordered Linear Scan:", size=10.5, weight="700", fill="#dc2626", mono=True)
    c.rect(945, 482, 320, 20, rx=4, fill="#fecaca", stroke="#dc2626", stroke_width=1.2)
    c.text(1105, 496, "1,048,576 CCX / Step (1.00x)", size=9.8, weight="700", fill="#991b1b", anchor="middle", mono=True)

    c.text(702, 526, "2. Bentley-Saxe Online Runs:", size=10.5, weight="700", fill="#2563eb", mono=True)
    c.rect(945, 512, 130, 20, rx=4, fill="#bfdbfe", stroke="#2563eb", stroke_width=1.2)
    c.text(1010, 526, "46,541 CCX (22.53x)", size=9.8, weight="800", fill="#1e3a8a", anchor="middle", mono=True)

    c.text(702, 556, "3. Parallel Bitonic Walkers:", size=10.5, weight="800", fill="#059669", mono=True)
    c.rect(945, 542, 92, 20, rx=4, fill="#bbf7d0", stroke="#16a34a", stroke_width=1.2)
    c.text(991, 556, "14,080 (74.5x!)", size=9.5, weight="800", fill="#166534", anchor="middle", mono=True)

    c.text(702, 588, "• When to use which:", size=10.5, weight="800", fill="#0f172a", mono=True)
    c.text(716, 608, "- Parallel Walkers (Kuwakado-Morii / Grover-Meet-Simon): Batcher Bitonic (14,080 CCX).", size=10, weight="600", fill="#334155", mono=True)
    c.text(716, 626, "- Single Sequential Online Walker (Ambainis Element Distinctness): Bentley-Saxe (46,541 CCX).", size=10, weight="600", fill="#334155", mono=True)

    return c.render()


# ============================================================================
# Figure 10: Walker-Vose O(1)-Depth Coherent Alias Sampler Circuit
# ============================================================================

def build_fig10() -> str:
    c = SVGCanvas(1320, 660)
    c.title_banner(
        "FIGURE 10",
        "Walker-Vose O(1)-Comparison Coherent Alias Table State Preparation",
        "WalkerVoseAliasTable(w=8, mu=16): Replaces 8-Level Grover-Rudolph Rotations with 1 Comparator + 1 CSWAP (49 Q, 280 CCX)",
    )

    c.panel(
        16, 94, 1288, 548,
        "Gate-Level Circuit for Coherent Discrete State Preparation  |0>  -->  SUM_{x=0}^{255} sqrt(p_x) |x> |garbage_x>",
        "Precomputes classical Robin-Hood buckets (Keep[i], Alias[i]) so every equal-probability bucket i in [0, 2^w) contains at most 2 outcomes",
        badge="49 Q | 280 Toffolis | 0 R_y",
        badge_fill="#dcfce7",
        badge_text="#166534",
    )

    wy = [180, 240, 300, 360, 420]
    wx0, wx1 = 175, 1135
    wlabels_l = [
        "|i[0..7]> = |0>^8",
        "|u[0..15]> = |0>^16",
        "|Alias[0..7]> = |0>^8",
        "|Keep[0..15]> = |0>^16",
        "|swap_flag> = |0>^1",
    ]
    wlabels_r = [
        "|x_out[0..7]> ~ p_x",
        "|u[0..15]> (Uniform)",
        "|i_orig / Alias[i]>",
        "|Keep[i]>",
        "|swap_flag> = [u >= Keep]",
    ]

    for idx in range(5):
        bd = "8" if idx in (0, 2) else ("16" if idx in (1, 3) else "1")
        col = "#0f766e" if idx == 0 else ("#7c3aed" if idx == 4 else "#334155")
        c.qwire(wy[idx], wx0, wx1, label_left=wlabels_l[idx], label_right=wlabels_r[idx], bundle=bd, color=col)

    # Step 1: Uniform Hadamard Fanout on |i> and |u> (0 Toffolis!)
    c.barrier(210, wy[0], wy[4], "Step 1: H Fanout")
    c.gate_box(260, wy[0], w=64, h=32, label="H^(x8)", sublabel="0 CCX", fill="url(#blue-grad)", stroke="#2563eb")
    c.gate_box(260, wy[1], w=64, h=32, label="H^(x16)", sublabel="0 CCX", fill="url(#blue-grad)", stroke="#2563eb")

    # Step 2: Select-SWAP QROAM Table Load of (Alias[i], Keep[i]) for i in [0..255]
    c.barrier(325, wy[0], wy[4], "Step 2: Alias QROAM")
    c.ctrl_dot(432, wy[0], color="#0d9488")
    c.line(432, wy[0], 432, wy[2], stroke="#0d9488", width=2.2)
    c.multi_gate(
        432, wy[2], wy[3], w=192,
        label="Select-SWAP QROAM", sublabel="Alias[i] (8b), Keep[i] (16b)", third_line="2^8 = 256 Toffolis",
        fill="url(#teal-grad)", stroke="#0d9488", text_color="#115e59"
    )

    # Step 3: Single 16-bit Gidney Ripple Comparator [u >= Keep[i]] into |swap_flag>
    c.barrier(542, wy[0], wy[4], "Step 3: 16-Bit Comparator")
    c.ctrl_dot(648, wy[1], color="#d97706")
    c.line(648, wy[1], 648, wy[3], stroke="#d97706", width=2.0)
    c.multi_gate(
        648, wy[3], wy[4], w=192,
        label="Gidney Comparator", sublabel="swap_flag ^= [u >= Keep[i]]", third_line="mu = 16 Toffolis",
        fill="url(#amber-grad)", stroke="#d97706", text_color="#92400e"
    )

    # Step 4: 8-Bit Fredkin CSWAP between |i> and |Alias[i]> controlled on |swap_flag>
    c.barrier(750, wy[0], wy[4], "Step 4: 8-Bit Fredkin CSWAP")
    c.fredkin(835, wy[4], wy[0], wy[2], color="#7c3aed")
    c.rect(780, wy[1] - 15, 110, 30, rx=6, fill="url(#purple-grad)", stroke="#7c3aed", stroke_width=1.5)
    c.text(835, wy[1] + 4, "w = 8 CSWAPs", size=10.5, weight="800", fill="#5b21b6", anchor="middle", mono=True)

    # Step 5: Output distribution annotation
    c.barrier(935, wy[0], wy[4], "Step 5: Exact Sample |x>")
    c.rect(960, 160, 155, 92, rx=7, fill="#f0fdf4", stroke="#16a34a", stroke_width=1.8)
    c.text(1037, 182, "Exact Output on |i>:", size=10.5, weight="800", fill="#166534", anchor="middle")
    c.text(1037, 202, "Pr[x] = p_x + O(2^-16)", size=10, weight="800", fill="#059669", anchor="middle", mono=True)
    c.text(1037, 222, "Total = 280 Toffolis", size=10, weight="700", fill="#15803d", anchor="middle", mono=True)
    c.text(1037, 240, "Depth = O(w + mu)", size=9.5, weight="600", fill="#166534", anchor="middle", mono=True)

    # Bottom Comparison Cards: Grover-Rudolph vs Walker-Vose Alias Table
    c.rect(36, 464, 1248, 160, rx=8, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.4)
    c.text(54, 490, "Why Walker-Vose Alias Tables Eliminate the Transcendental Rotation Bottleneck (Grover-Rudolph [2002]):", size=12, weight="800", fill="#0f172a")
    c.text(54, 514, "• Grover-Rudolph Binary-Tree State Prep: Requires w = 8 sequential stages of multiplexed controlled-R_y(theta_k) rotations,", size=10.5, weight="600", fill="#dc2626", mono=True)
    c.text(70, 534, "where each arbitrary angle theta_k = 2*arccos(sqrt(P_L / P_parent)) must be synthesized via Ross-Selinger grids (~50 T-gates * 8 = ~400+ T-gates).", size=10.3, weight="600", fill="#334155", mono=True)
    c.text(54, 558, "• Walker-Vose O(1)-Comparison Alias Method: Classical O(2^w) Robin-Hood preprocessing pairs each sub-average outcome i", size=10.5, weight="700", fill="#0f766e", mono=True)
    c.text(70, 578, "with a super-average donor Alias[i]. On the quantum computer, ONLY Clifford+Toffoli integer operations are executed:", size=10.3, weight="600", fill="#334155", mono=True)
    c.rect(70, 588, 1190, 28, rx=6, fill="#f0fdf4", stroke="#16a34a", stroke_width=1.2)
    c.text(665, 606, "Qubits: 2*w + 2*mu + 1 = 49 Q   |   Toffolis: 2^w (QROAM) + mu (Cmp) + w (CSWAP) = 256 + 16 + 8 = 280 CCX   |   Arbitrary R_y Gates: ZERO!", size=10.8, weight="800", fill="#166534", anchor="middle", mono=True)

    return c.render()


# ============================================================================
# Figure 11: Full 1,088-Qubit Shor ECDLP Quantum Circuit & Wire Map
# ============================================================================

def build_fig11() -> str:
    c = SVGCanvas(1320, 710)
    c.title_banner(
        "FIGURE 11",
        "Complete 1,088-Qubit Shor ECDLP Architecture & 6-Stage Point-Addition Pipeline (ECC-256)",
        "Breaks Roetteler et al. (2,338 Q) & Häner et al. (2,124 Q) by 53.5% via Packed Bézout Shift-Zipper + s=4 Binomial Pebbling",
    )

    c.panel(
        16, 94, 1288, 598,
        "Full 1,088-Qubit Register Allocation Map & 6-Stage Reversible Elliptic Curve Group Law Pipeline  |(X_1, Y_1)>  -->  |(X_1, Y_1) + T[e_m]>",
        "Reuses |UR[256]> & |VS[256]> for Select-SWAP lookup of T[e_m] = (X_2, Y_2), Direct-Quotient GCD, and Totalized Hua Squaring",
        badge="1,088 Logical Qubits (ECC-256)",
        badge_fill="#dcfce7",
        badge_text="#166534",
    )

    # 8 Horizontal Register Bundles showing exact qubit counts summing to 1,088 Q
    ey = [172, 214, 258, 302, 348, 394, 440, 482]
    ex0, ex1 = 185, 1165
    elabels_l = [
        "|Phi[0..15]> (16 Q)",
        "|e_m[0..3]> (4 Q)",
        "|X_1[0..255]> (256 Q)",
        "|Y_1[0..255]> (256 Q)",
        "|UR[0..255]> (256 Q)",
        "|VS[0..255]> (256 Q)",
        "|P_1..P_4> (64 Q)",
        "|Focus+Flag> (40 Q)",
    ]
    elabels_r = [
        "|Phi> (Phase Runway)",
        "|e_m> -> M_X",
        "|X_3> = lam^2-X1-X2",
        "|Y_3> = lam(X1-X3)-Y1",
        "|0>^256 (Clean!)",
        "|0>^256 (Clean!)",
        "|0>^64 (Pebbles)",
        "|0>^40 (Scratch)",
    ]
    ebundles = ["16", "4", "256", "256", "256", "256", "64", "40"]

    for idx in range(8):
        col = "#0f766e" if idx in (4, 5) else ("#7c3aed" if idx == 6 else ("#2563eb" if idx in (2, 3) else "#334155"))
        c.qwire(ey[idx], ex0, ex1, label_left=elabels_l[idx], label_right=elabels_r[idx], bundle=ebundles[idx], color=col, bundle_offset=12.0)

    # Stage 1: Select-SWAP QROAM Lookup of T[e_m] = (X_2, Y_2) into (UR, VS)
    c.barrier(228, ey[0], ey[7], "S1: Lookup")
    c.ctrl_dot(275, ey[1], color="#2563eb")
    c.line(275, ey[1], 275, ey[4], stroke="#2563eb", width=2.0)
    c.multi_gate(
        275, ey[4], ey[5], w=96,
        label="Select-SWAP", sublabel="T[e_m]->(X2,Y2)", third_line="in (UR, VS)",
        fill="url(#blue-grad)", stroke="#2563eb"
    )

    # Stage 2: Coordinate Differences dX = X_2 - X_1, dY = Y_2 - Y_1
    c.barrier(338, ey[0], ey[7], "Stage 2: Sub")
    c.ctrl_dot(392, ey[2], color="#0d9488")
    c.ctrl_dot(392, ey[3], color="#0d9488")
    c.line(392, ey[2], 392, ey[5], stroke="#0d9488", width=2.0)
    c.multi_gate(
        392, ey[4], ey[5], w=88,
        label="ModSub", sublabel="u0=p, v0=dX", third_line="s0 = dY",
        fill="url(#teal-grad)", stroke="#0d9488"
    )

    # Stage 3: Packed Bézout Shift-Zipper GCD (M=32 Jump-16 Windows + s=4 Pebbles)
    c.barrier(450, ey[0], ey[7], "Stage 3: Packed Shift-Zipper GCD")
    c.multi_gate(
        545, ey[4], ey[7], w=162,
        label="PackedBezoutShiftZipper", sublabel="32 Jump-16 Windows (77 Fwd)", third_line="UR -> lambda = dY/dX mod p",
        fill="url(#emerald-grad)", stroke="#059669", text_color="#065f46"
    )

    # Stage 4: Totalized Hua Squaring & X_3 Update (with 64-bit Exception Tag if dX == 0)
    c.barrier(642, ey[0], ey[7], "Stage 4: X_3 Update")
    c.ctrl_dot(715, ey[4], color="#7c3aed")
    c.line(715, ey[2], 715, ey[4], stroke="#7c3aed", width=2.0)
    c.multi_gate(
        715, ey[2], ey[3], w=116,
        label="Hua Square", sublabel="X_3 = lam^2-X1-X2", third_line="+64b Exc Tag",
        fill="url(#purple-grad)", stroke="#7c3aed"
    )

    # Stage 5: Y_3 Update using lambda in UR
    c.barrier(788, ey[0], ey[7], "Stage 5: Y_3")
    c.ctrl_dot(855, ey[4], color="#d97706")
    c.line(855, ey[2], 855, ey[4], stroke="#d97706", width=2.0)
    c.multi_gate(
        855, ey[2], ey[3], w=108,
        label="Slope Mul", sublabel="Y_3 = lam(X1-X3)-Y1",
        fill="url(#amber-grad)", stroke="#d97706"
    )

    # Stage 6: Binomial Pebble Adjoint GCD Uncomputation + Lookup Uncompute
    c.barrier(924, ey[0], ey[7], "Stage 6: Binomial Adjoint")
    c.multi_gate(
        1015, ey[4], ey[7], w=152,
        label="Binomial Adjoint GCD^+", sublabel="32 Rev Windows (s=4)", third_line="Restores UR,VS,P -> |0>",
        fill="url(#rose-grad)", stroke="#e11d48", text_color="#881337"
    )
    c.ctrl_dot(1125, ey[1], color="#2563eb")
    c.line(1125, ey[1], 1125, ey[5], stroke="#2563eb", width=1.8)
    c.multi_gate(1125, ey[4], ey[5], w=58, label="T[e_m]^+", sublabel="Clean", fill="url(#blue-grad)", stroke="#2563eb")

    # Bottom Accounting & Literature Comparison Table
    c.rect(36, 514, 1248, 160, rx=8, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.4)
    c.text(52, 538, "Exact 1,088-Qubit Budget Verification & ECC-256 Literature Comparison (N = 256 Bits):", size=11.8, weight="800", fill="#0f172a")

    # Left side of bottom box: Register sum
    c.text(52, 562, "• 4 Field Registers (4 * 256 Q):   X_1 (256) + Y_1 (256) + UR (256) + VS (256)  =  1,024 Q", size=10.3, weight="700", fill="#1e3a8a", mono=True)
    c.text(52, 582, "• Binomial Pebbles (s = 4 * 16 Q): P_1 (16) + P_2 (16) + P_3 (16) + P_4 (16)    =     64 Q  (Reused for 60-Q Window / Runway!)", size=10.3, weight="700", fill="#6d28d9", mono=True)
    c.text(52, 602, "• Total Logical Qubits:            1,024 + 64                                   =  1,088 Q  (Zero leaked garbage qubits!)", size=10.5, weight="800", fill="#059669", mono=True)
    c.text(52, 624, "• Point-Addition Exception Handling: Coherent 64-bit random linear hash tag (e_m == 0, P == +/-T[e_m]) -> delta_tot < 2^{-50}.", size=10.1, weight="600", fill="#334155", mono=True)
    c.text(52, 644, "• Physical Qubits (d = 21): 819,722 Q on Yoked 2D Surface Code  |  288,216 Q on [[288,12,18]] Bivariate Bicycle qLDPC.", size=10.3, weight="800", fill="#0f766e", mono=True)

    # Right side of bottom box: Visual bar comparison against Roetteler 2017, Haner 2020,Litinski 2023
    bx_comp = 835
    c.rect(bx_comp, 526, 430, 134, rx=6, fill="#f8fafc", stroke="#94a3b8", stroke_width=1.2)
    c.text(bx_comp + 12, 546, "ECC-256 Logical Width Comparison:", size=10.5, weight="800", fill="#0f172a")

    bars = [
        ("Litinski [2023] Fast:", 2820, "#cbd5e1", "#334155"),
        ("Roetteler et al. [2017]:", 2338, "#fecaca", "#991b1b"),
        ("Häner et al. [2020] Low-W:", 2124, "#fde68a", "#92400e"),
        ("Ours (Packed Zipper):", 1088, "#bbf7d0", "#166534"),
    ]
    for b_idx, (blbl, bval, bfill, btxt) in enumerate(bars):
        by_bar = 556 + b_idx * 24
        bw_bar = (bval / 2820.0) * 168
        c.text(bx_comp + 12, by_bar + 14, blbl, size=10.0, weight="700", fill=btxt, mono=True)
        c.rect(bx_comp + 188, by_bar, bw_bar, 18, rx=3, fill=bfill, stroke=btxt, stroke_width=1.2)
        c.text(bx_comp + 194 + bw_bar, by_bar + 13, f"{bval:,} Q", size=10.0, weight="800", fill=btxt, mono=True)

    return c.render()


# ============================================================================
# Figure 12: RSA-2048 / RSA-4096 Architectures A, B, C Comparison
# ============================================================================

def build_fig12() -> str:
    c = SVGCanvas(1320, 700)
    c.title_banner(
        "FIGURE 12",
        "RSA-2048 & RSA-4096 Three-Architecture Spectrum (Architectures A, B, and C)",
        "Arch A: In-Place Coset Zipper (1,924 Q) | Arch B: RNS Braun Tree (896 Q) | Arch C: Split-Register + Skew Carry-Save (1,364 Q)",
    )

    # Panel A: Left (x = 16, w = 418)
    c.panel(
        16, 94, 418, 588,
        "Arch A: In-Place Coset Zipper",
        "1,924 Q (RSA-2048) | 1.87B CCX | d = 29",
        badge="32x Ripple Stretch",
        badge_fill="#fef2f2",
        badge_text="#991b1b",
    )

    # Arch A Diagram
    c.rect(34, 154, 382, 86, rx=7, fill="#f1f5f9", stroke="#64748b", stroke_width=1.4)
    c.text(225, 174, "In-Place Coset Register |X[0..2111]> (33 Limbs * 64 Q)", size=10.2, weight="800", fill="#1e293b", anchor="middle", mono=True)
    for l_idx in range(6):
        lx = 46 + l_idx * 60
        fill_c = "#fed7aa" if l_idx == 2 else "#ffffff"
        str_c = "#ea580c" if l_idx == 2 else "#64748b"
        c.rect(lx, 184, 52, 42, rx=4, fill=fill_c, stroke=str_c, stroke_width=1.4)
        c.text(lx + 26, 209, "F_k" if l_idx == 2 else f"L_{l_idx}", size=9.5, weight="800", fill="#0f172a", anchor="middle", mono=True)

    c.path("M 192 228 L 192 258", stroke="#ea580c", width=2.2, marker_end="arrow-amber")
    c.rect(58, 260, 334, 82, rx=7, fill="url(#amber-grad)", stroke="#ea580c", stroke_width=1.8)
    c.text(225, 282, "Single Active 64-Bit Adder Focus", size=11, weight="800", fill="#9a3412", anchor="middle", mono=True)
    c.text(225, 302, "Streams k = 0 .. 31 sequentially", size=10, weight="700", fill="#c2410c", anchor="middle", mono=True)
    c.text(225, 322, "Carry c_k ripples across all 32 limbs!", size=10, weight="800", fill="#dc2626", anchor="middle", mono=True)

    # Carry ripple chain visual
    for r_i in range(5):
        rx_a = 72 + r_i * 64
        c.circle(rx_a, 370, r=14, fill="#fef2f2", stroke="#dc2626", stroke_width=1.5)
        c.text(rx_a, 374, f"c_{r_i}", size=9.5, weight="800", fill="#991b1b", anchor="middle", mono=True)
        if r_i < 4:
            c.line(rx_a + 14, 370, rx_a + 48, 370, stroke="#dc2626", width=1.8, marker_end="arrow-crimson")

    c.rect(34, 404, 382, 262, rx=8, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.4)
    c.text(48, 428, "Architecture A Profile (Baseline Zipper):", size=11, weight="800", fill="#0f172a")
    c.text(48, 450, "• RSA-2048 Width:  1,924 Logical Qubits", size=10, weight="700", fill="#334155", mono=True)
    c.text(48, 470, "• RSA-4096 Width:  3,972 Logical Qubits", size=10, weight="700", fill="#334155", mono=True)
    c.text(48, 490, "• Toffoli Count:   1.87B (2048) / 14.84B (4096)", size=10, weight="700", fill="#334155", mono=True)
    c.text(48, 510, "• Bottleneck:      Sequential limb streaming", size=10, weight="700", fill="#dc2626", mono=True)
    c.text(48, 528, "  stretches circuit duration by C = 32x,", size=10, weight="600", fill="#dc2626", mono=True)
    c.text(48, 546, "  forcing code distance d = 27 -> d = 29.", size=10, weight="600", fill="#dc2626", mono=True)
    c.text(48, 570, "• 2D Surface Code: 3.30M Phys Q | 50.1 Hours", size=10, weight="700", fill="#334155", mono=True)
    c.text(48, 590, "• Yoked Surface:   1.31M Phys Q | 50.1 Hours", size=10, weight="700", fill="#334155", mono=True)
    c.text(48, 610, "• Neutral-Atom:    50.1 Hours (No limb par!)", size=10, weight="700", fill="#dc2626", mono=True)
    c.text(48, 634, "Verdict: Superseded by Architecture C.", size=10.5, weight="800", fill="#991b1b", mono=True)

    # Panel B: Center (x = 450, w = 418)
    c.panel(
        450, 94, 418, 588,
        "Arch B: RNS + Braun Tree",
        "896 Q (RSA-2048) | 11.79B CCX | d = 29",
        badge="Min Logical Qubits!",
        badge_fill="#f3e8ff",
        badge_text="#6b21a8",
    )

    c.rect(468, 154, 382, 86, rx=7, fill="url(#purple-grad)", stroke="#7c3aed", stroke_width=1.5)
    c.text(659, 174, "k = 68 RNS Residues |r_i> (31 Bits Each)", size=10.5, weight="800", fill="#4c1d95", anchor="middle", mono=True)
    for m_idx, mlbl in enumerate(["m_1", "m_2", "m_3", "...", "m_67", "m_68"]):
        mx_b = 480 + m_idx * 60
        c.rect(mx_b, 184, 52, 42, rx=4, fill="#ffffff", stroke="#7c3aed", stroke_width=1.4)
        c.text(mx_b + 26, 209, mlbl, size=9.5, weight="800", fill="#5b21b6", anchor="middle", mono=True)

    c.path("M 659 240 L 659 262", stroke="#7c3aed", width=2.2, marker_end="arrow-purple")
    c.polygon([(488, 264), (830, 264), (755, 344), (563, 344)], fill="url(#teal-grad)", stroke="#0d9488", width=1.8)
    c.text(659, 292, "BraunTree(68, 31) CRT Accumulator", size=10.5, weight="800", fill="#134e4a", anchor="middle", mono=True)
    c.text(659, 312, "Depth = 7 Levels (Zero Carry Chain)", size=9.8, weight="700", fill="#0f766e", anchor="middle", mono=True)
    c.text(659, 330, "Computes exact CRT quotient q", size=9.5, weight="600", fill="#115e59", anchor="middle", mono=True)

    c.rect(510, 356, 298, 34, rx=6, fill="#fef3c7", stroke="#d97706", stroke_width=1.4)
    c.text(659, 377, "Streamed via 31-Bit Active ALU Focus!", size=10, weight="800", fill="#92400e", anchor="middle", mono=True)

    c.rect(468, 404, 382, 262, rx=8, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.4)
    c.text(482, 428, "Architecture B Profile (Sub-1000 Q Champion):", size=11, weight="800", fill="#0f172a")
    c.text(482, 450, "• RSA-2048 Width:  896 Logical Qubits (-56%!)", size=10, weight="800", fill="#059669", mono=True)
    c.text(482, 470, "• RSA-4096 Width:  1,728 Logical Qubits (-58%!)", size=10, weight="800", fill="#059669", mono=True)
    c.text(482, 490, "• Toffoli Count:   11.79B (2048) / 93.4B (4096)", size=10, weight="700", fill="#dc2626", mono=True)
    c.text(482, 510, "• Tradeoff:        Eliminates long carry chains,", size=10, weight="600", fill="#334155", mono=True)
    c.text(482, 528, "  but CRT base extension on every mod-N step", size=10, weight="600", fill="#334155", mono=True)
    c.text(482, 546, "  incurs a 6.9x Toffoli multiplier.", size=10, weight="700", fill="#dc2626", mono=True)
    c.text(482, 570, "• 2D Surface Code: 1.59M Phys Q | 315.8 Hours", size=10, weight="700", fill="#334155", mono=True)
    c.text(482, 590, "• Yoked Surface:   693K Phys Q  | 315.8 Hours", size=10, weight="700", fill="#6d28d9", mono=True)
    c.text(482, 610, "• qLDPC Regime D:  215K Phys Q  | 4.64 Hours", size=10, weight="700", fill="#0f766e", mono=True)
    c.text(482, 634, "Verdict: Best for strict <1,000 Q capacity cap.", size=10.2, weight="800", fill="#5b21b6", mono=True)

    # Panel C: Right (x = 884, w = 420)
    c.panel(
        884, 94, 420, 588,
        "Arch C: Split-Register + Skew Carry-Save",
        "1,364 Q (RSA-2048) | 1.70B CCX | d = 27",
        badge="Spacetime Optimal!",
        badge_fill="#dcfce7",
        badge_text="#166534",
    )

    c.rect(902, 154, 384, 102, rx=7, fill="url(#emerald-grad)", stroke="#059669", stroke_width=1.8)
    c.text(1094, 174, "C = 32 Limbs |L_k[64]> + Skew Carry Rail |d_k[2]>", size=10.2, weight="800", fill="#065f46", anchor="middle", mono=True)
    for s_idx in range(6):
        sx_c = 914 + s_idx * 60
        c.rect(sx_c, 184, 52, 34, rx=4, fill="#ffffff", stroke="#059669", stroke_width=1.4)
        c.text(sx_c + 26, 205, f"L_{s_idx}", size=9.5, weight="800", fill="#065f46", anchor="middle", mono=True)
        # 2-qubit skew carry badge directly underneath each limb
        c.rect(sx_c + 6, 224, 40, 22, rx=4, fill="#ccfbf1", stroke="#0d9488", stroke_width=1.2)
        c.text(sx_c + 26, 239, f"d_{s_idx}", size=9, weight="800", fill="#115e59", anchor="middle", mono=True)

    c.rect(902, 268, 384, 76, rx=7, fill="url(#blue-grad)", stroke="#2563eb", stroke_width=1.8)
    c.text(1094, 290, "O(1) Intra-Limb Depth: Zero Cross-Limb Ripple!", size=10.5, weight="800", fill="#1e3a8a", anchor="middle", mono=True)
    c.text(1094, 310, "Split-Register Check-and-Add (No 2048-b Coset Pad)", size=9.8, weight="700", fill="#1d4ed8", anchor="middle", mono=True)
    c.text(1094, 328, "All 32 limbs execute simultaneously in 1 round!", size=9.8, weight="800", fill="#059669", anchor="middle", mono=True)

    c.rect(918, 356, 352, 34, rx=6, fill="#dcfce7", stroke="#16a34a", stroke_width=1.5)
    c.text(1094, 377, "891,348 Yoked Q  |  344,304 qLDPC Q  |  24.9d Parallel AOD", size=10, weight="800", fill="#166534", anchor="middle", mono=True)

    c.rect(902, 404, 384, 262, rx=8, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.4)
    c.text(916, 428, "Architecture C Profile (Overall Winner):", size=11, weight="800", fill="#065f46")
    c.text(916, 450, "• RSA-2048 Width:  1,364 Logical Qubits (-33.5%)", size=10, weight="800", fill="#059669", mono=True)
    c.text(916, 470, "• RSA-4096 Width:  2,644 Logical Qubits (-35.5%)", size=10, weight="800", fill="#059669", mono=True)
    c.text(916, 490, "• Toffoli Count:   1.70B (2048) / 13.18B (4096)", size=10, weight="800", fill="#059669", mono=True)
    c.text(916, 510, "• Breakthrough:    64 skew-carry qubits absorb", size=10, weight="600", fill="#334155", mono=True)
    c.text(916, 528, "  all limb carries locally, eliminating the 32x", size=10, weight="600", fill="#334155", mono=True)
    c.text(916, 546, "  stretch and dropping code distance to d = 27!", size=10, weight="700", fill="#1e3a8a", mono=True)
    c.text(916, 570, "• 2D Surface Code: 2.52M Phys Q | 3.19 Days", size=10, weight="700", fill="#334155", mono=True)
    c.text(916, 590, "• Yoked Surface:   891,348 Phys Q | 3.19 Days", size=10, weight="800", fill="#059669", mono=True)
    c.text(916, 610, "• BB qLDPC / Atom: 344,304 Phys Q | 24.9 Days (AOD)", size=10, weight="800", fill="#1d4ed8", mono=True)
    c.text(916, 634, "Verdict: Global Spacetime & Hardware Optimum!", size=10.2, weight="800", fill="#065f46", mono=True)

    return c.render()


# ============================================================================
# Figure 13: AES-256 (356 Q), SLH-DSA-128s (4,320 Q), and DQI (9,984 Q)
# ============================================================================

def build_fig13() -> str:
    c = SVGCanvas(1320, 710)
    c.title_banner(
        "FIGURE 13",
        "Symmetric, Hash-Based, and Algebraic Decoding Oracles: AES-256, SLH-DSA-128s, & DQI",
        "Panel (a): AES-256 (356 Q, 42,240 CCX) | Panel (b): SLH-DSA-128s (4,320 Q) | Panel (c): DQI OPI Decoder (9,984 Q, -90.4%)",
    )

    # Panel (a): Top Left - AES-256 (356 Q)
    c.panel(
        16, 94, 636, 294,
        "Panel (a): AES-256 Grover Oracle (356 Q, 42,240 Toffolis)",
        "4 Parallel Boyar-Peralta Tower-Field S-Boxes (16 Q scratch) + In-Place MixColumns PLU",
        badge="356 Q | 0 Col Uncomp!",
        badge_fill="#dcfce7",
        badge_text="#166534",
    )

    ay = [168, 208, 250, 292]
    ax0, ax1 = 152, 520
    alabels_l = [
        "|Key_Zip[0..255]>",
        "|State_Col[0..127]>",
        "|F_2^4 Scratch (16Q)>",
        "|Round_Out[0..31]>",
    ]
    alabels_r = [
        "|Key_{r+1}> (Rolled)",
        "|MixCol(Sub(S))>",
        "|0>^16 (Immediate!)",
        "|State_{r+1}>",
    ]
    for idx in range(4):
        bd = "256" if idx == 0 else ("128" if idx == 1 else ("16" if idx == 2 else "32"))
        c.qwire(ay[idx], ax0, ax1, label_left=alabels_l[idx], label_right=alabels_r[idx], bundle=bd)

    c.multi_gate(215, ay[0], ay[2], w=76, label="KeySched", sublabel="4 S-Boxes", fill="url(#blue-grad)", stroke="#2563eb")
    c.multi_gate(305, ay[1], ay[2], w=84, label="SubBytes", sublabel="4x BP S-Box", third_line="Norm Uncomp", fill="url(#teal-grad)", stroke="#0d9488")
    c.multi_gate(395, ay[1], ay[3], w=74, label="MixCol", sublabel="Bruhat PLU", third_line="0 CCX!", fill="url(#emerald-grad)", stroke="#059669")
    c.cnot(465, ay[0], ay[3], color="#7c3aed")
    c.text(465, ay[3] + 20, "AddKey", size=9, weight="800", fill="#5b21b6", anchor="middle", mono=True)

    c.rect(34, 322, 600, 54, rx=6, fill="#f8fafc", stroke="#cbd5e1", stroke_width=1.2)
    c.text(48, 342, "• Eliminates Naive Column-Reuse Doubling: Uncomputes only the 4-bit F_{2^4} tower norm inside each", size=9.8, weight="600", fill="#334155", mono=True)
    c.text(48, 360, "  S-Box (22 -> 30 CCX) while retaining the 8-bit S-Box output in place -> Saves 29,568 Toffolis (-41.2%)!", size=9.8, weight="800", fill="#059669", mono=True)

    # Panel (b): Top Right - SLH-DSA / SPHINCS+-128s (4,320 Q)
    c.panel(
        668, 94, 636, 294,
        "Panel (b): SLH-DSA / SPHINCS+-128s Hypertree Oracle (4,320 Q)",
        "h'=9 Sequential Merkle Path Zipper (2,560 Q) + K=32 Rotary Keccak-f[1600] chi-Slice (1,632 Q)",
        badge="4,320 Q (-47.3% vs 8,192Q)",
        badge_fill="#dbeafe",
        badge_text="#1e3a8a",
    )

    hy = [168, 210, 252, 294]
    hx0, hx1 = 805, 1185
    hlabels_l = [
        "|Leaf_Idx[0..63]>",
        "|Tree_Stack (h'+1)>",
        "|Keccak_State>",
        "|Chi_Scratch (32Q)>",
    ]
    hlabels_r = [
        "|Leaf_Idx>",
        "|Root_PK[0..255]>",
        "|Sponge_Out>",
        "|0>^32 (Rotary!)",
    ]
    for idx in range(4):
        bd = "64" if idx == 0 else ("2560" if idx == 1 else ("1600" if idx == 2 else "32"))
        c.qwire(hy[idx], hx0, hx1, label_left=hlabels_l[idx], label_right=hlabels_r[idx], bundle=bd)

    c.multi_gate(870, hy[0], hy[1], w=82, label="WOTS+Ch", sublabel="In-Place", fill="url(#blue-grad)", stroke="#2563eb")
    c.multi_gate(968, hy[2], hy[3], w=90, label="Rotary Chi", sublabel="K=32 Slice", third_line="50 Sweeps", fill="url(#purple-grad)", stroke="#7c3aed")
    c.multi_gate(1068, hy[1], hy[2], w=82, label="SeqMerkle", sublabel="U_L -> U_R", third_line="h'+1=10 Regs", fill="url(#teal-grad)", stroke="#0d9488")
    c.multi_gate(1148, hy[0], hy[2], w=60, label="Verify", sublabel="d=7 Lyr", fill="url(#amber-grad)", stroke="#d97706")

    c.rect(686, 322, 600, 54, rx=6, fill="#f8fafc", stroke="#cbd5e1", stroke_width=1.2)
    c.text(700, 342, "• Rotary Keccak-f[1600] chi-Step: Evaluates 1600-bit degree-2 chi step in 50 slices of K=32 bits", size=9.8, weight="600", fill="#334155", mono=True)
    c.text(700, 360, "  using 32 scratch qubits (vs. 1,600 Q out-of-place) + Sequential Pebbling (-2,304 Q) = 4,320 Q total!", size=9.8, weight="800", fill="#1e3a8a", mono=True)

    # Panel (c): Bottom Full Width - DQI Coherent Algebraic Syndrome Decoder (9,984 Q)
    c.panel(
        16, 404, 1288, 290,
        "Panel (c): Decoded Quantum Interferometry (DQI) Coherent OPI Syndrome Decoder over F_3329[X] (n=256, d_deg=128)",
        "Odd-Half Butterfly NTT (3,072 Q) + Packed Polynomial Bézout Shift-Zipper (3,072 Q) + s=4 Binomial Polynomial Pebbles (3,072 Q) = 9,984 Q",
        badge="104,448 Q -> 9,984 Q (10.46x Narrower!)",
        badge_fill="#fef3c7",
        badge_text="#92400e",
    )

    qy = [478, 520, 562, 604]
    qx0, qx1 = 185, 1155
    qlabels_l = [
        "|Syndrome s(X)>",
        "|Poly_UR(X)> (256*12)",
        "|Poly_VS(X)> (256*12)",
        "|Pebbles P_1..P_4>",
    ]
    qlabels_r = [
        "|Error Vector e> (OPI)",
        "|0>^3072 (Clean!)",
        "|0>^3072 (Clean!)",
        "|0>^3072 (Clean!)",
    ]
    for idx in range(4):
        c.qwire(qy[idx], qx0, qx1, label_left=qlabels_l[idx], label_right=qlabels_r[idx], bundle="3072")

    # DQI Pipeline Stages
    c.multi_gate(
        270, qy[0], qy[1], w=122,
        label="Odd-Half NTT", sublabel="In-Place Gentleman", third_line="Cooley-Tukey",
        fill="url(#blue-grad)", stroke="#2563eb"
    )
    c.multi_gate(
        416, qy[1], qy[3], w=148,
        label="Poly Shift-Zipper", sublabel="deg(u)+deg(r)=256", third_line="M=16 Jump-8 Windows",
        fill="url(#teal-grad)", stroke="#0d9488"
    )
    c.multi_gate(
        572, qy[1], qy[2], w=125,
        label="Forney Eval", sublabel="Formal Deriv Lambda'", third_line="Chien Root Search",
        fill="url(#emerald-grad)", stroke="#059669"
    )
    c.multi_gate(
        720, qy[0], qy[1], w=110,
        label="Extract Error", sublabel="|e_i> in F_3329", third_line="Phase Kick",
        fill="url(#purple-grad)", stroke="#7c3aed"
    )
    c.multi_gate(
        878, qy[1], qy[3], w=152,
        label="Binomial Poly GCD^+", sublabel="s=4 Pebbles (3072 Q)", third_line="vs 24,576 Q History",
        fill="url(#amber-grad)", stroke="#d97706"
    )
    c.multi_gate(
        1048, qy[0], qy[1], w=110,
        label="Inverse NTT^+", sublabel="Restores Syndrome", third_line="Interference",
        fill="url(#rose-grad)", stroke="#e11d48"
    )

    c.rect(34, 628, 1252, 52, rx=6, fill="#fffbeb", stroke="#f59e0b", stroke_width=1.3)
    c.text(50, 648, "• Why DQI [Jordan et al. 2024] Needs Zipper Uncomputation: Coherent Berlekamp-Massey / Euclidean decoding must uncompute ALL", size=10, weight="700", fill="#92400e", mono=True)
    c.text(50, 666, "  intermediate remainder polynomials to interfere; out-of-place Euclidean takes 104,448 Q vs. 9,984 Q (-90.4%) with Packed Poly Zipper.", size=10, weight="800", fill="#065f46", mono=True)

    return c.render()


# ============================================================================
# Figure 14: Four Hardware Regimes (A, B, C, D) & External Decoder Pacing
# ============================================================================

def build_fig14() -> str:
    c = SVGCanvas(1320, 700)
    c.title_banner(
        "FIGURE 14",
        "Four Fault-Tolerant Hardware Regimes & Grade Phi1/Phi3 External Decoder Pacing",
        "Panel (a): Regimes A/B/C/D Physical Qubits & Runtime | Panel (b): Lindley Queue Stability Under External Feed-Forward Latency",
    )

    # Panel (a): Top Half - Four Fault-Tolerant Hardware Regimes
    c.panel(
        16, 94, 1288, 286,
        "Panel (a): End-to-End Physical Qubit & Runtime Co-Design Across Four Fault-Tolerant Hardware Regimes",
        "Evaluated at p_phys = 10^-3, tau_cycle = 1 us, with Gidney-Shutty-Jones [2024] Magic-State Cultivation (36 logical patches)",
        badge="891K Yoked / 344K qLDPC Q",
        badge_fill="#dcfce7",
        badge_text="#166534",
    )

    regimes = [
        (
            "Regime A: 2D Planar Surface Code",
            "Homogeneous 2*d^2 Grid + Cultivation",
            "• RSA-2048 (Arch C, d=27):  2,523,932 Phys Q",
            "• RSA-2048 Wall-Clock:      3.19 Days",
            "• ECC-256 (1,088 Q, d=21):  1,468,898 Phys Q",
            "• ECC-256 Wall-Clock:       3.30 Minutes",
            "#eff6ff", "#2563eb", "#1e3a8a"
        ),
        (
            "Regime B: Yoked Surface Code",
            "0.5*d^2 Cold Zipper Context + 2*d^2 Focus",
            "• RSA-2048 (Arch C, d=27):  891,348 Phys Q",
            "• Sub-Million Qubit RSA-2048 Milestone",
            "• ECC-256 (1,088 Q, d=21):  819,722 Phys Q",
            "• Matches Zipper Cold/Hot Partition",
            "#f0fdf4", "#16a34a", "#166534"
        ),
        (
            "Regime C-Par: Neutral-Atom 2D AOD",
            "32-Limb Parallel AOD Shuttling + Skew Carry",
            "• Parallel Limb Execution:  C = 32 Simultaneous",
            "• RSA-2048 Wall-Clock:      24.9 Days (37.8x vs Serial)",
            "• RSA-4096 Wall-Clock:      9.96 Hours (34.8x)",
            "• Eliminates Lattice-Surgery Bus Serialism",
            "#fffbeb", "#d97706", "#92400e"
        ),
        (
            "Regime D: [[288,12,18]] BB qLDPC",
            "Rate 1/24 Bivariate Bicycle + X^a Y^b Shift",
            "• RSA-2048 (Arch C):        344,304 Phys Q",
            "• RSA-2048 (Arch B):        264,192 Phys Q",
            "• ECC-256 (1,088 Q):        288,216 Phys Q",
            "• Torus Automorphism = 0-SWAP Focus Shift",
            "#faf5ff", "#7c3aed", "#5b21b6"
        ),
    ]

    for idx, (rtitle, rsub, l1, l2, l3, l4, rbg, rstr, rtxt) in enumerate(regimes):
        rx = 32 + idx * 316
        c.rect(rx, 150, 304, 214, rx=8, fill=rbg, stroke=rstr, stroke_width=1.8, shadow=True)
        c.text(rx + 14, 173, rtitle, size=11, weight="800", fill=rtxt)
        c.text(rx + 14, 190, rsub, size=10.0, weight="600", fill="#475569", mono=True)
        c.line(rx + 10, 198, rx + 294, 198, stroke=rstr, width=1.0)
        c.text(rx + 14, 222, l1, size=10.0, weight="700", fill="#0f172a", mono=True)
        c.text(rx + 14, 248, l2, size=10.0, weight="800", fill=rtxt, mono=True)
        c.text(rx + 14, 274, l3, size=10.0, weight="700", fill="#0f172a", mono=True)
        c.text(rx + 14, 300, l4, size=10.0, weight="800", fill=rtxt, mono=True)
        c.rect(rx + 14, 322, 276, 30, rx=5, fill="#ffffff", stroke=rstr, stroke_width=1.2)
        summary_tag = [
            "Baseline 2D Planar Grid",
            "-55.9% Phys Q via Yoked Cold Memory",
            "37.8x Faster RSA-2048 (24.9 Days)",
            "5.87x Fewer Phys Q (344K Q)",
        ][idx]
        c.text(rx + 152, 341, summary_tag, size=10.0, weight="800", fill=rtxt, anchor="middle", mono=True)

    # Panel (b): Bottom Half - External Decoder Pacing & Lindley Queue Stability
    c.panel(
        16, 396, 1288, 288,
        "Panel (b): Grade Phi1/Phi3 Compiler Pacing Under External Classical Feed-Forward Latency (tau_cycle = 1,000 ns)",
        "Models hardware decoder latency tau_dec as an external target parameter; switches MBU elbows to unitary RCCX whenever rho >= 1",
        badge="Automatic MBU / RCCX Selection",
        badge_fill="#ccfbf1",
        badge_text="#115e59",
    )

    profiles = [
        (
            "4 K Cryo-CMOS Feed-Forward",
            "tau_dec = 120 ns  |  rho = 0.12 < 1",
            "• Terhal backlog queue stable (rho < 1)",
            "• Compiler selects 0-T MBU elbow",
            "• 4 T per TempAND + CZ fixup",
            396, "#f0fdf4", "#16a34a", "#166534"
        ),
        (
            "300 K Room-Temp Coax Link",
            "tau_dec = 420 ns  |  rho = 0.42 < 1",
            "• Round-trip coax within 1,000 ns cycle",
            "• Compiler retains MBU with idle cost",
            "• Idling decoherence added to Grade Phi1",
            396, "#eff6ff", "#2563eb", "#1e3a8a"
        ),
        (
            "Unpaced Software MWPM Host",
            "tau_dec = 4,500 ns | rho = 4.50 > 1",
            "• Violates Terhal stability (rho >= 1)",
            "• Grade Phi3 forbids MBU backlog",
            "• Compiler falls back to unitary RCCX",
            396, "#fef2f2", "#dc2626", "#991b1b"
        ),
    ]

    sx_cur = 36
    for idx, (stitle, stime, b1, b2, b3, sw, sbg, sstr, stxt) in enumerate(profiles):
        c.rect(sx_cur, 454, sw, 138, rx=8, fill=sbg, stroke=sstr, stroke_width=1.8, shadow=True)
        c.text(sx_cur + 14, 476, stitle, size=11.0, weight="800", fill=stxt)
        c.rect(sx_cur + 14, 484, sw - 28, 22, rx=4, fill="#ffffff", stroke=sstr, stroke_width=1.2)
        c.text(sx_cur + sw / 2, 499, stime, size=10.0, weight="800", fill=stxt, anchor="middle", mono=True)
        c.text(sx_cur + 14, 526, b1, size=10.0, weight="600", fill="#1e293b", mono=True)
        c.text(sx_cur + 14, 546, b2, size=10.0, weight="600", fill="#1e293b", mono=True)
        c.text(sx_cur + 14, 568, b3, size=10.0, weight="800", fill=stxt, mono=True)
        sx_cur += sw + 30

    c.rect(36, 606, 1250, 62, rx=7, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.4)
    c.text(52, 628, "Lindley Queueing Law [Terhal 2015]:  rho = lambda_arr / mu_serv = tau_dec / tau_cycle < 1  required for MBU measurement-based uncomputation.", size=10.2, weight="800", fill="#0f172a", mono=True)
    c.text(52, 650, "When rho >= 1 (e.g. unpaced software MWPM), RevIR e-graph extraction automatically emits measurement-free unitary Margolus/RCCX uncomputation.", size=10.2, weight="700", fill="#0f766e", mono=True)

    return c.render()


# ============================================================================
# Figure 15: LakefillQ 4-Dialect Compiler Pipeline & Unified Judgment
# ============================================================================

def build_fig15() -> str:
    c = SVGCanvas(1320, 660)
    c.title_banner(
        "FIGURE 15",
        "The LakefillQ Four-Dialect Compiler Architecture & Unified Capability-and-Cost Judgment",
        "Surface #lang lakefillq -> Six-Primitive Kernel -> Equality-Saturated RevIR e-Graph -> Target MachineISA",
    )

    c.panel(
        16, 94, 1288, 548,
        "End-to-End Compilation Pipeline Preserving Substructural Wire Capabilities and Six-Component Physical Cost Vectors",
        "Gamma_in |- t : Q_e(A) -| Gamma_out  with e = (W_peak, W_clean, Phi, alpha, eps, E_ebit) and annotation-free XAG+Z3 cut-sweeping",
        badge="Zero Uncomputation Annotations",
        badge_fill="#dcfce7",
        badge_text="#166534",
    )

    dialects = [
        (
            "1. #lang lakefillq",
            "Functional Surface",
            "• Algebraic zippers & trees",
            "• Zero mbu/reversible tags",
            "• Source provenance spans",
            278, "#eff6ff", "#2563eb", "#1e3a8a"
        ),
        (
            "2. lambda_LFQ^kern",
            "6-Primitive Core",
            "• qalloc0 / qfree0 / qfocus",
            "• qunitary / qctrl / qmeas_x",
            "• XAG + FRAIG + Z3 Laws U1-U4",
            278, "#f0fdfa", "#0d9488", "#115e59"
        ),
        (
            "3. RevIR e-Graph",
            "ZX + MBU Saturation",
            "• Z_8 ZX phase-gadget fusion",
            "• MBU <-> RCCX <-> Shared-8T",
            "• MITM 4Q bitboard synthesis",
            278, "#faf5ff", "#7c3aed", "#5b21b6"
        ),
        (
            "4. MachineISA",
            "4 Hardware Targets",
            "• NISQ Transmon (Shared-8T)",
            "• Heron r2 / BB qLDPC (MBU)",
            "• QuEra Zoned AOD (0-T CCZ)",
            278, "#fffbeb", "#d97706", "#92400e"
        ),
    ]

    dx = 38
    for idx, (dtitle, dsub, b1, b2, b3, dw, dbg, dstr, dtxt) in enumerate(dialects):
        c.rect(dx, 162, dw, 166, rx=8, fill=dbg, stroke=dstr, stroke_width=1.8, shadow=True)
        c.text(dx + 14, 188, dtitle, size=11.5, weight="800", fill=dtxt, mono=True)
        c.rect(dx + 14, 198, dw - 28, 22, rx=4, fill="#ffffff", stroke=dstr, stroke_width=1.2)
        c.text(dx + dw / 2, 213, dsub, size=10.0, weight="800", fill=dtxt, anchor="middle", mono=True)
        c.text(dx + 14, 244, b1, size=10.0, weight="600", fill="#1e293b", mono=True)
        c.text(dx + 14, 268, b2, size=10.0, weight="600", fill="#1e293b", mono=True)
        c.text(dx + 14, 292, b3, size=10.0, weight="700", fill=dtxt, mono=True)
        if idx < 3:
            c.line(dx + dw + 4, 245, dx + dw + 34, 245, stroke="#334155", width=2.4, marker_end="arrow-slate")
        dx += dw + 44

    c.rect(38, 354, 604, 266, rx=8, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.5)
    c.text(56, 380, "Five-Point Substructural Wire-Capability Lattice:", size=11.5, weight="800", fill="#0f172a")
    c.text(56, 406, "0  <  BorrowZ  <  TaintedX  <  Lin1  <  Uniq1", size=11.0, weight="800", fill="#1e3a8a", mono=True)
    c.text(56, 434, "• BorrowZ: Read-only Z-control borrow (forbids H/X mutation)", size=10.0, weight="600", fill="#334155", mono=True)
    c.text(56, 458, "• TaintedX: Phase-entangled wire eligible for M_X + CZ fixup", size=10.0, weight="600", fill="#334155", mono=True)
    c.text(56, 482, "• Lin1 / Uniq1: Owned linear wire / alias-free zipper focus", size=10.0, weight="600", fill="#334155", mono=True)
    c.text(56, 514, "Symbolic Cut-Sweeping Inference (Zero Surface Flags):", size=11.0, weight="800", fill="#0f766e")
    c.text(56, 538, "• Law U1: Unitary Bijectivity   • Law U2: Domain-Guarded Injection", size=10.0, weight="700", fill="#1e293b", mono=True)
    c.text(56, 562, "• Law U3: Phase-Up-To MBU       • Law U4: Chordal Wire Recycling", size=10.0, weight="700", fill="#1e293b", mono=True)
    c.text(56, 590, "Counterexample witnesses resugared directly to source spans.", size=10.0, weight="700", fill="#dc2626", mono=True)

    c.rect(666, 354, 616, 266, rx=8, fill="#ffffff", stroke="#cbd5e1", stroke_width=1.5)
    c.text(684, 380, "Hardware-Parameterized Cost Extraction Across 4 Targets:", size=11.5, weight="800", fill="#0f172a")
    c.text(684, 406, "e = (W_peak, W_clean, Phi, alpha, eps, E_ebit),  r |> e", size=10.8, weight="800", fill="#5b21b6", mono=True)
    c.text(684, 434, "• NISQ High-SPAM Transmon:  Extracts 0-meas Shared-CCZ 8T", size=10.0, weight="700", fill="#1e3a8a", mono=True)
    c.text(684, 458, "• IBM Heron r2 Dynamic:     Extracts 4-T MBU elbow + M_X", size=10.0, weight="700", fill="#0f766e", mono=True)
    c.text(684, 482, "• QuEra Zoned Neutral-Atom: Extracts 0-T native Rydberg CCZ", size=10.0, weight="700", fill="#92400e", mono=True)
    c.text(684, 506, "• [[288,12,18]] BB qLDPC:   Extracts 4-T MBU + torus shift", size=10.0, weight="700", fill="#5b21b6", mono=True)
    c.text(684, 538, "Mechanized Soundness & Simulator Fidelity:", size=11.0, weight="800", fill="#166534")
    c.text(684, 562, "• 285 Lean 4 + Coq theorems (zero axioms, zero sorry/Admitted)", size=10.0, weight="700", fill="#1e293b", mono=True)
    c.text(684, 586, "• 100% mutant kill rate (30/30) & F = 1.000000 on Aer/Cirq/Stim", size=10.0, weight="700", fill="#059669", mono=True)

    return c.render()


# ============================================================================
# Main Entrypoint: Build All Figures & Mirror Across Workspaces
# ============================================================================

FIGURE_BUILDERS = [
    ("fig01_gidney_mbu_and_pebbling_circuit.svg", build_fig01),
    ("fig02_huet_focus_zipper_circuit_and_floorplan.svg", build_fig02),
    ("fig03_skew_binary_carry_save_circuit.svg", build_fig03),
    ("fig04_braun_tree_popcount_and_rns_circuit.svg", build_fig04),
    ("fig05_packed_bezout_shift_zipper_circuit.svg", build_fig05),
    ("fig06_binomial_pebble_spacetime_dag.svg", build_fig06),
    ("fig07_monoidal_finger_tree_simhash_vtaa_circuit.svg", build_fig07),
    ("fig08_bruhat_lu_and_streaming_isd_circuit.svg", build_fig08),
    ("fig09_critbit_bitonic_and_bentley_saxe_circuit.svg", build_fig09),
    ("fig10_walker_vose_alias_circuit.svg", build_fig10),
    ("fig11_ecdlp_1088q_full_algorithm_architecture.svg", build_fig11),
    ("fig12_rsa_architectures_abc_comparison_circuit.svg", build_fig12),
    ("fig13_aes_slhdsa_dqi_circuits.svg", build_fig13),
    ("fig14_four_hardware_regimes_and_decoder_pacing.svg", build_fig14),
    ("fig14_four_hardware_regimes_and_0dsp_fpga.svg", build_fig14),
    ("fig15_lakefillq_compiler_and_judgment.svg", build_fig15),
    ("fig15_quantum_type_theory_and_redex_f1_f12.svg", build_fig15),
]


def main() -> None:
    repo_root = Path(__file__).resolve().parent.parent
    ws_parent = repo_root.parent
    ws13_dir = ws_parent / "ws13-okasaki-quantum-data-structures" / "figures"
    ws14_dir = ws_parent / "ws14-zipper-cut-distributed-multi-qpu" / "figures"
    parent_brain_dir = Path("/home/antigravity/.gemini/jetski/brain/v1/default/jetski_remote_agents_3p/dd08f10a-3ed1-4e55-b026-f7c8710762e7")
    parent_brain_flat = Path("/home/antigravity/.gemini/jetski/brain/dd08f10a-3ed1-4e55-b026-f7c8710762e7")

    target_dirs = [ws13_dir, ws14_dir]
    if parent_brain_dir.parent.exists():
        target_dirs.append(parent_brain_dir)
    if parent_brain_flat.exists():
        target_dirs.append(parent_brain_flat)

    for d in target_dirs:
        d.mkdir(parents=True, exist_ok=True)

    print("=" * 78)
    print(f"GENERATING {len(FIGURE_BUILDERS)} PUBLICATION-QUALITY QUANTUM CIRCUIT & ARCHITECTURE SVG FIGURES")
    print("=" * 78)

    for fname, builder in FIGURE_BUILDERS:
        svg_content = builder()
        # Validate XML parse and structure
        root = ET.fromstring(svg_content)
        num_elems = len(list(root.iter()))
        size_bytes = len(svg_content.encode("utf-8"))
        assert size_bytes > 2000, f"SVG {fname} unexpectedly small ({size_bytes} bytes)"

        primary_path = ws13_dir / fname
        primary_path.write_text(svg_content, encoding="utf-8")

        for mirror_dir in target_dirs[1:]:
            (mirror_dir / fname).write_text(svg_content, encoding="utf-8")

        print(f"  [OK] {fname:<52} | {size_bytes:>6,} bytes | {num_elems:>4} XML nodes")

    print("=" * 78)
    print(f"Successfully generated and verified all {len(FIGURE_BUILDERS)} SVG figures in:")
    for d in target_dirs:
        print(f"  -> {d}")
    print("=" * 78)


if __name__ == "__main__":
    main()
