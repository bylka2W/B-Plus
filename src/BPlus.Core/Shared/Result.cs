namespace BPlus.Core;

public readonly record struct Result<T, TError>
{
    public T? Value { get; }
    public TError? Error { get; }
    public bool IsOk { get; }
    public bool IsError => !IsOk;

    private Result(T value) { Value = value; Error = default; IsOk = true; }
    private Result(TError error) { Value = default; Error = error; IsOk = false; }

    public static Result<T, TError> Ok(T value) => new(value);
    public static Result<T, TError> Err(TError error) => new(error);

    public T Unwrap() => IsOk ? Value! : throw new InvalidOperationException($"Unwrapped error: {Error}");
    public T UnwrapOr(T fallback) => IsOk ? Value! : fallback;
    public TError UnwrapError() => IsError ? Error! : throw new InvalidOperationException("Expected error but got Ok");
}
