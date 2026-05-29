using System.Runtime.CompilerServices;

namespace BPlusTranspiler;

public static class BPlusAssert
{
    public static void That(bool condition, string message = "", [CallerArgumentExpression(nameof(condition))] string expr = "")
    {
        if (!condition)
            throw new InvalidOperationException($"Assertion failed: {expr}{(message.Length > 0 ? $" — {message}" : "")}");
    }

    public static void NotNull<T>(T? value, [CallerArgumentExpression(nameof(value))] string expr = "")
        where T : class
    {
        if (value is null)
            throw new InvalidOperationException($"Expected non-null: {expr}");
    }
}
