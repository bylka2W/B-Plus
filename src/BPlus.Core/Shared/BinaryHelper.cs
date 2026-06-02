using System.Buffers.Binary;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace BPlus.Core;

internal static class BinaryHelper
{
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static ushort ReadUInt16LE(ReadOnlySpan<byte> data) =>
        BinaryPrimitives.ReadUInt16LittleEndian(data);

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static uint ReadUInt32LE(ReadOnlySpan<byte> data) =>
        BinaryPrimitives.ReadUInt32LittleEndian(data);

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static ulong ReadUInt64LE(ReadOnlySpan<byte> data) =>
        BinaryPrimitives.ReadUInt64LittleEndian(data);

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void WriteUInt16LE(Span<byte> dest, ushort value) =>
        BinaryPrimitives.WriteUInt16LittleEndian(dest, value);

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void WriteUInt32LE(Span<byte> dest, uint value) =>
        BinaryPrimitives.WriteUInt32LittleEndian(dest, value);

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void WriteUInt64LE(Span<byte> dest, ulong value) =>
        BinaryPrimitives.WriteUInt64LittleEndian(dest, value);

    public static byte[] StructToBytes<T>(ref T value) where T : unmanaged
    {
        var bytes = new byte[Unsafe.SizeOf<T>()];
        MemoryMarshal.Write(bytes, in value);
        return bytes;
    }

    public static T BytesToStruct<T>(ReadOnlySpan<byte> data) where T : unmanaged =>
        MemoryMarshal.Read<T>(data);
}
