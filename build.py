"""Build the community installer from portable source and pinned upstream releases."""
from pathlib import Path
import argparse,hashlib,json,os,shutil,subprocess,urllib.request,zipfile

ROOT=Path(__file__).resolve().parent

def digest(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f,'sha256').hexdigest()

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--from-bundle',type=Path,help='Reuse matching payloads from an existing installer ZIP')
    ap.add_argument('--validate-only',action='store_true')
    args=ap.parse_args()
    if os.name!='nt':
        ap.error('Build on Windows x64 with .NET Framework and Python 3.11+.')
    lock=json.loads((ROOT/'bundle.lock.json').read_text(encoding='utf-8'))
    assert len(lock['apps'])==12 and lock['studioIncluded'] is False
    cache=ROOT/'cache';cache.mkdir(exist_ok=True)
    seed=zipfile.ZipFile(args.from_bundle) if args.from_bundle else None
    payloads=[]
    try:
        for app in lock['apps']:
            rel=app['payload'].replace('\\','/')
            assert rel.startswith('Payloads/') and '..' not in rel.split('/')
            target=cache/rel
            target.parent.mkdir(parents=True,exist_ok=True)
            if not target.exists():
                partial=target.with_suffix(target.suffix+'.partial')
                try:
                    if seed:
                        member='Craft-Suite-Windows-x64/InstallerData/'+rel
                        with seed.open(member) as source,partial.open('wb') as out:
                            shutil.copyfileobj(source,out)
                    else:
                        req=urllib.request.Request(app['downloadUrl'],headers={'User-Agent':'Craft-Suite-Community-Builder'})
                        with urllib.request.urlopen(req,timeout=90) as source,partial.open('wb') as out:
                            shutil.copyfileobj(source,out)
                    if partial.stat().st_size!=app['payloadBytes'] or digest(partial)!=app['sha256']:
                        raise ValueError('Payload integrity mismatch: '+app['name'])
                    partial.replace(target)
                finally:
                    if partial.exists(): partial.unlink()
            if target.stat().st_size!=app['payloadBytes'] or digest(target)!=app['sha256']:
                raise ValueError('Cached payload integrity mismatch: '+app['name'])
            payloads.append((rel,target))
    finally:
        if seed: seed.close()
    package=ROOT/'build/Craft-Suite-Windows-x64'
    if package.exists():
        raise FileExistsError('Build folder exists. Rename or remove build/ before a new build; files were preserved.')
    data=package/'InstallerData';data.mkdir(parents=True)
    compiler=Path(os.environ.get('WINDIR',r'C:\Windows'))/'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    subprocess.run([str(compiler),'/nologo','/target:winexe','/platform:x64','/optimize+','/debug-',
                    '/reference:System.Windows.Forms.dll','/win32manifest:'+str(ROOT/'src/CraftSetup.manifest'),
                    '/out:'+str(package/'Setup.exe'),str(ROOT/'src/CraftSetup.cs')],check=True)
    for name in ['Install.ps1','README.txt','APPS.txt','BUNDLE-LICENSE.txt']:
        shutil.copyfile(ROOT/'src'/name,data/name)
    shutil.copyfile(ROOT/'src/README.txt',package/'README.txt')
    shutil.copytree(ROOT/'third_party/Notices',data/'Notices')
    shutil.copytree(ROOT/'assets/AppIcons',data/'AppIcons')
    lock['supportFiles']=[{'path':p.relative_to(data).as_posix().replace('/','\\'),'sha256':digest(p)}
                          for p in sorted(data.rglob('*')) if p.is_file()]
    (data/'bundle.json').write_text(json.dumps(lock,indent=2),encoding='utf-8',newline='\n')
    if args.validate_only:
        print('Validated all 12 pinned payloads; compiled Setup.exe and prepared support files. No app installation or release ZIP created.')
        return
    for rel,target in payloads:
        p=data/rel;p.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(target,p)
    dist=ROOT/'dist';dist.mkdir(exist_ok=True)
    output=dist/('Craft-Suite-'+lock['installerVersion']+'-Windows-x64-Setup.zip')
    if output.exists(): raise FileExistsError('Release file already exists; it was preserved.')
    with zipfile.ZipFile(output,'w',allowZip64=True) as z:
        for p in sorted(package.rglob('*')):
            if p.is_file():
                info=zipfile.ZipInfo('Craft-Suite-Windows-x64/'+p.relative_to(package).as_posix(),date_time=(2026,10,10,0,0,0))
                info.create_system=0
                info.compress_type=zipfile.ZIP_STORED if p.suffix=='.zip' else zipfile.ZIP_DEFLATED
                with p.open('rb') as f,z.open(info,'w',force_zip64=True) as out: shutil.copyfileobj(f,out)
    with zipfile.ZipFile(output) as z:
        if z.testzip() is not None: raise ValueError('Output archive CRC failure')
    output.with_suffix('.sha256').write_text(digest(output)+'  '+output.name+'\n',encoding='utf-8',newline='\n')
    print(output)

if __name__=='__main__':main()
