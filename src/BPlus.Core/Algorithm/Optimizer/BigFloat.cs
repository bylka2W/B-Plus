using System.Numerics;
using System.Text;

namespace BPlus.Core.Algorithm.Optimizer;

public class BigFloat
{
    readonly int _bitsPerLimb = 32;
    uint[] _limbs = Array.Empty<uint>();
    int _sign = 1;
    int _precision = 256;

    public int Sign => _sign;
    public int Precision => _precision;

    public BigFloat(int precision = 256)
    {
        _precision = precision;
        _limbs = new uint[(precision / _bitsPerLimb) + 1];
        _sign = 1;
    }

    BigFloat(uint[] limbs, int sign, int precision)
    {
        _limbs = limbs;
        _sign = sign;
        _precision = precision;
    }

    public static BigFloat FromInt(int value, int precision = 256)
    {
        var bf = new BigFloat(precision);
        bf._limbs[0] = (uint)Math.Abs(value);
        bf._sign = value < 0 ? -1 : 1;
        return bf;
    }

    public static BigFloat FromDouble(double value, int precision = 256)
    {
        if (value == 0) return new BigFloat(precision);
        var bf = new BigFloat(precision);
        bool negative = value < 0;
        value = Math.Abs(value);
        int exp = 0;
        while (value >= 2.0) { value /= 2.0; exp++; }
        while (value < 1.0) { value *= 2.0; exp--; }
        value -= 1.0;
        for (int i = 0; i < bf._limbs.Length && value > 0; i++)
        {
            value *= 4294967296.0;
            uint limb = (uint)value;
            bf._limbs[i] = limb;
            value -= limb;
        }
        bf._sign = negative ? -1 : 1;
        return bf;
    }

    public static BigFloat Pi(int precision = 256)
    {
        var pi = new BigFloat(precision);
        pi._limbs[0] = 0x243F6A88; pi._limbs[1] = 0x85A308D3; pi._limbs[2] = 0x13198A2E; pi._limbs[3] = 0x03707344;
        if (precision > 128) { pi._limbs[4] = 0x4F1C467F; pi._limbs[5] = 0x09C8B8A6; }
        return pi;
    }

    public static BigFloat E(int precision = 256)
    {
        var e = new BigFloat(precision);
        e._limbs[0] = 0x2B7E1516; e._limbs[1] = 0x28AED2A6; e._limbs[2] = 0xABF71588; e._limbs[3] = 0x09CF4F3C;
        if (precision > 128) { e._limbs[4] = 0xC9625654; }
        return e;
    }

    public static BigFloat Zero(int precision = 256) => new(precision);
    public static BigFloat One(int precision = 256) { var bf = new BigFloat(precision); bf._limbs[0] = 1; return bf; }

    public static BigFloat Add(BigFloat a, BigFloat b)
    {
        if (a._sign != b._sign) return SubAbs(a, b);
        var res = new uint[Math.Max(a._limbs.Length, b._limbs.Length) + 1];
        int carry = 0;
        int len = Math.Min(res.Length, Math.Max(a._limbs.Length, b._limbs.Length));
        for (int i = 0; i < len; i++)
        {
            ulong sum = (ulong)carry + (i < a._limbs.Length ? a._limbs[i] : 0) + (i < b._limbs.Length ? b._limbs[i] : 0);
            res[i] = (uint)sum;
            carry = (int)(sum >> 32);
        }
        if (carry > 0 && len < res.Length) res[len] = (uint)carry;
        return new BigFloat(Trim(res), a._sign, a._precision);
    }

    public static BigFloat Subtract(BigFloat a, BigFloat b)
    {
        if (a._sign != b._sign) return AddAbs(a, b);
        return SubAbs(a, b);
    }

    static BigFloat SubAbs(BigFloat a, BigFloat b)
    {
        int cmp = CompareAbs(a, b);
        if (cmp == 0) return new BigFloat(a._precision);
        BigFloat big = cmp > 0 ? a : b;
        BigFloat small = cmp > 0 ? b : a;
        int sign = cmp > 0 ? a._sign : -a._sign;
        var res = new uint[big._limbs.Length];
        int borrow = 0;
        for (int i = 0; i < res.Length; i++)
        {
            ulong diff = (ulong)(i < big._limbs.Length ? big._limbs[i] : 0)
                      - (i < small._limbs.Length ? small._limbs[i] : 0)
                      - (ulong)borrow;
            res[i] = (uint)diff;
            borrow = diff < 0 ? 1 : 0;
        }
        return new BigFloat(Trim(res), sign, a._precision);
    }

