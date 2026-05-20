using System.Text;
using System.Text.RegularExpressions;

namespace BPlusTranspiler.Optimizer;

public class SymbolicPreprocessor
{
    public string Simplify(string expr)
    {
        var s = expr.Trim();
        s = SimplifyPowers(s);
        s = SimplifyProducts(s);
        s = SimplifyTrigIdentities(s);
        s = SimplifyFractions(s);
        s = SimplifyConstants(s);
        s = SimplifyParens(s);
        return s;
    }

    string SimplifyTrigIdentities(string s)
    {
        s = Regex.Replace(s, @"sin\s*\(\s*0\s*\)\s*", "0");
        s = Regex.Replace(s, @"cos\s*\(\s*0\s*\)\s*", "1");
        s = Regex.Replace(s, @"sin\s*\(\s*0\s*\)\s*", "0");
        s = Regex.Replace(s, @"tan\s*\(\s*0\s*\)\s*", "0");
        s = Regex.Replace(s, @"sin\s*\(\s*PI\s*\)\s*", "0", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"cos\s*\(\s*PI\s*\)\s*", "-1", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"sin\s*\(\s*PI\s*/\s*2\s*\)\s*", "1", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"cos\s*\(\s*PI\s*/\s*2\s*\)\s*", "0", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"sin\s*\(\s*x\s*\)\s*\^\s*2\s*\+\s*cos\s*\(\s*x\s*\)\s*\^\s*2\s*", "1", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"1\s*-\s*sin\s*\(\s*x\s*\)\s*\^\s*2\s*", "cos(x)^2", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"1\s*-\s*cos\s*\(\s*x\s*\)\s*\^\s*2\s*", "sin(x)^2", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"sin\s*\(\s*2\s*\*\s*x\s*\)\s*", "2*sin(x)*cos(x)", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"cos\s*\(\s*2\s*\*\s*x\s*\)\s*", "cos(x)^2 - sin(x)^2", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"tan\s*\(\s*x\s*\)\s*/\s*sin\s*\(\s*x\s*\)\s*", "1/cos(x)", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"sin\s*\(\s*-x\s*\)\s*", "-sin(x)", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"cos\s*\(\s*-x\s*\)\s*", "cos(x)", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"tan\s*\(\s*-x\s*\)\s*", "-tan(x)", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"sin\s*\(\s*x\s*\)\s*\*\s*sin\s*\(\s*x\s*\)\s*", "sin(x)^2", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"cos\s*\(\s*x\s*\)\s*\*\s*cos\s*\(\s*x\s*\)\s*", "cos(x)^2", RegexOptions.IgnoreCase);
        return s;
    }

    string SimplifyProducts(string s)
    {
        s = Regex.Replace(s, @"\b0\s*\*\s*[^=()\n]+", "0");
        s = Regex.Replace(s, @"[^=()\n]+\s*\*\s*0\b", "0");
        s = Regex.Replace(s, @"\b1\s*\*\s*([a-zA-Z_]\w*)", "$1");
        s = Regex.Replace(s, @"([a-zA-Z_]\w*)\s*\*\s*1\b", "$1");
        s = Regex.Replace(s, @"a\s*\*\s*a\b", "a^2");
        s = Regex.Replace(s, @"a\s*\^\s*2\s*\*\s*a\s*\^\s*2", "a^4");
        s = Regex.Replace(s, @"a\s*\^\s*2\s*\*\s*a", "a^3");
        s = Regex.Replace(s, @"a\s*\*\s*a\s*\^\s*2", "a^3");
        s = Regex.Replace(s, @"(-?\d+)\s*\*\s*\1\b", "$1^2");
        s = Regex.Replace(s, @"(-?\d+)\s*\^\s*2\s*\*\s*(-?\d+)\s*\^\s*2\b", m => {
            var a = double.Parse(m.Groups[1].Value);
            var b = double.Parse(m.Groups[2].Value);
            return (a*a*b*b).ToString();
        });
        s = Regex.Replace(s, @"(-?\d+)\s*\^\s*2\s*\*\s*(-?\d+)\b", m => {
            var a = double.Parse(m.Groups[1].Value);
            var b = double.Parse(m.Groups[2].Value);
            return (a*a*b).ToString();
        });
        s = Regex.Replace(s, @"(-?\d+)\s*\*\s*(-?\d+)\s*\^\s*2\b", m => {
            var a = double.Parse(m.Groups[1].Value);
            var b = double.Parse(m.Groups[2].Value);
            return (a*b*b).ToString();
        });
        return s;
    }

    string SimplifyPowers(string s)
    {
        s = Regex.Replace(s, @"(-?\d+)\s*\^\s*0\b", "1");
        s = Regex.Replace(s, @"(-?\d+)\s*\^\s*1\b", "$1");
        s = Regex.Replace(s, @"a\s*\^\s*1\b", "a");
        s = Regex.Replace(s, @"a\s*\^\s*0\b", "1");
        s = Regex.Replace(s, @"a\s*\^\s*2\s*/\s*a\s*\^\s*2\b", "1");
        s = Regex.Replace(s, @"a\s*\^\s*3\s*/\s*a\s*\^\s*2\b", "a");
        s = Regex.Replace(s, @"\(([^)]+)\)\s*\^\s*2\b", m => {
            var inner = m.Groups[1].Value;
            if (inner.Contains("+")) inner = $"({inner})";
            return inner + "*" + inner;
        });
        s = Regex.Replace(s, @"sqrt\s*\(\s*a\s*\^\s*2\s*\)\s*", "abs(a)", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"exp\s*\(\s*0\s*\)\s*", "1", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"log\s*\(\s*1\s*\)\s*", "0", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"log\s*\(\s*e\s*\)\s*", "1", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"a\s*\^\s*(-?\d+)\s*\*\s*a\s*\^\s*(-?\d+)\b", m => {
            var e1 = int.Parse(m.Groups[1].Value);
            var e2 = int.Parse(m.Groups[2].Value);
            return $"a^({e1+e2})";
        });
        s = Regex.Replace(s, @"\(a\+b\)\^2\b", "a^2 + 2*a*b + b^2");
        s = Regex.Replace(s, @"\(a-b\)\^2\b", "a^2 - 2*a*b + b^2");
        s = Regex.Replace(s, @"\(a\+b\)\s*\^\s*2\b", "a^2 + 2*a*b + b^2");
        s = Regex.Replace(s, @"\(a-b\)\s*\^\s*2\b", "a^2 - 2*a*b + b^2");
        return s;
    }

