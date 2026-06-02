using System.Runtime.InteropServices;
using System.Text;

namespace BPlus.Native;

public static class BpcBackend
{
    private const string DllName = "bpc_backend.dll";

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    private static extern uint bpc_generate(
        IntPtr source,
        UIntPtr srcLen,
        IntPtr output,
        ref UIntPtr outLen,
        byte mode
    );

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    private static extern uint bpc_generate_json(
        IntPtr json,
        UIntPtr jsonLen,
        IntPtr output,
        ref UIntPtr outLen,
        byte mode
    );

    private static string CallDll(Func<IntPtr, uint> invoker)
    {
        var outBuf = new byte[4 * 1024 * 1024];
        var outHandle = GCHandle.Alloc(outBuf, GCHandleType.Pinned);
        try
        {
            var result = invoker(outHandle.AddrOfPinnedObject());
            if (result != 0)
                throw new InvalidOperationException($"backend failed with code {result}");
            return Encoding.UTF8.GetString(outBuf, 0, Array.IndexOf(outBuf, (byte)0));
        }
        finally
        {
            outHandle.Free();
        }
    }

    public static string Generate(string source, int mode = 0)
    {
        var srcBytes = Encoding.UTF8.GetBytes(source);
        var srcHandle = GCHandle.Alloc(srcBytes, GCHandleType.Pinned);
        try
        {
            UIntPtr outLen = (UIntPtr)(4 * 1024 * 1024);
            return CallDll(outPtr =>
            {
                return bpc_generate(
                    srcHandle.AddrOfPinnedObject(),
                    (UIntPtr)srcBytes.Length,
                    outPtr,
                    ref outLen,
                    (byte)mode
                );
            });
        }
        finally
        {
            srcHandle.Free();
        }
    }

    public static string GenerateFromJson(string json, int mode = 0)
    {
        var jsonBytes = Encoding.UTF8.GetBytes(json);
        var jsonHandle = GCHandle.Alloc(jsonBytes, GCHandleType.Pinned);
        try
        {
            return CallDll(outPtr =>
            {
                UIntPtr outLen = (UIntPtr)(4 * 1024 * 1024);
                return bpc_generate_json(
                    jsonHandle.AddrOfPinnedObject(),
                    (UIntPtr)jsonBytes.Length,
                    outPtr,
                    ref outLen,
                    (byte)mode
                );
            });
        }
        finally
        {
            jsonHandle.Free();
        }
    }

    public static int GenerateToFile(string inputFile, string outputFile = "output.zig", int mode = 0)
    {
        var source = File.ReadAllText(inputFile);
        var code = Generate(source, mode);
        File.WriteAllText(outputFile, code);
        Console.WriteLine($"Generated {outputFile} ({(new FileInfo(outputFile)).Length} bytes)");
        return 0;
    }
}
