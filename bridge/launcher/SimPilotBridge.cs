// SimPilot Bridge.exe: a native WPF window plus a tray icon around node.exe / bridge.cjs.
// Compiled in CI with the C# 5 compiler that ships with Windows (csc.exe, .NET Framework 4), so keep to C# 5:
// no string interpolation, no ?. operator, no expression-bodied members, no nameof.
// To look at the window while changing it, run ./scripts/launcher-preview.sh on the Mac: it builds and opens it on the PC.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Shell;
using System.Windows.Threading;
using Microsoft.Win32;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;
using Run = System.Windows.Documents.Run;
using Shapes = System.Windows.Shapes;

static class Program
{
    public const int Port = 8386;
    public const int SecurePort = 8387;
    const string ShowEvent = "Local\\SimPilotBridgeShow";
    static readonly JavaScriptSerializer Js = new JavaScriptSerializer();

    [STAThread]
    static int Main(string[] args)
    {
        if (Array.IndexOf(args, "--check") >= 0) return SelfCheck();
        if (Array.IndexOf(args, "--preview") >= 0) return Preview();
        bool created;
        using (Mutex single = new Mutex(true, "Local\\SimPilotBridgeLauncher", out created))
        {
            if (!created)
            {
                try { EventWaitHandle.OpenExisting(ShowEvent).Set(); } catch (Exception) { }   // already running: show its window
                return 0;
            }
            Application app = new Application();
            app.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            TrayApp tray = new TrayApp(Array.IndexOf(args, "--minimized") >= 0, new EventWaitHandle(false, EventResetMode.AutoReset, ShowEvent));
            app.Startup += delegate { tray.Begin(); };
            app.Run();
        }
        return 0;
    }

    // CI runs this after compiling: builds the whole window (not shown) and feeds it sample data, so a broken UI fails the build.
    static int SelfCheck()
    {
        int result = 1;
        Look.Preview = true;
        Thread t = new Thread(delegate ()
        {
            try
            {
                Spring spring = new Spring(0.7);
                if (spring.Ease(0) != 0 || spring.Ease(1) != 1 || spring.Ease(0.5) < 1) return;   // starts at 0, overshoots a little, lands on 1
                object status = Status(0);
                if (!Json.Bool(status, "sim", "connected") || Json.Int(status, "bridge", "apps") != 2) return;
                MainWindow w = new MainWindow(null);
                for (int state = 0; state < 3; state++) Sample(w, state);
                for (int page = 1; page < 6; page++) w.ShowPage(page);
                w.OpenWizard();
                result = 0;
            }
            catch (Exception ex) { Console.Error.WriteLine(ex.ToString()); }
        });
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
        t.Join();
        return result;
    }

    // ./scripts/launcher-preview.sh opens this on the PC: the window with sample data and no bridge. It changes nothing on the PC.
    static int Preview()
    {
        Look.Preview = true;
        Application app = new Application();
        MainWindow w = new MainWindow(null);
        int state = 0;
        Sample(w, 0);
        w.Rebuilt += delegate { Sample(w, state); };
        w.ContentRendered += delegate { w.Toast("Preview with sample data. Press Space to switch the state."); };
        w.KeyDown += delegate (object s, KeyEventArgs e) { if (e.Key == Key.Space) { state = (state + 1) % 3; Sample(w, state); } };
        app.Run(w);
        return 0;
    }

    static object Status(int state)
    {
        return Js.DeserializeObject(state == 0
            ? "{\"sim\":{\"connected\":true,\"aircraftTitle\":\"Fenix A320\"},\"link\":{\"connected\":true},\"bridge\":{\"apps\":2,\"version\":\"0.1.1\",\"port\":8386}}"
            : "{\"sim\":{\"connected\":true,\"aircraftTitle\":\"Fenix A320\"},\"link\":{\"connected\":false},\"bridge\":{\"apps\":0,\"version\":\"0.1.1\",\"port\":8386}}");
    }

    /// Sample data for --check and --preview: 0 = everything connected, 1 = waiting for the iPad, 2 = bridge stopped.
    static void Sample(MainWindow w, int state)
    {
        if (state == 2) w.ShowStopped("SimPilot Bridge stopped (exit code 1). Press Restart bridge.");
        else w.ApplyStatus(Status(state));
        w.ApplyInfo(Js.DeserializeObject("{\"cache\":{\"airports\":[{\"icao\":\"EGSS\",\"charts\":14,\"bytes\":123456789},{\"icao\":\"LIRA\",\"charts\":9,\"bytes\":80740352}],\"bytes\":204197141}}"));
        w.ApplyLog(Js.DeserializeObject("{\"entries\":[{\"time\":\"2026-11-04T16:41:58.004Z\",\"level\":\"info\",\"scope\":\"sim\",\"message\":\"connected to MSFS 2024\"},{\"time\":\"2026-11-04T16:42:01.123Z\",\"level\":\"warn\",\"scope\":\"link\",\"message\":\"in-sim link lost\"},{\"time\":\"2026-11-04T16:42:09.877Z\",\"level\":\"error\",\"scope\":\"charts\",\"message\":\"EGSS export failed, retrying\"}]}"));
    }
}

static class Json
{
    public static object Get(object root, params string[] path)
    {
        object cur = root;
        foreach (string key in path)
        {
            Dictionary<string, object> d = cur as Dictionary<string, object>;
            if (d == null || !d.ContainsKey(key)) return null;
            cur = d[key];
        }
        return cur;
    }
    public static bool Bool(object root, params string[] path) { object v = Get(root, path); return v is bool && (bool)v; }
    public static int Int(object root, params string[] path) { return (int)Long(root, path); }
    public static long Long(object root, params string[] path)
    {
        object v = Get(root, path);
        return v is IConvertible && !(v is string) && !(v is bool) ? Convert.ToInt64(v, CultureInfo.InvariantCulture) : 0;
    }
    public static string Str(object root, params string[] path) { return Get(root, path) as string; }
    public static IEnumerable List(object root, params string[] path)
    {
        IEnumerable list = Get(root, path) as IEnumerable;
        return list == null || list is string ? new object[0] : list;
    }
}

static class Net
{
    /// Plain HTTP to the bridge running in this same program. Throws with the bridge's own error message when it gives one.
    public static string Call(string method, string path, int timeoutMs, string pairingKey = null)
    {
        HttpWebRequest r = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + Program.Port + path);
        r.Method = method;
        r.Timeout = timeoutMs;
        r.ReadWriteTimeout = timeoutMs;
        r.Proxy = null;
        if (method == "POST") { r.ContentLength = 0; r.Headers["x-simpilot-ui"] = "1"; }   // the bridge only accepts repairs from this window
        if (!string.IsNullOrEmpty(pairingKey)) r.Headers["x-simpilot-token"] = pairingKey;
        try
        {
            using (HttpWebResponse res = (HttpWebResponse)r.GetResponse()) return Read(res);
        }
        catch (WebException ex)
        {
            HttpWebResponse res = ex.Response as HttpWebResponse;
            if (res == null) throw;
            string message = null;
            try { message = Json.Str(new JavaScriptSerializer().DeserializeObject(Read(res)), "error"); } catch (Exception) { }
            throw new Exception(message ?? ("The bridge answered " + (int)res.StatusCode));
        }
    }

    static string Read(HttpWebResponse res)
    {
        using (StreamReader sr = new StreamReader(res.GetResponseStream(), Encoding.UTF8)) return sr.ReadToEnd();
    }

    public static object Obj(string method, string path, int timeoutMs, string pairingKey = null) { return new JavaScriptSerializer().DeserializeObject(Call(method, path, timeoutMs, pairingKey)); }
}

// ---- look: near-black with hairlines, light and one blue accent (think Linear / Raycast) ----
static class Pal
{
    public static Color C(string hex) { return (Color)ColorConverter.ConvertFromString(hex); }
    public static SolidColorBrush B(string hex) { return new SolidColorBrush(C(hex)); }   // new each time: animated brushes can't be shared
    public const string Frame = "#0B0C0E", Panel = "#101114", Layer = "#08FFFFFF", Raised = "#0FFFFFFF", Line = "#12FFFFFF", Line2 = "#1FFFFFFF", Clear = "#00FFFFFF";
    public const string Fg = "#F7F8F8", Fg2 = "#8A8F98", Fg3 = "#5E626A", Ok = "#4CC38A", Warn = "#F2994A", Bad = "#EB5757";
    /// The accent (Settings > Accent colour) and a lighter tint of it. Set before the window is built.
    public static string Blue, BlueHi;
    static readonly string FontDir = ExtractFonts();
    public static readonly FontFamily Sans = Font("Inter"), Display = Font("Inter Display"), Mono = new FontFamily("Cascadia Mono, Consolas"), IconFont = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets");
    /// Things move at all (Settings > Animation is not Off). Off: everything snaps into place.
    public static bool Motion { get { return Look.Motion != "Off"; } }
    /// Endless background animations (glow, pulses, streaks) run: Animation is Full.
    public static bool Ambient { get { return Look.Motion == "Full"; } }

    static Pal() { Accent(Look.Accent); }

    public static void Accent(string name)
    {
        int i = Math.Max(0, Array.IndexOf(Look.Accents, name));
        Blue = Look.AccentHex[i];
        BlueHi = Mix(Blue, "#FFFFFF", 0.4);
    }

    /// The accent with an alpha, e.g. A("40") for 25 %.
    public static string A(string alpha) { return "#" + alpha + Blue.Substring(1); }

    /// Blends two #RRGGBB colours; t = 0 is the first, 1 the second.
    public static string Mix(string a, string b, double t)
    {
        Color x = C(a), y = C(b);
        return Color.FromRgb((byte)(x.R + (y.R - x.R) * t), (byte)(x.G + (y.G - x.G) * t), (byte)(x.B + (y.B - x.B) * t)).ToString();
    }

    // Endless animations run on clocks kept here, so they can all be paused while the window is hidden or minimized.
    // A paused clock costs nothing; WPF stops drawing frames when no clock is running.
    static readonly List<KeyValuePair<KeyValuePair<IAnimatable, DependencyProperty>, AnimationClock>> loops = new List<KeyValuePair<KeyValuePair<IAnimatable, DependencyProperty>, AnimationClock>>();
    static bool paused;

    /// Starts an endless animation from Loop (or stops it with null). Only while Animation is Full.
    public static void Run(IAnimatable target, DependencyProperty p, AnimationTimeline loop)
    {
        for (int i = loops.Count - 1; i >= 0; i--)
            if (loops[i].Key.Key == target && loops[i].Key.Value == p) { loops[i].Value.Controller.Stop(); loops.RemoveAt(i); }
        if (loop == null || !Ambient) { target.ApplyAnimationClock(p, null); return; }
        AnimationClock clock = loop.CreateClock();
        target.ApplyAnimationClock(p, clock);
        if (paused) clock.Controller.Pause();
        loops.Add(new KeyValuePair<KeyValuePair<IAnimatable, DependencyProperty>, AnimationClock>(new KeyValuePair<IAnimatable, DependencyProperty>(target, p), clock));
    }

    public static void Pause(bool on)
    {
        if (on == paused) return;
        paused = on;
        foreach (var l in loops) { if (on) l.Value.Controller.Pause(); else l.Value.Controller.Resume(); }
    }

    /// Drops every endless animation, for when the window that owns them closes or is rebuilt.
    public static void StopAll()
    {
        foreach (var l in loops) l.Value.Controller.Stop();
        loops.Clear();
    }

    /// Inter ships inside the exe; WPF only loads fonts from files, so they are written to a folder once.
    /// Temp, not the app's LocalAppData folder: the window keeps them open, which would block Uninstall from deleting that folder.
    static string ExtractFonts()
    {
        try
        {
            string dir = Path.Combine(Path.GetTempPath(), "SimPilot Bridge fonts");
            Directory.CreateDirectory(dir);
            Assembly asm = Assembly.GetExecutingAssembly();
            foreach (string name in asm.GetManifestResourceNames())
            {
                if (!name.EndsWith(".ttf")) continue;
                string file = Path.Combine(dir, name);
                using (Stream s = asm.GetManifestResourceStream(name))
                {
                    if (File.Exists(file) && new FileInfo(file).Length == s.Length) continue;   // another copy may have it open
                    using (FileStream f = File.Create(file)) s.CopyTo(f);
                }
            }
            return dir + "\\";
        }
        catch (Exception) { return null; }
    }

    static FontFamily Font(string family)
    {
        return FontDir == null ? new FontFamily("Segoe UI") : new FontFamily(new Uri(FontDir), "./#" + family + ", Segoe UI");
    }

    public static Duration Ms(int ms) { return new Duration(TimeSpan.FromMilliseconds(Motion ? ms : 0)); }
    public static IEasingFunction Out() { return new CubicEase { EasingMode = EasingMode.EaseOut }; }

    /// A hairline border that catches light along its top edge.
    public static Brush Edge() { return new LinearGradientBrush(C("#26FFFFFF"), C("#0AFFFFFF"), 90); }

    public static TextBlock Text(string text, double size, string fg, bool bold)
    {
        TextBlock t = new TextBlock { Text = text, FontSize = size, Foreground = B(fg), FontFamily = Sans, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        if (bold) t.FontWeight = FontWeights.SemiBold;
        return t;
    }

    public static TextBlock Title(string text, double size)
    {
        TextBlock t = Text(text, size, Fg, true);
        t.FontFamily = Display;
        return t;
    }

    /// An endless ambient animation: back and forth (breathing) or repeating (a pulse). Capped frame rate, since it runs all the time.
    public static AnimationTimeline Loop(double from, double to, int ms, bool reverse, int fps)
    {
        DoubleAnimation a = new DoubleAnimation(from, to, new Duration(TimeSpan.FromMilliseconds(ms))) { RepeatBehavior = RepeatBehavior.Forever, AutoReverse = reverse };
        a.EasingFunction = reverse ? (IEasingFunction)new SineEase { EasingMode = EasingMode.EaseInOut } : Out();
        Timeline.SetDesiredFrameRate(a, fps);
        return a;
    }

    public static Shapes.Path Icon(string data, string stroke, double size)
    {
        return new Shapes.Path { Data = Geometry.Parse(data), Stroke = B(stroke), StrokeThickness = 1.5, Width = size, Height = size, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, StrokeLineJoin = PenLineJoin.Round, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
    }

    public static void Fade(UIElement e, double to, int ms)
    {
        e.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(to, Ms(ms)) { EasingFunction = Out() });
    }

    public static void Reveal(UIElement e)
    {
        e.Visibility = Visibility.Visible;
        e.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, Ms(300)) { EasingFunction = Out() });
    }

    public static void Tint(SolidColorBrush b, string hex, int ms)
    {
        b.BeginAnimation(SolidColorBrush.ColorProperty, new ColorAnimation(C(hex), Ms(ms)) { EasingFunction = Out() });
    }

    public static void Tint(GradientStop s, string hex, int ms)
    {
        s.BeginAnimation(GradientStop.ColorProperty, new ColorAnimation(C(hex), Ms(ms)) { EasingFunction = Out() });
    }

    /// Animates any number (a transform's X, a scale, a height) to a value along the given curve.
    public static void To(IAnimatable target, DependencyProperty p, double to, int ms, IEasingFunction ease)
    {
        target.BeginAnimation(p, new DoubleAnimation(to, Ms(ms)) { EasingFunction = ease });
    }

    public static void From(IAnimatable target, DependencyProperty p, double from, double to, int ms, IEasingFunction ease)
    {
        target.BeginAnimation(p, new DoubleAnimation(from, to, Ms(ms)) { EasingFunction = ease });
    }

    public static void Scale(ScaleTransform s, double to, int ms, IEasingFunction ease)
    {
        To(s, ScaleTransform.ScaleXProperty, to, ms, ease);
        To(s, ScaleTransform.ScaleYProperty, to, ms, ease);
    }

    /// Fades a label out, swaps its text and lets it rise back in. Before the window is on screen it just sets the text.
    public static void Swap(TextBlock t, string text)
    {
        if ((t.Tag as string ?? t.Text) == text) return;
        t.Tag = text;
        if (!Motion || !t.IsLoaded) { t.Text = text; return; }
        TranslateTransform move = t.RenderTransform as TranslateTransform;
        if (move == null) { move = new TranslateTransform(); t.RenderTransform = move; }
        DoubleAnimation hide = new DoubleAnimation(0, Ms(110));
        hide.Completed += delegate
        {
            t.Text = (string)t.Tag;
            t.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, Ms(220)) { EasingFunction = Out() });
            move.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(6, 0, Ms(420)) { EasingFunction = new Spring(0.8) });
        };
        t.BeginAnimation(UIElement.OpacityProperty, hide);
    }

    /// A soft shadow under a card. It is drawn by a layer of its own: an effect on the card itself would turn off ClearType for its text.
    public static Grid Lift(Border card, double blur, double depth, double opacity)
    {
        Grid g = new Grid();
        g.Children.Add(new Border { CornerRadius = card.CornerRadius, Background = B(Frame), Effect = new DropShadowEffect { BlurRadius = blur, ShadowDepth = depth, Direction = 270, Opacity = opacity } });
        g.Children.Add(card);
        return g;
    }
}

