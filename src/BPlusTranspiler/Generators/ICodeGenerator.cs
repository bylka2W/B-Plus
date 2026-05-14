using System.Runtime.InteropServices;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Optimizer;

namespace BPlusTranspiler.Generators;

public interface ICodeGenerator
{
    Dictionary<string, string> GenerateFiles(ProgramNode program);
    string GetFileExtension();
    string GetLanguageName();
}

// Zig: IAllocator — explicit allocator interface for codegen
public interface IAllocator
{
    IntPtr Alloc(int size, int alignment);
    void Free(IntPtr ptr);
    string Name { get; }
}

public class ArenaAllocator : IAllocator
{
    private List<IntPtr> _blocks = new();
    private int _currentOffset;
    private int _blockSize;
    public string Name => "arena";

    public ArenaAllocator(int blockSize = 65536) { _blockSize = blockSize; }

    public IntPtr Alloc(int size, int alignment)
    {
        _currentOffset = (_currentOffset + alignment - 1) & ~(alignment - 1);
        if (_currentOffset + size > _blockSize)
        {
            _blocks.Add(Marshal.AllocHGlobal(_blockSize));
            _currentOffset = 0;
        }
        var ptr = _blocks.Last() + _currentOffset;
        _currentOffset += size;
        return ptr;
    }

    public void Free(IntPtr ptr) { }
}

public class PoolAllocator : IAllocator
{
    private System.Collections.Concurrent.ConcurrentQueue<IntPtr> _pool = new();
    private int _slotSize;
    public string Name => "pool";

    public PoolAllocator(int slotSize = 64) { _slotSize = slotSize; }

    public IntPtr Alloc(int size, int alignment)
    {
        if (_pool.TryDequeue(out var ptr)) return ptr;
        return Marshal.AllocHGlobal(Math.Max(size, _slotSize));
    }

    public void Free(IntPtr ptr) { _pool.Enqueue(ptr); }
}

public class StackAllocator : IAllocator
{
    private IntPtr _base;
    private int _offset;
    private int _capacity;
    public string Name => "stack";

    public StackAllocator(int capacity = 4096)
    {
        _capacity = capacity;
        _base = Marshal.AllocHGlobal(capacity);
    }

    public IntPtr Alloc(int size, int alignment)
    {
        _offset = (_offset + alignment - 1) & ~(alignment - 1);
        if (_offset + size > _capacity) throw new OutOfMemoryException("Stack allocator overflow");
        var ptr = _base + _offset;
        _offset += size;
        return ptr;
    }

    public void Free(IntPtr ptr) { }
    public void Reset() { _offset = 0; }
}