    static BigFloat AddAbs(BigFloat a, BigFloat b)
    {
        var res = new uint[Math.Max(a._limbs.Length, b._limbs.Length) + 1];
        int carry = 0;
        int len = Math.Min(res.Length, Math.Max(a._limbs.Length, b._limbs.Length));
        for (int i = 0; i < len; i++)
        {
            ulong sum = (ulong)carry
                     + (i < a._limbs.Length ? a._limbs[i] : 0)
                     + (i < b._limbs.Length ? b._limbs[i] : 0);
            res[i] = (uint)sum;
            carry = (int)(sum >> 32);
        }
        if (carry > 0 && len < res.Length) res[len] = (uint)carry;
        return new BigFloat(Trim(res), a._sign, a._precision);
    }

    public static BigFloat Multiply(BigFloat a, BigFloat b)
    {
        if (IsZero(a) || IsZero(b)) return new BigFloat(a._precision);
        var res = new uint[a._limbs.Length + b._limbs.Length];
        for (int i = 0; i < a._limbs.Length; i++)
        {
            ulong carry = 0;
            for (int j = 0; j < b._limbs.Length; j++)
            {
                ulong prod = (ulong)a._limbs[i] * b._limbs[j] + res[i + j] + carry;
                res[i + j] = (uint)prod;
                carry = prod >> 32;
            }
            res[i + b._limbs.Length] = (uint)carry;
        }
        return new BigFloat(Trim(res), (short)(a._sign * b._sign), a._precision);
    }

public static BigFloat Divide(BigFloat a, BigFloat b, int maxIter = 100)
    {
        if (IsZero(b)) throw new DivideByZeroException();
        if (IsZero(a)) return new BigFloat(a._precision);
        int cmp = CompareAbs(a, b);
        if (cmp < 0) return new BigFloat(a._precision);
        if (cmp == 0) { var r = new BigFloat(a._precision); r._limbs[0] = 1; return r; }
        var result = new BigFloat(a._precision);
        var rem = new BigFloat(a._precision);
        Array.Copy(a._limbs, rem._limbs, a._limbs.Length);
        rem._sign = a._sign;
        for (int iter = 0; iter < maxIter && !IsZero(rem); iter++)
        {
            int qDigit = 0;
            while (CompareAbs(rem, b) >= 0)
            {
                rem = Subtract(rem, b);
                qDigit++;
            }
            result._limbs[iter] = (uint)qDigit;
        }
        result._sign = (short)(a._sign * b._sign);
        return result;
    }

    public static BigFloat Sqrt(BigFloat a)
    {
        if (a._sign < 0) throw new InvalidOperationException("sqrt of negative");
        if (IsZero(a)) return a;
        var x = a;
        for (int i = 0; i < 20; i++)
        {
            x = Divide(Multiply(x, a), Add(Multiply(x, x), One(a._precision)));
            if (i > 0) x = Divide(Add(x, Divide(a, x)), Two(a._precision));
        }
        return x;
    }

    public static BigFloat Pow(BigFloat a, int exp)
    {
        if (exp == 0) return One(a._precision);
        if (exp == 1) return a;
        if (exp < 0) return Divide(One(a._precision), Pow(a, -exp));
        var result = One(a._precision);
        var base_ = a;
        while (exp > 0)
        {
            if ((exp & 1) == 1) result = Multiply(result, base_);
            base_ = Multiply(base_, base_);
            exp >>= 1;
        }
        return result;
    }

    static BigFloat Two(int p) { var t = One(p); t._limbs[0] = 2; return t; }

