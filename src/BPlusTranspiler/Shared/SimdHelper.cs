using System.Numerics;
using System.Runtime.CompilerServices;

namespace BPlusTranspiler;

internal static class SimdHelper
{
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static bool ContainsAnyByte(ReadOnlySpan<byte> data, byte value)
    {
        if (data.Length < Vector<byte>.Count)
            return data.IndexOf(value) >= 0;

        var vec = new Vector<byte>(value);
        var i = 0;
        for (; i <= data.Length - Vector<byte>.Count; i += Vector<byte>.Count)
        {
            var chunk = new Vector<byte>(data.Slice(i));
            if (Vector.EqualsAny(chunk, vec))
                return true;
        }
        for (; i < data.Length; i++)
            if (data[i] == value)
                return true;
        return false;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static int IndexOfAny(ReadOnlySpan<byte> data, byte v0, byte v1)
    {
        var vec0 = new Vector<byte>(v0);
        var vec1 = new Vector<byte>(v1);
        var i = 0;
        for (; i <= data.Length - Vector<byte>.Count; i += Vector<byte>.Count)
        {
            var chunk = new Vector<byte>(data.Slice(i));
            if (Vector.EqualsAny(chunk, vec0))
                return i + LocateFirst(data.Slice(i), v0);
            if (Vector.EqualsAny(chunk, vec1))
                return i + LocateFirst(data.Slice(i), v1);
        }
        for (; i < data.Length; i++)
            if (data[i] == v0 || data[i] == v1)
                return i;
        return -1;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static int LocateFirst(ReadOnlySpan<byte> chunk, byte value)
    {
        for (int j = 0; j < chunk.Length; j++)
            if (chunk[j] == value) return j;
        return -1;
    }
}
