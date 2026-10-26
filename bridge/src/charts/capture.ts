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
  struct Block { public int X, Y, W, H; }
  static Bitmap page;
  static int viewW, viewH;
  static double scale;

  static SimPilotCapture() { SetProcessDPIAware(); }

  public static string Run(string line) {
    try {
      string[] a = (line ?? "").Trim().Split(' ');
      if (a[0] == "tile" && a.Length == 9) {
        int[] n = new int[4];
        for (int k = 0; k < 4; k++) n[k] = int.Parse(a[k + 1], CultureInfo.InvariantCulture);
        double[] d = new double[4];
        for (int k = 0; k < 4; k++) d[k] = double.Parse(a[k + 5], CultureInfo.InvariantCulture);
        Tile(n[0], n[1], n[2], n[3], d[0], d[1], d[2], d[3]);
        return "ok";
      }
      if (a[0] == "finish") return Finish();
      if (a[0] == "ping") return "ok";
      return "err unknown command";
    } catch (Exception e) {
      Reset();
      return "err " + e.Message.Replace('\r', ' ').Replace('\n', ' ');
    }
  }

  static void Tile(int i, int j, int cols, int rows, double vw, double vh, double iw, double ih) {
    Rectangle screen = SystemInformation.VirtualScreen;
    using (Bitmap shot = new Bitmap(screen.Width, screen.Height, PixelFormat.Format32bppArgb)) {
      using (Graphics g = Graphics.FromImage(shot)) {
        g.CopyFromScreen(screen.Left, screen.Top, 0, 0, screen.Size, CopyPixelOperation.SourceCopy);
      }
      Rectangle view = FindView(shot);
      if (view.Width <= 0) throw new Exception("Can't see the SimPilot Link window. Keep it open and fully visible on screen (not minimised or covered), and run MSFS in windowed or borderless mode.");
      if (i == 0 && j == 0) {
        Reset();
        viewW = view.Width;
        viewH = view.Height;
        scale = view.Width / vw;
        int w = Math.Max(1, (int)Math.Round(iw * scale));
        int h = Math.Max(1, (int)Math.Round(ih * scale));
        if ((long)w * h > 100000000L) throw new Exception("Chart page is too large to capture.");
        page = new Bitmap(w, h, PixelFormat.Format24bppRgb);
        using (Graphics g = Graphics.FromImage(page)) g.Clear(Color.White);
      } else if (page == null) {
        throw new Exception("Chart capture was interrupted; request the airport again.");
      } else if (Math.Abs(view.Width - viewW) > 2 || Math.Abs(view.Height - viewH) > 2) {
        throw new Exception("The SimPilot Link window was resized during capture; request the airport again.");
      }
      int dx = (int)Math.Round(i * vw * scale);
      int dy = (int)Math.Round(j * vh * scale);
      using (Graphics g = Graphics.FromImage(page)) {
        g.CompositingMode = CompositingMode.SourceCopy;
        g.InterpolationMode = InterpolationMode.NearestNeighbor;
        g.DrawImage(shot, new Rectangle(dx, dy, view.Width, view.Height), view, GraphicsUnit.Pixel);
      }
    }
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
  static Rectangle FindView(Bitmap bmp) {
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
          if (area > bestArea) { bestArea = area; best = new Rectangle(x, y, w, h); }
        }
      }
      return best;
    } finally {
      bmp.UnlockBits(data);
    }
  }

  static bool Is(byte[] p, int o, bool magenta) {
    int b = p[o], g = p[o + 1], r = p[o + 2];
    return magenta ? (r >= 200 && g <= 60 && b >= 200) : (r <= 60 && g >= 200 && b >= 200);
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

  warmUp(): void {
    this.start().catch((err) => log.warn(`chart capture helper not ready: ${(err as Error).message}`));
  }

  async tile(t: CaptureTile): Promise<void> {
    const n = (v: number) => String(Math.round(v * 1000) / 1000);
    await this.command(`tile ${t.i} ${t.j} ${t.cols} ${t.rows} ${n(t.view.w)} ${n(t.view.h)} ${n(t.image.w)} ${n(t.image.h)}`);
  }

  async finish(): Promise<Buffer> {
    const reply = await this.command('finish');
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
