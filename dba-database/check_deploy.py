#!/usr/bin/env python3
"""Static sanity checks for DBAdmin_HC_Deploy.sql (no SQL Server needed):
   every batch lexes cleanly, every nested string literal closes, parentheses balance
   at every nesting level, object names are unique, and every CREATE matches its @name."""
import re, sys

def lex(s):
    """returns (ok, strings[], paren_balance) ignoring comments; strings are unescaped contents"""
    i, n, depth, strs = 0, len(s), 0, []
    while i < n:
        c = s[i]
        if c in "Nn" and i + 1 < n and s[i+1] == "'" and (i == 0 or not (s[i-1].isalnum() or s[i-1] == '_')):
            i += 1; continue
        if c == "'":
            j, buf = i + 1, []
            while True:
                if j >= n: return False, strs, depth, 'unterminated string at %d' % i
                if s[j] == "'":
                    if j + 1 < n and s[j+1] == "'": buf.append("'"); j += 2; continue
                    break
                buf.append(s[j]); j += 1
            strs.append(''.join(buf)); i = j + 1; continue
        if c == '[':
            j = s.find(']', i)
            if j < 0: return False, strs, depth, 'unterminated [ at %d' % i
            i = j + 1; continue
        if s.startswith('--', i):
            j = s.find('\n', i); i = n if j < 0 else j; continue
        if s.startswith('/*', i):
            d, j = 1, i + 2
            while j < n and d:
                if s.startswith('/*', j): d += 1; j += 2
                elif s.startswith('*/', j): d -= 1; j += 2
                else: j += 1
            if d: return False, strs, depth, 'unterminated comment at %d' % i
            i = j; continue
        if c == '(': depth += 1
        if c == ')': depth -= 1
        i += 1
    return True, strs, depth, None

def main(path):
    txt = open(path, encoding='utf-8').read().replace('\r\n', '\n')
    batches = re.split(r'^GO[ \t]*$', txt, flags=re.M)
    errors, names, count = [], set(), 0
    for b in batches:
        ok, strs, depth, why = lex(b)
        if not ok or depth:
            errors.append(f'outer batch: {why or "paren balance %d" % depth}: {b.strip()[:80]!r}'); continue
        if 'EXEC dbo.HC_usp_deploy' not in b: continue
        count += 1
        name = re.search(r"@name = N'(\w+)'", b).group(1)
        if name in names: errors.append('duplicate name ' + name)
        names.add(name)
        m = re.search(r"@definition = N'", b)
        ok, d_strs, _, _ = lex(b[m.start() + len('@definition = '):])
        defs = [d_strs[0]]
        fb = re.search(r"@fallback_definition = N'", b)
        if fb:
            defs.append(lex(b[fb.start() + len('@fallback_definition = '):])[1][0])
        for k, d in enumerate(defs):
            if not re.match(r'CREATE OR ALTER (VIEW|FUNCTION|PROCEDURE) dbo\.' + name + r'\b', d):
                errors.append(f'{name}: definition {k} does not create dbo.{name}')
            ok, inner, depth, why = lex(d)
            if not ok or depth:
                errors.append(f'{name} def{k}: {why or "paren balance %d" % depth}')
                continue
            hm = re.search(r"DECLARE @hc_sql nvarchar\(max\) = N'", d)
            if hm:
                body = lex(d[hm.start() + len('DECLARE @hc_sql nvarchar(max) = '):])[1][0]
                ok, _, depth, why = lex(body)
                if not ok or depth:
                    errors.append(f'{name} dynamic body: {why or "paren balance %d" % depth}')
    print(f'{count} objects checked, {len(errors)} problems')
    for e in errors: print('  ' + e)
    return 1 if errors else 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