/// A damped spring as an easing curve, the way iOS moves things: quick off the mark, a hint of overshoot, a soft landing.
class Spring : EasingFunctionBase
{
    readonly double damping;   // below 1; lower bounces more

    public Spring(double damping) { this.damping = damping; EasingMode = EasingMode.EaseIn; }   // EaseIn: the curve is used as it is

    protected override double EaseInCore(double t)
    {
        if (t >= 1) return 1;
        double w = 6.9 / damping, wd = w * Math.Sqrt(1 - damping * damping);   // settles to within 0.1 % by the end
        return 1 - Math.Exp(-damping * w * t) * (Math.Cos(wd * t) + damping * w / wd * Math.Sin(wd * t));
    }

    protected override Freezable CreateInstanceCore() { return new Spring(damping); }
}

/// The Settings page's choices, kept in HKCU\Software\SimPilot Bridge (Uninstall deletes the key).
static class Look
{
    const string Key = @"Software\SimPilot Bridge";
    public static readonly string[] Accents = { "Blue", "Indigo", "Violet", "Teal", "Green", "Amber", "Rose" };
    public static readonly string[] AccentHex = { "#4F8CFF", "#7480FF", "#A274FF", "#2EC4B6", "#4CC38A", "#F2A93B", "#F2668B" };
    public static readonly string[] Motions = { "Full", "Calm", "Off" };
    public static string Accent = Read("Accent", "Blue");
    public static string Motion = Read("Motion", SystemParameters.ClientAreaAnimation ? "Full" : "Off");   // follows Windows' "Animation effects" until changed
    public static bool Effects = Read("Effects", "On") == "On";
    public static bool HideAddress = Read("HideAddress", "Off") == "On";

    static string Read(string name, string fallback)
    {
        try { using (RegistryKey k = Registry.CurrentUser.OpenSubKey(Key)) { string v = k == null ? null : k.GetValue(name) as string; return v ?? fallback; } }
        catch (Exception) { return fallback; }
    }

    /// --check and --preview: choices apply but are not saved.
    public static bool Preview;

    public static void Save(string name, string value)
    {
        if (Preview) return;
        try { using (RegistryKey k = Registry.CurrentUser.CreateSubKey(Key)) k.SetValue(name, value); } catch (Exception) { }
    }
}

/// Thin scroll bars and dark tooltips; WPF's own are light grey Windows 7 ones.
static class Theme
{
    public static ResourceDictionary Styles()
    {
        return (ResourceDictionary)XamlReader.Parse(@"
<ResourceDictionary xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
  <Style TargetType='ScrollBar'>
    <Setter Property='Width' Value='10'/>
    <Setter Property='MinWidth' Value='10'/>
    <Setter Property='Template'>
      <Setter.Value>
        <ControlTemplate TargetType='ScrollBar'>
          <Track x:Name='PART_Track' Orientation='Vertical' IsDirectionReversed='True' Margin='0,6,2,6'>
            <Track.DecreaseRepeatButton><RepeatButton Command='ScrollBar.PageUpCommand' Opacity='0' Focusable='False'/></Track.DecreaseRepeatButton>
            <Track.IncreaseRepeatButton><RepeatButton Command='ScrollBar.PageDownCommand' Opacity='0' Focusable='False'/></Track.IncreaseRepeatButton>
            <Track.Thumb>
              <Thumb>
                <Thumb.Template>
                  <ControlTemplate TargetType='Thumb'>
                    <Border x:Name='Bar' Background='#38FFFFFF' CornerRadius='3' Width='6' HorizontalAlignment='Center'/>
                    <ControlTemplate.Triggers>
                      <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='Bar' Property='Background' Value='#66FFFFFF'/></Trigger>
                      <Trigger Property='IsDragging' Value='True'><Setter TargetName='Bar' Property='Background' Value='#88FFFFFF'/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </Thumb.Template>
              </Thumb>
            </Track.Thumb>
          </Track>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType='ToolTip'>
    <Setter Property='Template'>
      <Setter.Value>
        <ControlTemplate TargetType='ToolTip'>
          <Border Background='#F22C2F35' BorderBrush='#24FFFFFF' BorderThickness='1' CornerRadius='7' Padding='10,6'>
            <ContentPresenter TextElement.Foreground='#FFFFFF' TextElement.FontSize='12.5' TextElement.FontFamily='Segoe UI'/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
</ResourceDictionary>");
    }
}

/// Windows 11 window styling through DWM: dark frame, rounded corners and a hairline border in the window's own colours.
static class Dwm
{
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hwnd, int index, int value);

    static int Set(IntPtr hwnd, int attribute, int value)
    {
        try { return DwmSetWindowAttribute(hwnd, attribute, ref value, 4); } catch (Exception) { return -1; }
    }

    /// True on Windows 11, which then draws the window's border itself; older Windows keeps the window's own.
    public static bool Style(Window w)
    {
        IntPtr hwnd = new WindowInteropHelper(w).Handle;
        // Without the system menu DWM draws no caption buttons of its own; the window has its own.
        SetWindowLong(hwnd, -16, GetWindowLong(hwnd, -16) & ~0x80000);
        Set(hwnd, 20, 1);   // DWMWA_USE_IMMERSIVE_DARK_MODE
        Set(hwnd, 33, 2);   // DWMWA_WINDOW_CORNER_PREFERENCE: round
        return Set(hwnd, 34, 0x002D2826) == 0;   // DWMWA_BORDER_COLOR, BGR for #26282D
    }
}

static class Icons
{
    // 24 x 24, for the connection map
    public const string Plane = "M12,2.5 C12.8,2.5 13.3,3.4 13.3,4.5 L13.3,9.2 L21,13.6 L21,15.6 L13.3,13.2 L13.3,18 L15.6,19.8 L15.6,21.4 L12,20.4 L8.4,21.4 L8.4,19.8 L10.7,18 L10.7,13.2 L3,15.6 L3,13.6 L10.7,9.2 L10.7,4.5 C10.7,3.4 11.2,2.5 12,2.5 Z";
    public const string Pc = "M3.5,4.5 H20.5 V15.5 H3.5 Z M9,19.5 H15 M12,15.5 V19.5";
    public const string Ipad = "M6,2.5 H18 A1.5,1.5 0 0 1 19.5,4 V20 A1.5,1.5 0 0 1 18,21.5 H6 A1.5,1.5 0 0 1 4.5,20 V4 A1.5,1.5 0 0 1 6,2.5 Z M11,18.5 H13";
    // 16 x 16
    public const string Status = "M2,2H7V7H2Z M9,2H14V7H9Z M2,9H7V14H2Z M9,9H14V14H9Z";
    public const string Chart = "M3.5,1.5 H12.5 V14.5 H3.5 Z M6,5 H10 M6,8 H10 M6,11 H8.5";
    public const string Log = "M3,4H13 M3,8H13 M3,12H9";
    public const string Wrench = "M10.5,2.5 A3,3 0 0 0 6.8,6.4 L2.5,10.7 L5.3,13.5 L9.6,9.2 A3,3 0 0 0 13.5,5.5 L11.7,7.3 L9.7,6.8 L9.2,4.8 Z";
    public const string Help = "M2,8 A6,6 0 1 0 14,8 A6,6 0 1 0 2,8 Z M6.3,6.3 A1.8,1.8 0 1 1 8.7,8 C8.2,8.2 8,8.6 8,9.1 M8,11.2 L8,11.3";
    public const string Wifi = "M1.5,6.2 A9.5,9.5 0 0 1 14.5,6.2 M3.8,8.8 A6.2,6.2 0 0 1 12.2,8.8 M6.1,11.3 A3,3 0 0 1 9.9,11.3 M8,13.6 L8,13.7";
    public const string Power = "M8,1.8 V7.5 M4.6,4 A5.5,5.5 0 1 0 11.4,4";
    public const string Shield = "M8,1.5 L13.5,3.5 V7.5 C13.5,11 11,13.5 8,14.5 C5,13.5 2.5,11 2.5,7.5 V3.5 Z M5.5,8 L7.3,9.8 L10.5,6.5";
    public const string Trash = "M2.5,4 H13.5 M6.2,4 V2.5 H9.8 V4 M4,4 L4.7,14 H11.3 L12,4";
    public const string Exit = "M6.5,2.5 H3 V13.5 H6.5 M10,5 L13,8 L10,11 M13,8 H6";
    public const string Eye = "M1.5,8 C1.5,8 4,3.5 8,3.5 C12,3.5 14.5,8 14.5,8 C14.5,8 12,12.5 8,12.5 C4,12.5 1.5,8 1.5,8 Z M10,8 A2,2 0 1 0 6,8 A2,2 0 1 0 10,8 Z";
    public const string EyeShut = Eye + " M2,2 L14,14";
    public const string Chevron = "M4,6 L8,10 L12,6";
    public const string Gear = "M8,5.5 A2.5,2.5 0 1 0 8,10.5 A2.5,2.5 0 1 0 8,5.5 Z M8,1.5 V3 M8,13 V14.5 M1.5,8 H3 M13,8 H14.5 M3.4,3.4 L4.5,4.5 M11.5,11.5 L12.6,12.6 M3.4,12.6 L4.5,11.5 M11.5,4.5 L12.6,3.4";
    public const string Palette = "M8,1.5 A6.5,6.5 0 1 0 8,14.5 C9,14.5 9.5,13.8 9.2,13 C8.8,12 9.4,11 10.5,11 H12 A2.5,2.5 0 0 0 14.5,8.5 C14.5,4.6 11.6,1.5 8,1.5 Z M5,7.5 L5,7.6 M7.5,4.8 L7.5,4.9 M10.6,5.8 L10.6,5.9";
    public const string Wave = "M1.5,8 C3.5,3 5.5,3 8,8 C10.5,13 12.5,13 14.5,8";
    public const string Sparkle = "M8,1.5 L9.3,6.7 L14.5,8 L9.3,9.3 L8,14.5 L6.7,9.3 L1.5,8 L6.7,6.7 Z";
}

/// A rounded button: it brightens on hover, dips when pressed and springs back on release.
class Btn : Border
{
    public event Action Click;
    readonly TextBlock label;
    readonly ScaleTransform press = new ScaleTransform(1, 1);
    readonly Action<bool> highlight;
    bool down;

    public Btn(string text, string kind)   // primary | ghost | danger | icon
    {
        CornerRadius = new CornerRadius(8);
        BorderThickness = new Thickness(1);
        Padding = new Thickness(13, 6, 13, 6);
        Cursor = Cursors.Hand;
        RenderTransform = press;
        RenderTransformOrigin = new Point(0.5, 0.5);
        label = Pal.Text(text, 13, kind == "danger" ? Pal.Bad : Pal.Fg, false);
        label.FontWeight = kind == "primary" ? FontWeights.SemiBold : FontWeights.Medium;
        Child = label;
        if (kind == "primary")
        {
            GradientStop top = new GradientStop(Pal.C(Pal.Mix(Pal.Blue, "#FFFFFF", 0.1)), 0), bottom = new GradientStop(Pal.C(Pal.Mix(Pal.Blue, "#000000", 0.1)), 1);
            Background = new LinearGradientBrush(new GradientStopCollection { top, bottom }, 90);
            BorderBrush = new LinearGradientBrush(Pal.C("#80FFFFFF"), Pal.C("#14FFFFFF"), 90);   // light catching the top edge
            DropShadowEffect glow = new DropShadowEffect { Color = Pal.C(Pal.Blue), BlurRadius = 18, ShadowDepth = 2, Direction = 270, Opacity = 0.35 };
            Effect = glow;
            highlight = delegate (bool on)
            {
                Pal.Tint(top, on ? Pal.Mix(Pal.Blue, "#FFFFFF", 0.25) : Pal.Mix(Pal.Blue, "#FFFFFF", 0.1), 160);
                Pal.Tint(bottom, on ? Pal.Mix(Pal.Blue, "#FFFFFF", 0.05) : Pal.Mix(Pal.Blue, "#000000", 0.1), 160);
                glow.BeginAnimation(DropShadowEffect.OpacityProperty, new DoubleAnimation(on ? 0.7 : 0.35, Pal.Ms(220)));
            };
        }
        else
        {
            bool danger = kind == "danger";
            SolidColorBrush fill = Pal.B("#0AFFFFFF"), edge = Pal.B(Pal.Line2), fg = (SolidColorBrush)label.Foreground;
            Background = fill;
            BorderBrush = edge;
            highlight = delegate (bool on)
            {
                Pal.Tint(fill, on ? (danger ? "#1FEB5757" : "#17FFFFFF") : "#0AFFFFFF", 160);
                Pal.Tint(edge, on ? (danger ? "#59EB5757" : "#33FFFFFF") : Pal.Line2, 160);
                if (danger) Pal.Tint(fg, on ? "#FF8A8A" : Pal.Bad, 160);
            };
        }
        MouseEnter += delegate { if (IsEnabled) highlight(true); };
        MouseLeave += delegate { highlight(false); };
        MouseLeftButtonDown += delegate
        {
            if (!IsEnabled) return;
            down = true;
            Pal.Scale(press, 0.95, 90, Pal.Out());
            CaptureMouse();
        };
        MouseLeftButtonUp += delegate (object s, MouseButtonEventArgs e)
        {
            if (!down) return;   // pressed somewhere else and released here
            down = false;
            Point p = e.GetPosition(this);
            bool inside = p.X >= 0 && p.Y >= 0 && p.X <= ActualWidth && p.Y <= ActualHeight;
            ReleaseMouseCapture();
            Pal.Scale(press, 1, 480, new Spring(0.5));
            if (inside && IsEnabled && Click != null) Click();
        };
        IsEnabledChanged += delegate
        {
            Pal.Fade(this, IsEnabled ? 1 : 0.45, 160);
            Cursor = IsEnabled ? Cursors.Hand : Cursors.Arrow;
            if (!IsEnabled) highlight(false);
        };
    }

    public string Text { get { return label.Text; } set { label.Text = value; } }
    public void SetContent(UIElement e) { Child = e; }
}

/// Status dot; while connected a soft ring pulses around it.
class Dot : Grid
{
    readonly Shapes.Ellipse core = new Shapes.Ellipse { Width = 8, Height = 8, Fill = Pal.B(Pal.Fg3) };
    readonly Shapes.Ellipse ring = new Shapes.Ellipse { Width = 8, Height = 8, Fill = Pal.B(Pal.Ok), Opacity = 0, RenderTransformOrigin = new Point(0.5, 0.5) };
    readonly ScaleTransform scale = new ScaleTransform(1, 1);
    bool pulsing;

    public Dot()
    {
        Width = 18; Height = 18;
        ring.RenderTransform = scale;
        Children.Add(ring);
        Children.Add(core);
    }

