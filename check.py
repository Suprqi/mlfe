#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
مَلَفّي — فاحص سلامة الملف
الاستخدام:  python3 check.py malaffi-v2.5.html
يفحص أخطاءً وقعت فعلًا في هذا المشروع وصُحّحت، ويمنع تكرارها.
"""
import re, sys, collections

def main(path):
    s = open(path, encoding='utf-8').read()
    js = '\n'.join(m.group(1) for m in re.finditer(r'<script[^>]*>(.*?)</script>', s, re.S))
    html = re.sub(r'<script[^>]*>.*?</script>', '', s, flags=re.S)
    css = '\n'.join(m.group(1) for m in re.finditer(r'<style[^>]*>(.*?)</style>', s, re.S))
    fails = []

    def ok(cond, label, detail=''):
        print(('  ✅ ' if cond else '  ❌ ') + label + (('  → ' + detail) if (detail and not cond) else ''))
        if not cond: fails.append(label)

    print('\n════ فاحص مَلَفّي ════\n')
    print(f'  الحجم: {len(s.encode()):,} بايت  ·  الأسطر: {s.count(chr(10)):,}\n')

    # 1) استخدام ثابت قبل تعريفه (TDZ) — أسقط التطبيق سابقًا
    decls = [(m.group(2), m.start(), m.end())
             for m in re.finditer(r'(?m)^(const|let)\s+([A-Za-z_$][\w$]*)\s*=', js)]
    def stmt_end(i):
        d = 0; q = None; j = i
        while j < len(js):
            c = js[j]
            if q:
                if c == '\\': j += 2; continue
                if c == q: q = None
            elif c in '"\'`': q = c
            elif c in '([{': d += 1
            elif c in ')]}': d -= 1
            elif c == ';' and d <= 0: return j
            j += 1
        return len(js)
    tdz = []
    for name, start, eq in decls:
        init = js[eq:stmt_end(eq)]
        fn = re.search(r'(=>|function)', init)
        for other, opos, _ in decls:
            if opos <= start: continue
            m = re.search(r'\b' + re.escape(other) + r'\b', init)
            if m and not (fn and m.start() > fn.start()):
                tdz.append(f'{name} ← {other}')
    ok(not tdz, 'لا استخدام لثابت قبل تعريفه (TDZ)', '، '.join(tdz[:3]))

    # 2) تهريب النصوص
    esc = re.search(r'function esc\(([^)]*)\)\{(.*?)\n', js)
    body = esc.group(2) if esc else ''
    ok(all(x in body for x in ['&amp;', '&lt;', '&gt;', '&quot;', '&#39;']),
       'esc() يهرّب & < > " \' ')

    # 3) $ لا تُستعمل كمحدّد CSS
    bad = re.findall(r"\$\('[#.][^']*'\)", js)
    ok(not bad, '$() لا تُستعمل بمحدّد CSS', '، '.join(bad[:3]))

    # 4) مجموع الأوزان = 100
    w = re.search(r'const PF_STD_W=(\{[^}]*\})', js)
    total = sum(int(x) for x in re.findall(r':(\d+)', w.group(1))) if w else 0
    n = len(re.findall(r':(\d+)', w.group(1))) if w else 0
    ok(total == 100 and n == 11, f'الأوزان: {n} عنصرًا ومجموعها {total}٪', 'يجب 11 عنصرًا و100٪')

    # 5) تطابق مفاتيح الأوزان والسجلات
    ex = re.search(r'const PF_STD_EX=\{([\s\S]*?)\n\};', js)
    kw = re.findall(r"'([^']+)':\d+", w.group(1)) if w else []
    ke = re.findall(r"(?m)^'([^']+)':\[", ex.group(1)) if ex else []
    ok(kw == ke and len(ke) == 11, 'مفاتيح الأوزان = مفاتيح السجلات (11)')

    # 6) دوال ومُعرّفات مكررة
    dup_fn = {k: v for k, v in collections.Counter(
        re.findall(r'\bfunction\s+(\w+)\s*\(', js)).items() if v > 1}
    ok(not dup_fn, 'لا دوال مكررة', str(dup_fn))
    dup_id = {k: v for k, v in collections.Counter(
        re.findall(r'\bid="([^"${]+)"', html)).items() if v > 1}
    ok(not dup_id, 'لا مُعرّفات HTML مكررة', str(dup_id))

    # 7) معالجات الأحداث تشير لدوال معرّفة
    defs = set(re.findall(r'\bfunction\s+([A-Za-z_$][\w$]*)\s*\(', js))
    builtin = {'getElementById','print','click','filter','split','trim','toggle',
               'stopPropagation','Number','String','if','void','return','typeof','parseInt'}
    calls = set()
    for m in re.finditer(r'\bon\w+\s*=\s*"([^"]*)"', html):
        calls |= set(re.findall(r'([A-Za-z_$][\w$]*)\s*\(', m.group(1)))
    miss = sorted(c for c in calls if c not in defs and c not in builtin)
    ok(not miss, 'كل معالجات الأحداث معرّفة', '، '.join(miss[:5]))

    # 8) مقاسات الملف المولَّد نسبية لا بكسلية
    pf = re.search(r'/\* ===== ملف الأداء الوظيفي(.*?)/\* --- الملحق', css, re.S)
    blk = pf.group(1) if pf else ''
    px = re.findall(r'font-size:\s*\d+(?:\.\d+)?px', blk)
    ok('container-type' in css and not px, 'مقاسات الملف المولَّد بوحدات نسبية (cqw)')
    ok('@supports not (container-type' in css, 'يوجد بديل للأجهزة القديمة')

    # 9) ضغط الصور وتحذير الامتلاء
    ok('shrinkImage' in js, 'ضغط الصور مفعّل قبل التخزين')
    ok('مساحة التخزين ممتلئة' in js, 'تحذير امتلاء التخزين موجود')

    # 10) بقايا تصحيح
    ok('console.log' not in js and 'debugger' not in js, 'لا console.log ولا debugger')


    # 11) كلمات مفتاحية يتيمة (لا يمسكها node --check)
    orphan = []
    for pat, lbl in [(r'\basync\s+/\*', 'async قبل تعليق'),
                     (r'\bfunction\s+/\*', 'function قبل تعليق'),
                     (r'(?m)^\s*async\s*$', 'async وحدها'),
                     (r'(?m)^\s*(?:const|let|var)\s*$', 'تعريف بلا اسم')]:
        if re.search(pat, js):
            orphan.append(lbl)
    ok(not orphan, 'لا كلمات مفتاحية يتيمة', '، '.join(orphan))


    # ── توازن وسوم HTML الأساسية ──
    # إدراج CSS قبل </head> بدل </style> يبتلع الوسم فيتوقف كل التنسيق
    # ويظهر الكود نصًّا في الوثائق.
    for _t in ('html', 'head', 'body', 'style', 'script'):
        _o = len(re.findall(r'<' + _t + r'[\s>]', s))
        _c = len(re.findall(r'</' + _t + r'>', s))
        ok(_o == _c, 'وسم <%s> متزن' % _t, '%d فتح / %d إغلاق' % (_o, _c))

    print('\n' + ('  ✅ الملف سليم\n' if not fails
                  else f'  ❌ {len(fails)} فحصًا فشل — عالجها قبل النشر\n'))
    return 1 if fails else 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else 'malaffi-v2.5.html'))
