using BPlus.Core.Parser;

namespace BPlus.Core;

public readonly record struct ParseResult<T>
{
    private readonly Result<T, ParseException> _inner;

    public T? Value => _inner.Value;
    public ParseException? Error => _inner.Error;
    public bool IsOk => _inner.IsOk;
    public bool IsError => _inner.IsError;

    private ParseResult(Result<T, ParseException> inner) => _inner = inner;

    public static ParseResult<T> Ok(T value) => new(Result<T, ParseException>.Ok(value));
    public static ParseResult<T> Err(ParseException error) => new(Result<T, ParseException>.Err(error));

    public T Unwrap() => _inner.Unwrap();
    public T UnwrapOr(T fallback) => _inner.UnwrapOr(fallback);
    public ParseException UnwrapError() => _inner.UnwrapError();
}
