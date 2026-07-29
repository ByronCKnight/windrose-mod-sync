// WindroseSync - keeps a Windrose client's mod set identical to the server's.
//
// Runs BEFORE the game starts, because UE4SS mods only mount at engine startup -
// anything downloaded mid-session cannot take effect until a restart.
//
// Targets .NET Framework 4.8 (preinstalled on Windows 10/11) so players install
// nothing. Built with the in-box csc.exe, so the language level is C# 5:
// no string interpolation, no null-conditionals, no tuples.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace WindroseSync
{
    internal static class Program
    {
        private const string SteamAppId = "3041230";
        private const string GameExeRel = @"R5\Binaries\Win64\Windrose-Win64-Shipping.exe";
        private const string GameProcName = "Windrose-Win64-Shipping";

        // Where mods have to live depends on which process holds authority:
        //   - connected to a dedicated server -> the server does, nothing needed here
        //   - singleplayer -> the game process itself
        //   - Host Game -> a SEPARATE WindroseServer process under R5\Builds
        // so the launcher installs to two locations on the player's machine.
        private sealed class Target
        {
            public string Name;      // matches "target" in the manifest
            public string Root;      // install root, relative to the game folder
            public bool Required;    // hostserver is absent on some installs
            public string Label;
        }

        private static readonly Target[] Targets =
        {
            new Target { Name = "client",     Required = true,
                         Root = @"R5\Binaries\Win64",
                         Label = "game + singleplayer" },
            new Target { Name = "hostserver", Required = false,
                         Root = @"R5\Builds\WindowsServer\R5\Binaries\Win64",
                         Label = "Host Game server" },
        };

        // Within each target the launcher may only touch <root>\ue4ss\**. Everything
        // else is off limits - notably Content\Paks, ~18 GB of base game data.
        private const string ManagedSubdir = "ue4ss";

        // UE4SS loads whenever this sits next to the executable, so its presence is
        // what decides modded vs vanilla. It ships inert at ue4ss\proxy\dwmapi.dll
        // and is only copied into place for the duration of a launcher-started run.
        private const string ProxyName = "dwmapi.dll";
        private const string ProxyStaged = @"ue4ss\proxy\dwmapi.dll";

        // UE4SS and its mods write runtime artifacts (logs, object dumps, temp files)
        // *inside* the managed folder. Those are not ours to manage: deleting them
        // would fight the runtime and destroy the very logs an admin needs to
        // diagnose a problem. Skipped by the stale-file sweep.
        private static readonly string[] RuntimeSuffixes = { ".log", ".tmp", ".wsync-tmp", ".dmp", ".bak" };
        private static readonly string[] RuntimeDirNames = { "logs", "crashdumps", "objectdumps" };

        private static int _exitCode;

        private static int Main(string[] args)
        {
            Console.Title = "Windrose Mod Sync";
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;

            bool noLaunch = args.Any(a => a.Equals("--no-launch", StringComparison.OrdinalIgnoreCase));
            bool verify = args.Any(a => a.Equals("--verify", StringComparison.OrdinalIgnoreCase));
            // Manual control over the mod gate, for testing and for admins who
            // prefer to start the game themselves. Not advertised to players.
            bool doEnable = args.Any(a => a.Equals("--enable", StringComparison.OrdinalIgnoreCase));
            bool doDisable = args.Any(a => a.Equals("--disable", StringComparison.OrdinalIgnoreCase));

            Banner();

            try
            {
                Config cfg = Config.Load();
                Info("Source: " + cfg.Describe());

                string gameRoot = ResolveGameRoot(cfg);
                Info("Game:   " + gameRoot);

                EnsureGameNotRunning();

                if (doDisable)
                {
                    DisableMods(gameRoot, false);
                    Ok("Mods disabled. Windrose will run vanilla.");
                    return 0;
                }

                // Clear any proxy left behind by a crash or a force-closed launcher,
                // so state is always known-good before we sync.
                DisableMods(gameRoot, true);

                Manifest manifest = FetchManifest(cfg);
                Info("Release: " + manifest.release + "   (" + manifest.files.Count + " files)");

                CheckGameBuild(gameRoot, manifest);

                Plan plan = BuildPlan(gameRoot, manifest);
                Report(plan);

                if (verify)
                {
                    Info("--verify: no changes written.");
                    // 2 = out of sync. Otherwise pass through 3 if the game build
                    // drifted, so scripted callers can distinguish the two.
                    if (!plan.IsClean) return 2;
                    return _exitCode;
                }

                if (!plan.IsClean)
                {
                    Apply(gameRoot, manifest, cfg, plan);
                    Ok("Client is now in sync with the server mod set.");
                }
                else
                {
                    Ok("Already in sync - nothing to do.");
                }

                if (doEnable)
                {
                    int n = EnableMods(gameRoot);
                    Ok("Mods enabled for " + n + " location(s). Start Windrose when ready.");
                    Info("Run with --disable afterwards to go back to vanilla.");
                    return _exitCode;
                }

                if (!noLaunch) LaunchAndWait(gameRoot);
                return _exitCode;
            }
            catch (SyncException ex)
            {
                Fail(ex.Message);
                if (!string.IsNullOrEmpty(ex.Hint)) Console.WriteLine("       " + ex.Hint);
                Pause();
                return 1;
            }
            catch (Exception ex)
            {
                Fail("Unexpected error: " + ex.Message);
                Console.WriteLine(ex.StackTrace);
                Pause();
                return 1;
            }
        }

        // ---------------------------------------------------------------- config

        // Players get ONE file and double-click it. The mod source is baked in at
        // build time (BuildConfig.cs, generated by build.ps1), so there is nothing
        // to edit and nothing to place beside the exe.
        //
        // Two optional overrides exist for the admin, neither needed by players:
        //   - WindroseSync.config.json beside the exe (self-hosting, testing)
        //   - a remembered game path, cached under %LOCALAPPDATA% so it works even
        //     when the exe sits somewhere unwritable like Downloads or Program Files
        private sealed class Config
        {
            public string owner = BuildConfig.Owner;
            public string repo = BuildConfig.Repo;
            public string gitref = BuildConfig.GitRef;
            public string base_url = BuildConfig.BaseUrl;
            public string game_path = "";

            public string Describe()
            {
                if (!string.IsNullOrEmpty(base_url)) return base_url;
                return "github.com/" + owner + "/" + repo + " @ " + gitref;
            }

            public string RawBase()
            {
                if (!string.IsNullOrEmpty(base_url))
                    return base_url.EndsWith("/") ? base_url : base_url + "/";
                return "https://raw.githubusercontent.com/" + owner + "/" + repo + "/" + gitref + "/";
            }

            private static string SidecarPath()
            {
                string dir = Path.GetDirectoryName(
                    System.Reflection.Assembly.GetExecutingAssembly().Location);
                return Path.Combine(dir, "WindroseSync.config.json");
            }

            private static string CachePath()
            {
                string dir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "WindroseSync");
                Directory.CreateDirectory(dir);
                return Path.Combine(dir, "settings.json");
            }

            private static Dictionary<string, object> ReadJson(string path)
            {
                try
                {
                    if (!File.Exists(path)) return null;
                    var ser = new JavaScriptSerializer();
                    return ser.Deserialize<Dictionary<string, object>>(File.ReadAllText(path));
                }
                catch { return null; }
            }

            public static Config Load()
            {
                var cfg = new Config();

                // Sidecar overrides the baked-in source, if an admin dropped one in.
                var side = ReadJson(SidecarPath());
                if (side != null)
                {
                    if (side.ContainsKey("owner") && !string.IsNullOrEmpty(Convert.ToString(side["owner"])))
                        cfg.owner = Convert.ToString(side["owner"]);
                    if (side.ContainsKey("repo") && !string.IsNullOrEmpty(Convert.ToString(side["repo"])))
                        cfg.repo = Convert.ToString(side["repo"]);
                    if (side.ContainsKey("gitref") && !string.IsNullOrEmpty(Convert.ToString(side["gitref"])))
                        cfg.gitref = Convert.ToString(side["gitref"]);
                    if (side.ContainsKey("base_url"))
                        cfg.base_url = Convert.ToString(side["base_url"]);
                    if (side.ContainsKey("game_path") && !string.IsNullOrEmpty(Convert.ToString(side["game_path"])))
                        cfg.game_path = Convert.ToString(side["game_path"]);
                }

                // Remembered game path wins only if we don't already have one.
                if (string.IsNullOrEmpty(cfg.game_path))
                {
                    var cache = ReadJson(CachePath());
                    if (cache != null && cache.ContainsKey("game_path"))
                        cfg.game_path = Convert.ToString(cache["game_path"]);
                }

                if (string.IsNullOrEmpty(cfg.owner) && string.IsNullOrEmpty(cfg.base_url))
                    throw new SyncException(
                        "This launcher was built without a mod source.",
                        "Whoever built it must run launcher\\build.ps1 -Owner <github-account>.");
                return cfg;
            }

            public void SaveGamePath(string p)
            {
                game_path = p;
                try
                {
                    var ser = new JavaScriptSerializer();
                    var d = new Dictionary<string, object> { { "game_path", p } };
                    File.WriteAllText(CachePath(), ser.Serialize(d));
                }
                catch { /* remembering the path is a convenience, never fatal */ }
            }
        }

        // ------------------------------------------------------------- locate game

        private static string ResolveGameRoot(Config cfg)
        {
            if (!string.IsNullOrEmpty(cfg.game_path) &&
                File.Exists(Path.Combine(cfg.game_path, GameExeRel)))
                return cfg.game_path;

            foreach (string lib in SteamLibraries())
            {
                string candidate = Path.Combine(lib, @"steamapps\common\Windrose");
                if (File.Exists(Path.Combine(candidate, GameExeRel)))
                {
                    cfg.SaveGamePath(candidate);
                    return candidate;
                }
            }

            // Auto-detection covers the normal Steam install. If it fails - unusual
            // library layout, moved folder - ask once and remember, rather than
            // making the player hand-edit a config file.
            Warn("Could not find Windrose automatically.");
            Console.WriteLine();
            Console.WriteLine("  Paste the folder containing Windrose.exe, for example:");
            Console.WriteLine("  C:\\Program Files (x86)\\Steam\\steamapps\\common\\Windrose");
            Console.WriteLine();

            for (int attempt = 0; attempt < 3; attempt++)
            {
                Console.Write("  Windrose folder: ");
                string typed = Console.ReadLine();
                if (typed == null) break;
                typed = typed.Trim().Trim('"');
                if (typed.Length == 0) continue;

                if (File.Exists(Path.Combine(typed, GameExeRel)))
                {
                    cfg.SaveGamePath(typed);
                    Ok("Saved - you won't be asked again.");
                    return typed;
                }
                Fail("No Windrose install there (looking for " + GameExeRel + ")");
            }

            throw new SyncException(
                "Could not find your Windrose installation.",
                "Find the folder containing Windrose.exe and run this launcher again.");
        }

        private static IEnumerable<string> SteamLibraries()
        {
            var roots = new List<string>();
            string steam = null;

            foreach (var hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
            {
                foreach (var key in new[] { @"Software\Valve\Steam", @"Software\WOW6432Node\Valve\Steam" })
                {
                    try
                    {
                        using (RegistryKey k = hive.OpenSubKey(key))
                        {
                            if (k == null) continue;
                            object v = k.GetValue("SteamPath") ?? k.GetValue("InstallPath");
                            if (v != null && !string.IsNullOrEmpty(Convert.ToString(v)))
                            {
                                steam = Convert.ToString(v).Replace('/', '\\');
                                break;
                            }
                        }
                    }
                    catch { }
                }
                if (steam != null) break;
            }

            if (steam != null) roots.Add(steam);

            // Additional libraries live in libraryfolders.vdf. Parse loosely - the
            // format is simple key/value pairs and we only want "path" entries.
            if (steam != null)
            {
                string vdf = Path.Combine(steam, @"steamapps\libraryfolders.vdf");
                if (File.Exists(vdf))
                {
                    foreach (string line in File.ReadAllLines(vdf))
                    {
                        string t = line.Trim();
                        if (!t.StartsWith("\"path\"", StringComparison.OrdinalIgnoreCase)) continue;
                        int first = t.IndexOf('"', 6);
                        if (first < 0) continue;
                        int second = t.IndexOf('"', first + 1);
                        if (second < 0) continue;
                        string p = t.Substring(first + 1, second - first - 1).Replace(@"\\", @"\");
                        if (!roots.Contains(p)) roots.Add(p);
                    }
                }
            }
            return roots;
        }

        private static void EnsureGameNotRunning()
        {
            if (Process.GetProcessesByName(GameProcName).Length > 0)
                throw new SyncException(
                    "Windrose is currently running.",
                    "Close the game completely, then run this launcher again. " +
                    "Mod files are locked while the game is open.");
        }

        // ------------------------------------------------------------- manifest

        private sealed class ManifestFile
        {
            public string target;
            public string path;
            public string sha256;
            public long size;
        }

        private sealed class Manifest
        {
            public string release = "";
            public string client_digest = "";
            public string gameClientSha = null;
            public List<ManifestFile> files = new List<ManifestFile>();
        }

        private static Manifest FetchManifest(Config cfg)
        {
            string url = cfg.RawBase() + "manifest.json";
            string text;
            try
            {
                using (var wc = new WebClient())
                {
                    wc.Encoding = Encoding.UTF8;
                    wc.Headers.Add("User-Agent", "WindroseSync");
                    // Defeat CDN caching so a fresh publish is picked up immediately.
                    text = wc.DownloadString(url + "?t=" + DateTime.UtcNow.Ticks);
                }
            }
            catch (Exception ex)
            {
                throw new SyncException(
                    "Could not download the mod manifest.",
                    "Checked: " + url + Environment.NewLine +
                    "       " + ex.Message + Environment.NewLine +
                    "       The game was NOT started, to avoid connecting with a mismatched mod set.");
            }

            var ser = new JavaScriptSerializer();
            ser.MaxJsonLength = int.MaxValue;
            var root = ser.Deserialize<Dictionary<string, object>>(text);

            var m = new Manifest();
            if (root.ContainsKey("release")) m.release = Convert.ToString(root["release"]);
            if (root.ContainsKey("client_digest")) m.client_digest = Convert.ToString(root["client_digest"]);

            if (root.ContainsKey("game_build") && root["game_build"] is Dictionary<string, object>)
            {
                var gb = (Dictionary<string, object>)root["game_build"];
                if (gb.ContainsKey("client_sha256") && gb["client_sha256"] != null)
                    m.gameClientSha = Convert.ToString(gb["client_sha256"]);
            }

            if (root.ContainsKey("files"))
            {
                foreach (var o in (System.Collections.ArrayList)root["files"])
                {
                    var d = (Dictionary<string, object>)o;
                    m.files.Add(new ManifestFile
                    {
                        // Older manifests had no target; those were client-only.
                        target = d.ContainsKey("target") ? Convert.ToString(d["target"]) : "client",
                        path = Convert.ToString(d["path"]).Replace('/', '\\'),
                        sha256 = Convert.ToString(d["sha256"]).ToLowerInvariant(),
                        size = Convert.ToInt64(d["size"])
                    });
                }
            }

            if (m.files.Count == 0)
                throw new SyncException("The manifest lists no files.",
                    "Refusing to continue - applying it would delete your mods.");
            return m;
        }

        private static void CheckGameBuild(string gameRoot, Manifest m)
        {
            if (string.IsNullOrEmpty(m.gameClientSha)) return;
            string exe = Path.Combine(gameRoot, GameExeRel);
            string local = Sha256File(exe);
            if (!local.Equals(m.gameClientSha, StringComparison.OrdinalIgnoreCase))
            {
                Warn("Your Windrose build does not match the one these mods were built for.");
                Console.WriteLine("       expected " + m.gameClientSha.Substring(0, 16) + "...");
                Console.WriteLine("       yours    " + local.Substring(0, 16) + "...");
                Console.WriteLine("       The game probably updated. Mods may misbehave until the");
                Console.WriteLine("       server admin publishes a rebuilt mod set.");
                _exitCode = 3;
            }
        }

        // ------------------------------------------------------------- planning

        private sealed class Plan
        {
            public List<ManifestFile> Download = new List<ManifestFile>();
            public List<string> Delete = new List<string>();
            public long Bytes;
            public bool IsClean { get { return Download.Count == 0 && Delete.Count == 0; } }
        }

        // A path is managed only if it lives under <target root>\ue4ss\ for one of
        // the targets. Both the plan and the apply step check this, so a malformed
        // or hostile manifest cannot reach the rest of the install.
        private static bool IsManaged(string rel)
        {
            foreach (Target t in Targets)
            {
                string root = Path.Combine(t.Root, ManagedSubdir) + @"\";
                if (rel.StartsWith(root, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }

        private static Target TargetFor(string name)
        {
            foreach (Target t in Targets)
                if (t.Name.Equals(name, StringComparison.OrdinalIgnoreCase)) return t;
            return null;
        }

        private static bool TargetPresent(string gameRoot, Target t)
        {
            // hostserver only exists if the game shipped the bundled server build.
            return Directory.Exists(Path.Combine(gameRoot, t.Root));
        }

        private static bool IsRuntimeArtifact(string rel)
        {
            foreach (string suffix in RuntimeSuffixes)
                if (rel.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) return true;

            foreach (string seg in rel.Split('\\'))
                foreach (string d in RuntimeDirNames)
                    if (seg.Equals(d, StringComparison.OrdinalIgnoreCase)) return true;

            return false;
        }

        // Manifest paths are relative to their target's payload folder; on disk they
        // live under that target's root. Everything funnels through here so the
        // managed-scope check can never be bypassed.
        private static string ToRelInstall(ManifestFile f)
        {
            Target t = TargetFor(f.target);
            if (t == null)
                throw new SyncException(
                    "The manifest names an install target this launcher doesn't know: " + f.target,
                    "You are probably running an old launcher against a newer mod set. " +
                    "Download the current WindroseSync.exe.");
            return Path.Combine(t.Root, f.path);
        }

        private static Plan BuildPlan(string gameRoot, Manifest m)
        {
            var plan = new Plan();
            var wanted = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var skipped = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            foreach (ManifestFile f in m.files)
            {
                Target t = TargetFor(f.target);
                if (!TargetPresent(gameRoot, t))
                {
                    // Optional target missing (e.g. no bundled server build). Skip it
                    // rather than fail - the rest of the mod set is still valid.
                    if (!t.Required) { skipped.Add(t.Name); continue; }
                    throw new SyncException(
                        "Required game folder is missing: " + t.Root,
                        "Verify the game files through Steam and try again.");
                }

                string rel = ToRelInstall(f);
                if (!IsManaged(rel))
                    throw new SyncException(
                        "The manifest refers to a file outside the managed mod folders: " + f.path,
                        "Refusing to continue. This would touch game files the launcher must not modify.");

                wanted.Add(rel);

                string abs = Path.Combine(gameRoot, rel);
                if (!File.Exists(abs) || !Sha256File(abs).Equals(f.sha256, StringComparison.OrdinalIgnoreCase))
                {
                    plan.Download.Add(f);
                    plan.Bytes += f.size;
                }
            }

            foreach (string name in skipped)
            {
                Target t = TargetFor(name);
                Info("Skipping " + t.Label + " - not present in this install.");
            }

            // Anything inside a managed root the manifest doesn't list is stale,
            // except runtime artifacts, which belong to the game rather than to us.
            foreach (Target t in Targets)
            {
                if (skipped.Contains(t.Name)) continue;
                string absRoot = Path.Combine(gameRoot, Path.Combine(t.Root, ManagedSubdir));
                if (!Directory.Exists(absRoot)) continue;
                foreach (string abs in Directory.GetFiles(absRoot, "*", SearchOption.AllDirectories))
                {
                    string rel = abs.Substring(gameRoot.Length).TrimStart('\\');
                    if (wanted.Contains(rel)) continue;
                    if (IsRuntimeArtifact(rel)) continue;
                    plan.Delete.Add(rel);
                }
            }
            return plan;
        }

        private static void Report(Plan p)
        {
            if (p.IsClean) return;
            Console.WriteLine();
            if (p.Download.Count > 0)
            {
                Info(string.Format(CultureInfo.InvariantCulture,
                    "{0} file(s) to download ({1:N1} MB)", p.Download.Count, p.Bytes / 1048576.0));
                foreach (var f in p.Download.Take(10)) Console.WriteLine("       + " + f.path);
                if (p.Download.Count > 10) Console.WriteLine("       ... and " + (p.Download.Count - 10) + " more");
            }
            if (p.Delete.Count > 0)
            {
                Info(p.Delete.Count + " stale file(s) to remove");
                foreach (string d in p.Delete.Take(10)) Console.WriteLine("       - " + d);
                if (p.Delete.Count > 10) Console.WriteLine("       ... and " + (p.Delete.Count - 10) + " more");
            }
            Console.WriteLine();
        }

        // -------------------------------------------------------------- applying

        private static void Apply(string gameRoot, Manifest m, Config cfg, Plan plan)
        {
            // The same bytes often land in two targets (UE4SS.dll, the mod itself).
            // Fetch each distinct hash once and copy locally for the rest - halves
            // the transfer on a fresh install.
            var fetched = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

            int n = 0;
            foreach (ManifestFile f in plan.Download)
            {
                n++;
                string rel = ToRelInstall(f);
                if (!IsManaged(rel)) continue;               // belt and braces
                string abs = Path.Combine(gameRoot, rel);
                Directory.CreateDirectory(Path.GetDirectoryName(abs));

                string label = f.target + ": " + f.path;
                Console.Write(string.Format("  [{0}/{1}] {2} ... ", n, plan.Download.Count, label));

                string alreadyHave;
                if (fetched.TryGetValue(f.sha256, out alreadyHave) && File.Exists(alreadyHave))
                {
                    try
                    {
                        File.Copy(alreadyHave, abs, true);
                        Console.WriteLine("copied");
                        continue;
                    }
                    catch { /* fall through to a normal download */ }
                }

                string url = cfg.RawBase() + "payload/" + f.target + "/" + f.path.Replace('\\', '/');
                string tmp = abs + ".wsync-tmp";
                try
                {
                    using (var wc = new WebClient())
                    {
                        wc.Headers.Add("User-Agent", "WindroseSync");
                        wc.DownloadFile(url, tmp);
                    }

                    // Verify before it is allowed anywhere near the game folder.
                    string got = Sha256File(tmp);
                    if (!got.Equals(f.sha256, StringComparison.OrdinalIgnoreCase))
                    {
                        File.Delete(tmp);
                        throw new SyncException(
                            "Downloaded file failed its hash check: " + f.path,
                            "expected " + f.sha256.Substring(0, 16) + "..., got " + got.Substring(0, 16) + "...");
                    }

                    // Atomic swap - never leave a half-written DLL in place.
                    if (File.Exists(abs)) File.Delete(abs);
                    File.Move(tmp, abs);
                    fetched[f.sha256] = abs;
                    Console.WriteLine("ok");
                }
                catch (SyncException) { Console.WriteLine("FAILED"); throw; }
                catch (Exception ex)
                {
                    Console.WriteLine("FAILED");
                    if (File.Exists(tmp)) { try { File.Delete(tmp); } catch { } }
                    throw new SyncException("Could not download " + f.path + ": " + ex.Message,
                        "The game was NOT started. Check your connection and try again.");
                }
            }

            foreach (string rel in plan.Delete)
            {
                if (!IsManaged(rel)) continue;               // belt and braces
                try
                {
                    File.Delete(Path.Combine(gameRoot, rel));
                    Console.WriteLine("  removed " + rel);
                }
                catch (Exception ex) { Warn("Could not remove " + rel + ": " + ex.Message); }
            }

            PruneEmptyDirs(gameRoot);
        }

        private static void PruneEmptyDirs(string gameRoot)
        {
            foreach (Target t in Targets)
            {
                string absRoot = Path.Combine(gameRoot, Path.Combine(t.Root, ManagedSubdir));
                if (!Directory.Exists(absRoot)) continue;
                foreach (string dir in Directory.GetDirectories(absRoot, "*", SearchOption.AllDirectories)
                                                .OrderByDescending(d => d.Length))
                {
                    try
                    {
                        if (Directory.GetFileSystemEntries(dir).Length == 0) Directory.Delete(dir);
                    }
                    catch { }
                }
            }
        }

        // ------------------------------------------------- mod activation gating
        //
        // UE4SS only loads if dwmapi.dll sits beside the executable. The launcher
        // copies it in just before starting the game and removes it afterwards, so
        // launching Windrose any other way runs completely vanilla - no UE4SS, no
        // mods. State is self-correcting: every run clears stale proxies first.

        private static string ProxyLivePath(string gameRoot, Target t)
        {
            return Path.Combine(gameRoot, Path.Combine(t.Root, ProxyName));
        }

        private static string ProxySourcePath(string gameRoot, Target t)
        {
            return Path.Combine(gameRoot, Path.Combine(t.Root, ProxyStaged));
        }

        private static int EnableMods(string gameRoot)
        {
            int enabled = 0;
            foreach (Target t in Targets)
            {
                string src = ProxySourcePath(gameRoot, t);
                if (!File.Exists(src)) continue;
                try
                {
                    File.Copy(src, ProxyLivePath(gameRoot, t), true);
                    enabled++;
                }
                catch (Exception ex)
                {
                    Warn("Could not enable mods for " + t.Label + ": " + ex.Message);
                }
            }
            return enabled;
        }

        private static void DisableMods(string gameRoot, bool quiet)
        {
            foreach (Target t in Targets)
            {
                string live = ProxyLivePath(gameRoot, t);
                if (!File.Exists(live)) continue;
                try { File.Delete(live); }
                catch (Exception ex)
                {
                    if (!quiet)
                        Warn("Could not disable mods for " + t.Label + " (" + ex.Message + ")." +
                             " They will stay active until the game closes.");
                }
            }
        }

        private static void LaunchAndWait(string gameRoot)
        {
            Console.WriteLine();
            int n = EnableMods(gameRoot);
            Info("Mods enabled for this session (" + n + " location(s)).");
            Info("Starting Windrose...");

            try
            {
                Process.Start(new ProcessStartInfo("steam://rungameid/" + SteamAppId) { UseShellExecute = true });
            }
            catch (Exception ex)
            {
                DisableMods(gameRoot, true);
                Warn("Could not start the game via Steam: " + ex.Message);
                Console.WriteLine("       Start Windrose from Steam, then run this launcher again.");
                return;
            }

            // Steam's URL handler returns immediately, so wait for the real process.
            Console.WriteLine();
            Info("Waiting for the game to start...");
            Process game = null;
            for (int i = 0; i < 120 && game == null; i++)      // up to ~2 minutes
            {
                System.Threading.Thread.Sleep(1000);
                Process[] found = Process.GetProcessesByName(GameProcName);
                if (found.Length > 0) game = found[0];
            }

            if (game == null)
            {
                Warn("Didn't see the game start within 2 minutes.");
                Console.WriteLine("       Mods are left enabled. Run this launcher again after you finish");
                Console.WriteLine("       playing to switch them back off.");
                return;
            }

            Ok("Game running. Leave this window open - it turns mods back off when you quit.");
            try { game.WaitForExit(); } catch { }

            DisableMods(gameRoot, false);
            Console.WriteLine();
            Ok("Game closed, mods disabled. Windrose will run vanilla until you use this launcher again.");
        }

        // ----------------------------------------------------------------- utils

        private static string Sha256File(string path)
        {
            using (var sha = SHA256.Create())
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536))
            {
                byte[] h = sha.ComputeHash(fs);
                var sb = new StringBuilder(h.Length * 2);
                foreach (byte b in h) sb.Append(b.ToString("x2"));
                return sb.ToString();
            }
        }

        private sealed class SyncException : Exception
        {
            public readonly string Hint;
            public SyncException(string msg, string hint) : base(msg) { Hint = hint; }
        }

        private static void Banner()
        {
            Console.ForegroundColor = ConsoleColor.Cyan;
            Console.WriteLine("  Windrose Mod Sync");
            Console.ResetColor();
            Console.WriteLine("  ------------------------------------------------");
        }
        private static void Info(string m) { Console.WriteLine("  " + m); }
        private static void Ok(string m)
        {
            Console.ForegroundColor = ConsoleColor.Green; Console.WriteLine("  " + m); Console.ResetColor();
        }
        private static void Warn(string m)
        {
            Console.ForegroundColor = ConsoleColor.Yellow; Console.WriteLine("  WARNING: " + m); Console.ResetColor();
        }
        private static void Fail(string m)
        {
            Console.ForegroundColor = ConsoleColor.Red; Console.WriteLine("  ERROR: " + m); Console.ResetColor();
        }
        private static void Pause()
        {
            Console.WriteLine();
            Console.WriteLine("  Press any key to close...");
            try { Console.ReadKey(true); } catch { }
        }
    }
}
