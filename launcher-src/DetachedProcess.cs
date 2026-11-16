using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace AgyProxy
{
    public static class DetachedProcess
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr Descriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool Inherit;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo
        {
            public int Size;
            public string Reserved, Desktop, Title;
            public int X, Y, XSize, YSize, XChars, YChars, Fill, Flags;
            public short ShowWindow, ReservedSize;
            public IntPtr ReservedBytes, StdInput, StdOutput, StdError;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfoEx { public StartupInfo Info; public IntPtr Attributes; }
        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInfo { public IntPtr Process, Thread; public int ProcessId, ThreadId; }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFileW(string name, uint access, uint share,
            ref SecurityAttributes attributes, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute,
            IntPtr value, IntPtr size, IntPtr previous, IntPtr returnedSize);
        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessW(string application, StringBuilder command,
            IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags,
            IntPtr environment, string directory, ref StartupInfoEx startup, out ProcessInfo process);
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        public static int Start(string executable, string arguments, string directory)
        {
            var security = new SecurityAttributes();
            security.Length = Marshal.SizeOf(typeof(SecurityAttributes));
            security.Inherit = true;
            IntPtr input = IntPtr.Zero, output = IntPtr.Zero, attributes = IntPtr.Zero, handles = IntPtr.Zero;
            bool initialized = false;
            try
            {
                input = CreateFileW("NUL", 0x80000000, 3, ref security, 3, 0, IntPtr.Zero);
                if (input == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
                output = CreateFileW("NUL", 0x40000000, 3, ref security, 3, 0, IntPtr.Zero);
                if (output == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
                IntPtr size = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
                attributes = Marshal.AllocHGlobal(size);
                if (!InitializeProcThreadAttributeList(attributes, 1, 0, ref size))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                initialized = true;
                handles = Marshal.AllocHGlobal(IntPtr.Size * 2);
                Marshal.WriteIntPtr(handles, 0, input);
                Marshal.WriteIntPtr(handles, IntPtr.Size, output);
                if (!UpdateProcThreadAttribute(attributes, 0, new IntPtr(0x20002), handles,
                    new IntPtr(IntPtr.Size * 2), IntPtr.Zero, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                var startup = new StartupInfoEx();
                startup.Info.Size = Marshal.SizeOf(typeof(StartupInfoEx));
                startup.Info.Flags = 0x100; // STARTF_USESTDHANDLES
                startup.Info.StdInput = input;
                startup.Info.StdOutput = output;
                startup.Info.StdError = output;
                startup.Attributes = attributes;
                var command = new StringBuilder("\"" + executable + "\" " + arguments);
                ProcessInfo process;
                // Inherit proxy environment, but inherit only NUL standard handles, never launcher pipes.
                if (!CreateProcessW(executable, command, IntPtr.Zero, IntPtr.Zero, true,
                    0x08080000, IntPtr.Zero, directory, ref startup, out process))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                CloseHandle(process.Thread);
                CloseHandle(process.Process);
                return process.ProcessId;
            }
            finally
            {
                if (initialized) DeleteProcThreadAttributeList(attributes);
                if (attributes != IntPtr.Zero) Marshal.FreeHGlobal(attributes);
                if (handles != IntPtr.Zero) Marshal.FreeHGlobal(handles);
                if (input != IntPtr.Zero && input != new IntPtr(-1)) CloseHandle(input);
                if (output != IntPtr.Zero && output != new IntPtr(-1)) CloseHandle(output);
            }
        }
    }
}
