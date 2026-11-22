"""Reference implementations of f01..f12 (never copied into the agent's repo)."""


def f01(s):
    return s[::-1]


def f02(n):
    return sum(int(c) for c in str(n))


def f03(s):
    return s == s[::-1]


def f04(n):
    return "FizzBuzz" if n % 15 == 0 else "Fizz" if n % 3 == 0 else "Buzz" if n % 5 == 0 else str(n)


def f05(s):
    return sum(1 for c in s if c in "aeiouAEIOU")


def f06(s):
    out, i = [], 0
    while i < len(s):
        j = i
        while j < len(s) and s[j] == s[i]:
            j += 1
        out.append(str(j - i) + s[i])
        i = j
    return "".join(out)


def f07(a, b):
    while b:
        a, b = b, a % b
    return a


def f08(n):
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a


def f09(s):
    return " ".join(w[:1].upper() + w[1:].lower() for w in s.split(" "))


def f10(xs):
    out = []
    for x in xs:
        if x not in out:
            out.append(x)
    return out


def f11(n):
    out = ""
    for v, r in ((50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")):
        while n >= v:
            out += r
            n -= v
    return out


def f12(xs, k):
    if not xs:
        return []
    k %= len(xs)
    return xs[k:] + xs[:k]
