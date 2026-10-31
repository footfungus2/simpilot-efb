// Screen capture of chart pages shown by the SimPilot Link panel. MSFS gives panels chart images only as GPU
// bitmaps (ChartView LiveViews) that can be displayed but not read back, so the panel shows each page between two
// marker squares and the bridge copies those screen pixels. Windows only: a long-running Windows PowerShell process
// with a small C# helper (System.Drawing, part of every Windows install) does the capture and stitching.

import { type ChildProcessWithoutNullStreams, spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { HttpError } from '../http.js';
import { logger } from '../log.js';

const log = logger('capture');
const COMMAND_TIMEOUT_MS = 30_000;

/** One piece of a page: the panel's view shows the page (scaled to `image`) offset by (-i * view.w, -j * view.h). */
export interface CaptureTile {
  i: number;
  j: number;
  cols: number;
  rows: number;
  /** Panel CSS pixels. */
  view: { w: number; h: number };
  image: { w: number; h: number };
}

export interface Capturer {
  /** Gets ready ahead of the first chart (the helper takes a few seconds to start); problems show up again at the first tile. */
  warmUp?(): void;
  /** Captures one tile; tile (0, 0) starts a new page. Rejects with a message for the user if it can't. */
  tile(t: CaptureTile): Promise<void>;
  /** The stitched page as PNG. */
  finish(): Promise<Buffer>;
}

// Markers: a magenta square touching the view's top-left corner and a cyan one touching its bottom-right corner.
export const HELPER_SCRIPT = String.raw`
$ErrorActionPreference = 'Stop'
Add-Type -ReferencedAssemblies System.Drawing, System.Windows.Forms -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class SimPilotCapture {
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  struct Block { public int X, Y, W, H; }
  static Bitmap page;
  static int viewW, viewH;
  static double scale, scaleY;

  // Per-monitor aware (V2 = -4), so screen pixels are never bitmap-stretched on a mixed-DPI setup; older Windows falls back.
  static SimPilotCapture() {
    try { if (!SetProcessDpiAwarenessContext(new IntPtr(-4))) SetProcessDPIAware(); }
    catch (EntryPointNotFoundException) { SetProcessDPIAware(); }
  }

  public static string Run(string line) {
    try {
      string[] a = (line ?? "").Trim().Split(' ');
      if (a[0] == "tile" && a.Length == 9) {
        int[] n = new int[4];
        for (int k = 0; k < 4; k++) n[k] = int.Parse(a[k + 1], CultureInfo.InvariantCulture);
        double[] d = new double[4];
        for (int k = 0; k < 4; k++) d[k] = double.Parse(a[k + 5], CultureInfo.InvariantCulture);
        return Tile(n[0], n[1], n[2], n[3], d[0], d[1], d[2], d[3]);
      }
      if (a[0] == "finish") return Finish();
      if (a[0] == "ping") return "ok";
      return "err unknown command";
    } catch (Exception e) {
      Reset();
      haveView = false;
      return "err " + e.Message.Replace('\r', ' ').Replace('\n', ' ');
    }
  }

  // Where the panel was last found. Every page starts with a search of the whole screen; the tiles after it only look at
  // this rectangle (the view, both markers and the tile-number squares), which is much less to copy and to scan.
  static bool haveView;
  static Rectangle cView, cRegion;
  static Block cMark, cCyan;

  static Bitmap Grab(Rectangle screen, Rectangle r) {
    Bitmap b = new Bitmap(r.Width, r.Height, PixelFormat.Format32bppArgb);
    using (Graphics g = Graphics.FromImage(b)) {
      g.CopyFromScreen(screen.Left + r.X, screen.Top + r.Y, 0, 0, r.Size, CopyPixelOperation.SourceCopy);
    }
    return b;
  }

  static Block Shift(Block k, Rectangle r) {
    Block s = new Block();
    s.X = k.X - r.X; s.Y = k.Y - r.Y; s.W = k.W; s.H = k.H;
    return s;
  }

  // Still the marker we found before? (Three points inside the block.)
  static bool IsBlock(Bitmap b, Block k, bool magenta) {
    int[] f = new int[] { 1, 2, 3 };
    foreach (int n in f) {
      int x = k.X + k.W * n / 4, y = k.Y + k.H * n / 4;
      if (x < 0 || y < 0 || x >= b.Width || y >= b.Height) return false;
      Color c = b.GetPixel(x, y);
      if (!IsRgb(c.R, c.G, c.B, magenta)) return false;
    }
    return true;
  }

  // The panel marks the tile it is showing with 8 black/white squares (bit k = square k, value = tile number + 1) along the
  // top edge. Until that number is on screen the tile is stale or half drawn, so look again instead of stitching it in.
  static string Tile(int i, int j, int cols, int rows, double vw, double vh, double iw, double ih) {
    System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();
    Rectangle screen = SystemInformation.VirtualScreen;
    int want = j * cols + i + 1, seen = -1, tries = 0, misses = 0;
    bool fast = false;
    Rectangle src = Rectangle.Empty; // the view, in the coordinates of shot
    string why = null;
    Bitmap shot = null;
    try {
      if (i == 0 && j == 0) haveView = false;
      while (true) {
        tries++;
        if (shot != null) { shot.Dispose(); shot = null; }
        if (haveView) {
          shot = Grab(screen, cRegion);
          Block m = Shift(cMark, cRegion);
          if (!IsBlock(shot, m, true) || !IsBlock(shot, Shift(cCyan, cRegion), false)) {
            haveView = false; // moved, resized or covered: look at the whole screen again
            continue;
          }
          src = new Rectangle(cView.X - cRegion.X, cView.Y - cRegion.Y, cView.Width, cView.Height);
          seen = ReadCode(shot, m);
          fast = true;
        } else {
          fast = false;
          shot = Grab(screen, new Rectangle(0, 0, screen.Width, screen.Height));
          Block mark, cyan;
          Rectangle view = FindView(shot, out mark, out cyan, out why);
          if (view.Width <= 0) {
            if (++misses >= 3) break;
            System.Threading.Thread.Sleep(150);
            continue;
          }
          src = view;
          seen = ReadCode(shot, mark);
          cView = view; cMark = mark; cCyan = cyan;
          int x1 = Math.Min(shot.Width, Math.Max(cyan.X + cyan.W, mark.X + (int)Math.Ceiling(mark.W * 10.5)));
          cRegion = new Rectangle(mark.X, mark.Y, x1 - mark.X, cyan.Y + cyan.H - mark.Y);
          haveView = true;
        }
        if (seen == want || clock.ElapsedMilliseconds > 3000) break;
        System.Threading.Thread.Sleep(25);
      }
      if (src.Width <= 0) throw new Exception(why);
      if (seen != want) {
        haveView = false;
        throw new Exception("The SimPilot Link window did not finish drawing chart tile " + want + " (it shows " + seen + "). Keep it open and uncovered, then export the chart again.");
      }
      string note = "ok";
      if (i == 0 && j == 0) {
        Reset();
        viewW = src.Width;
        viewH = src.Height;
        scale = src.Width / vw;
        scaleY = src.Height / vh;
        int w = Math.Max(1, (int)Math.Round(iw * scale));
        int h = Math.Max(1, (int)Math.Round(ih * scaleY));
        if ((long)w * h > 100000000L) throw new Exception("Chart page is too large to capture.");
        page = new Bitmap(w, h, PixelFormat.Format24bppRgb);
        using (Graphics g = Graphics.FromImage(page)) g.Clear(Color.White);
        note = "ok scale=" + scale.ToString("0.000", CultureInfo.InvariantCulture) + " page=" + w + "x" + h;
      } else if (page == null) {
        throw new Exception("Chart capture was interrupted; request the airport again.");
      } else if (Math.Abs(src.Width - viewW) > 2 || Math.Abs(src.Height - viewH) > 2) {
        throw new Exception("The SimPilot Link window was resized during capture; request the airport again.");
      }
      // Whole screen pixels per tile, so neighbouring tiles meet exactly (no rounding seams).
      using (Graphics g = Graphics.FromImage(page)) {
        g.CompositingMode = CompositingMode.SourceCopy;
        g.InterpolationMode = InterpolationMode.NearestNeighbor;
        g.DrawImage(shot, new Rectangle(i * viewW, j * viewH, src.Width, src.Height), src, GraphicsUnit.Pixel);
      }
      return note + " tries=" + tries + " fast=" + (fast ? 1 : 0) + " ms=" + clock.ElapsedMilliseconds;
    } finally {
      if (shot != null) shot.Dispose();
    }
  }

  static int ReadCode(Bitmap shot, Block m) {
    int value = 0;
    int y = m.Y + m.H / 2;
    for (int k = 0; k < 8; k++) {
      int x = m.X + (int)Math.Round(m.W * (k + 1.5));
      if (x < 0 || x >= shot.Width || y < 0 || y >= shot.Height) return -1;
      Color c = shot.GetPixel(x, y);
      if (c.R + c.G + c.B > 384) value |= 1 << k;
    }
    return value;
  }

  static string Finish() {
    if (page == null) throw new Exception("Chart capture was interrupted; request the airport again.");
    using (MemoryStream ms = new MemoryStream()) {
      page.Save(ms, ImageFormat.Png);
      Reset();
      return "png " + Convert.ToBase64String(ms.ToArray());
    }
  }

  static void Reset() {
    if (page != null) { page.Dispose(); page = null; }
  }

  // The view lies between the magenta block's bottom-right corner and the cyan block's top-left corner.
  static Rectangle FindView(Bitmap bmp, out Block mark, out Block cyan, out string why) {
    mark = new Block();
    cyan = new Block();
    why = null;
    BitmapData data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    try {
      byte[] px = new byte[data.Stride * bmp.Height];
      Marshal.Copy(data.Scan0, px, 0, px.Length);
      List<Block> tl = Blocks(px, data.Stride, bmp.Width, bmp.Height, true);
      List<Block> br = Blocks(px, data.Stride, bmp.Width, bmp.Height, false);
      Rectangle best = Rectangle.Empty;
      long bestArea = 0;
      foreach (Block m in tl) {
        foreach (Block c in br) {
          if (Math.Abs(m.W - c.W) > 3 || Math.Abs(m.H - c.H) > 3) continue;
          int x = m.X + m.W, y = m.Y + m.H, w = c.X - x, h = c.Y - y;
          if (w < 50 || h < 50) continue;
          long area = (long)w * h;
          if (area > bestArea) { bestArea = area; best = new Rectangle(x, y, w, h); mark = m; cyan = c; }
        }
      }
      if (best.Width <= 0) {
        if (tl.Count == 0 && br.Count == 0) why = "Can't see the SimPilot Link window. Keep it open and fully visible on screen (not minimised or covered), and run MSFS in windowed or borderless mode. If it is open, turn HDR off in Windows: HDR washes out the colours the capture looks for.";
        else if (tl.Count == 0 || br.Count == 0) why = "Only one corner marker of the SimPilot Link window is visible: it is partly covered or off screen. Make the panel bigger and fully visible.";
        else why = "Found SimPilot Link markers, but they don't make up a window. Make the panel bigger and fully visible.";
      }
      return best;
    } finally {
      bmp.UnlockBits(data);
    }
  }

  static bool Is(byte[] p, int o, bool magenta) {
    return IsRgb(p[o + 2], p[o + 1], p[o], magenta);
  }

  static bool IsRgb(int r, int g, int b, bool magenta) {
    // Wide enough to survive washed-out (HDR / colour-managed) captures; the shape test in Blocks keeps false hits out.
    return magenta ? (r >= 170 && b >= 170 && g <= Math.Min(r, b) - 90) : (g >= 170 && b >= 170 && r <= Math.Min(g, b) - 90);
  }

  // Solid, roughly square blocks of the colour (thin magenta route lines elsewhere on screen don't qualify).
  static List<Block> Blocks(byte[] p, int stride, int w, int h, bool magenta) {
    List<Block> list = new List<Block>();
    for (int y = 0; y < h && list.Count < 64; y += 3) {
      for (int x = 0; x < w && list.Count < 64; x += 3) {
        if (!Is(p, y * stride + x * 4, magenta)) continue;
        bool seen = false;
        foreach (Block b in list) if (x >= b.X && x < b.X + b.W && y >= b.Y && y < b.Y + b.H) { seen = true; break; }
        if (seen) continue;
        int x0 = x, y0 = y;
        while (x0 > 0 && Is(p, y0 * stride + (x0 - 1) * 4, magenta)) x0--;
        while (y0 > 0 && Is(p, (y0 - 1) * stride + x0 * 4, magenta)) y0--;
        int bw = 0, bh = 0;
        while (x0 + bw < w && Is(p, y0 * stride + (x0 + bw) * 4, magenta)) bw++;
        while (y0 + bh < h && Is(p, (y0 + bh) * stride + x0 * 4, magenta)) bh++;
        if (bw >= 6 && bh >= 6 && bw <= 300 && bh <= 300 && Math.Abs(bw - bh) <= Math.Max(2, bw / 4)) {
          Block blk = new Block();
          blk.X = x0; blk.Y = y0; blk.W = bw; blk.H = bh;
          list.Add(blk);
        }
      }
    }
    return list;
  }
}
'@
[Console]::Out.WriteLine('ready')
while ($true) {
  $line = [Console]::In.ReadLine()
  if ($null -eq $line) { break }
  [Console]::Out.WriteLine([SimPilotCapture]::Run($line))
}
`;

/** Runs the capture helper on demand and sends it one command at a time. */
export class ScreenCapture implements Capturer {
  private proc: ChildProcessWithoutNullStreams | undefined;
  private lines: string[] = [];
  private waiters: ((line: string | undefined) => void)[] = [];
  private queue: Promise<unknown> = Promise.resolve();
  /** Timing of the page being captured, logged when it is finished: where the time goes. */
  private stats = { startedAt: 0, tiles: 0, helperMs: 0, tries: 0, fast: 0 };

  warmUp(): void {
    this.start().catch((err) => log.warn(`chart capture helper not ready: ${(err as Error).message}`));
  }

  async tile(t: CaptureTile): Promise<void> {
    const n = (v: number) => String(Math.round(v * 1000) / 1000);
    const began = Date.now();
    const reply = await this.command(`tile ${t.i} ${t.j} ${t.cols} ${t.rows} ${n(t.view.w)} ${n(t.view.h)} ${n(t.image.w)} ${n(t.image.h)}`);
    if (t.i === 0 && t.j === 0) {
      log.info(`capture ${reply.replace(/^ok /, "")} (scale 1.000 = one screen pixel per panel pixel)`);
      this.stats = { startedAt: began, tiles: 0, helperMs: 0, tries: 0, fast: 0 };
    }
    const num = (key: string) => Number(new RegExp(`${key}=(\\d+)`).exec(reply)?.[1] ?? 0);
    this.stats.tiles++;
    this.stats.helperMs += num("ms");
    this.stats.tries += num("tries");
    this.stats.fast += num("fast");
  }

  async finish(): Promise<Buffer> {
    const finishing = Date.now();
    const reply = await this.command('finish');
    const { tiles, helperMs, tries, fast, startedAt } = this.stats;
    if (tiles) {
      log.info(`page captured: ${tiles} tiles in ${((Date.now() - startedAt) / 1000).toFixed(1)} s (capture ${helperMs} ms, avg ${(tries / tiles).toFixed(1)} looks per tile, ${fast} quick, stitching ${Date.now() - finishing} ms)`);
      this.stats.tiles = 0;
    }
    return Buffer.from(reply.replace(/^png /, ''), 'base64');
  }

  stop(): void {
    this.proc?.kill();
    this.proc = undefined;
  }

  private command(line: string): Promise<string> {
    const run = this.queue.then(async () => {
      const proc = await this.start();
      proc.stdin.write(line + '\n');
      const reply = await this.next(COMMAND_TIMEOUT_MS);
      if (reply === undefined) {
        this.stop();
        throw new HttpError(500, 'Chart capture helper stopped responding');
      }
      if (reply.startsWith('err ')) throw new HttpError(409, reply.slice(4));
      return reply;
    });
    this.queue = run.catch(() => undefined);
    return run;
  }

  private async start(): Promise<ChildProcessWithoutNullStreams> {
    if (this.proc) return this.proc;
    if (process.platform !== 'win32') throw new HttpError(501, 'Chart capture needs the bridge running on the Windows PC with MSFS');
    const script = path.join(os.tmpdir(), 'simpilot-chart-capture.ps1');
    fs.writeFileSync(script, HELPER_SCRIPT);
    const proc = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script], { windowsHide: true });
    this.proc = proc;
    this.lines = [];
    readline.createInterface({ input: proc.stdout }).on('line', (line) => {
      const waiter = this.waiters.shift();
      if (waiter) waiter(line);
      else this.lines.push(line);
    });
    proc.stderr.on('data', (d: Buffer) => log.warn(`helper: ${d.toString().trim().slice(0, 300)}`));
    const gone = (why: string) => {
      if (this.proc === proc) this.proc = undefined;
      log.warn(`chart capture helper ${why}`);
      for (const w of this.waiters.splice(0)) w(undefined);
    };
    proc.on('exit', (code) => gone(`exited (${code})`));
    proc.on('error', (err) => gone(`failed: ${err.message}`));
    // Compiling the helper takes a moment on first start.
    if ((await this.next(60_000)) !== 'ready') {
      this.stop();
      throw new HttpError(500, 'Chart capture helper did not start; check the bridge window for errors');
    }
    return proc;
  }

  private next(timeoutMs: number): Promise<string | undefined> {
    const queued = this.lines.shift();
    if (queued !== undefined) return Promise.resolve(queued);
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        const at = this.waiters.indexOf(done);
        if (at >= 0) this.waiters.splice(at, 1);
        resolve(undefined);
      }, timeoutMs);
      const done = (line: string | undefined) => {
        clearTimeout(timer);
        resolve(line);
      };
      this.waiters.push(done);
    });
  }
}