    public void Set(bool ok, bool busy)
    {
        Pal.Tint((SolidColorBrush)core.Fill, ok ? Pal.Ok : busy ? Pal.Blue : Pal.Fg3, 300);
        Pal.Tint((SolidColorBrush)ring.Fill, busy ? Pal.Blue : Pal.Ok, 300);
        bool want = ok || busy;
        if (want == pulsing) return;
        pulsing = want;
        Pal.Run(scale, ScaleTransform.ScaleXProperty, want ? Pal.Loop(1, 2.4, 2200, false, 30) : null);
        Pal.Run(scale, ScaleTransform.ScaleYProperty, want ? Pal.Loop(1, 2.4, 2200, false, 30) : null);
        Pal.Run(ring, UIElement.OpacityProperty, want ? Pal.Loop(0.45, 0, 2200, false, 30) : null);
    }
}

/// iOS-style switch: the knob stretches while pressed and springs across.
class Switch : Border
{
    public event Action Changed;
    readonly SolidColorBrush track = Pal.B(Pal.Line2);
    readonly Border knob = new Border { Width = 16, Height = 16, CornerRadius = new CornerRadius(8), Background = Pal.B(Pal.Fg), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center };
    readonly TranslateTransform move = new TranslateTransform(3, 0);
    bool on, held;

    public Switch()
    {
        Width = 40; Height = 22; CornerRadius = new CornerRadius(11); Background = track; Cursor = Cursors.Hand;
        knob.RenderTransform = move;
        knob.Effect = new DropShadowEffect { BlurRadius = 4, ShadowDepth = 1, Direction = 270, Opacity = 0.35 };
        Child = knob;
        MouseLeftButtonDown += delegate { held = true; Layout(true); CaptureMouse(); };
        MouseLeftButtonUp += delegate (object s, MouseButtonEventArgs e)
        {
            if (!held) return;
            held = false;
            ReleaseMouseCapture();
            Point p = e.GetPosition(this);
            if (p.X >= 0 && p.Y >= 0 && p.X <= ActualWidth && p.Y <= ActualHeight)
            {
                on = !on;
                if (Changed != null) Changed();
            }
            Layout(true);
        };
    }

    public bool On { get { return on; } }

    public void Set(bool value, bool animate) { on = value; Layout(animate); }

    void Layout(bool animate)
    {
        double w = held ? 20 : 16;
        Pal.Tint(track, on ? Pal.Blue : Pal.Line2, animate ? 200 : 0);
        Pal.To(knob, WidthProperty, w, animate ? 260 : 0, new Spring(0.75));
        Pal.To(move, TranslateTransform.XProperty, on ? Width - 3 - w : 3, animate ? 440 : 0, new Spring(0.7));
    }
}

class NavItem : Border
{
    public event Action Click;
    readonly SolidColorBrush fill = Pal.B(Pal.Clear);
    readonly SolidColorBrush fg = Pal.B(Pal.Fg2);
    bool selected;

    public NavItem(string text, string iconData)
    {
        Height = 34; CornerRadius = new CornerRadius(8); Padding = new Thickness(12, 0, 12, 0); Cursor = Cursors.Hand; Background = fill;
        StackPanel row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        Shapes.Path icon = Pal.Icon(iconData, Pal.Fg2, 16);
        icon.Stroke = fg;
        icon.Margin = new Thickness(0, 0, 11, 0);
        TextBlock t = new TextBlock { Text = text, FontSize = 13.5, FontWeight = FontWeights.Medium, FontFamily = Pal.Sans, Foreground = fg, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(icon); row.Children.Add(t);
        Child = row;
        MouseEnter += delegate { if (!selected) { Pal.Tint(fill, "#08FFFFFF", 120); Pal.Tint(fg, Pal.Fg, 120); } };
        MouseLeave += delegate { if (!selected) { Pal.Tint(fill, Pal.Clear, 200); Pal.Tint(fg, Pal.Fg2, 200); } };
        MouseLeftButtonUp += delegate { if (Click != null) Click(); };
    }

    public void Select(bool on)
    {
        selected = on;
        Pal.Tint(fill, Pal.Clear, 200);   // the sliding indicator behind the items shows the selection
        Pal.Tint(fg, on ? Pal.Fg : Pal.Fg2, 200);
    }
}

/// A question that slides open; the chevron turns as it does.
class Faq : StackPanel
{
    readonly Border body;
    readonly TextBlock answer;
    readonly RotateTransform turn = new RotateTransform(0);
    bool open;

    public Faq(string question, string text)
    {
        SolidColorBrush hover = Pal.B(Pal.Clear);
        Grid head = new Grid { Background = hover, Cursor = Cursors.Hand };
        head.ColumnDefinitions.Add(new ColumnDefinition());
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        TextBlock q = Pal.Text(question, 14, Pal.Fg, false);
        q.FontWeight = FontWeights.Medium;
        q.Margin = new Thickness(20, 16, 12, 16);
        Shapes.Path chevron = Pal.Icon(Icons.Chevron, Pal.Fg2, 16);
        chevron.RenderTransform = turn; chevron.RenderTransformOrigin = new Point(0.5, 0.5);
        chevron.Margin = new Thickness(0, 0, 20, 0);
        Grid.SetColumn(chevron, 1);
        head.Children.Add(q); head.Children.Add(chevron);
        answer = Pal.Text(text, 13.5, Pal.Fg2, false);
        answer.LineHeight = 21;
        answer.Margin = new Thickness(20, 0, 48, 18);
        answer.Opacity = 0;
        body = new Border { Child = answer, Height = 0, ClipToBounds = true };
        Children.Add(head); Children.Add(body);
        head.MouseEnter += delegate { Pal.Tint(hover, "#08FFFFFF", 120); };
        head.MouseLeave += delegate { Pal.Tint(hover, Pal.Clear, 200); };
        head.MouseLeftButtonUp += delegate { Toggle(); };
    }

    void Toggle()
    {
        open = !open;
        answer.Measure(new Size(Math.Max(200, ActualWidth), double.PositiveInfinity));
        Pal.To(body, HeightProperty, open ? answer.DesiredSize.Height : 0, open ? 440 : 240, open ? new Spring(0.85) : Pal.Out());
        Pal.Fade(answer, open ? 1 : 0, open ? 320 : 140);
        Pal.To(turn, RotateTransform.AngleProperty, open ? 180 : 0, 420, new Spring(0.7));
    }
}

/// A raised card: hairline edge lit from above, and a soft light that follows the mouse across it.
class Card : Border
{
    readonly Border shine;
    readonly RadialGradientBrush light = new RadialGradientBrush(Pal.C("#10FFFFFF"), Pal.C("#00FFFFFF")) { MappingMode = BrushMappingMode.Absolute, RadiusX = 260, RadiusY = 260 };

    public Card(UIElement content)
    {
        Background = Pal.B(Pal.Layer);
        BorderBrush = Pal.Edge();
        BorderThickness = new Thickness(1);
        CornerRadius = new CornerRadius(12);
        shine = new Border { Background = light, CornerRadius = new CornerRadius(11), Opacity = 0, IsHitTestVisible = false };
        Grid layers = new Grid();
        layers.Children.Add(shine);
        layers.Children.Add(content);
        Child = layers;
        if (!Look.Effects) return;
        MouseMove += delegate (object s, MouseEventArgs e) { Point p = e.GetPosition(this); light.Center = p; light.GradientOrigin = p; };
        MouseEnter += delegate { Pal.Fade(shine, 1, 250); };
        MouseLeave += delegate { Pal.Fade(shine, 0, 450); };
    }
}

/// A number that counts up to its value.
class Counter : TextBlock
{
    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register("Value", typeof(double), typeof(Counter),
        new PropertyMetadata(0.0, delegate (DependencyObject d, DependencyPropertyChangedEventArgs e) { Counter c = (Counter)d; c.Text = c.format((long)Math.Round((double)e.NewValue)); }));
    readonly Func<long, string> format;
    long target = -1;

    public Counter(Func<long, string> format)
    {
        this.format = format;
        FontFamily = Pal.Display; FontSize = 30; FontWeight = FontWeights.SemiBold; Foreground = Pal.B(Pal.Fg);
        Text = format(0);
    }

    public void Set(long value)
    {
        if (value == target) return;
        target = value;
        Pal.To(this, ValueProperty, value, 900, new QuarticEase { EasingMode = EasingMode.EaseOut });
    }

    public void Replay() { if (target > 0) Pal.From(this, ValueProperty, 0, target, 1100, new QuarticEase { EasingMode = EasingMode.EaseOut }); }
}

/// One end of the connection map: an app-icon tile that glows and sends out a pulse while connected, its name and a status line.
class Node : StackPanel
{
    readonly SolidColorBrush edge = Pal.B(Pal.Line2), stroke = Pal.B(Pal.Fg2);
    readonly DropShadowEffect glow = new DropShadowEffect { Color = Pal.C(Pal.Blue), BlurRadius = 34, ShadowDepth = 0, Opacity = 0 };
    readonly Border halo = new Border { CornerRadius = new CornerRadius(18), BorderBrush = Pal.B(Pal.Blue), BorderThickness = new Thickness(1.5), Opacity = 0, RenderTransformOrigin = new Point(0.5, 0.5) };
    readonly ScaleTransform haloScale = new ScaleTransform(1, 1), pop = new ScaleTransform(1, 1);
    readonly TextBlock sub;
    bool pulsing;

    public Node(string name, string icon)
    {
        Grid badge = new Grid { Width = 64, Height = 64, RenderTransform = pop, RenderTransformOrigin = new Point(0.5, 0.5) };
        halo.RenderTransform = haloScale;
        Shapes.Path p = Pal.Icon(icon, Pal.Fg2, 24);
        p.Stroke = stroke;
        badge.Children.Add(halo);
        badge.Children.Add(new Border { CornerRadius = new CornerRadius(18), Background = new LinearGradientBrush(Pal.C("#1E2024"), Pal.C("#121316"), 90), BorderBrush = edge, BorderThickness = new Thickness(1), Child = p, Effect = glow });
        Children.Add(badge);
        TextBlock t = Pal.Text(name, 13.5, Pal.Fg, false);
        t.FontWeight = FontWeights.Medium;
        t.HorizontalAlignment = HorizontalAlignment.Center;
        t.Margin = new Thickness(0, 14, 0, 0);
        sub = Pal.Text("", 12.5, Pal.Fg2, false);
        sub.TextAlignment = TextAlignment.Center;
        sub.HorizontalAlignment = HorizontalAlignment.Center;
        sub.Margin = new Thickness(0, 3, 0, 0);
        Children.Add(t); Children.Add(sub);
    }

    public void Set(bool on, string text)
    {
        Pal.Swap(sub, text);
        Pal.Tint(edge, on ? Pal.A("B3") : Pal.Line2, 400);
        Pal.Tint(stroke, on ? Pal.Fg : Pal.Fg2, 400);
        glow.BeginAnimation(DropShadowEffect.OpacityProperty, new DoubleAnimation(on ? 0.75 : 0, Pal.Ms(600)) { EasingFunction = Pal.Out() });
        if (on == pulsing) return;
        pulsing = on;
        Pal.Run(haloScale, ScaleTransform.ScaleXProperty, on ? Pal.Loop(1, 1.45, 2600, false, 30) : null);
        Pal.Run(haloScale, ScaleTransform.ScaleYProperty, on ? Pal.Loop(1, 1.45, 2600, false, 30) : null);
        Pal.Run(halo, OpacityProperty, on ? Pal.Loop(0.6, 0, 2600, false, 30) : null);
    }

    /// Pops the tile in, for the status card's entrance.
    public void Intro(int delay)
    {
        TimeSpan d = TimeSpan.FromMilliseconds(delay);
        BeginAnimation(OpacityProperty, null); Opacity = 0;
        BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, Pal.Ms(320)) { BeginTime = d });
        foreach (DependencyProperty axis in new[] { ScaleTransform.ScaleXProperty, ScaleTransform.ScaleYProperty })
            pop.BeginAnimation(axis, new DoubleAnimation(0.6, 1, Pal.Ms(760)) { BeginTime = d, EasingFunction = new Spring(0.55) });
    }
}

/// The line between two tiles. While connected, a streak of light runs along it from the sim towards the iPad.
class Link : Grid
{
    readonly Border lit = new Border { Height = 1, Background = Pal.B(Pal.A("80")), VerticalAlignment = VerticalAlignment.Center, Opacity = 0 };
    readonly Grid streak = new Grid { Opacity = 0 };
    readonly TranslateTransform run = new TranslateTransform(-0.6, 0);
    readonly ScaleTransform draw = new ScaleTransform(1, 1);
    bool streaming;

    public Link()
    {
        Height = 10;
        VerticalAlignment = VerticalAlignment.Top;
        Margin = new Thickness(-33, 27, -33, 0);   // centred on the tiles; tile edge to tile edge (columns 150 wide, tiles 64), less 10
        RenderTransform = draw;
        RenderTransformOrigin = new Point(0, 0.5);
        Children.Add(new Border { Height = 1, Background = Pal.B(Pal.Line2), VerticalAlignment = VerticalAlignment.Center });
        Children.Add(lit);
        LinearGradientBrush comet = new LinearGradientBrush(new GradientStopCollection {
            new GradientStop(Pal.C(Pal.A("00")), 0.3), new GradientStop(Pal.C(Pal.A("FF")), 0.46), new GradientStop(Colors.White, 0.5), new GradientStop(Pal.C(Pal.A("00")), 0.52) }, 0);
        comet.RelativeTransform = run;
        // The glow is the same streak drawn wider and faded top and bottom: a blur effect would redraw every frame.
        streak.Children.Add(new Shapes.Rectangle { Fill = comet, Opacity = 0.5, OpacityMask = new LinearGradientBrush(new GradientStopCollection { new GradientStop(Colors.Transparent, 0), new GradientStop(Colors.Black, 0.5), new GradientStop(Colors.Transparent, 1) }, 90) });
        streak.Children.Add(new Shapes.Rectangle { Height = 2, Fill = comet });
        Children.Add(streak);
    }

    public void Set(bool on)
    {
        Pal.Fade(lit, on ? 1 : 0, 500);
        Pal.Fade(streak, on ? 1 : 0, 500);
        if (on == streaming) return;
        streaming = on;
        AnimationTimeline sweep = new DoubleAnimation(-0.6, 0.75, new Duration(TimeSpan.FromMilliseconds(1700))) { RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut } };
        Pal.Run(run, TranslateTransform.XProperty, on ? sweep : null);
    }

    /// Draws the line from left to right, for the status card's entrance.
    public void Intro(int delay)
    {
        draw.BeginAnimation(ScaleTransform.ScaleXProperty, null); draw.ScaleX = 0;
        draw.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0, 1, Pal.Ms(520)) { BeginTime = TimeSpan.FromMilliseconds(delay), EasingFunction = new QuarticEase { EasingMode = EasingMode.EaseOut } });
    }
}

/// The accent colour choices: a row of dots that grow under the mouse; the chosen one wears a ring.
class Swatches : StackPanel
{
    public Swatches(string selected, Action<string> pick)
    {
        Orientation = Orientation.Horizontal;
        List<Shapes.Ellipse> rings = new List<Shapes.Ellipse>();
        string chosen = selected;
        for (int i = 0; i < Look.Accents.Length; i++)
        {
            string name = Look.Accents[i], hex = Look.AccentHex[i];
            ScaleTransform grow = new ScaleTransform(1, 1);
            Grid g = new Grid { Width = 26, Height = 26, Margin = new Thickness(4, 0, 0, 0), Cursor = Cursors.Hand, Background = Pal.B(Pal.Clear), ToolTip = name, RenderTransform = grow, RenderTransformOrigin = new Point(0.5, 0.5) };
            Shapes.Ellipse ring = new Shapes.Ellipse { Stroke = Pal.B(Pal.Fg), StrokeThickness = 1.5, Opacity = name == selected ? 1 : 0 };
            rings.Add(ring);
            g.Children.Add(ring);
            g.Children.Add(new Shapes.Ellipse { Width = 18, Height = 18, Fill = new LinearGradientBrush(Pal.C(Pal.Mix(hex, "#FFFFFF", 0.15)), Pal.C(Pal.Mix(hex, "#000000", 0.12)), 90), Stroke = Pal.B("#33FFFFFF"), StrokeThickness = 1 });
            g.MouseEnter += delegate { Pal.Scale(grow, 1.18, 420, new Spring(0.5)); };
            g.MouseLeave += delegate { Pal.Scale(grow, 1, 420, new Spring(0.7)); };
            g.MouseLeftButtonUp += delegate
            {
                if (name == chosen) return;
                chosen = name;
                foreach (Shapes.Ellipse r in rings) Pal.Fade(r, r == ring ? 1 : 0, 200);
                pick(name);
            };
            Children.Add(g);
        }
    }
}

