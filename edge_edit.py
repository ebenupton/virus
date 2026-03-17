#!/usr/bin/env python3
"""Interactive edge colour editor for the 32x32 heightmap.

Displays the heightmap grid with coloured edges. Click or use keyboard
to cycle edge colours through Yellow/Green/Cyan/Blue.  The sidebar shows
current LUT state; new entries are added dynamically when needed.

Controls:
  Left-click / Space     cycle edge colour forward  (Y→G→Cy→B)
  Right-click / Backspace cycle edge colour backward
  Arrow keys             move selection
  Tab                    toggle h-edge / v-edge
  Ctrl+S                 save map_data.inc + edge_color.inc
  Q / Escape             quit
"""

import tkinter as tk
import re, sys

SIZE = 32
CELL = 20
PAD  = 24
MAX_LUT  = 12    # max entries per LUT during editing
SAVE_LUT = 8     # must reduce to this many before saving

# MODE 2 right-pixel byte value → (display hex colour, short name)
CINFO = {
    0x00: ('#1a1a1a', 'Bk'),
    0x01: ('#ff2222', 'R'),
    0x04: ('#00cc00', 'G'),
    0x05: ('#cccc00', 'Y'),
    0x10: ('#4466ff', 'B'),
    0x11: ('#cc44cc', 'M'),
    0x14: ('#00cccc', 'Cy'),
    0x15: ('#ffffff', 'W'),
}

# Cycle order for non-plateau edges
CYCLE = [0x05, 0x04, 0x14, 0x10]   # Y → G → Cy → B

PLAT_MIN, PLAT_MAX = 14, 18


# ── helpers ──────────────────────────────────────────────────────────

def color_hex(v):
    return CINFO.get(v, ('#888', '??'))[0]

def color_name(v):
    return CINFO.get(v, ('#888', '??'))[1]

def cell_display_color(h):
    """Height → background colour for cell display."""
    if h == 0:  return '#002a4a'
    if h == 31: return '#888888'
    t = (h - 1) / 29.0
    r = int(90  + 50 * t)
    g = int(75  + 65 * t)
    b = int(35  + 15 * t)
    return f'#{r:02x}{g:02x}{b:02x}'


# ── main class ───────────────────────────────────────────────────────

