using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace Hako.Platform;

// Windows ships this SQLite library. Never open Codex databases for writing or change their pragmas.
internal static class ReadOnlySqlite
{
    public static List<string[]> Query(string path, string sql, CancellationToken token)
    {
        IntPtr db = IntPtr.Zero, statement = IntPtr.Zero;
        try
        {
            if (sqlite3_open_v2(path, out db, 1 | 0x10000, IntPtr.Zero) != 0)
                throw new IOException("Cannot open Codex metadata database read-only.");
            sqlite3_busy_timeout(db, 200);
            if (sqlite3_prepare_v2(db, sql, -1, out statement, IntPtr.Zero) != 0)
                throw new IOException("Unsupported Codex metadata schema.");
            var result = new List<string[]>();
            int code;
            while ((code = sqlite3_step(statement)) == 100)
            {
                token.ThrowIfCancellationRequested();
                var row = new string[sqlite3_column_count(statement)];
                for (var i = 0; i < row.Length; i++)
                    row[i] = Marshal.PtrToStringUTF8(sqlite3_column_text(statement, i)) ?? "";
                result.Add(row);
            }
            if (code != 101) throw new IOException("Cannot read Codex metadata snapshot.");
            return result;
        }
        finally
        {
            if (statement != IntPtr.Zero) sqlite3_finalize(statement);
            if (db != IntPtr.Zero) sqlite3_close(db);
        }
    }

    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_open_v2([MarshalAs(UnmanagedType.LPUTF8Str)] string path, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_prepare_v2(IntPtr db, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, int length, out IntPtr statement, IntPtr tail);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_busy_timeout(IntPtr db, int milliseconds);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_step(IntPtr statement);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_column_count(IntPtr statement);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr sqlite3_column_text(IntPtr statement, int column);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_finalize(IntPtr statement);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_close(IntPtr db);
}