/// A small segmented control; the highlight glides to the chosen option.
class Segmented : Grid
{
    const double W = 62;

    public Segmented(string[] options, string selected, Action<string> pick)
    {
        Height = 32; Width = W * options.Length + 6;
        string chosen = selected;
        Children.Add(new Border { CornerRadius = new CornerRadius(8), Background = Pal.B("#0AFFFFFF"), BorderBrush = Pal.B(Pal.Line2), BorderThickness = new Thickness(1) });
        TranslateTransform slide = new TranslateTransform(W * Math.Max(0, Array.IndexOf(options, selected)), 0);
        Children.Add(new Border { Width = W, Margin = new Thickness(3), HorizontalAlignment = HorizontalAlignment.Left, CornerRadius = new CornerRadius(6), Background = Pal.B("#1AFFFFFF"), BorderBrush = Pal.Edge(), BorderThickness = new Thickness(1), RenderTransform = slide });
        StackPanel row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(3) };
        List<SolidColorBrush> inks = new List<SolidColorBrush>();
        for (int i = 0; i < options.Length; i++)
        {
            int index = i;
            TextBlock t = Pal.Text(options[i], 12.5, options[i] == selected ? Pal.Fg : Pal.Fg2, false);
            t.FontWeight = FontWeights.Medium;
            t.HorizontalAlignment = HorizontalAlignment.Center;
            inks.Add((SolidColorBrush)t.Foreground);
            Border cell = new Border { Width = W, Background = Pal.B(Pal.Clear), Cursor = Cursors.Hand, Child = t };
            cell.MouseLeftButtonUp += delegate
            {
                if (options[index] == chosen) return;
                chosen = options[index];
                Pal.To(slide, TranslateTransform.XProperty, W * index, 480, new Spring(0.72));
                for (int k = 0; k < inks.Count; k++) Pal.Tint(inks[k], k == index ? Pal.Fg : Pal.Fg2, 200);
                pick(chosen);
            };
            row.Children.Add(cell);
        }
        Children.Add(row);
    }
}

/// Things the window reads straight from Windows, so they show even when the bridge isn't answering.
static class Local
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string RunName = "SimPilot Bridge";

    /// The PC's LAN addresses as "ip:port", Wi-Fi/Ethernet first and VPN/virtual adapters last.
    public static List<string> Addresses()
    {
        List<KeyValuePair<int, string>> found = new List<KeyValuePair<int, string>>();
        try
        {
            foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up || nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                int rank = Regex.IsMatch(nic.Name + " " + nic.Description, "vpn|virtual|vethernet|vmware|wsl|tun|docker|hyper-v|tap|bluetooth", RegexOptions.IgnoreCase) ? 1 : 0;
                foreach (UnicastIPAddressInformation ip in nic.GetIPProperties().UnicastAddresses)
                    if (ip.Address.AddressFamily == AddressFamily.InterNetwork && !ip.Address.ToString().StartsWith("169.254."))
                        found.Add(new KeyValuePair<int, string>(rank, ip.Address + ":" + Program.SecurePort));
            }
        }
        catch (Exception) { }
        List<string> result = new List<string>();
        foreach (KeyValuePair<int, string> f in found) if (f.Key == 0) result.Add(f.Value);
        foreach (KeyValuePair<int, string> f in found) if (f.Key != 0) result.Add(f.Value);
        return result;
    }

    public static bool AutostartOn()
    {
        try { using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKey)) return k != null && k.GetValue(RunName) != null; }
        catch (Exception) { return false; }
    }

    public static bool SetAutostart(bool on)
    {
        try
        {
            using (RegistryKey k = Registry.CurrentUser.CreateSubKey(RunKey))
            {
                if (on) k.SetValue(RunName, "\"" + System.Windows.Forms.Application.ExecutablePath + "\" --minimized");
                else k.DeleteValue(RunName, false);
            }
            return true;
        }
        catch (Exception) { return false; }
    }

    /// MSFS 2024's Community2024 folder from UserCfg.opt (Microsoft Store and Steam keep it in different places).
    public static string FindCommunity(out bool installed)
    {
        installed = false;
        List<string> configs = new List<string>();
        string local = Environment.GetEnvironmentVariable("LOCALAPPDATA"), roaming = Environment.GetEnvironmentVariable("APPDATA");
        try
        {
            string packages = Path.Combine(local ?? "", "Packages");
            if (local != null && Directory.Exists(packages))
                foreach (string d in Directory.GetDirectories(packages, "Microsoft.Limitless_*"))
                {
                    configs.Add(Path.Combine(d, @"LocalCache\UserCfg.opt"));
                    configs.Add(Path.Combine(d, @"LocalState\UserCfg.opt"));
                }
        }
        catch (Exception) { }
        if (roaming != null) configs.Add(Path.Combine(roaming, @"Microsoft Flight Simulator 2024\UserCfg.opt"));
        string fallback = null;
        foreach (string cfg in configs)
        {
            string packagesPath = null;
            try
            {
                if (!File.Exists(cfg)) continue;
                foreach (string line in File.ReadAllLines(cfg))
                {
                    Match m = Regex.Match(line, "^\\s*InstalledPackagesPath\\s+\"([^\"]+)\"");
                    if (m.Success) { packagesPath = m.Groups[1].Value.Trim(); break; }
                }
            }
            catch (Exception) { }
            if (packagesPath == null || !Directory.Exists(packagesPath)) continue;
            foreach (string name in new[] { "Community2024", "Community" })
            {
                string c = Path.Combine(packagesPath, name);
                if (Directory.Exists(Path.Combine(c, "simpilot-link"))) { installed = true; return c; }
            }
            if (fallback == null) fallback = Path.Combine(packagesPath, "Community2024");
        }
        return fallback;
    }

    /// Same rules as build.ps1 for a folder the user picked: Packages, Community2024 or simpilot-link itself.
    public static string CommunityFromChoice(string selected, out bool installed)
    {
        selected = selected.TrimEnd('\\', '/');
        string leaf = Path.GetFileName(selected);
        string community = leaf.Equals("Community2024", StringComparison.OrdinalIgnoreCase) || leaf.Equals("Community", StringComparison.OrdinalIgnoreCase) ? selected
            : leaf.Equals("simpilot-link", StringComparison.OrdinalIgnoreCase) ? Path.GetDirectoryName(selected) : Path.Combine(selected, "Community2024");
        installed = Directory.Exists(Path.Combine(community, "simpilot-link"));
        return community;
    }

    public static string SdkPath()
    {
        string[] candidates = {
            Environment.GetEnvironmentVariable("MSFS2024_SDK"),
            Environment.GetEnvironmentVariable("MSFS2024_SDK", EnvironmentVariableTarget.User),
            Environment.GetEnvironmentVariable("MSFS2024_SDK", EnvironmentVariableTarget.Machine),
            @"C:\MSFS 2024 SDK",
            Path.Combine(Environment.GetEnvironmentVariable("SystemDrive") ?? "C:", "MSFS 2024 SDK") };
        foreach (string c in candidates)
        {
            try { if (!string.IsNullOrEmpty(c) && File.Exists(Path.Combine(c, @"Tools\bin\fspackagetool.exe"))) return c; } catch (Exception) { }
        }
        return null;
    }

    public static bool SimRunning()
    {
        try { return Process.GetProcessesByName("FlightSimulator2024").Length > 0; } catch (Exception) { return false; }
    }
}

/// One line of the install checklist: a numbered badge that spins while it waits and pops into a tick when done.
class StepRow : Grid
{
    readonly SolidColorBrush badgeFill = Pal.B(Pal.Raised), thread = Pal.B(Pal.Line2);
    readonly TextBlock number, detail;
    readonly Shapes.Path tick = new Shapes.Path { Data = Geometry.Parse("M4,9 L7.5,12.5 L14,5.5"), Stroke = Pal.B(Pal.Fg), StrokeThickness = 2, Width = 18, Height = 18, Opacity = 0, StrokeLineJoin = PenLineJoin.Round, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, RenderTransformOrigin = new Point(0.5, 0.5) };
    readonly Shapes.Path spinner = new Shapes.Path { Data = Geometry.Parse("M15,1 A14,14 0 0 1 29,15"), Stroke = Pal.B(Pal.BlueHi), StrokeThickness = 2, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, Width = 30, Height = 30, Opacity = 0 };
    readonly ScaleTransform pop = new ScaleTransform(0.4, 0.4);
    readonly RotateTransform spin = new RotateTransform(0, 15, 15);
    readonly ContentControl slot = new ContentControl { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(16, 0, 0, 0) };
    string state = "todo";

    public StepRow(int n, string title, bool last)
    {
        Margin = new Thickness(0, 0, 0, 16);
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition());
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        // the line down to the next step, filled in once this one is done
        if (!last) Children.Add(new Border { Width = 2, CornerRadius = new CornerRadius(1), Background = thread, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(14, 36, 0, -14) });
        Grid badge = new Grid { Width = 30, Height = 30, Margin = new Thickness(0, 0, 14, 0), VerticalAlignment = VerticalAlignment.Top };
        badge.Children.Add(new Border { CornerRadius = new CornerRadius(15), Background = badgeFill });
        number = Pal.Text(n.ToString(), 13, Pal.Fg2, true);
        number.HorizontalAlignment = HorizontalAlignment.Center;
        tick.RenderTransform = pop;
        spinner.RenderTransform = spin;
        badge.Children.Add(number); badge.Children.Add(tick); badge.Children.Add(spinner);
        StackPanel text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        TextBlock t = Pal.Text(title, 14.5, Pal.Fg, false);
        t.FontWeight = FontWeights.Medium;
        detail = Pal.Text("", 13, Pal.Fg2, false);
        detail.Margin = new Thickness(0, 3, 0, 0);
        detail.LineHeight = 19;
        text.Children.Add(t); text.Children.Add(detail);
        Grid.SetColumn(text, 1); Grid.SetColumn(slot, 2);
        Children.Add(badge); Children.Add(text); Children.Add(slot);
    }

    public void Set(string newState, string text, UIElement action)
    {
        detail.Text = text;
        slot.Content = action;
        if (newState == state) return;
        state = newState;
        bool done = newState == "done", active = newState == "active", fail = newState == "fail";
        Pal.Tint(badgeFill, done ? Pal.Blue : fail ? "#40EB5757" : active ? Pal.A("2E") : Pal.Raised, 260);
        Pal.Tint(thread, done ? Pal.A("99") : Pal.Line2, 500);
        Pal.Tint((SolidColorBrush)number.Foreground, fail ? Pal.Bad : active ? Pal.BlueHi : newState == "todo" ? Pal.Fg2 : Pal.Fg, 260);
        Pal.Fade(number, done ? 0 : 1, 160);
        Pal.Fade(tick, done ? 1 : 0, 200);
        if (done)
        {
            Pal.From(pop, ScaleTransform.ScaleXProperty, 0.4, 1, 520, new Spring(0.55));
            Pal.From(pop, ScaleTransform.ScaleYProperty, 0.4, 1, 520, new Spring(0.55));
        }
        Pal.Fade(spinner, active ? 1 : 0, 200);
        spin.BeginAnimation(RotateTransform.AngleProperty, active && Pal.Motion ? new DoubleAnimation(0, 360, new Duration(TimeSpan.FromMilliseconds(900))) { RepeatBehavior = RepeatBehavior.Forever } : null);
    }
}

/// Guided chart panel install: finds MSFS 2024, checks the SDK and that the sim is closed, then runs build.ps1 with live progress.
class PanelWizard : Grid
{
    readonly MainWindow owner;
    readonly string panelDir;
    readonly Grid cardHost;
    readonly ScaleTransform cardScale = new ScaleTransform(0.94, 0.94);
    readonly TranslateTransform cardMove = new TranslateTransform(0, 20);
    readonly TextBlock title, subtitle, next;
    readonly StepRow sFind, sSdk, sSim, sInstall;
    readonly Border barTrack, barFill, shimmer;
    readonly TranslateTransform shimmerMove = new TranslateTransform(-120, 0);
    readonly TextBlock barText;
    readonly TextBlock logText;
    readonly ScrollViewer logScroll;
    readonly Border logBox;
    readonly Btn details, cancel, go;
    readonly DispatcherTimer simTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
    readonly StringBuilder log = new StringBuilder();
    string community;
    bool installed, sdkOk, simClosed, running, finished, logOpen, shown;
    double progress;