class EdgeEditor:

    def __init__(self, root):
        self.root = root
        self.root.title('Heightmap Edge Editor')
        self.modified = False
        self.sel = None          # (row, col, 'h'|'v') or None
        self.unassigned = set()  # set of (y, x) tuples
        self.overflow = {}       # (y,x) → pattern index for indices >= 8

        self.load_data()
        self.build_ui()
        self.full_redraw()

    # ── data ──

    def load_data(self):
        # heightmap — only parse lines with "; row N" comments
        vals = []
        with open('map_data.inc') as f:
            for line in f:
                if re.search(r';\s*row\s+\d+', line):
                    vals.extend(int(m, 16)
                                for m in re.findall(r'\$([0-9A-Fa-f]{2})', line))
        assert len(vals) == SIZE * SIZE, f'expected {SIZE*SIZE}, got {len(vals)}'
        self.grid = [vals[y*SIZE:(y+1)*SIZE] for y in range(SIZE)]

        # LUT tables
        with open('edge_color.inc') as f:
            src = f.read()
        def ext(label):
            i = src.index(f'{label}:')
            m = re.search(r'\.byte\s+(.+)', src[i:])
            return [int(x, 16) for x in re.findall(r'\$([0-9A-Fa-f]{2})', m.group(1))]
        self.luts = {
            'sea':  {'h': ext('h_color_sea'),  'v': ext('v_color_sea')},
            'plat': {'h': ext('h_color_plat'), 'v': ext('v_color_plat')},
            'land': {'h': ext('h_color_land'), 'v': ext('v_color_land')},
        }

    def height(self, y, x):     return self.grid[y][x] >> 3
    def pattern(self, y, x):
        return self.overflow.get((y, x), self.grid[y][x] & 7)
    def set_pattern(self, y, x, pat):
        if pat >= SAVE_LUT:
            self.overflow[(y, x)] = pat
        else:
            self.overflow.pop((y, x), None)
            self.grid[y][x] = (self.height(y, x) << 3) | pat
    def cat(self, y, x):
        h = self.height(y, x)
        return 'sea' if h == 0 else 'plat' if h == 31 else 'land'

    def edge_val(self, y, x, t):
        """Return right-pixel byte value for edge t ('h'|'v') of cell (y,x)."""
        c = self.cat(y, x)
        return self.luts[c][t][self.pattern(y, x)]

    def used_patterns(self, cat):
        s = set()
        for y in range(SIZE):
            for x in range(SIZE):
                if (y, x) not in self.unassigned and self.cat(y, x) == cat:
                    s.add(self.pattern(y, x))
        return s

    def pattern_counts(self, cat):
        d = {}
        for y in range(SIZE):
            for x in range(SIZE):
                if (y, x) not in self.unassigned and self.cat(y, x) == cat:
                    p = self.pattern(y, x)
                    d[p] = d.get(p, 0) + 1
        return d

    # ── UI ──

    def build_ui(self):
        main = tk.Frame(self.root, bg='#222')
        main.pack(fill=tk.BOTH, expand=True)

        gw = SIZE * CELL + 2 * PAD
        gh = SIZE * CELL + 2 * PAD
        self.cv = tk.Canvas(main, width=gw, height=gh, bg='#222',
                            highlightthickness=0)
        self.cv.pack(side=tk.LEFT)

        side = tk.Frame(main, bg='#333', width=280)
        side.pack(side=tk.RIGHT, fill=tk.Y)
        side.pack_propagate(False)

        self.lut_text = tk.Text(side, bg='#333', fg='#ccc',
                                font=('Courier', 11), width=34,
                                wrap=tk.NONE, highlightthickness=0,
                                borderwidth=0)
        self.lut_text.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)
        self.lut_text.config(state=tk.DISABLED)

        self.status = tk.StringVar(value='Click an edge to begin')
        tk.Label(side, textvariable=self.status, bg='#333', fg='#fff',
                 wraplength=260, justify=tk.LEFT, anchor='w'
                 ).pack(fill=tk.X, padx=5, pady=(0, 5))

        bf = tk.Frame(side, bg='#333')
        bf.pack(fill=tk.X, padx=5, pady=5)
        tk.Button(bf, text='Save  (Ctrl+S)', command=self.save).pack(fill=tk.X)
        tk.Button(bf, text='Quit  (Q)', command=self.root.quit
                  ).pack(fill=tk.X, pady=(2, 0))

        # bindings
        self.cv.bind('<Button-1>', self.on_click)
        self.cv.bind('<Button-2>', lambda e: self.on_click(e, rev=True))
        self.cv.bind('<Button-3>', lambda e: self.on_click(e, rev=True))
        self.root.bind('<Control-s>', lambda e: self.save())
        self.root.bind('<Escape>', lambda e: self.root.quit())
        self.root.bind('q', lambda e: self.root.quit())
        self.root.bind('<Up>',    lambda e: self.move_sel(dy=-1))
        self.root.bind('<Down>',  lambda e: self.move_sel(dy=1))
        self.root.bind('<Left>',  lambda e: self.move_sel(dx=-1))
        self.root.bind('<Right>', lambda e: self.move_sel(dx=1))
        self.root.bind('<Tab>',   lambda e: self.toggle_sel())
        self.root.bind('<space>',     lambda e: self.cycle_sel(False))
        self.root.bind('<BackSpace>', lambda e: self.cycle_sel(True))

    # ── drawing ──

    def full_redraw(self):
        self.cv.delete('all')
        self._draw_cells()
        self._draw_grid_lines()
        self._draw_edges()
        self._draw_selection()
        self._update_lut()

    def _draw_cells(self):
        H = CELL // 2
        for y in range(SIZE):
            for x in range(SIZE):
                cx = PAD + x * CELL
                cy = PAD + y * CELL
                self.cv.create_rectangle(cx - H, cy - H, cx + H, cy + H,
                                         fill=cell_display_color(self.height(y, x)),
                                         outline='', tags='cell')

    def _draw_grid_lines(self):
        """Thin dark lines on every cell boundary for visual clarity."""
        c = '#333333'
        for i in range(SIZE + 1):
            x = PAD + i * CELL
            self.cv.create_line(x, PAD, x, PAD + SIZE * CELL,
                                fill=c, width=1, tags='grid')
            y = PAD + i * CELL
            self.cv.create_line(PAD, y, PAD + SIZE * CELL, y,
                                fill=c, width=1, tags='grid')

    def _draw_edges(self):
        self.cv.delete('edge')
        for y in range(SIZE):
            for x in range(SIZE):
                if (y, x) in self.unassigned:
                    hc = vc = '#ff2222'
                else:
                    hc = color_hex(self.edge_val(y, x, 'h'))
                    vc = color_hex(self.edge_val(y, x, 'v'))

                # h-edge: horizontal line at top of cell
                ly = PAD + y * CELL
                lx0 = PAD + x * CELL
                lx1 = lx0 + CELL
                self.cv.create_line(lx0, ly, lx1, ly,
                                    fill=hc, width=2, tags='edge')
                if y == 0:
                    self.cv.create_line(lx0, PAD + SIZE * CELL,
                                        lx1, PAD + SIZE * CELL,
                                        fill=hc, width=2, tags='edge')

                # v-edge: vertical line at left of cell
                lx = PAD + x * CELL
                ly0 = PAD + y * CELL
                ly1 = ly0 + CELL
                self.cv.create_line(lx, ly0, lx, ly1,
                                    fill=vc, width=2, tags='edge')
                if x == 0:
                    self.cv.create_line(PAD + SIZE * CELL, ly0,
                                        PAD + SIZE * CELL, ly1,
                                        fill=vc, width=2, tags='edge')

    def _hl(self, y, x, typ, colour, _width):
        """Draw bracket markers at both ends of an edge (doesn't obscure it)."""
        M = 4  # marker length in pixels
        if typ == 'h':
            # h-edge is horizontal at top of cell
            ly = PAD + y * CELL
            lx0, lx1 = PAD + x * CELL, PAD + (x + 1) * CELL
            # left bracket
            self.cv.create_line(lx0, ly - M, lx0, ly, lx0 + M, ly,
                                fill=colour, width=2, tags='sel')
            # right bracket
            self.cv.create_line(lx1, ly - M, lx1, ly, lx1 - M, ly,
                                fill=colour, width=2, tags='sel')
        else:
            # v-edge is vertical at left of cell
            lx = PAD + x * CELL
            ly0, ly1 = PAD + y * CELL, PAD + (y + 1) * CELL
            # top bracket
            self.cv.create_line(lx - M, ly0, lx, ly0, lx, ly0 + M,
                                fill=colour, width=2, tags='sel')
            # bottom bracket
            self.cv.create_line(lx - M, ly1, lx, ly1, lx, ly1 - M,
                                fill=colour, width=2, tags='sel')

    def _draw_selection(self):
        self.cv.delete('sel')
        if not self.sel:
            return
        y, x, typ = self.sel
        partner = 'v' if typ == 'h' else 'h'
        self._hl(y, x, partner, '#663333', 3)   # partner dim
        self._hl(y, x, typ,     '#ff4444', 4)   # selected bright

    def _update_lut(self):
        t = self.lut_text
        t.config(state=tk.NORMAL)
        t.delete('1.0', tk.END)

        for cat, label in [('sea', 'Sea'), ('land', 'Land'), ('plat', 'Plateau')]:
            used = self.used_patterns(cat)
            counts = self.pattern_counts(cat)
            lut = self.luts[cat]

            n_entries = len(lut['h'])
            over = len(used - set(range(SAVE_LUT)))  # entries in 8..11
            hdr = f'══ {label} LUT ({len(used)}/{SAVE_LUT}) ══\n'
            if len(used) > SAVE_LUT:
                t.insert(tk.END, hdr, 'over')
                t.tag_config('over', foreground='#ff8844')
            else:
                t.insert(tk.END, hdr)
            for i in range(n_entries):
                hn = color_name(lut['h'][i])
                vn = color_name(lut['v'][i])
                tag = f'lut_{cat}_{i}'
                prefix = ' ' if i < SAVE_LUT else '+'
                if i in used:
                    n = counts.get(i, 0)
                    t.insert(tk.END, f'{prefix}{i}: h={hn:2s} v={vn:2s}  ({n:4d})\n', tag)
                else:
                    t.insert(tk.END, f'{prefix}{i}: h={hn:2s} v={vn:2s}  [free]\n', tag)
                t.tag_bind(tag, '<Button-1>',
                           lambda e, c=cat, p=i: self.free_lut_entry(c, p))
                fg = '#ff8844' if i >= SAVE_LUT and i in used else \
                     '#cccccc' if i in used else '#666666'
                t.tag_config(tag, foreground=fg)
            t.insert(tk.END, '\n')

        if self.unassigned:
            t.insert(tk.END, f'!! {len(self.unassigned)} unassigned\n', 'warn')
            t.tag_config('warn', foreground='#ff4444')
            t.insert(tk.END, '\n')

        t.insert(tk.END, '── Controls ──\n')
        t.insert(tk.END, 'Click face      : paint square\n')
        t.insert(tk.END, 'Click edge      : cycle edge\n')
        t.insert(tk.END, 'Click LUT entry : free it\n')
        t.insert(tk.END, 'R-click         : cycle ←\n')
        t.insert(tk.END, 'Ctrl+S          : save\n')
        t.insert(tk.END, 'Q / Esc         : quit\n')
        t.config(state=tk.DISABLED)

    def free_lut_entry(self, cat, pat):
        """Free a LUT entry: set all vertices using it to unassigned."""
        count = 0
        for y in range(SIZE):
            for x in range(SIZE):
                if ((y, x) not in self.unassigned
                        and self.cat(y, x) == cat
                        and self.pattern(y, x) == pat):
                    self.unassigned.add((y, x))
                    count += 1
        if count > 0:
            self.modified = True
            self.status.set(f'Freed {cat}[{pat}]: {count} vertices unassigned')
            self._draw_edges()
            self._update_lut()
        else:
            self.status.set(f'{cat}[{pat}] not in use')

    # ── interaction ──

    def on_click(self, event, rev=False):
        gx = (event.x - PAD) / CELL
        gy = (event.y - PAD) / CELL
        if not (-0.4 <= gx <= SIZE + 0.4 and -0.4 <= gy <= SIZE + 0.4):
            return

        near_x = round(gx)
        near_y = round(gy)
        dx = abs(gx - near_x) * CELL
        dy = abs(gy - near_y) * CELL
        th = CELL * 0.4

        edge_th = CELL * 0.3
        if min(dx, dy) >= edge_th and 0 <= gx < SIZE and 0 <= gy < SIZE:
            # Inside a face → paint all 4 edges of the face
            self.paint_face(int(gy) % SIZE, int(gx) % SIZE, rev)
        elif dy < th and dy <= dx and 0 <= near_y <= SIZE:
            # Near horizontal grid line → h-edge (drawn horizontally)
            row = int(near_y) % SIZE
            col = max(0, min(SIZE - 1, int(gx)))
            self.sel = (row, col, 'h')
            self.cycle_edge(row, col, 'h', rev)
        elif dx < th and dx < dy and 0 <= near_x <= SIZE:
            # Near vertical grid line → v-edge (drawn vertically)
            col = int(near_x) % SIZE
            row = max(0, min(SIZE - 1, int(gy)))
            self.sel = (row, col, 'v')
            self.cycle_edge(row, col, 'v', rev)

    def move_sel(self, dx=0, dy=0):
        if not self.sel:
            self.sel = (0, 0, 'h')
        y, x, t = self.sel
        self.sel = ((y + dy) % SIZE, (x + dx) % SIZE, t)
        self._draw_selection()
        self._show_sel_info()

    def toggle_sel(self):
        if not self.sel:
            self.sel = (0, 0, 'h')
        y, x, t = self.sel
        self.sel = (y, x, 'v' if t == 'h' else 'h')
        self._draw_selection()
        self._show_sel_info()

    def cycle_sel(self, rev):
        if not self.sel:
            return
        y, x, t = self.sel
        self.cycle_edge(y, x, t, rev)

    def _set_vertex(self, y, x, want_h, want_v):
        """Set vertex (y,x) edges to want_h/want_v. Returns True on success."""
        c = self.cat(y, x)
        if c == 'plat':
            return False
        lut = self.luts[c]
        # Find existing pattern
        for i in range(len(lut['h'])):
            if lut['h'][i] == want_h and lut['v'][i] == want_v:
                self.set_pattern(y, x, i)
                self.unassigned.discard((y, x))
                return True
        # Create new entry
        used = self.used_patterns(c)
        n = len(lut['h'])
        free = [i for i in range(n) if i not in used]
        if not free:
            if n < MAX_LUT:
                # Extend the LUT
                i = n
                lut['h'].append(want_h)
                lut['v'].append(want_v)
            else:
                self.status.set(f'No free {c} LUT slots! (max {MAX_LUT})')
                return False
        else:
            i = free[0]
            lut['h'][i] = want_h
            lut['v'][i] = want_v
        self.set_pattern(y, x, i)
        self.unassigned.discard((y, x))
        return True

    def paint_face(self, fy, fx, rev=False):
        """Paint all 4 edges of face (fy,fx) to the next cycle colour."""
        # Cycle based on top edge's current colour
        cur = CYCLE[-1] if (fy, fx) in self.unassigned else self.edge_val(fy, fx, 'h')
        if cur in CYCLE:
            target = CYCLE[(CYCLE.index(cur) + (-1 if rev else 1)) % len(CYCLE)]
        else:
            target = CYCLE[0]

        # 3 vertices to modify:
        # (fy, fx): both h-edge (top) and v-edge (left) become target
        # (fy+1, fx): h-edge (bottom) becomes target, v-edge preserved
        # (fy, fx+1): v-edge (right) becomes target, h-edge preserved
        y1 = (fy + 1) % SIZE
        x1 = (fx + 1) % SIZE

        self._set_vertex(fy, fx, target, target)

        cur_v = self.edge_val(y1, fx, 'v')
        self._set_vertex(y1, fx, target, cur_v)

        cur_h = self.edge_val(fy, x1, 'h')
        self._set_vertex(fy, x1, cur_h, target)

        self.sel = (fy, fx, 'h')
        self.modified = True
        self.status.set(f'Face ({fy},{fx}) → {color_name(target)}')
        self._draw_edges()
        self._draw_selection()
        self._update_lut()

    def _show_sel_info(self):
        if not self.sel:
            return
        y, x, t = self.sel
        c = self.cat(y, x)
        p = self.pattern(y, x)
        ev = self.edge_val(y, x, t)
        cn = color_name(ev)
        self.status.set(f'({y},{x}) {t}-edge: {cn}  [{c} pat={p}]')

    def cycle_edge(self, y, x, typ, rev=False):
        c = self.cat(y, x)
        if c == 'plat':
            self.status.set(f'({y},{x}) is plateau — not editable')
            self._draw_selection()
            return

        lut = self.luts[c]
        if (y, x) in self.unassigned:
            cur_h = cur_v = CYCLE[-1]  # so first click gives CYCLE[0]
        else:
            p = self.pattern(y, x)
            cur_h, cur_v = lut['h'][p], lut['v'][p]

        old = cur_h if typ == 'h' else cur_v
        if old in CYCLE:
            i = CYCLE.index(old)
            new = CYCLE[(i + (-1 if rev else 1)) % len(CYCLE)]
        else:
            new = CYCLE[0]

        want_h = new if typ == 'h' else cur_h
        want_v = cur_v if typ == 'h' else new

        # find existing pattern
        found = None
        for i in range(len(lut['h'])):
            if lut['h'][i] == want_h and lut['v'][i] == want_v:
                found = i
                break

        if found is None:
            used = self.used_patterns(c)
            n = len(lut['h'])
            free = [i for i in range(n) if i not in used]
            if not free:
                if n < MAX_LUT:
                    found = n
                    lut['h'].append(want_h)
                    lut['v'].append(want_v)
                else:
                    self.status.set(f'No free {c} LUT slots! (max {MAX_LUT})')
                    self._draw_selection()
                    return
            else:
                found = free[0]
                lut['h'][found] = want_h
                lut['v'][found] = want_v
            self.status.set(
                f'New {c}[{found}]: h={color_name(want_h)} '
                f'v={color_name(want_v)}')
        else:
            self.status.set(
                f'({y},{x}) {typ}→{color_name(new)} (pat {found})')

        self.set_pattern(y, x, found)
        self.unassigned.discard((y, x))
        self.sel = (y, x, typ)
        self.modified = True
        self._draw_edges()
        self._draw_selection()
        self._update_lut()

    # ── save ──

    def save(self):
        if self.unassigned:
            self.status.set(
                f'Cannot save: {len(self.unassigned)} unassigned vertices')
            return
        if self.overflow:
            self.status.set(
                f'Cannot save: {len(self.overflow)} vertices use overflow entries')
            return
        for cat in ('sea', 'land', 'plat'):
            used = self.used_patterns(cat)
            if len(used) > SAVE_LUT:
                self.status.set(
                    f'Cannot save: {cat} uses {len(used)} entries (max {SAVE_LUT})')
                return
        # ── map_data.inc — replace only "; row N" lines, preserve rest ──
        with open('map_data.inc') as f:
            lines = f.readlines()
        row_idx = 0
        for i, line in enumerate(lines):
            if re.search(r';\s*row\s+\d+', line):
                v = ', '.join(f'${self.grid[row_idx][x]:02X}'
                              for x in range(SIZE))
                lines[i] = f'    .byte {v}  ; row {row_idx}\n'
                row_idx += 1
        with open('map_data.inc', 'w') as f:
            f.writelines(lines)

        # ── edge_color.inc — rewrite LUT tables ──
        def fmt(vals):
            vs = ', '.join(f'${v:02X}' for v in vals)
            ns = ' '.join(f'{color_name(v):4s}' for v in vals)
            return vs, ns

        with open('edge_color.inc', 'w') as f:
            f.write('; edge_color.inc — Edge colour LUTs for grid rendering\n')
            f.write(';\n')
            f.write('; Three 8-entry tables, indexed by color bits 0-2 of heightmap cell.\n')
            f.write('; Table selected by vertex height: 0 = sea, 31 = plateau, other = land.\n')
            f.write(';\n')
            f.write(';           pattern: 000  001  010  011  100  101  110  111\n')
            for cat, name in [('sea', 'sea'), ('plat', 'plat'), ('land', 'land')]:
                hv, hn = fmt(self.luts[cat]['h'][:SAVE_LUT])
                vv, vn = fmt(self.luts[cat]['v'][:SAVE_LUT])
                f.write(f'h_color_{name}:\n')
                f.write(f'    .byte          {hv}\n')
                base = f'v_color_{name}:'
                pad = max(1, 63 - len(base))
                f.write(f'{base}{" " * pad}; {hn}\n')
                f.write(f'    .byte          {vv.ljust(47)}; {vn}\n')
                f.write('\n')

        self.modified = False
        self.status.set('Saved map_data.inc + edge_color.inc')


if __name__ == '__main__':
    root = tk.Tk()
    EdgeEditor(root)
    root.mainloop()
