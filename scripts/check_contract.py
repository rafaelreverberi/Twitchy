#!/usr/bin/env python3
import json
from pathlib import Path
spec=json.loads(Path('docs/SERVER_API.json').read_text())
assert spec['openapi']=='3.1.0'
assert len(spec['paths'])==7
names=set(spec['components']['schemas'])
def visit(value):
    if isinstance(value,dict):
        if '$ref' in value: assert value['$ref'].split('/')[-1] in names
        for item in value.values():visit(item)
    elif isinstance(value,list):
        for item in value:visit(item)
visit(spec)
print('OpenAPI JSON parsed; all local schema references resolved.')
