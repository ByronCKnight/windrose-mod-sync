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

        // The ONLY paths this tool may create, overwrite or delete. Everything else
        // in the game install is off limits - notably Content/Paks, which holds the
        // ~18 GB of base game data.
        private static readonly string[] ManagedRoots = { @"R5\Binaries\Win64\ue4ss" };
        private static readonly string[] ManagedFiles = { @"R5\Binaries\Win64\dwmapi.dll" };

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

            Banner();

            try
            {
                Config cfg = Config.Load();
                Info("Source: " + cfg.Describe());

                string gameRoot = ResolveGameRoot(cfg);
                Info("Game:   " + gameRoot);

                EnsureGameNotRunning();

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

                if (!noLaunch) LaunchGame();
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

        private sealed class Config
        {
            public string owner = "";
            public string repo = "windrose-mod-sync";
            public string gitref = "main";
            public string game_path = "";
            // Optional override. When set, files are fetched from here instead of
            // GitHub - used for local testing, and for admins who would rather
            // self-host the payload than publish it to a repo.
            public string base_url = "";

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

            private static string ConfigPath()
            {
                string dir = Path.GetDirectoryName(
                    System.Reflection.Assembly.GetExecutingAssembly().Location);
                return Path.Combine(dir, "WindroseSync.config.json");
            }

            public static Config Load()
            {
                string path = ConfigPath();
                if (!File.Exists(path))
                    throw new SyncException(
                        "Missing WindroseSync.config.json next to the launcher.",
                        "It must contain your repo, e.g. {\"owner\":\"yourname\",\"repo\":\"windrose-mod-sync\",\"gitref\":\"main\"}");

                var ser = new JavaScriptSerializer();
                var raw = ser.Deserialize<Dictionary<string, object>>(File.ReadAllText(path));
                var cfg = new Config();
                if (raw.ContainsKey("owner")) cfg.owner = Convert.ToString(raw["owner"]);
                if (raw.ContainsKey("repo")) cfg.repo = Convert.ToString(raw["repo"]);
                if (raw.ContainsKey("gitref")) cfg.gitref = Convert.ToString(raw["gitref"]);
                if (raw.ContainsKey("game_path")) cfg.game_path = Convert.ToString(raw["game_path"]);
                if (raw.ContainsKey("base_url")) cfg.base_url = Convert.ToString(raw["base_url"]);

                if (string.IsNullOrEmpty(cfg.owner) && string.IsNullOrEmpty(cfg.base_url))
                    throw new SyncException("WindroseSync.config.json has no \"owner\".",
                                            "Set it to the GitHub account or org that owns the mod repo, " +
                                            "or set \"base_url\" to self-host the payload.");
                return cfg;
            }

            public void SaveGamePath(string p)
            {
                try
                {
                    var ser = new JavaScriptSerializer();
                    var d = new Dictionary<string, object>
                    {
                        { "owner", owner }, { "repo", repo },
                        { "gitref", gitref }, { "game_path", p },
                        { "base_url", base_url }
                    };
                    File.WriteAllText(ConfigPath(), ser.Serialize(d));
                }
                catch { /* caching the path is a convenience, never fatal */ }
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

            throw new SyncException(
                "Could not find your Windrose installation.",
                "Add its folder to WindroseSync.config.json as \"game_path\", " +
                "e.g. \"C:\\\\Program Files (x86)\\\\Steam\\\\steamapps\\\\common\\\\Windrose\"");
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

        private static bool IsManaged(string rel)
        {
            foreach (string f in ManagedFiles)
                if (rel.Equals(f, StringComparison.OrdinalIgnoreCase)) return true;
            foreach (string r in ManagedRoots)
                if (rel.StartsWith(r + @"\", StringComparison.OrdinalIgnoreCase)) return true;
            return false;
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

        // Manifest paths are relative to payload/client; on disk they live under
        // R5\Binaries\Win64. Everything funnels through here so the managed-scope
        // check can never be bypassed.
        private static string ToRelInstall(string manifestPath)
        {
            return Path.Combine(@"R5\Binaries\Win64", manifestPath);
        }

        private static Plan BuildPlan(string gameRoot, Manifest m)
        {
            var plan = new Plan();
            var wanted = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            foreach (ManifestFile f in m.files)
            {
                string rel = ToRelInstall(f.path);
                if (!IsManaged(rel))
                {
                    // A manifest must never reach outside the managed scope.
                    throw new SyncException(
                        "The manifest refers to a file outside the managed mod folders: " + f.path,
                        "Refusing to continue. This would touch game files the launcher must not modify.");
                }
                wanted.Add(rel);

                string abs = Path.Combine(gameRoot, rel);
                if (!File.Exists(abs) || !Sha256File(abs).Equals(f.sha256, StringComparison.OrdinalIgnoreCase))
                {
                    plan.Download.Add(f);
                    plan.Bytes += f.size;
                }
            }

            // Anything inside the managed roots that the manifest doesn't list is
            // stale - except runtime artifacts, which belong to the game, not to us.
            foreach (string root in ManagedRoots)
            {
                string absRoot = Path.Combine(gameRoot, root);
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
            int n = 0;
            foreach (ManifestFile f in plan.Download)
            {
                n++;
                string rel = ToRelInstall(f.path);
                if (!IsManaged(rel)) continue;               // belt and braces
                string abs = Path.Combine(gameRoot, rel);
                Directory.CreateDirectory(Path.GetDirectoryName(abs));

                string url = cfg.RawBase() + "payload/client/" + f.path.Replace('\\', '/');
                string tmp = abs + ".wsync-tmp";

                Console.Write(string.Format("  [{0}/{1}] {2} ... ", n, plan.Download.Count, f.path));
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
            foreach (string root in ManagedRoots)
            {
                string absRoot = Path.Combine(gameRoot, root);
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

        private static void LaunchGame()
        {
            Console.WriteLine();
            Info("Starting Windrose...");
            try
            {
                Process.Start(new ProcessStartInfo("steam://rungameid/" + SteamAppId) { UseShellExecute = true });
            }
            catch (Exception ex)
            {
                Warn("Could not start the game via Steam: " + ex.Message);
                Console.WriteLine("       Launch Windrose from Steam yourself - your mods are already in sync.");
            }
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
