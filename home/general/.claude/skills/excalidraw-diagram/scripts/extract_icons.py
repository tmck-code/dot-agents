'''Split the icon source scene (Excalidraw+ scene 2iWPETFJuU0) into references/icons/<name>.excalidraw + index.json.
Usage: python3 scripts/extract_icons.py <scene.json>  (fetch the scene with GET /api/v1/scenes/2iWPETFJuU0/content).
Cluster keys are the first 6 chars of the outermost groupId in that scene.'''
import json, collections, pathlib, sys

ICONS = {
    # name: (tags, [cluster key prefixes])
    'aws-ecs':            ('aws ecs container service orange tile',        ['raOQNU']),
    'aws-s3':             ('aws s3 bucket storage green tile',             ['JPs0Zc']),
    'dial-1':             ('rotary dial gauge knob position 1 of 5 low',   ['Gsv_Dk']),
    'dial-2':             ('rotary dial gauge knob position 2 of 5',       ['QZYbjk']),
    'dial-3':             ('rotary dial gauge knob position 3 of 5 mid',   ['wfRcpM']),
    'dial-4':             ('rotary dial gauge knob position 4 of 5',       ['XZTqhD']),
    'dial-5':             ('rotary dial gauge knob position 5 of 5 high',  ['Z4cNLj']),
    'alert-exclamation':  ('yellow square red exclamation warning',        ['Rn3UQr']),
    'alert-cross':        ('yellow square red cross error fail',           ['CtRXNV']),
    'alert-question':     ('yellow square red question unknown',           ['9OpTI1']),
    'alert-check':        ('yellow square green tick success',             ['nnZW9V']),
    'databricks':         ('databricks logo circle',                       ['0NrwTj']),
    'buildkite':          ('buildkite ci logo green',                      ['0_SSF3']),
    'docker':             ('docker whale logo labelled',                   ['RCuLLq']),
    'postgresql':         ('postgres postgresql elephant line drawing',    ['1XMbm-']),
    'github':             ('github octocat logo black',                    ['CGTCAE']),
    'github-dashboard':   ('github dashboard teal circle tile',            ['eLxnvw']),
    'elasticsearch':      ('elastic elasticsearch logo circle',            ['pq663k']),
    'delta-lake':         ('delta lake triangle logo blue',                ['wun3ln']),
    'database':           ('database cylinder generic store',              ['3CA_YO']),
    'json':               ('json braces black tile code',                  ['rvKvMr']),
    'person-lanyard':     ('stick figure person badge lanyard user',       ['Fh2q4w']),
    'person-hat':         ('stick figure person hat user',                 ['pJ9r4y']),
    'person-cap':         ('stick figure propeller cap smiling face filled', ['fGT8A-']),
    'person-cap-outline': ('stick figure propeller cap smiling face outline', ['_wogbV']),
    'tmck-code':              ('robot knight tmck-code personal avatar author self', ['0yGgfU']),
    'tmck-code-circle':       ('robot knight tmck-code personal avatar green circle', ['e5PEA7']),
    'tmck-code-square':       ('robot knight tmck-code personal avatar green square', ['5X-4gq']),
    'emoji-crying':       ('emoji crying sad tears',                       ['URmneu']),
    'emoji-shocked':      ('emoji shocked surprised tears',                ['w3S_ZV']),
    'emoji-shocked-red':  ('emoji shocked red eyes panic',                 ['Y0S-QI']),
    'cloud':              ('cloud outline black internet',                 ['a4ivja']),
    'cpu':                ('cpu chip processor compute',                   ['4hTR1l']),
    'status-check':       ('green circle tick ok pass',                    ['OfQpqu']),
    'status-cross':       ('red circle cross fail error',                  ['hCtlJK', 'o9a6Yx', 'gu9Ktb']),
    'status-info':        ('blue circle i info',                           ['sS0OD3']),
    'status-warning':     ('yellow triangle exclamation warning',          ['TM80Ni']),
    'status-question':    ('purple circle question unknown',               ['t4JYEv', '5HhAnz']),
    'phone':              ('mobile phone device',                          ['UpTEFa']),
    'laptop':             ('laptop computer device',                       ['IUkflQ']),
    'toggle-on':          ('toggle switch on blue',                        ['AZZpLn']),
    'toggle-off':         ('toggle switch off green',                      ['0NAmU5']),
    'switch-on':          ('pill switch on black labelled',                ['s_B9TW']),
    'switch-off':         ('pill switch off grey labelled',                ['P_RmFh']),
    'switch-on-square':   ('square switch on black labelled',              ['HD_1aa']),
    'switch-off-square':  ('square switch off grey labelled',              ['4Pv7Sy']),
    'check-filled':       ('black filled circle tick done',                ['y1l5fB']),
    'cross-outline':      ('black outline circle cross closed',            ['xhq8bl']),
}

CIRCLE = 182.0
CIRCLE_FILL = 0.68
# Logos wrapped in the same outlined white circle as elasticsearch/databricks: name -> element types to keep
CIRCLED = {'docker': {'image'}, 'postgresql': {'line'}, 'delta-lake': {'line'}}
PATH_TYPES = {'line', 'arrow', 'freedraw'}


