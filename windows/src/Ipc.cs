using System;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;

namespace Lidless
{
    /// <summary>One-line commands from a second Lidless.exe (hooks, URLs) to the running instance.
    /// Commands: "show", "start [minutes] [lid]", "stop", "extend [minutes]", "hold id [minutes]", "release id".</summary>
    internal static class Ipc
    {
        private static string PipeName =>
            "lidless-" + Process.GetCurrentProcess().SessionId + "-" + Environment.UserName;

        public static void Serve(Action<string> onCommand)
        {
            var thread = new Thread(() =>
            {
                while (true)
                {
                    try
                    {
                        using (var server = new NamedPipeServerStream(PipeName, PipeDirection.In, 1,
                                   PipeTransmissionMode.Byte, PipeOptions.None))
                        {
                            server.WaitForConnection();
                            using (var reader = new StreamReader(server, Encoding.UTF8))
                            {
                                string line = reader.ReadLine();
                                if (!string.IsNullOrWhiteSpace(line)) onCommand(line.Trim());
                            }
                        }
                    }
                    catch (Exception)
                    {
                        Thread.Sleep(500);
                    }
                }
            });
            thread.IsBackground = true;
            thread.Name = "Lidless IPC";
            thread.Start();
        }

        /// <summary>Sends a command to the running instance. Returns false if none answers.</summary>
        public static bool Send(string command, int timeoutMs = 800)
        {
            try
            {
                using (var client = new NamedPipeClientStream(".", PipeName, PipeDirection.Out))
                {
                    client.Connect(timeoutMs);
                    var bytes = Encoding.UTF8.GetBytes(command + "\n");
                    client.Write(bytes, 0, bytes.Length);
                    client.Flush();
                    return true;
                }
            }
            catch (Exception)
            {
                return false;
            }
        }

        /// <summary>Sends a command, starting Lidless first if it is not running.</summary>
        public static void SendOrLaunch(string command)
        {
            if (Send(command)) return;
            try
            {
                // Shell execute: the new app must not inherit the hook's stdin/stdout pipes, or Claude Code would wait on it.
                Process.Start(new ProcessStartInfo(App.ExePath) { UseShellExecute = true });
            }
            catch (Exception)
            {
                return;
            }
            var deadline = DateTime.UtcNow.AddSeconds(6);
            while (DateTime.UtcNow < deadline)
            {
                Thread.Sleep(300);
                if (Send(command, 500)) return;
            }
        }
    }
}