    string SimplifyFractions(string s)
    {
        s = Regex.Replace(s, @"\b0\s*/\s*[^=()\n]+\b", "0");
        s = Regex.Replace(s, @"[^=()\n]+\s*/\s*1\b", "$&");
        s = Regex.Replace(s, @"(-?\d+)\s*/\s*\1\b", "1");
        s = Regex.Replace(s, @"(-?\d+)\s*/\s*(-?\d+)\s*/\s*(-?\d+)\b", m => {
            var a = double.Parse(m.Groups[1].Value);
            var b = double.Parse(m.Groups[2].Value);
            var c = double.Parse(m.Groups[3].Value);
            return (a / (b / c)).ToString("G");
        });
        s = Regex.Replace(s, @"a\s*/\s*a\b", "1");
        s = Regex.Replace(s, @"(-?\d+)\s*/\s*(-?\d+)\b", m => {
            var a = double.Parse(m.Groups[1].Value);
            var b = double.Parse(m.Groups[2].Value);
            if (b != 0 && a % b == 0) return (a / b).ToString();
            return m.Value;
        });
        return s;
    }

    string SimplifyConstants(string s)
    {
        s = Regex.Replace(s, @"\bPI\s*\b", "3.141592653589793", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"\bE\s*(?![a-zA-Z])", "2.718281828459045", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"3\.141592653589793\s*\+\s*0\b", "3.141592653589793");
        s = Regex.Replace(s, @"0\s*\+\s*3\.141592653589793\b", "3.141592653589793");
        s = Regex.Replace(s, @"3\.141592653589793\s*\*\s*1\b", "3.141592653589793");
        s = Regex.Replace(s, @"1\s*\*\s*3\.141592653589793\b", "3.141592653589793");
        s = Regex.Replace(s, @"2\.718281828459045\s*\+\s*0\b", "2.718281828459045");
        s = Regex.Replace(s, @"0\s*\+\s*2\.718281828459045\b", "2.718281828459045");
        s = Regex.Replace(s, @"2\.718281828459045\s*\*\s*1\b", "2.718281828459045");
        s = Regex.Replace(s, @"1\s*\*\s*2\.718281828459045\b", "2.718281828459045");
        s = Regex.Replace(s, @"3\.141592653589793\s*/\s*1\b", "3.141592653589793");
        s = Regex.Replace(s, @"2\.718281828459045\s*/\s*1\b", "2.718281828459045");
        s = Regex.Replace(s, @"(-?\d+\.?\d*)\s*\+\s*0\b", "$1");
        s = Regex.Replace(s, @"0\s*\+\s*(-?\d+\.?\d*)\b", "$1");
        s = Regex.Replace(s, @"(-?\d+\.?\d*)\s*\*\s*1\b", "$1");
        s = Regex.Replace(s, @"1\s*\*\s*(-?\d+\.?\d*)\b", "$1");
        s = Regex.Replace(s, @"(-?\d+\.?\d*)\s*-\s*0\b", "$1");
        s = Regex.Replace(s, @"0\s*-\s*(-?\d+\.?\d*)\b", m => "-" + m.Groups[1].Value);
        s = Regex.Replace(s, @"sqrt\s*\(\s*4\.0\s*\)\s*", "2");
        s = Regex.Replace(s, @"sqrt\s*\(\s*9\.0\s*\)\s*", "3");
        s = Regex.Replace(s, @"sqrt\s*\(\s*16\.0\s*\)\s*", "4");
        s = Regex.Replace(s, @"sqrt\s*\(\s*25\.0\s*\)\s*", "5");
        s = Regex.Replace(s, @"sqrt\s*\(\s*100\.0\s*\)\s*", "10");
        return s;
    }

    string SimplifyParens(string s)
    {
        s = Regex.Replace(s, @"\(\s*0\s*\)\s*\+", "0 +");
        s = Regex.Replace(s, @"\+\s*\(\s*0\s*\)", "+ 0");
        s = Regex.Replace(s, @"\(\s*0\s*\)\s*-", "0 -");
        s = Regex.Replace(s, @"\(\s*0\s*\)\s*\*", "0 *");
        s = Regex.Replace(s, @"\(\s*1\s*\)\s*\*", "1 *");
        s = Regex.Replace(s, @"\(\s*([^)]+)\)\s*\^\s*1\b", "$1");
        return s;
    }

    public bool CanEvaluate(string expr)
    {
        var s = Simplify(expr);
        return !Regex.IsMatch(s, @"[a-zA-Z_]");
    }

    public double Evaluate(string expr)
    {
        var s = Simplify(expr);
        if (double.TryParse(s, out var v)) return v;
        try { return double.Parse(s); } catch { return double.NaN; }
    }
}