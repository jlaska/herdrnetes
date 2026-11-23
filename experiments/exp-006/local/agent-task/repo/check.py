"""Progress meter, not a gate: run `python3 check.py` to see which functions pass.

Appends "<epoch> check k/12 passing=..." to progress.log next to this file
unless --nolog is given. Always exits 0, even if kata.py is broken.
"""
import sys

sys.dont_write_bytecode = True  # never reuse a stale .pyc of an edited kata.py
import os
import signal
import time

CASES = {
    "f01": [(("abc",), "cba"), (("",), ""), (("ab cd",), "dc ba")],
    "f02": [((0,), 0), ((123,), 6), ((9990,), 27)],
    "f03": [(("abba",), True), (("abca",), False), (("",), True), (("Aa",), False)],
    "f04": [((15,), "FizzBuzz"), ((9,), "Fizz"), ((10,), "Buzz"), ((7,), "7")],
    "f05": [(("",), 0), (("rhythm",), 0), (("Education",), 5), (("AEIOUaeiou",), 10)],
    "f06": [(("",), ""), (("aaabcc",), "3a1b2c"), (("abc",), "1a1b1c"), (("zzzzzzzzzzzz",), "12z")],
    "f07": [((12, 18), 6), ((7, 13), 1), ((0, 5), 5), ((0, 0), 0)],
    "f08": [((0,), 0), ((1,), 1), ((10,), 55), ((30,), 832040)],
    "f09": [(("hello wORLD",), "Hello World"), (("",), ""), (("a  b",), "A  B")],
    "f10": [(([],), []), (([3, 1, 3, 2, 1],), [3, 1, 2]), ((["b", "a", "b"],), ["b", "a"])],
    "f11": [((1,), "I"), ((4,), "IV"), ((14,), "XIV"), ((49,), "XLIX"), ((50,), "L")],
    "f12": [(([1, 2, 3, 4, 5], 2), [3, 4, 5, 1, 2]), (([1, 2, 3], 0), [1, 2, 3]), (([1, 2, 3], 4), [2, 3, 1]), (([], 5), [])],
}


def alarm(signum, frame):
    raise TimeoutError("case took more than 2 s")


def passes(fn):
    for args, want in CASES[fn]:
        signal.alarm(2)
        try:
            got = getattr(kata, fn)(*args)
            if got != want or type(got) is not type(want):
                return False
        except KeyboardInterrupt:
            raise
        except BaseException:  # NotImplementedError, TimeoutError, SystemExit, ...
            return False
        finally:
            signal.alarm(0)
    return True


signal.signal(signal.SIGALRM, alarm)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
signal.alarm(2)  # the import itself may hang
try:
    import kata
except KeyboardInterrupt:
    raise
except BaseException:  # SyntaxError, SystemExit, TimeoutError ...: every function FAILs
    kata = None
finally:
    signal.alarm(0)
done = []
for name in sorted(CASES):
    ok = kata is not None and passes(name)
    print(("PASS " if ok else "FAIL ") + name)
    if ok:
        done.append(name)
print("TOTAL %d/12" % len(done))
if "--nolog" not in sys.argv[1:]:
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "progress.log"), "a") as f:
        f.write("%.3f check %d/12 passing=%s\n" % (time.time(), len(done), ",".join(done)))