    public static bool operator ==(BigFloat a, BigFloat b) => CompareAbs(a, b) == 0 && a._sign == b._sign;
    public static bool operator !=(BigFloat a, BigFloat b) => !(a == b);
    public static bool operator <(BigFloat a, BigFloat b) => Compare(a, b) < 0;
    public static bool operator >(BigFloat a, BigFloat b) => Compare(a, b) > 0;
    public static bool operator <=(BigFloat a, BigFloat b) => Compare(a, b) <= 0;
    public static bool operator >=(BigFloat a, BigFloat b) => Compare(a, b) >= 0;
    public static BigFloat operator +(BigFloat a, BigFloat b) => Add(a, b);
    public static BigFloat operator -(BigFloat a, BigFloat b) => Subtract(a, b);
    public static BigFloat operator *(BigFloat a, BigFloat b) => Multiply(a, b);
    public static BigFloat operator /(BigFloat a, BigFloat b) => Divide(a, b);
    public static BigFloat operator -(BigFloat a) { var r = new BigFloat(a._precision); Array.Copy(a._limbs, r._limbs, a._limbs.Length); r._sign = -a._sign; return r; }

    static int Compare(BigFloat a, BigFloat b)
    {
        if (a._sign != b._sign) return a._sign > b._sign ? 1 : -1;
        int cmp = CompareAbs(a, b);
        return a._sign > 0 ? cmp : -cmp;
    }

    static int CompareAbs(BigFloat a, BigFloat b)
    {
        int la = LeadingNonZero(a._limbs, a._limbs.Length);
        int lb = LeadingNonZero(b._limbs, b._limbs.Length);
        if (la != lb) return la > lb ? 1 : -1;
        for (int i = la; i >= 0; i--)
        {
            if (a._limbs[i] != b._limbs[i])
                return a._limbs[i] > b._limbs[i] ? 1 : -1;
        }
        return 0;
    }

    static int LeadingNonZero(uint[] limbs, int len) { for (int i = len - 1; i >= 0; i--) if (limbs[i] != 0) return i; return -1; }
    static uint[] Trim(uint[] limbs) { int i = limbs.Length - 1; while (i > 0 && limbs[i] == 0) i--; var t = new uint[i + 1]; Array.Copy(limbs, t, i + 1); return t; }
    static bool IsZero(BigFloat a) => LeadingNonZero(a._limbs, a._limbs.Length) < 0;
    static void SubAbsInPlace(uint[] big, BigFloat small) { int borrow = 0; for (int i = 0; i < big.Length; i++) { ulong diff = (ulong)big[i] - (i < small._limbs.Length ? small._limbs[i] : 0) - (ulong)borrow; big[i] = (uint)diff; borrow = diff < 0 ? 1 : 0; } }

    public override string ToString()
    {
        if (IsZero(this)) return "0";
        var sb = new StringBuilder();
        if (_sign < 0) sb.Append('-');
        int lead = LeadingNonZero(_limbs, _limbs.Length);
        if (lead < 0) return "0";
        if (_limbs.Length > 0 && lead == 0) sb.Append(_limbs[0]);
        else { sb.AppendFormat("{0:X8}", _limbs[lead]); for (int i = lead - 1; i >= 0; i--) sb.AppendFormat("{0:X8}", _limbs[i]); }
        return sb.ToString();
    }

    public string ToDecimal(int decimals = 20)
    {
        if (IsZero(this)) return "0.0";
        var sb = new StringBuilder();
        if (_sign < 0) sb.Append('-');
        int lead = LeadingNonZero(_limbs, _limbs.Length);
        if (lead < 0) return "0.0";
        var rem = new uint[_limbs.Length]; Array.Copy(_limbs, rem, _limbs.Length);
        int intPart = 0;
        for (int i = lead; i >= 0; i--) { intPart = intPart * (int.MaxValue / 10) + (int)(_limbs[i] / 100000000); }
        sb.Append(intPart);
        sb.Append('.');
        for (int d = 0; d < decimals; d++)
        {
            ulong carry = 0;
            for (int i = rem.Length - 1; i >= 0; i--) { ulong t = ((ulong)rem[i] << 32) + carry; rem[i] = (uint)(t / 10); carry = t % 10; }
            sb.Append((char)('0' + (int)carry));
        }
        while (sb[sb.Length - 1] == '0') sb.Length--;
        return sb.ToString();
    }

    public override bool Equals(object? obj) => obj is BigFloat b && b == this;
    public override int GetHashCode() => _sign.GetHashCode() ^ _limbs[0].GetHashCode();
}