def circled(name, shifted, gid):
    'Drop decoration, scale the logo to fit the circle and prepend the circle.'
    keep = [e for e in shifted if e['type'] in CIRCLED[name]]
    x0, y0, x1, y1 = bbox(keep)
    k = CIRCLE * CIRCLE_FILL / max(x1 - x0, y1 - y0)
    dx = (CIRCLE - (x1 - x0) * k) / 2; dy = (CIRCLE - (y1 - y0) * k) / 2
    for e in keep:
        e['x'] = round((e['x'] - x0) * k + dx, 2); e['y'] = round((e['y'] - y0) * k + dy, 2)
        e['width'] = round(e['width'] * k, 2); e['height'] = round(e['height'] * k, 2)
        if e['type'] in PATH_TYPES and e.get('points'):
            e['points'] = [[round(px * k, 2), round(py * k, 2)] for px, py in e['points']]
    circle = {'type': 'ellipse', 'id': f'{gid}-circle', 'x': 0, 'y': 0, 'width': CIRCLE, 'height': CIRCLE,
              'angle': 0, 'strokeColor': '#1e1e1e', 'backgroundColor': '#ffffff', 'fillStyle': 'solid',
              'strokeWidth': 1, 'strokeStyle': 'solid', 'roughness': 0, 'opacity': 100, 'groupIds': [gid],
              'frameId': None, 'roundness': {'type': 2}, 'seed': 1, 'version': 1, 'versionNonce': 1,
              'isDeleted': False, 'boundElements': None, 'updated': 1, 'link': None, 'locked': False}
    return [circle] + keep, 0, 0, CIRCLE, CIRCLE



def bounds(e):
    'Visual bounding box; line points may start at a negative offset from x,y.'
    if e['type'] in PATH_TYPES and e.get('points'):
        xs = [px for px, _ in e['points']]; ys = [py for _, py in e['points']]
        return e['x'] + min(xs), e['y'] + min(ys), e['x'] + max(xs), e['y'] + max(ys)
    return e['x'], e['y'], e['x'] + e['width'], e['y'] + e['height']


def bbox(els):
    bs = [bounds(e) for e in els]
    return min(b[0] for b in bs), min(b[1] for b in bs), max(b[2] for b in bs), max(b[3] for b in bs)


# Per-icon fixes applied after normalisation: element ids to drop, ids to move to the back (shadows draw first),
# and shadows to add as (main element id, dark fill, dx, dy).
FIXUPS = {
    'status-cross':    {'drop': ['gu9Ktb'], 'to_back': ['o9a6Yx']},
    'status-question': {'shadow': ('t4JYEv', '#7950f2', 7, 8)},
}


def fixup(name, shifted, gid):
    f = FIXUPS.get(name)
    if not f:
        return shifted
    drop = tuple(f.get('drop', ())); back = tuple(f.get('to_back', ()))
    shifted = [e for e in shifted if not e['id'].startswith(drop)]
    shifted = [e for e in shifted if e['id'].startswith(back)] + [e for e in shifted if not e['id'].startswith(back)]
    if 'shadow' not in f:
        return shifted
    main_id, fill, dx, dy = f['shadow']
    main = next(e for e in shifted if e['id'].startswith(main_id))
    shadow = dict(main, id=f'{gid}-shadow', x=main['x'] + dx, y=main['y'] + dy, backgroundColor=fill,
                  boundElements=None, groupIds=[gid])
    return [shadow] + shifted


scene = json.load(open(sys.argv[1]))
els = [e for e in scene['elements'] if not e.get('isDeleted') and e['type'] != 'frame']
clusters = collections.defaultdict(list)
for e in els:
    key = e['groupIds'][-1] if e.get('groupIds') else e['id']
    clusters[key[:6]].append(e)

out = pathlib.Path('references/icons')
index = {}
used = set()
for name, (tags, keys) in ICONS.items():
    members = [e for k in keys for e in clusters[k]]
    used.update(keys)
    x0, y0, x1, y1 = bbox(members)
    gid = f'icon-{name}'
    shifted = []
    for e in members:
        e = dict(e)
        e['x'] = round(e['x'] - x0, 2); e['y'] = round(e['y'] - y0, 2)
        e['frameId'] = None
        e['groupIds'] = [g for g in e.get('groupIds', []) if g not in keys and g[:6] not in keys] + [gid]
        for k in ('customData',):
            e.pop(k, None)
        shifted.append(e)
    shifted = fixup(name, shifted, gid)
    if name in CIRCLED:
        shifted, x0, y0, x1, y1 = circled(name, shifted, gid)
    files = {e['fileId']: scene['files'][e['fileId']] for e in shifted if e['type'] == 'image'}
    doc = {'type': 'excalidraw', 'version': 2, 'source': 'excalidraw-diagram-skill',
           'elements': shifted, 'appState': {'viewBackgroundColor': '#ffffff'}, 'files': files}
    (out / f'{name}.excalidraw').write_text(json.dumps(doc, separators=(',', ':')) + '\n')
    index[name] = {'width': round(x1 - x0), 'height': round(y1 - y0), 'tags': tags,
                   'elements': len(shifted), 'image': bool(files)}
(out / 'index.json').write_text(json.dumps(index, indent=1) + '\n')
unused = set(clusters) - used
print('icons', len(index), 'unused clusters', [(k, [e['type'] for e in clusters[k]], [e.get('text') for e in clusters[k] if e['type']=='text']) for k in unused])