    public PanelWizard(MainWindow owner, string appDir)
    {
        this.owner = owner;
        panelDir = Path.Combine(appDir, "Chart panel (optional)");
        Visibility = Visibility.Collapsed;
        Background = new SolidColorBrush(Color.FromArgb(0x99, 0x05, 0x06, 0x07));
        Border card = new Border { Background = Pal.B("#131417"), BorderBrush = Pal.Edge(), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(16), Padding = new Thickness(32, 28, 32, 24) };
        cardHost = Pal.Lift(card, 70, 24, 0.7);
        cardHost.Width = 620;
        cardHost.HorizontalAlignment = HorizontalAlignment.Center;
        cardHost.VerticalAlignment = VerticalAlignment.Center;
        cardHost.RenderTransform = new TransformGroup { Children = { cardScale, cardMove } };
        cardHost.RenderTransformOrigin = new Point(0.5, 0.5);
        StackPanel s = new StackPanel();
        title = Pal.Title("Install the chart panel", 24);
        subtitle = Pal.Text("SimPilot Link sends the sim's own charts to your iPad. Setting it up takes about two minutes.", 14, Pal.Fg2, false);
        subtitle.Margin = new Thickness(0, 6, 0, 28);
        s.Children.Add(title); s.Children.Add(subtitle);
        sFind = new StepRow(1, "Find MSFS 2024", false); sSdk = new StepRow(2, "MSFS 2024 SDK", false); sSim = new StepRow(3, "Close MSFS 2024", false); sInstall = new StepRow(4, "Install SimPilot Link", true);
        s.Children.Add(sFind); s.Children.Add(sSdk); s.Children.Add(sSim); s.Children.Add(sInstall);

        barTrack = new Border { Height = 6, CornerRadius = new CornerRadius(3), Background = Pal.B(Pal.Raised), Margin = new Thickness(44, -4, 0, 0), ClipToBounds = true, Opacity = 0 };
        Grid barInner = new Grid();
        barFill = new Border { CornerRadius = new CornerRadius(3), Background = Pal.B(Pal.Blue), HorizontalAlignment = HorizontalAlignment.Left, Width = 0 };
        shimmer = new Border { Width = 120, HorizontalAlignment = HorizontalAlignment.Left, RenderTransform = shimmerMove,
            Background = new LinearGradientBrush(new GradientStopCollection { new GradientStop(Color.FromArgb(0, 255, 255, 255), 0), new GradientStop(Color.FromArgb(80, 255, 255, 255), 0.5), new GradientStop(Color.FromArgb(0, 255, 255, 255), 1) }, 0) };
        barInner.Children.Add(barFill); barInner.Children.Add(shimmer);
        barTrack.Child = barInner;
        barText = Pal.Text("", 12.5, Pal.Fg2, false);
        barText.Margin = new Thickness(44, 8, 0, 0);
        s.Children.Add(barTrack); s.Children.Add(barText);

        next = Pal.Text("", 14, Pal.Fg, false);
        next.LineHeight = 22; next.Margin = new Thickness(0, 4, 0, 0); next.Visibility = Visibility.Collapsed;
        s.Children.Add(next);

        logText = new TextBlock { FontFamily = Pal.Mono, FontSize = 11.5, Foreground = Pal.B(Pal.Fg2), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(14, 10, 14, 10) };
        logScroll = new ScrollViewer { Content = logText, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        logBox = new Border { Child = logScroll, Height = 0, Background = Pal.B("#0A0B0D"), CornerRadius = new CornerRadius(10), Margin = new Thickness(0, 14, 0, 0), ClipToBounds = true };
        s.Children.Add(logBox);

        Grid foot = new Grid { Margin = new Thickness(0, 22, 0, 0) };
        details = new Btn("Show details", "ghost") { HorizontalAlignment = HorizontalAlignment.Left };
        details.Click += ToggleDetails;
        StackPanel right = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        cancel = new Btn("Cancel", "ghost") { Margin = new Thickness(0, 0, 10, 0) };
        cancel.Click += delegate { Close(); };
        go = new Btn("Install", "primary");
        go.Click += Go;
        right.Children.Add(cancel); right.Children.Add(go);
        foot.Children.Add(details); foot.Children.Add(right);
        s.Children.Add(foot);
        card.Child = s;
        Children.Add(cardHost);
        simTimer.Tick += delegate { CheckSim(); };
    }

    public bool Running { get { return running; } }

    public void Shutdown() { simTimer.Stop(); }

    public void Open()
    {
        if (running) { Show(); return; }
        finished = false; progress = 0; log.Length = 0; logText.Text = "";
        title.Text = "Install the chart panel";
        subtitle.Text = "SimPilot Link sends the sim's own charts to your iPad. Setting it up takes about two minutes.";
        next.Visibility = Visibility.Collapsed;
        Pal.Fade(barTrack, 0, 0); barText.Text = ""; Pal.To(barFill, WidthProperty, 0, 0, null);   // animations hold their last value, so reset through them
        cancel.Visibility = Visibility.Visible;
        sInstall.Set("todo", "Copies the panel into the sim's Community folder.", null);
        community = Local.FindCommunity(out installed);
        Evaluate();
        Show();
    }

    void Show()
    {
        shown = true;
        Visibility = Visibility.Visible;
        Pal.From(this, OpacityProperty, 0, 1, 220, Pal.Out());
        Pal.From(cardScale, ScaleTransform.ScaleXProperty, 0.94, 1, 560, new Spring(0.72));
        Pal.From(cardScale, ScaleTransform.ScaleYProperty, 0.94, 1, 560, new Spring(0.72));
        Pal.From(cardMove, TranslateTransform.YProperty, 20, 0, 560, new Spring(0.8));
        owner.Dim(true);
        simTimer.Start();
    }

    void Close()
    {
        if (running) return;
        shown = false;
        simTimer.Stop();
        DoubleAnimation fade = new DoubleAnimation(0, Pal.Ms(180));
        fade.Completed += delegate { if (!shown) Visibility = Visibility.Collapsed; };
        BeginAnimation(OpacityProperty, fade);
        Pal.Scale(cardScale, 0.97, 180, Pal.Out());
        Pal.To(cardMove, TranslateTransform.YProperty, 10, 180, Pal.Out());
        owner.Dim(false);
    }

    Btn Small(string text, Action click) { Btn b = new Btn(text, "ghost"); b.Padding = new Thickness(12, 5, 12, 5); b.Click += click; return b; }

    void Evaluate()
    {
        if (community == null)
            sFind.Set("fail", "Couldn't find where MSFS 2024 keeps its add-ons. Choose the Packages folder (the one with Community2024 in it).", Small("Choose folder", Choose));
        else
            sFind.Set("done", (installed ? "SimPilot Link is already installed in " : "Will install into ") + community, Small("Change", Choose));

        string sdk = Local.SdkPath();
        sdkOk = sdk != null;
        if (installed) sSdk.Set("done", "Not needed: the panel is already installed, so it is updated in place.", null);
        else if (sdkOk) sSdk.Set("done", "Found in " + sdk + ". It is only needed this once.", null);
        else sSdk.Set("fail", "Needed once to add the panel. In MSFS 2024 open Settings > Advanced Options > Developer Mode and switch it on, then choose Help > SDK Installer in the menu bar at the top and install it.", Small("Check again", delegate { Evaluate(); }));
        go.Text = installed ? "Update panel" : "Install";
        CheckSim();
    }

    void CheckSim()
    {
        if (running || finished) return;
        simClosed = !Local.SimRunning();
        sSim.Set(simClosed ? "done" : "active", simClosed ? "MSFS 2024 is closed." : "MSFS 2024 is open. Close it to continue; this updates by itself.", null);
        go.IsEnabled = community != null && (installed || sdkOk) && simClosed && File.Exists(Path.Combine(panelDir, "build.ps1"));
        if (!File.Exists(Path.Combine(panelDir, "build.ps1"))) sInstall.Set("fail", "The \"Chart panel (optional)\" folder is missing next to SimPilot Bridge.exe. Extract the whole SimPilot-for-PC.zip and run it from there.", null);
    }

    void Choose()
    {
        Forms.FolderBrowserDialog dialog = new Forms.FolderBrowserDialog { Description = "Select the MSFS 2024 Packages folder, or Community2024 if it already exists.", ShowNewFolderButton = false };
        if (dialog.ShowDialog() != Forms.DialogResult.OK || string.IsNullOrEmpty(dialog.SelectedPath)) return;
        community = Local.CommunityFromChoice(dialog.SelectedPath, out installed);
        Evaluate();
    }

    void ToggleDetails()
    {
        logOpen = !logOpen;
        details.Text = logOpen ? "Hide details" : "Show details";
        Pal.To(logBox, HeightProperty, logOpen ? 180 : 0, 360, logOpen ? new Spring(0.85) : Pal.Out());
    }

    void SetProgress(double value, string text)
    {
        progress = Math.Max(progress, value);
        barText.Text = text;
        double width = Math.Max(0, barTrack.ActualWidth > 0 ? barTrack.ActualWidth : 512) * progress;
        Pal.To(barFill, WidthProperty, width, 700, new Spring(0.9));
    }

    void Go()
    {
        if (finished) { Close(); return; }
        if (running || !go.IsEnabled) return;
        running = true; progress = 0; log.Length = 0; logText.Text = "";
        go.IsEnabled = false; cancel.Visibility = Visibility.Collapsed;
        ((SolidColorBrush)barFill.Background).Color = Pal.C(Pal.Blue);
        sInstall.Set("active", installed ? "Updating the panel files..." : "Building and installing. The SDK may take a minute.", null);
        barTrack.Opacity = 0; Pal.Fade(barTrack, 1, 200);
        if (Pal.Motion) shimmerMove.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(-120, 600, TimeSpan.FromMilliseconds(1300)) { RepeatBehavior = RepeatBehavior.Forever });
        SetProgress(0.05, "Starting...");
        string args = "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(panelDir, "build.ps1") + "\" -Community \"" + community.TrimEnd('\\') + "\"" + (installed ? " -UpdateScript" : "");
        ProcessStartInfo psi = new ProcessStartInfo("powershell.exe", args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true, WorkingDirectory = panelDir };
        try
        {
            Process ps = new Process { StartInfo = psi, EnableRaisingEvents = true };
            ps.OutputDataReceived += delegate (object o, DataReceivedEventArgs e) { if (e.Data != null) Dispatcher.BeginInvoke(new Action(delegate { Line(e.Data); })); };
            ps.ErrorDataReceived += delegate (object o, DataReceivedEventArgs e) { if (e.Data != null) Dispatcher.BeginInvoke(new Action(delegate { Line(e.Data); })); };
            ps.Exited += delegate { int code = 1; try { code = ps.ExitCode; } catch (Exception) { } Dispatcher.BeginInvoke(new Action(delegate { Done(code); })); };
            ps.Start();
            ps.StandardInput.Close();   // nothing may wait for typed input
            ps.BeginOutputReadLine();
            ps.BeginErrorReadLine();
        }
        catch (Exception ex) { Line("Couldn't start PowerShell: " + ex.Message); Done(1); }
    }

    void Line(string text)
    {
        log.AppendLine(text);
        logText.Text = log.ToString();
        logScroll.ScrollToEnd();
        Match m = Regex.Match(text, "^== (\\d)/4 (.+)$");
        if (m.Success) SetProgress(int.Parse(m.Groups[1].Value) / 4.0 - 0.1, m.Groups[2].Value);
    }

    void Done(int code)
    {
        if (!running) return;
        running = false;
        shimmerMove.BeginAnimation(TranslateTransform.XProperty, null);
        shimmerMove.X = -120;
        if (code == 0)
        {
            finished = true;
            SetProgress(1, "Finished");
            sInstall.Set("done", "Installed in " + community + ".", null);
            title.Text = installed ? "Chart panel updated" : "Chart panel installed";
            subtitle.Text = "One last thing in the sim:";
            next.Text = "1.  Start MSFS 2024 (new panels load only when the sim starts) and load into a flight.\n2.  Click the gear icon in the toolbar, switch SimPilot Link on and open it.\n3.  Leave the panel open while you fly. The Status page then shows the chart panel as connected.";
            Pal.Reveal(next);
            go.Text = "Done"; go.IsEnabled = true;
            owner.Toast(installed ? "Chart panel updated." : "Chart panel installed.");
            installed = true;
            return;
        }
        string last = "";
        foreach (string l in log.ToString().Split('\n')) { string t = l.Trim(); if (t.Length > 0 && !t.StartsWith("==") && !t.StartsWith("At ") && !t.StartsWith("+ ")) last = t; }
        sInstall.Set("fail", last.Length > 0 ? last : "The installer stopped (exit code " + code + ").", null);
        ((SolidColorBrush)barFill.Background).Color = Pal.C(Pal.Bad);
        barText.Text = "Didn't finish";
        if (!logOpen) ToggleDetails();
        go.Text = "Try again"; cancel.Visibility = Visibility.Visible;
        Evaluate();
    }
}

class MainWindow : Window
{
    const double NavStep = 38;   // nav item height plus gap
    const int SettingsPage = 4;
    readonly TrayApp host;
    readonly BlurEffect blur = new BlurEffect { Radius = 0 };
    readonly List<FrameworkElement> pageList = new List<FrameworkElement>();
    readonly List<NavItem> navItems = new List<NavItem>();
    readonly Dictionary<string, Btn> actions = new Dictionary<string, Btn>();
    readonly DispatcherTimer timer = new DispatcherTimer();
    readonly DispatcherTimer toastTimer = new DispatcherTimer();
    /// Fires after a Settings change rebuilt the window (the preview refills its sample data).
    public event Action Rebuilt;

    // Everything below is made again by Build(), which a Settings change runs to apply the new look.
    PanelWizard wizard;
    Grid shell, pages, toastHost;
    ScaleTransform shellScale, glowScale;
    TranslateTransform indicatorMove, toastMove;
    Border glowLayer;
    TextBlock hostText, topIp, connText, version, newVersion, headline, lede, addr, pairingCodeText, logText, tLink, toastText;
    Counter statAirports, statBytes;
    Dot connDot, dLink;
    Node nSim, nPc, nIpad;
    Link lSim, lIpad;
    SolidColorBrush chipFill;
    GradientStop heroGlow;
    StackPanel airports;
    ScrollViewer logScroll;
    Switch autostart;
    Btn install, restart;
    Shapes.Path eyeOpen, eyeShut;
    bool ipHidden = Look.HideAddress, polling, infoLoading, logLoading, updateBusy, dimmed;
    int current = -1, misses, tick;
    string firstAddress = "";
    string lastLog = "";

    public MainWindow(TrayApp host)
    {
        this.host = host;
        Title = "SimPilot Bridge";
        Width = 1080; Height = 720;
        ResizeMode = ResizeMode.CanMinimize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        WindowChrome.SetWindowChrome(this, new WindowChrome { CaptionHeight = 52, ResizeBorderThickness = new Thickness(0), GlassFrameThickness = new Thickness(0, 0, 0, 1), CornerRadius = new CornerRadius(0), UseAeroCaptionButtons = false });   // 1 px of glass keeps the system shadow
        Background = Pal.B(Pal.Frame);
        BorderBrush = Pal.B("#26282D");
        BorderThickness = new Thickness(1);
        UseLayoutRounding = true;
        FontFamily = Pal.Sans;
        try { Resources.MergedDictionaries.Add(Theme.Styles()); } catch (Exception) { if (host == null) throw; }   // --check must catch a broken theme
        try { Icon = BitmapFrame.Create(LogoStream(), BitmapCreateOptions.None, BitmapCacheOption.OnLoad); } catch (Exception) { }
        SourceInitialized += delegate { if (Dwm.Style(this)) BorderThickness = new Thickness(0); };
        Build(0);

        IsVisibleChanged += delegate
        {
            Pause();
            if (!IsVisible) return;
            Entrance();
            if (host != null) Refresh();
        };
        StateChanged += delegate { Pause(); };

        toastTimer.Interval = TimeSpan.FromSeconds(5);
        toastTimer.Tick += delegate { toastTimer.Stop(); HideToast(); };
        timer.Interval = TimeSpan.FromSeconds(2);
        timer.Tick += delegate { Refresh(); };
        if (host != null) { timer.Start(); Refresh(); CheckUpdate(); }
    }

