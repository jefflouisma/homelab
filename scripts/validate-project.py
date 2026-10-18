import ast
from pathlib import Path
import subprocess

import yaml


ROOT = Path(__file__).resolve().parents[1]


def check_resources(documents, label):
    seen = set()
    for document in documents:
        if not isinstance(document, dict) or 'apiVersion' not in document:
            continue
        metadata = document['metadata']
        identity = (document['apiVersion'].split('/')[0], document['kind'], metadata.get('namespace', ''), metadata['name'])
        if identity in seen:
            raise ValueError(f'{label}: duplicate resource {identity}')
        seen.add(identity)
    print(f'PASS {label}: {len(seen)} unique resources')


def main():
    tracked = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT).decode().split('\0')
    paths = sorted({ROOT / name for name in tracked if name and (ROOT / name).is_file()})
    for path in paths:
        relative = path.relative_to(ROOT)
        if str(relative).startswith('fenrir/images/wolf/'):
            continue
        if path.suffix in {'.yaml', '.yml'}:
            list(yaml.safe_load_all(path.read_text()))
        elif path.suffix == '.sh':
            subprocess.run(['bash', '-n', str(path)], check=True)
        elif path.suffix == '.py':
            ast.parse(path.read_text(), filename=str(relative))
    print('PASS first-party YAML, shell and Python syntax')
    for directory in ['barleta/apps', 'barleta/apps/analytics']:
        rendered = subprocess.check_output(['kubectl', 'kustomize', directory], cwd=ROOT, text=True)
        check_resources(yaml.safe_load_all(rendered), directory)
    for directory in ['barleta/apps/identity', 'barleta/apps/house']:
        documents = [document for path in (ROOT / directory).rglob('*.yaml') for document in yaml.safe_load_all(path.read_text())]
        check_resources(documents, directory)


if __name__ == '__main__':
    main()
