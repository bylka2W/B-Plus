using System;
using System.Runtime.InteropServices;

namespace BPlusTranspiler.Runtime;

public class ExecutableMemory : IDisposable
{
    private IntPtr _address;
    private readonly int _size;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr VirtualAlloc(IntPtr lpAddress, uint dwSize, uint flAllocationType, uint flProtect);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool VirtualFree(IntPtr lpAddress, uint dwSize, uint dwFreeType);

    private const uint PAGE_RWX = 0x40;
    private const uint MEM_COMMIT = 0x1000;
    private const uint MEM_RESERVE = 0x2000;
    private const uint PAGE_EXECUTE_READWRITE = 0x40;
    private const uint MEM_RELEASE = 0x8000;

    public IntPtr Address => _address;
    public int Size => _size;

    public ExecutableMemory(int byteCount)
    {
        _size = byteCount;
        int pageSize = 4096;
        int totalSize = ((byteCount + pageSize - 1) / pageSize) * pageSize;

        _address = VirtualAlloc(IntPtr.Zero, (uint)totalSize, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
        if (_address == IntPtr.Zero)
            throw new InvalidOperationException($"VirtualAlloc failed: {Marshal.GetLastWin32Error()}");
    }

    public static ExecutableMemory WithData(int codeSize, int dataSizeBytes)
    {
        int pageSize = 4096;
        int codePages = (codeSize + pageSize - 1) / pageSize;
        int dataPages = (dataSizeBytes + pageSize - 1) / pageSize;
        int totalSize = (codePages + dataPages) * pageSize;

        IntPtr addr = VirtualAlloc(IntPtr.Zero, (uint)totalSize, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
        if (addr == IntPtr.Zero)
            throw new InvalidOperationException($"VirtualAlloc failed: {Marshal.GetLastWin32Error()}");

        var mem = new ExecutableMemory(totalSize);
        mem._SetAddress(addr);
        return mem;
    }

    internal void _SetAddress(IntPtr addr) { _address = addr; }

    public void Write(byte[] data, int offset = 0)
    {
        if (offset + data.Length > _size)
            throw new ArgumentException($"Data too large: {offset + data.Length} > {_size}");
        Marshal.Copy(data, 0, _address + offset, data.Length);
    }

    public void InitArray(int offset, int count)
    {
        for (int i = 0; i < count && offset + i * 8 < _size; i++)
            Marshal.WriteInt64(_address + offset + i * 8, i);
    }

    public void WriteByte(int offset, byte value)
    {
        Marshal.WriteByte(_address + offset, value);
    }

    public T GetDelegate<T>() where T : Delegate
    {
        return Marshal.GetDelegateForFunctionPointer<T>(_address);
    }

    public IntPtr GetPointer() => _address;

    public void Dispose()
    {
        if (_address != IntPtr.Zero)
        {
            VirtualFree(_address, 0, MEM_RELEASE);
            _address = IntPtr.Zero;
        }
    }

    public static ExecutableMemory FromArray(byte[] code)
    {
        var mem = new ExecutableMemory(code.Length);
        mem.Write(code);
        return mem;
    }

    public static IntPtr AllocatePageAligned(int size, int alignment = 4096)
    {
        int totalSize = ((size + alignment - 1) / alignment) * alignment;
        return VirtualAlloc(IntPtr.Zero, (uint)totalSize, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    }
}

public static class X64Emitter
{
    public static ExecutableMemory Compile(byte[] code)
    {
        return ExecutableMemory.FromArray(code);
    }

    public static ExecutableMemory Compile(List<byte> code)
    {
        return ExecutableMemory.FromArray(code.ToArray());
    }

    public static ExecutableMemory Allocate(int size)
    {
        return new ExecutableMemory(size);
    }
}