    /// Lays the whole window out with the current Settings and shows the given page.
    void Build(int page)
    {
        Pal.StopAll();
        if (wizard != null) wizard.Shutdown();
        pageList.Clear(); navItems.Clear(); actions.Clear();
        shell = new Grid(); pages = new Grid();
        shellScale = new ScaleTransform(1, 1); glowScale = new ScaleTransform(1, 1);
        indicatorMove = new TranslateTransform(); toastMove = new TranslateTransform(0, 24);
        current = -1; lastLog = ""; firstAddress = ""; dimmed = false;

        Grid root = new Grid();
        shell.RowDefinitions.Add(new RowDefinition { Height = new GridLength(52) });
        shell.RowDefinitions.Add(new RowDefinition());
        shell.RenderTransform = shellScale;
        shell.RenderTransformOrigin = new Point(0.5, 0.5);
        shell.Children.Add(TopBar());
        Grid body = new Grid { Margin = new Thickness(8, 0, 8, 8) };
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(220) });
        body.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetRow(body, 1);
        shell.Children.Add(body);
        body.Children.Add(Sidebar());
        Border panel = new Border { Background = Pal.B(Pal.Panel), BorderBrush = Pal.Edge(), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(12), ClipToBounds = true };
        Grid.SetColumn(panel, 1);
        Grid content = new Grid();
        content.Children.Add(pages);
        content.Children.Add(Toaster());
        panel.Child = content;
        body.Children.Add(panel);
        root.Children.Add(shell);
        Content = root;

        AddPage(StatusPage()); AddPage(ChartsPage()); AddPage(LogPage()); AddPage(RepairPage()); AddPage(SettingsView()); AddPage(HelpPage());
        wizard = new PanelWizard(this, AppDomain.CurrentDomain.BaseDirectory);
        root.Children.Add(wizard);
        hostText.Text = Environment.MachineName;
        UpdateAddresses();
        autostart.Set(Local.AutostartOn(), false);
        ShowPage(page);
        Pause();
    }

    /// Applies a Settings change: rebuilds everything in the new look and plays the entrance again.
    void Restyle()
    {
        Build(SettingsPage);
        Entrance();
        if (Rebuilt != null) Rebuilt();
        if (host != null) Refresh();
    }

    /// The window fades up and settles, the sidebar slides in, then the page builds itself.
    void Entrance()
    {
        Pal.From(shell, OpacityProperty, 0, 1, 320, Pal.Out());
        Pal.From(shellScale, ScaleTransform.ScaleXProperty, 0.96, 1, 760, new Spring(0.8));
        Pal.From(shellScale, ScaleTransform.ScaleYProperty, 0.96, 1, 760, new Spring(0.8));
        for (int i = 0; i < navItems.Count; i++) Rise(navItems[i], 120 + 40 * i, -14, true);
        Enter(current, 160);
    }

    /// Background animations stop while nobody can see them.
    void Pause() { Pal.Pause(!IsVisible || WindowState == WindowState.Minimized); }

    public static Stream LogoStream() { return Assembly.GetExecutingAssembly().GetManifestResourceStream("logo.png"); }

    static Image Logo(double size, double radius)
    {
        BitmapImage img = new BitmapImage();
        img.BeginInit(); img.StreamSource = LogoStream(); img.CacheOption = BitmapCacheOption.OnLoad; img.EndInit(); img.Freeze();
        Image i = new Image { Source = img, Width = size, Height = size, IsHitTestVisible = false, Clip = new RectangleGeometry(new Rect(0, 0, size, size), radius, radius) };
        RenderOptions.SetBitmapScalingMode(i, BitmapScalingMode.HighQuality);   // the logo is 192 px; the default scaling makes it jagged
        return i;
    }

    // Closing only hides SimPilot Bridge in the tray; the window itself really closes so its memory is given back.
    // The tray icon builds a new one when it is opened again.
    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        base.OnClosing(e);
        if (host != null && wizard.Running) { e.Cancel = true; Hide(); host.WindowHidden(); }   // an install keeps going and is still on screen next time
    }

    protected override void OnClosed(EventArgs e)
    {
        timer.Stop(); toastTimer.Stop(); wizard.Shutdown();
        Pal.StopAll();
        base.OnClosed(e);
        if (host != null) host.WindowClosed();
    }

    // ---- layout ----

    Grid TopBar()
    {
        Grid g = new Grid();
        StackPanel left = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(18, 0, 0, 0), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center };
        Image logo = Logo(20, 5);
        logo.Margin = new Thickness(0, 0, 10, 0);
        left.Children.Add(logo);
        TextBlock name = Pal.Text("SimPilot Bridge", 13.5, Pal.Fg, false);
        name.FontWeight = FontWeights.Medium;
        left.Children.Add(name);
        left.Children.Add(Pal.Text("/", 13.5, Pal.Fg3, false));
        ((FrameworkElement)left.Children[2]).Margin = new Thickness(10, 0, 10, 0);
        hostText = Pal.Text("", 13.5, Pal.Fg2, false);
        topIp = Pal.Text("", 12.5, Pal.Fg3, false);
        topIp.FontFamily = Pal.Mono;
        topIp.Margin = new Thickness(10, 1, 0, 0);
        left.Children.Add(hostText); left.Children.Add(topIp);
        g.Children.Add(left);

        StackPanel right = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        chipFill = Pal.B(Pal.Layer);
        Border chip = new Border { Background = chipFill, BorderBrush = Pal.B(Pal.Line2), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(13), Padding = new Thickness(5, 2, 12, 2), Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
        StackPanel cp = new StackPanel { Orientation = Orientation.Horizontal };
        connDot = new Dot();
        connText = Pal.Text("Starting", 12.5, Pal.Fg2, false); connText.FontWeight = FontWeights.Medium; connText.Margin = new Thickness(2, 0, 0, 0);
        cp.Children.Add(connDot); cp.Children.Add(connText);
        chip.Child = cp;
        right.Children.Add(chip);
        right.Children.Add(CaptionButton("", false)); right.Children.Add(CaptionButton("", true));
        g.Children.Add(right);
        return g;
    }

    Border CaptionButton(string glyph, bool close)
    {
        SolidColorBrush fill = Pal.B(Pal.Clear);
        TextBlock t = new TextBlock { Text = glyph, FontFamily = Pal.IconFont, FontSize = 10, Foreground = Pal.B(Pal.Fg2), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        Border b = new Border { Width = 46, Height = 52, Background = fill, Child = t };
        WindowChrome.SetIsHitTestVisibleInChrome(b, true);
        b.MouseEnter += delegate { Pal.Tint(fill, close ? "#C42B1C" : Pal.Raised, 120); Pal.Tint((SolidColorBrush)t.Foreground, Pal.Fg, 120); };
        b.MouseLeave += delegate { Pal.Tint(fill, Pal.Clear, 200); Pal.Tint((SolidColorBrush)t.Foreground, Pal.Fg2, 200); };
        b.MouseLeftButtonUp += delegate { if (close) Close(); else WindowState = WindowState.Minimized; };
        return b;
    }

    Grid Sidebar()
    {
        Grid side = new Grid { Margin = new Thickness(4, 4, 10, 0) };
        side.RowDefinitions.Add(new RowDefinition());
        side.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid nav = new Grid { VerticalAlignment = VerticalAlignment.Top };
        nav.Children.Add(new Border { Height = 34, CornerRadius = new CornerRadius(8), Background = Pal.B(Pal.Raised), BorderBrush = Pal.Edge(), BorderThickness = new Thickness(1), VerticalAlignment = VerticalAlignment.Top, RenderTransform = indicatorMove });
        StackPanel items = new StackPanel();
        string[] names = { "Status", "Charts", "Log", "Repair", "Settings", "Help" };
        string[] icons = { Icons.Status, Icons.Chart, Icons.Log, Icons.Wrench, Icons.Gear, Icons.Help };
        for (int i = 0; i < names.Length; i++)
        {
            int index = i;
            NavItem n = new NavItem(names[i], icons[i]) { Margin = new Thickness(0, 0, 0, NavStep - 34) };
            n.Click += delegate { ShowPage(index); };
            navItems.Add(n); items.Children.Add(n);
        }
        nav.Children.Add(items);
        side.Children.Add(nav);

        Grid me = new Grid { Margin = new Thickness(8, 0, 0, 12) };
        me.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        me.ColumnDefinitions.Add(new ColumnDefinition());
        Image logo = Logo(30, 8);
        logo.Margin = new Thickness(0, 0, 11, 0);
        StackPanel tx = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        version = Pal.Text("Version", 12.5, Pal.Fg2, false);
        version.FontWeight = FontWeights.Medium;
        newVersion = Pal.Text("", 12, Pal.Fg3, false);
        tx.Children.Add(version); tx.Children.Add(newVersion);
        Grid.SetColumn(tx, 1);
        me.Children.Add(logo); me.Children.Add(tx);
        Grid.SetRow(me, 1);
        side.Children.Add(me);
        return side;
    }

    static StackPanel Page() { return new StackPanel { Margin = new Thickness(36, 32, 36, 32) }; }

    static Grid Header(string title, params UIElement[] buttons)
    {
        Grid g = new Grid();
        g.Children.Add(Pal.Title(title, 26));
        StackPanel row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        foreach (UIElement b in buttons) { ((FrameworkElement)b).Margin = new Thickness(8, 0, 0, 0); row.Children.Add(b); }
        g.Children.Add(row);
        return g;
    }

    static TextBlock Lede(string text) { TextBlock t = Pal.Text(text, 14, Pal.Fg2, false); t.LineHeight = 22; t.Margin = new Thickness(0, 8, 0, 28); return t; }

    static Border Divider() { return new Border { Height = 1, Background = Pal.B(Pal.Line), Margin = new Thickness(18, 0, 18, 0) }; }

    static TextBlock Heading(string text) { TextBlock t = Pal.Text(text.ToUpperInvariant(), 11, Pal.Fg3, true); t.Margin = new Thickness(2, 32, 0, 12); return t; }

    static Border IconTile(string icon, bool danger)
    {
        return new Border
        {
            Width = 32, Height = 32, CornerRadius = new CornerRadius(8), VerticalAlignment = VerticalAlignment.Center,
            Background = Pal.B(danger ? "#14EB5757" : "#0AFFFFFF"), BorderBrush = danger ? (Brush)Pal.B("#33EB5757") : Pal.Edge(), BorderThickness = new Thickness(1),
            Child = Pal.Icon(icon, danger ? Pal.Bad : Pal.Fg2, 16)
        };
    }

    /// A card row: icon tile, title with a line of explanation, and a control on the right.
    static Grid Row(string icon, bool danger, string title, string text, FrameworkElement control)
    {
        Grid g = new Grid { Margin = new Thickness(18, 16, 18, 16) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Border tile = IconTile(icon, danger);
        tile.Margin = new Thickness(0, 0, 14, 0);
        StackPanel s = new StackPanel { Margin = new Thickness(0, 0, 20, 0), VerticalAlignment = VerticalAlignment.Center };
        TextBlock t = Pal.Text(title, 13.5, Pal.Fg, false); t.FontWeight = FontWeights.Medium;
        TextBlock d = Pal.Text(text, 13, Pal.Fg2, false); d.Margin = new Thickness(0, 3, 0, 0); d.LineHeight = 19;
        s.Children.Add(t); s.Children.Add(d);
        Grid.SetColumn(s, 1);
        control.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 2);
        g.Children.Add(tile); g.Children.Add(s); g.Children.Add(control);
        return g;
    }

    static Card Stat(string label, Counter value)
    {
        StackPanel s = new StackPanel { Margin = new Thickness(22, 18, 22, 18) };
        s.Children.Add(Pal.Text(label.ToUpperInvariant(), 11, Pal.Fg3, true));
        value.Margin = new Thickness(0, 6, 0, 0);
        s.Children.Add(value);
        return new Card(s);
    }

    /// The status card: a glow and a dot grid behind one big line of what's going on, and a map of sim, PC and iPad
    /// that lights up as each one connects.
    Grid Hero()
    {
        Grid hero = new Grid();
        hero.Children.Add(new Border { CornerRadius = new CornerRadius(16), Background = Pal.B("#0C0D10"), BorderBrush = Pal.Edge(), BorderThickness = new Thickness(1) });

        Grid art = new Grid { Margin = new Thickness(1), IsHitTestVisible = false };
        art.SizeChanged += delegate (object o, SizeChangedEventArgs e) { art.Clip = new RectangleGeometry(new Rect(e.NewSize), 15, 15); };
        heroGlow = new GradientStop(Pal.C(Pal.A("40")), 0);
        glowLayer = new Border
        {
            Background = new RadialGradientBrush(new GradientStopCollection { heroGlow, new GradientStop(Pal.C(Pal.A("00")), 1) }) { Center = new Point(0.5, 0), GradientOrigin = new Point(0.5, 0), RadiusX = 0.6, RadiusY = 0.9 },
            RenderTransform = glowScale, RenderTransformOrigin = new Point(0.5, 0)
        };
        if (Look.Effects) Pal.Run(glowLayer, OpacityProperty, Pal.Loop(1, 0.65, 4200, true, 30));   // breathing
        art.Children.Add(glowLayer);
        art.Children.Add(new Shapes.Rectangle
        {
            Fill = new DrawingBrush(new GeometryDrawing(Pal.B("#24FFFFFF"), null, new EllipseGeometry(new Point(1, 1), 0.8, 0.8)))
            {
                TileMode = TileMode.Tile, Stretch = Stretch.None,
                Viewbox = new Rect(0, 0, 20, 20), ViewboxUnits = BrushMappingMode.Absolute,
                Viewport = new Rect(0, 0, 20, 20), ViewportUnits = BrushMappingMode.Absolute
            },
            OpacityMask = new RadialGradientBrush(Colors.Black, Colors.Transparent) { Center = new Point(0.5, 0.2), GradientOrigin = new Point(0.5, 0.2), RadiusX = 0.55, RadiusY = 0.8 }
        });
        if (Look.Effects) hero.Children.Add(art);

        StackPanel s = new StackPanel { Margin = new Thickness(32, 52, 32, 34) };
        headline = Pal.Title("Starting", 32);
        headline.HorizontalAlignment = HorizontalAlignment.Center;
        headline.TextAlignment = TextAlignment.Center;
        lede = Pal.Text("Starting the bridge...", 14.5, Pal.Fg2, false);
        lede.HorizontalAlignment = HorizontalAlignment.Center;
        lede.TextAlignment = TextAlignment.Center;
        lede.MaxWidth = 520;
        lede.Margin = new Thickness(0, 10, 0, 0);
        s.Children.Add(headline); s.Children.Add(lede);

        Grid map = new Grid { Margin = new Thickness(0, 44, 0, 0), MaxWidth = 680 };
        foreach (double w in new double[] { 150, 0, 150, 0, 150 })
            map.ColumnDefinitions.Add(new ColumnDefinition { Width = w > 0 ? new GridLength(w) : new GridLength(1, GridUnitType.Star) });
        nSim = new Node("MSFS 2024", Icons.Plane); nPc = new Node("This PC", Icons.Pc); nIpad = new Node("iPad", Icons.Ipad);
        lSim = new Link(); lIpad = new Link();
        StackPanel panelChip = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 6, 0, 0) };
        dLink = new Dot();
        tLink = Pal.Text("Chart panel", 12, Pal.Fg3, false);
        panelChip.Children.Add(dLink); panelChip.Children.Add(tLink);
        nSim.Children.Add(panelChip);
        UIElement[] parts = { nSim, lSim, nPc, lIpad, nIpad };
        for (int i = 0; i < parts.Length; i++) { Grid.SetColumn(parts[i], i); map.Children.Add(parts[i]); }
        s.Children.Add(map);
        nPc.Set(false, "Starting"); nSim.Set(false, "Waiting"); nIpad.Set(false, "Waiting");
        hero.Children.Add(s);

        Btn log = new Btn("Open log", "ghost"); log.Click += delegate { ShowPage(2); };
        install = new Btn("Install update", "primary"); install.Visibility = Visibility.Collapsed; install.Click += InstallUpdate;
        restart = new Btn("Restart bridge", "ghost"); restart.Visibility = Visibility.Collapsed; restart.Click += delegate { if (host != null) host.RestartBridge(); };
        StackPanel buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 16, 16, 0) };
        foreach (Btn b in new[] { restart, log, install }) { b.Margin = new Thickness(8, 0, 0, 0); buttons.Children.Add(b); }
        hero.Children.Add(buttons);
        return hero;
    }

    FrameworkElement StatusPage()
    {
        StackPanel p = Page();
        p.Children.Add(Hero());

        StackPanel reach = new StackPanel { Orientation = Orientation.Horizontal };
        Border code = new Border { Background = Pal.B("#0A0B0D"), BorderBrush = Pal.B(Pal.Line2), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Padding = new Thickness(12, 6, 12, 6), Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        addr = Pal.Text("", 13.5, Pal.Fg, false); addr.FontFamily = Pal.Mono; addr.TextWrapping = TextWrapping.NoWrap;
        code.Child = addr;
        reach.Children.Add(code);
        eyeOpen = Pal.Icon(Icons.Eye, Pal.Fg2, 16);
        eyeShut = Pal.Icon(Icons.EyeShut, Pal.Fg2, 16);
        eyeOpen.Opacity = ipHidden ? 0 : 1;
        eyeShut.Opacity = ipHidden ? 1 : 0;
        Grid eyeIcon = new Grid { Width = 16, Height = 16 }; eyeIcon.Children.Add(eyeOpen); eyeIcon.Children.Add(eyeShut);
        Btn eye = new Btn("", "icon"); eye.Padding = new Thickness(8); eye.SetContent(eyeIcon); eye.ToolTip = "Hide or show the address";
        eye.Click += delegate
        {
            ipHidden = !ipHidden;
            Look.HideAddress = ipHidden;
            Look.Save("HideAddress", ipHidden ? "On" : "Off");
            Pal.Fade(eyeOpen, ipHidden ? 0 : 1, 160); Pal.Fade(eyeShut, ipHidden ? 1 : 0, 160);
            RenderAddress();
        };
        reach.Children.Add(eye);

        Card card = new Card(Row(Icons.Wifi, false, "iPad doesn't find this PC?", "Type this address into SimPilot under Settings > Bridge.", reach)) { Margin = new Thickness(0, 16, 0, 0) };
        p.Children.Add(card);
        StackPanel pairing = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        pairingCodeText = Pal.Text("Waiting for bridge…", 12.5, Pal.Fg, false); pairingCodeText.FontFamily = Pal.Mono; pairingCodeText.TextWrapping = TextWrapping.Wrap; pairingCodeText.MaxWidth = 480;
        pairing.Children.Add(pairingCodeText);
        Btn copyPairingCode = new Btn("Copy code", "ghost"); copyPairingCode.Margin = new Thickness(12, 0, 0, 0);
        copyPairingCode.Click += delegate { try { Clipboard.SetText(pairingCodeText.Text); Toast("Pairing code copied."); } catch (Exception) { Toast("Couldn't reach the clipboard."); } };
        pairing.Children.Add(copyPairingCode);
        p.Children.Add(new Card(Row(Icons.Ipad, false, "Pair your iPad", "Enter this code in SimPilot under Settings > Bridge.", pairing)) { Margin = new Thickness(0, 12, 0, 0) });
        return Scroll(p);
    }

    FrameworkElement ChartsPage()
    {
        StackPanel p = Page();
        p.Children.Add(Header("Charts", ActionButton("open-cache", "Open cache folder", "ghost", false), WizardButton("Install chart panel", "primary")));
        p.Children.Add(Lede("Charts the chart panel exported from the sim. The iPad asks for them when you open an airport."));
        Grid stats = new Grid { Margin = new Thickness(0, 0, 0, 16) };
        stats.ColumnDefinitions.Add(new ColumnDefinition());
        stats.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        stats.ColumnDefinitions.Add(new ColumnDefinition());
        statAirports = new Counter(delegate (long v) { return v.ToString(CultureInfo.InvariantCulture); });
        statBytes = new Counter(Bytes);
        Card a = Stat("Airports", statAirports), b = Stat("On disk", statBytes);
        Grid.SetColumn(b, 2);
        stats.Children.Add(a); stats.Children.Add(b);
        p.Children.Add(stats);
        airports = new StackPanel();
        p.Children.Add(new Card(airports));
        return Scroll(p);
    }

    FrameworkElement LogPage()
    {
        StackPanel p = Page();
        Btn copy = new Btn("Copy", "ghost");
        copy.Click += delegate
        {
            try { Clipboard.SetText(lastLog.Length == 0 ? " " : lastLog); Toast("Log copied."); } catch (Exception) { Toast("Couldn't reach the clipboard."); }
        };
        p.Children.Add(Header("Log", copy));
        p.Children.Add(Lede("What the bridge has been doing. Attach this when reporting a problem."));
        logText = new TextBlock { FontFamily = Pal.Mono, FontSize = 12.5, Foreground = Pal.B(Pal.Fg2), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(20, 16, 20, 16), LineHeight = 22 };
        logScroll = new ScrollViewer { Content = logText, Height = 420, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        p.Children.Add(new Card(logScroll) { Background = Pal.B("#0A0B0D") });
        return Scroll(p);
    }

    FrameworkElement RepairPage()
    {
        StackPanel p = Page();
        p.Children.Add(Header("Repair"));
        p.Children.Add(Lede("Fix common problems. None of these touch your flights or the iPad app."));
        StackPanel fix = new StackPanel();
        fix.Children.Add(Row(Icons.Shield, false, "Allow through Windows Firewall", "Adds the rule for private networks if the iPad can't connect. Windows asks for admin approval.", ActionButton("firewall", "Fix firewall", "ghost", false)));
        fix.Children.Add(Divider());
        fix.Children.Add(Row(Icons.Chart, false, "Install or repair chart panel", "Guides you through installing SimPilot Link in MSFS 2024, or puts its files back if it stopped working.", WizardButton("Open", "ghost")));
        fix.Children.Add(Divider());
        fix.Children.Add(Row(Icons.Trash, false, "Clear chart cache", "Deletes exported charts. They export again when needed.", ActionButton("clear-cache", "Clear cache", "ghost", false)));
        p.Children.Add(new Card(fix));
        p.Children.Add(Heading("Uninstall"));
        p.Children.Add(new Card(Row(Icons.Exit, true, "Uninstall SimPilot Bridge", "Removes autostart, the firewall rule and cached charts, then closes. Delete the SimPilot for PC folder to finish. Remove the chart panel by deleting simpilot-link from the sim's Community folder.", ActionButton("uninstall", "Uninstall", "danger", true)))
            { Background = Pal.B("#08EB5757"), BorderBrush = Pal.B("#2EEB5757") });
        return Scroll(p);
    }

    FrameworkElement SettingsView()
    {
        StackPanel p = Page();
        p.Children.Add(Header("Settings"));
        p.Children.Add(Lede("Make SimPilot Bridge look the way you like. Changes apply straight away."));
        StackPanel look = new StackPanel();
        look.Children.Add(Row(Icons.Palette, false, "Accent colour", "Buttons, highlights and the glow on the Status page.", new Swatches(Look.Accent, delegate (string a) { Apply("Accent", a); })));
        look.Children.Add(Divider());
        look.Children.Add(Row(Icons.Wave, false, "Animation", "Calm keeps the transitions but stops the background animations, which also saves a little CPU. Off stops all motion.", new Segmented(Look.Motions, Look.Motion, delegate (string m) { Apply("Motion", m); })));
        look.Children.Add(Divider());
        Switch effects = new Switch();
        effects.Set(Look.Effects, false);
        effects.Changed += delegate { Apply("Effects", effects.On ? "On" : "Off"); };
        look.Children.Add(Row(Icons.Sparkle, false, "Glow and light", "The glow behind the Status page and the light that follows the mouse over cards.", effects));
        p.Children.Add(new Card(look));
        p.Children.Add(Heading("General"));
        autostart = new Switch();
        autostart.Changed += delegate
        {
            if (host == null) { Toast("Preview: nothing was changed."); return; }
            if (Local.SetAutostart(autostart.On)) Toast(autostart.On ? "SimPilot Bridge will start with Windows, hidden in the tray." : "Start with Windows is off.");
            else { autostart.Set(!autostart.On, true); Toast("Couldn't change Start with Windows."); }
        };

        p.Children.Add(new Card(Row(Icons.Power, false, "Start with Windows", "Starts hidden in the tray when you sign in.", autostart)));
        return Scroll(p);
    }

    /// Saves a Settings choice and, once the control has finished its own little animation, rebuilds the window in the new look.
    void Apply(string name, string value)
    {
        Look.Save(name, value);
        if (name == "Accent") { Look.Accent = value; Pal.Accent(value); }
        if (name == "Motion") Look.Motion = value;
        if (name == "Effects") Look.Effects = value == "On";
        DispatcherTimer later = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(Pal.Motion ? 280 : 0) };
        later.Tick += delegate { later.Stop(); Restyle(); };
        later.Start();
    }

    FrameworkElement HelpPage()
    {
        StackPanel p = Page();
        p.Children.Add(Header("Help"));
        p.Children.Add(Lede("Answers to the questions people ask most."));
        string[][] faq = {
            new[] { "The iPad doesn't find the PC", "Check both are on the same Wi-Fi, not a guest network. On the iPad: Settings > Privacy > Local Network > SimPilot EFB on. Otherwise type the address from the Status page into the app under Settings > Bridge." },
            new[] { "Windows Firewall asked something", "Tick \"Private networks\" and click Allow. Windows may call it \"Node.js JavaScript Runtime\"; that is SimPilot Bridge. Missed it? Use Repair > Fix firewall." },
            new[] { "MSFS says waiting", "Start MSFS 2024 and load into a flight. The bridge connects by itself; no setting is needed." },
            new[] { "Do I need the chart panel?", "No. Weather, SimBrief and VATSIM work without it. The panel only sends the sim's own charts to the iPad." },
            new[] { "Charts stay on exporting", "Keep the SimPilot Link panel open in the sim's toolbar and the sim window visible. Exports retry up to three times." },
            new[] { "Does it slow down the sim?", "Barely. It reads position 10 times a second over SimConnect and does nothing else unless the iPad asks." },
            new[] { "How do I update?", "Click Install update when it appears. The bridge downloads the new version and restarts by itself." } };
        StackPanel list = new StackPanel();
        for (int i = 0; i < faq.Length; i++)
        {
            if (i > 0) list.Children.Add(Divider());
            list.Children.Add(new Faq(faq[i][0], faq[i][1]));
        }
        p.Children.Add(new Card(list));
        return Scroll(p);
    }

    static ScrollViewer Scroll(UIElement e) { return new ScrollViewer { Content = e, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false }; }

    UIElement Toaster()
    {
        toastText = Pal.Text("", 13, Pal.Fg, false);
        Border pill = new Border { Background = Pal.B("#F21A1B1F"), BorderBrush = Pal.Edge(), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(20), Padding = new Thickness(16, 9, 18, 9) };
        StackPanel row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(new Border { Width = 6, Height = 6, CornerRadius = new CornerRadius(3), Background = Pal.B(Pal.Blue), Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center, Effect = new DropShadowEffect { Color = Pal.C(Pal.Blue), BlurRadius = 8, ShadowDepth = 0 } });
        toastText.MaxWidth = 560;
        row.Children.Add(toastText);
        pill.Child = row;
        toastHost = Pal.Lift(pill, 32, 10, 0.6);
        toastHost.HorizontalAlignment = HorizontalAlignment.Center;
        toastHost.VerticalAlignment = VerticalAlignment.Bottom;
        toastHost.Margin = new Thickness(24, 0, 24, 22);
        toastHost.RenderTransform = toastMove;
        toastHost.Opacity = 0;
        toastHost.IsHitTestVisible = false;
        return toastHost;
    }

    void AddPage(FrameworkElement page)
    {
        page.Visibility = Visibility.Collapsed;
        pageList.Add(page);
        pages.Children.Add(page);
    }

    public void ShowPage(int index)
    {
        if (index == current) return;
        bool first = current < 0;
        for (int i = 0; i < pageList.Count; i++)
        {
            navItems[i].Select(i == index);
            pageList[i].Visibility = i == index ? Visibility.Visible : Visibility.Collapsed;
        }
        Pal.To(indicatorMove, TranslateTransform.YProperty, index * NavStep, first ? 0 : 560, new Spring(0.72));   // the selection glides
        current = index;
        Enter(index, 0);
        HideToast();
        if (host != null) Refresh();
    }

    /// Fades an element in while it slides into place, after a delay.
    static void Rise(UIElement e, int delay, double from, bool sideways)
    {
        TranslateTransform move = e.RenderTransform as TranslateTransform;
        if (move == null) { move = new TranslateTransform(); e.RenderTransform = move; }
        DependencyProperty axis = sideways ? TranslateTransform.XProperty : TranslateTransform.YProperty;
        TimeSpan d = TimeSpan.FromMilliseconds(Pal.Motion ? delay : 0);
        e.BeginAnimation(UIElement.OpacityProperty, null); e.Opacity = 0;   // hidden until its turn
        move.BeginAnimation(axis, null);
        e.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, Pal.Ms(340)) { BeginTime = d, EasingFunction = Pal.Out() });
        move.BeginAnimation(axis, new DoubleAnimation(from, 0, Pal.Ms(700)) { BeginTime = d, EasingFunction = new Spring(0.8) });
    }

    /// Builds a page in: its blocks rise one after another; the status card then blooms its glow, pops its tiles and draws its lines.
    void Enter(int index, int delay)
    {
        ScrollViewer sv = pageList[index] as ScrollViewer;
        if (sv == null) return;
        sv.ScrollToTop();
        Panel blocks = sv.Content as Panel;
        if (blocks == null) return;
        for (int i = 0; i < blocks.Children.Count; i++) Rise(blocks.Children[i], delay + 55 * Math.Min(i, 6), 20, false);
        if (index == 1) { statAirports.Replay(); statBytes.Replay(); }
        if (index != 0 || !Pal.Motion) return;
        Pal.From(glowScale, ScaleTransform.ScaleXProperty, 0.3, 1, 1600, new QuarticEase { EasingMode = EasingMode.EaseOut });
        Pal.From(glowScale, ScaleTransform.ScaleYProperty, 0.3, 1, 1600, new QuarticEase { EasingMode = EasingMode.EaseOut });
        nSim.Intro(delay + 220); lSim.Intro(delay + 360); nPc.Intro(delay + 340); lIpad.Intro(delay + 480); nIpad.Intro(delay + 460);
    }

    /// Blurs and settles everything behind the chart panel wizard.
    public void Dim(bool on)
    {
        dimmed = on;
        if (on) shell.Effect = blur;
        DoubleAnimation a = new DoubleAnimation(on ? 16 : 0, Pal.Ms(on ? 320 : 200)) { EasingFunction = Pal.Out() };
        a.Completed += delegate { if (!dimmed) shell.Effect = null; };   // an effect left on, even at 0, turns off ClearType
        blur.BeginAnimation(BlurEffect.RadiusProperty, a);
    }

    // ---- actions ----

    Btn WizardButton(string label, string kind)
    {
        Btn b = new Btn(label, kind);
        b.Click += delegate { OpenWizard(); };
        return b;
    }

    public void OpenWizard() { wizard.Open(); }

    void UpdateAddresses()
    {
        List<string> list = Local.Addresses();
        string first = list.Count > 0 ? list[0] : "";
        if (first == firstAddress) return;
        firstAddress = first;
        RenderAddress();
    }

    Btn ActionButton(string id, string label, string kind, bool confirm)
    {
        Btn b = new Btn(label, kind);
        DispatcherTimer disarm = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
        bool armed = false;
        disarm.Tick += delegate { disarm.Stop(); armed = false; b.Text = label; };
        b.Click += delegate
        {
            if (confirm && !armed) { armed = true; b.Text = "Click again to confirm"; disarm.Start(); return; }
            disarm.Stop(); armed = false; b.Text = label;
            Act(id, b, id == "uninstall", null);
        };
        actions[id] = b;
        return b;
    }

    void Act(string id, Btn button, bool quitsAfter, Action<bool> done)
    {
        if (host == null) { Toast("Preview: nothing was changed."); return; }
        if (button != null) button.IsEnabled = false;
        if (quitsAfter) host.DeferQuit = true;
        Toast("Working...");
        ThreadPool.QueueUserWorkItem(delegate
        {
            string message; bool ok = true;
            try { message = Json.Str(Net.Obj("POST", "/bridge/manage/" + id, 180000), "message") ?? "Done."; }
            catch (Exception ex) { message = ex.Message; ok = false; }
            Dispatcher.BeginInvoke(new Action(delegate
            {
                if (button != null) button.IsEnabled = true;
                Toast(message);
                if (done != null) done(ok);
                if (quitsAfter)
                {
                    if (ok) { MessageBox.Show(this, message, "SimPilot Bridge", MessageBoxButton.OK, MessageBoxImage.Information); host.Quit(); }
                    else host.DeferQuit = false;
                }
                Refresh();
            }));
        });
    }

    public void Toast(string text)
    {
        toastText.Text = text;
        Pal.Fade(toastHost, 1, 180);
        Pal.To(toastMove, TranslateTransform.YProperty, 0, 520, new Spring(0.7));
        toastTimer.Stop(); toastTimer.Start();
    }

    void HideToast()
    {
        Pal.Fade(toastHost, 0, 220);
        Pal.To(toastMove, TranslateTransform.YProperty, 16, 260, Pal.Out());
    }

    void InstallUpdate()
    {
        if (updateBusy) return;
        updateBusy = true; install.IsEnabled = false;
        Toast("Downloading the update...");
        ThreadPool.QueueUserWorkItem(delegate
        {
            string error = null;
            try { Net.Call("POST", "/bridge/update", 330000); } catch (Exception ex) { error = ex.Message; }
            Dispatcher.BeginInvoke(new Action(delegate
            {
                updateBusy = false; install.IsEnabled = true;
                if (error == null) Toast("Installing. SimPilot Bridge closes and opens again by itself in a few seconds.");
                else Toast("Update failed: " + error);
            }));
        });
    }

    void CheckUpdate()
    {
        ThreadPool.QueueUserWorkItem(delegate
        {
            object u = null;
            try { u = Net.Obj("GET", "/bridge/update", 25000); } catch (Exception) { }
            if (u == null) return;
            Dispatcher.BeginInvoke(new Action(delegate
            {
                bool available = Json.Bool(u, "available"), can = Json.Bool(u, "canInstall");
                newVersion.Text = available ? Json.Str(u, "latest") + " available" : "Up to date";
                ((SolidColorBrush)newVersion.Foreground).Color = Pal.C(available ? Pal.Warn : Pal.Fg3);
                bool show = available && can;
                if (show && install.Visibility != Visibility.Visible) Pal.Reveal(install);
                if (!show) install.Visibility = Visibility.Collapsed;
            }));
        });
    }

    // ---- live data ----

    void Refresh()
    {
        if (host == null || polling) return;
        polling = true;
        tick++;
        bool wantInfo = (current == 0 || current == 1) && !infoLoading && (current == 1 || tick % 3 == 1);
        bool wantLog = current == 2 && !logLoading;
        if (wantInfo) infoLoading = true;
        if (wantLog) logLoading = true;
        ThreadPool.QueueUserWorkItem(delegate
        {
            object status = null, info = null, log = null;
            try { status = Net.Obj("GET", "/api/status", 1500); } catch (Exception) { }
            if (status != null && (wantInfo || wantLog)) { try { info = Net.Obj("GET", "/bridge/info", 4000); } catch (Exception) { } }
            string pairingKey = Json.Str(info, "pairingKey");
            if (status != null && wantLog) { try { log = Net.Obj("GET", "/api/diagnostics", 3000, pairingKey); } catch (Exception) { } }
            Dispatcher.BeginInvoke(new Action(delegate
            {
                polling = false; infoLoading = false; logLoading = false;
                if (tick % 3 == 1) UpdateAddresses();
                bool ours = host.BridgeRunning;
                if (status == null)
                {
                    misses++;
                    if (!ours || misses >= 10) ShowStopped(host.LastError);
                    if (current == 2) ApplyOutput();
                    return;
                }
                misses = 0;
                if (!ours)
                {
                    // Something answers on the port, but not the bridge this program started.
                    ShowStopped("Another SimPilot Bridge is already running on this PC, probably an older copy in a different folder. Close it (look for its window or tray icon), then press Restart bridge.");
                    if (current == 2) ApplyOutput();
                    return;
                }
                ApplyStatus(status);
                if (info != null) ApplyInfo(info);
                if (log != null) ApplyLog(log);
            }));
        });
    }

    void Chip(bool ok, string text)
    {
        connDot.Set(ok, false);
        Pal.Swap(connText, text);
        Pal.Tint(chipFill, ok ? "#144CC38A" : "#1FEB5757", 300);
        Pal.Tint((SolidColorBrush)connText.Foreground, ok ? Pal.Fg : "#FF8A8A", 300);
    }

    public void ShowStopped(string why)
    {
        Chip(false, "Stopped");
        nPc.Set(false, "Stopped"); nSim.Set(false, "Unavailable"); nIpad.Set(false, "Unavailable");
        lSim.Set(false); lIpad.Set(false);
        dLink.Set(false, false); Pal.Swap(tLink, "Chart panel unavailable");
        Pal.Swap(headline, "The bridge stopped");
        Pal.Swap(lede, string.IsNullOrEmpty(why) ? "Press Restart bridge. The Log page shows what it printed." : why);
        Pal.Tint(heroGlow, "#40EB5757", 700);
        if (restart.Visibility != Visibility.Visible) Pal.Reveal(restart);
    }

    public void ApplyStatus(object s)
    {
        bool sim = Json.Bool(s, "sim", "connected"), link = Json.Bool(s, "link", "connected");
        int apps = Json.Int(s, "bridge", "apps");
        string title = Json.Str(s, "sim", "aircraftTitle");
        restart.Visibility = Visibility.Collapsed;
        Chip(true, "Running");
        version.Text = "Version " + (Json.Str(s, "bridge", "version") ?? "");
        nPc.Set(true, "Bridge running");
        nSim.Set(sim, sim ? (string.IsNullOrEmpty(title) ? "Connected" : title) : "Waiting for the sim");
        nIpad.Set(apps > 0, apps > 1 ? apps + " devices connected" : apps > 0 ? "Connected" : "Waiting for the app");
        lSim.Set(sim); lIpad.Set(apps > 0);
        dLink.Set(link, false);
        Pal.Swap(tLink, link ? "Chart panel connected" : "Chart panel off (optional)");
        string head, text;
        if (apps > 0 && sim) { head = "Everything is connected"; text = "Leave this running while you fly."; }
        else if (apps > 0) { head = "Waiting for MSFS 2024"; text = "Start the sim and load into a flight. The bridge connects by itself."; }
        else if (sim) { head = "Waiting for your iPad"; text = "Open SimPilot on the iPad, on the same Wi-Fi as this PC."; }
        else { head = "Ready"; text = "Open SimPilot on your iPad and start MSFS 2024."; }
        Pal.Swap(headline, head);
        Pal.Swap(lede, text);
        Pal.Tint(heroGlow, apps > 0 && sim ? Pal.A("66") : Pal.A("38"), 700);
    }

    static string Bytes(long bytes)
    {
        return bytes < 1048576 ? Math.Max(1, bytes / 1024) + " KB" : (bytes / 1048576) + " MB";
    }

    public void ApplyInfo(object info)
    {
        if (pairingCodeText != null) pairingCodeText.Text = Json.Str(info, "pairingCode") ?? "";
        airports.Children.Clear();
        int count = 0;
        foreach (object a in Json.List(info, "cache", "airports"))
        {
            if (count++ > 0) airports.Children.Add(Divider());
            Grid g = new Grid { Margin = new Thickness(18, 14, 20, 14) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition());
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            TextBlock icao = Pal.Text(Json.Str(a, "icao") ?? "", 13, Pal.Fg, true);
            icao.FontFamily = Pal.Mono;
            Border badge = new Border { Background = Pal.B("#0DFFFFFF"), BorderBrush = Pal.Edge(), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(7), Padding = new Thickness(9, 4, 9, 4), Margin = new Thickness(0, 0, 14, 0), Child = icao };
            TextBlock charts = Pal.Text(Json.Int(a, "charts") + " charts", 14, Pal.Fg, false);
            charts.FontWeight = FontWeights.Medium;
            Grid.SetColumn(charts, 1);
            TextBlock size = Pal.Text(Bytes(Json.Long(a, "bytes")), 12.5, Pal.Fg3, false); size.FontFamily = Pal.Mono;
            Grid.SetColumn(size, 2);
            g.Children.Add(badge); g.Children.Add(charts); g.Children.Add(size);
            airports.Children.Add(g);
        }
        if (count == 0)
        {
            StackPanel empty = new StackPanel { Margin = new Thickness(24, 30, 24, 30), HorizontalAlignment = HorizontalAlignment.Center };
            Border tile = IconTile(Icons.Chart, false);
            tile.Margin = new Thickness(0, 0, 0, 12);
            TextBlock t = Pal.Text("No charts yet. Open an airport in the iPad app with the chart panel running.", 13.5, Pal.Fg2, false);
            t.TextAlignment = TextAlignment.Center;
            empty.Children.Add(tile); empty.Children.Add(t);
            airports.Children.Add(empty);
        }
        statAirports.Set(count);
        statBytes.Set(Json.Long(info, "cache", "bytes"));
    }

    void RenderAddress()
    {
        string a = firstAddress.Length == 0 ? "no network found" : firstAddress;
        string shown = ipHidden ? MaskDigits(a) : a;
        addr.Text = shown;
        topIp.Text = firstAddress.Length == 0 ? "" : (ipHidden ? MaskDigits(firstAddress) : firstAddress).Split(':')[0];
    }

    static string MaskDigits(string s)
    {
        StringBuilder b = new StringBuilder();
        foreach (char c in s) b.Append(char.IsDigit(c) ? '•' : c);
        return b.ToString();
    }

    void ApplyOutput()
    {
        string text = "The bridge isn't answering. This is what it printed:\n\n" + host.Output();
        if (text == lastLog) return;
        lastLog = text;
        logText.Text = text;
        logScroll.ScrollToEnd();
    }

    public void ApplyLog(object log)
    {
        StringBuilder sb = new StringBuilder();
        List<Run> runs = new List<Run>();
        foreach (object e in Json.List(log, "entries"))
        {
            DateTime when;
            string time = Json.Str(e, "time") ?? "";
            string shown = DateTime.TryParse(time, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out when) ? when.ToLocalTime().ToString("HH:mm:ss") : time;
            string level = Json.Str(e, "level");
            string mark = level == "warn" ? "! " : level == "error" ? "!! " : "";
            string scope = "[" + Json.Str(e, "scope") + "] ", message = mark + Json.Str(e, "message");
            sb.Append(shown).Append("  ").Append(scope).Append(message).Append('\n');
            if (runs.Count > 0) runs.Add(new Run("\n"));
            runs.Add(new Run(shown + "  ") { Foreground = Pal.B(Pal.Fg3) });
            runs.Add(new Run(scope) { Foreground = Pal.B(Pal.BlueHi) });
            runs.Add(new Run(message) { Foreground = Pal.B(level == "error" ? Pal.Bad : level == "warn" ? Pal.Warn : Pal.Fg2) });
        }
        string text = sb.ToString().TrimEnd('\n');
        if (text == lastLog) return;
        lastLog = text;
        bool stick = logScroll.VerticalOffset >= logScroll.ScrollableHeight - 8;
        logText.Inlines.Clear();
        logText.Inlines.AddRange(runs);
        if (stick) logScroll.ScrollToEnd();
    }
}

