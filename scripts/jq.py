#!/usr/bin/env python3
"""In giá trị theo đường dẫn dotted từ 1 file JSON. Dùng: jq.py <file> <a.b.0.c>"""
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    for k in sys.argv[2].split('.'):
        d = d[int(k)] if k.isdigit() else d[k]
    print(d if isinstance(d,(str,int,float,bool)) else json.dumps(d,ensure_ascii=False))
except Exception as e:
    print('')
