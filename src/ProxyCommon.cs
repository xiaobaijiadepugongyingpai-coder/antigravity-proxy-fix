/*
 * ProxyCommon: shared proxy discovery, TCP probing, and verbatim command-line
 * argument extraction for AntigravityProxy.exe and AgyShim (agy.exe).
 *
 * Kept C# 5 compatible so Windows built-in .NET Framework 4 csc.exe compiles it
 * with zero external dependencies.
 */

using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace AntigravityProxyFix
{
    internal static class ProxyCommon
    {
        private const int ProbeTimeoutMs = 300;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr GetCommandLineW();

        public static void MaybeSetProxy(string primaryEnvVar, string selfDir)
        {
            if (HasAnyEnv("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"))
            {
                return;
            }

            List<string> candidates = new List<string>();
            if (!string.IsNullOrEmpty(primaryEnvVar))
            {
                AddCandidate(candidates, Environment.GetEnvironmentVariable(primaryEnvVar));
            }

            if (!string.IsNullOrEmpty(selfDir))
            {
                AddCandidate(candidates, ReadProxyConf(Path.Combine(selfDir, "proxy.conf")));
            }

            string userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            if (!string.IsNullOrEmpty(userProfile))
            {
                AddCandidate(candidates, ReadProxyConf(Path.Combine(userProfile, @".agy-shim\proxy.conf")));
            }

            AddCandidate(candidates, "http://127.0.0.1:7897");
            AddCandidate(candidates, "http://127.0.0.1:7890");
            AddCandidate(candidates, "http://127.0.0.1:10809");

            string chosen = null;
            for (int i = 0; i < candidates.Count; i++)
            {
                if (ProbeProxyUrl(candidates[i]))
                {
                    chosen = candidates[i];
                    break;
                }
            }

            if (string.IsNullOrEmpty(chosen))
            {
                return;
            }

            Environment.SetEnvironmentVariable("HTTPS_PROXY", chosen);
            Environment.SetEnvironmentVariable("HTTP_PROXY", chosen);

            if (!HasAnyEnv("NO_PROXY", "no_proxy"))
            {
                Environment.SetEnvironmentVariable("NO_PROXY", "localhost,127.0.0.1,::1");
            }
        }

        public static string ExtractRawArguments()
        {
            IntPtr ptr = GetCommandLineW();
            if (ptr == IntPtr.Zero)
            {
                return string.Empty;
            }

            string cmd = Marshal.PtrToStringUni(ptr);
            if (string.IsNullOrEmpty(cmd))
            {
                return string.Empty;
            }

            int i = 0;
            int len = cmd.Length;
            while (i < len && (cmd[i] == ' ' || cmd[i] == '\t'))
            {
                i++;
            }

            if (i < len && cmd[i] == '"')
            {
                i++;
                while (i < len && cmd[i] != '"')
                {
                    i++;
                }
                if (i < len && cmd[i] == '"')
                {
                    i++;
                }
            }
            else
            {
                while (i < len && cmd[i] != ' ' && cmd[i] != '\t')
                {
                    i++;
                }
            }

            while (i < len && (cmd[i] == ' ' || cmd[i] == '\t'))
            {
                i++;
            }

            return i < len ? cmd.Substring(i) : string.Empty;
        }

        private static bool HasAnyEnv(params string[] names)
        {
            for (int i = 0; i < names.Length; i++)
            {
                string val = Environment.GetEnvironmentVariable(names[i]);
                if (!string.IsNullOrEmpty(val))
                {
                    return true;
                }
            }
            return false;
        }

        private static void AddCandidate(List<string> list, string raw)
        {
            string normalized = NormalizeProxyUrl(raw);
            if (string.IsNullOrEmpty(normalized))
            {
                return;
            }
            for (int i = 0; i < list.Count; i++)
            {
                if (string.Equals(list[i], normalized, StringComparison.OrdinalIgnoreCase))
                {
                    return;
                }
            }
            list.Add(normalized);
        }

        private static string ReadProxyConf(string path)
        {
            if (string.IsNullOrEmpty(path) || !File.Exists(path))
            {
                return null;
            }

            try
            {
                string[] lines = File.ReadAllLines(path);
                for (int i = 0; i < lines.Length; i++)
                {
                    string line = lines[i].Trim();
                    if (line.Length == 0 || line.StartsWith("#") || line.StartsWith(";"))
                    {
                        continue;
                    }
                    int eq = line.IndexOf('=');
                    if (eq > 0)
                    {
                        string key = line.Substring(0, eq).Trim();
                        if (string.Equals(key, "ANTIGRAVITY_PROXY", StringComparison.OrdinalIgnoreCase) ||
                            string.Equals(key, "AGY_PROXY", StringComparison.OrdinalIgnoreCase) ||
                            string.Equals(key, "HTTPS_PROXY", StringComparison.OrdinalIgnoreCase) ||
                            string.Equals(key, "HTTP_PROXY", StringComparison.OrdinalIgnoreCase) ||
                            string.Equals(key, "PROXY", StringComparison.OrdinalIgnoreCase))
                        {
                            line = line.Substring(eq + 1).Trim();
                        }
                    }
                    line = line.Trim('"', '\'').Trim();
                    if (line.Length > 0)
                    {
                        return line;
                    }
                }
            }
            catch
            {
                // Best effort only.
            }

            return null;
        }

        private static string NormalizeProxyUrl(string raw)
        {
            if (string.IsNullOrEmpty(raw))
            {
                return null;
            }
            string s = raw.Trim().Trim('"', '\'').Trim();
            if (s.Length == 0)
            {
                return null;
            }

            int portOnly;
            if (int.TryParse(s, out portOnly) && portOnly > 0 && portOnly <= 65535)
            {
                return "http://127.0.0.1:" + portOnly;
            }

            if (s.IndexOf("://", StringComparison.Ordinal) < 0)
            {
                s = "http://" + s;
            }

            Uri uri;
            if (!Uri.TryCreate(s, UriKind.Absolute, out uri))
            {
                return null;
            }
            if (string.IsNullOrEmpty(uri.Host) || uri.Port <= 0 || uri.Port > 65535)
            {
                return null;
            }
            return s;
        }

        private static bool ProbeProxyUrl(string url)
        {
            Uri uri;
            if (!Uri.TryCreate(url, UriKind.Absolute, out uri))
            {
                return false;
            }
            string host = uri.Host;
            int port = uri.Port;
            if (string.IsNullOrEmpty(host) || port <= 0 || port > 65535)
            {
                return false;
            }

            TcpClient client = null;
            try
            {
                client = new TcpClient();
                IAsyncResult ar = client.BeginConnect(host, port, null, null);
                bool signaled = ar.AsyncWaitHandle.WaitOne(ProbeTimeoutMs);
                if (!signaled)
                {
                    return false;
                }
                client.EndConnect(ar);
                return client.Connected;
            }
            catch
            {
                return false;
            }
            finally
            {
                if (client != null)
                {
                    try { client.Close(); } catch { }
                }
            }
        }
    }
}