class TrayApp
{
    readonly string dir = AppDomain.CurrentDomain.BaseDirectory;
    readonly bool startHidden;
    readonly EventWaitHandle showEvent;
    readonly Forms.NotifyIcon tray;
    readonly Forms.ToolStripMenuItem restartItem;
    MainWindow window;
    Process node;
    bool quitting, balloonShown;
    public bool DeferQuit;
    public string LastError;
    readonly List<string> output = new List<string>();

    /// True while the node.exe this program started is alive.
    public bool BridgeRunning { get { try { return node != null && !node.HasExited; } catch (Exception) { return false; } } }

    public string Output() { lock (output) return output.Count == 0 ? "(nothing yet)" : string.Join("\n", output.ToArray()); }

    void Capture(string line, bool error)
    {
        if (line == null) return;
        lock (output)
        {
            output.Add(line);
            if (output.Count > 300) output.RemoveAt(0);
        }
        string t = line.Trim();
        // Bridge log lines look like "12:00:01.234 ERROR [http] message"; warnings and stack frames are not the reason it stopped.
        bool logLine = Regex.IsMatch(t, "^\\d\\d:\\d\\d:\\d\\d");
        if (!error || t.Length == 0 || t.StartsWith("at ") || (logLine && !t.Contains(" ERROR "))) return;
        int cut = t.IndexOf("] ");
        LastError = logLine && cut > 0 ? t.Substring(cut + 2) : t;
    }

    public TrayApp(bool minimized, EventWaitHandle showEvent)
    {
        startHidden = minimized;
        this.showEvent = showEvent;
        Drawing.Icon icon = null;
        try { icon = Drawing.Icon.ExtractAssociatedIcon(System.Windows.Forms.Application.ExecutablePath); } catch (Exception) { }
        Forms.ContextMenuStrip menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open SimPilot Bridge", null, delegate { ShowWindow(); });
        restartItem = new Forms.ToolStripMenuItem("Restart bridge", null, delegate { RestartBridge(); });
        restartItem.Visible = false;
        menu.Items.Add(restartItem);
        menu.Items.Add("Quit", null, delegate { Quit(); });
        tray = new Forms.NotifyIcon();
        tray.Text = "SimPilot Bridge";
        tray.Icon = icon ?? Drawing.SystemIcons.Application;
        tray.ContextMenuStrip = menu;
        tray.Visible = true;
        tray.DoubleClick += delegate { ShowWindow(); };
    }

    public void Begin()
    {
        StartBridge();
        Thread listener = new Thread(delegate ()
        {
            while (!quitting)
            {
                showEvent.WaitOne();
                if (quitting) break;
                Application.Current.Dispatcher.BeginInvoke(new Action(ShowWindow));
            }
        });
        listener.IsBackground = true;
        listener.Start();
        if (!startHidden) ShowWindow();
    }

    void ShowWindow()
    {
        if (quitting) return;
        if (window == null)
        {
            window = new MainWindow(this);
            // Starting up touches a lot of memory once (fonts, layout, first frames); hand it back after the entrance.
            DispatcherTimer settle = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
            settle.Tick += delegate { settle.Stop(); Trim(); };
            settle.Start();
        }
        window.Show();
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
    }

    public void WindowClosed()
    {
        window = null;
        if (quitting) return;
        WindowHidden();
        Application.Current.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(Trim));
    }

    [DllImport("kernel32.dll")] static extern bool SetProcessWorkingSetSize(IntPtr process, IntPtr min, IntPtr max);

    /// Collects what the window left behind and lets Windows page out what the process isn't using.
    static void Trim()
    {
        GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
        try { SetProcessWorkingSetSize(Process.GetCurrentProcess().Handle, (IntPtr)(-1), (IntPtr)(-1)); } catch (Exception) { }
    }

    public void WindowHidden()
    {
        if (balloonShown) return;
        balloonShown = true;
        tray.ShowBalloonTip(4000, "SimPilot Bridge is still running", "Right-click the tray icon to quit it.", Forms.ToolTipIcon.Info);
    }

    // ---- bridge process ----

    public void RestartBridge() { StartBridge(); }

    void StartBridge()
    {
        string exe = System.IO.Path.Combine(dir, "node.exe");
        string script = System.IO.Path.Combine(dir, "bridge.cjs");
        if (!File.Exists(exe) || !File.Exists(script))
        {
            MessageBox.Show("node.exe or bridge.cjs is missing next to this program. Extract the whole SimPilot for PC folder and run it from there.", "SimPilot Bridge", MessageBoxButton.OK, MessageBoxImage.Warning);
            Quit();
            return;
        }
        KillStrays(exe);
        restartItem.Visible = false;
        LastError = null;
        lock (output) output.Clear();
        ProcessStartInfo psi = new ProcessStartInfo(exe, "\"" + script + "\"");
        psi.WorkingDirectory = dir;
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        // Redirect all three: with a hidden console as stdin, the bridge would wait forever for Enter after an error.
        psi.RedirectStandardInput = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = Encoding.UTF8;
        psi.StandardErrorEncoding = Encoding.UTF8;
        try
        {
            node = new Process();
            node.StartInfo = psi;
            node.EnableRaisingEvents = true;
            node.Exited += OnNodeExited;
            node.OutputDataReceived += delegate (object o, DataReceivedEventArgs a) { Capture(a.Data, false); };
            node.ErrorDataReceived += delegate (object o, DataReceivedEventArgs a) { Capture(a.Data, true); };
            node.Start();
            node.StandardInput.Close();
            node.BeginOutputReadLine();
            node.BeginErrorReadLine();
        }
        catch (Exception ex) { LastError = "Couldn't start the bridge: " + ex.Message; Stopped(LastError); }
    }

    // A previous launcher that crashed can leave its bridge running and holding the port.
    static void KillStrays(string exe)
    {
        try
        {
            foreach (Process p in Process.GetProcessesByName("node"))
            {
                try { if (string.Equals(p.MainModule.FileName, exe, StringComparison.OrdinalIgnoreCase)) { p.Kill(); p.WaitForExit(3000); } }
                catch (Exception) { }
            }
        }
        catch (Exception) { }
    }

    void OnNodeExited(object sender, EventArgs e)
    {
        int code = 1;
        try { code = node.ExitCode; } catch (Exception) { }
        Application.Current.Dispatcher.BeginInvoke(new Action(delegate
        {
            // Exit code 0 is the bridge shutting itself down for an update or an uninstall.
            if (quitting || DeferQuit) return;
            if (code == 0) { Quit(); return; }
            if (string.IsNullOrEmpty(LastError)) LastError = "SimPilot Bridge stopped (exit code " + code + "). Press Restart bridge.";
            Stopped(LastError);
        }));
    }

    void Stopped(string message)
    {
        restartItem.Visible = true;
        tray.Text = "SimPilot Bridge - stopped";
        tray.ShowBalloonTip(6000, "SimPilot Bridge", message.Length > 250 ? message.Substring(0, 250) : message, Forms.ToolTipIcon.Warning);
    }

    public void Quit()
    {
        if (quitting) return;
        quitting = true;
        try { showEvent.Set(); } catch (Exception) { }
        try { if (node != null && !node.HasExited) node.Kill(); } catch (Exception) { }
        tray.Visible = false;
        tray.Dispose();
        Application.Current.Shutdown();
    }
}
