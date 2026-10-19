"""Isolated real control server -> ticket Host -> official Moonlight test.
No production connection. Random credentials/tokens stay in memory only.
"""
import json, os, pathlib, re, secrets, socket, subprocess, tempfile, time, urllib.request, sys

from mode_wire_client import flow_test, listening_pids

ROOT = pathlib.Path(__file__).resolve().parents[1]
def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0)); return sock.getsockname()[1]

def main():
    port, host_port = free_port(), free_port()
    base = f'http://127.0.0.1:{port}'
    wsl_dir = '/tmp/yl-quality-' + secrets.token_hex(10)
    subprocess.run(['wsl','-d','Ubuntu','--','mkdir','-m','700',wsl_dir],check=True,stdout=subprocess.DEVNULL)
    server = subprocess.Popen(['wsl','-d','Ubuntu','--','env',f'YUANLIAN_BIND=127.0.0.1:{port}',f'YUANLIAN_DB={wsl_dir}/test.db',
        'python3','-c',"import os;open(os.environ['YUANLIAN_DB']+'.pid','w').write(str(os.getpid()));os.execv('/home/ubuntu/yl-server-build/target/release/yl-server',['yl-server'])"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    token = None
    def api(method,path,body=None):
        headers={'Content-Type':'application/json'}
        if token: headers['Authorization']='Bearer '+token
        request=urllib.request.Request(base+path,data=None if body is None else json.dumps(body).encode(),headers=headers,method=method)
        with urllib.request.urlopen(request,timeout=10) as response:return json.load(response)
    host=None; viewer=None; host_log=None; viewer_log=None
    with tempfile.TemporaryDirectory(prefix='yl-quality-test-') as temp:
        temp=pathlib.Path(temp)
        try:
            for _ in range(100):
                try: api('GET','/health'); break
                except OSError:time.sleep(.15)
            password=secrets.token_urlsafe(24)
            api('POST','/api/v1/setup',{'username':'testadmin','password':password})
            token=api('POST','/api/v1/auth/login',{'username':'testadmin','password':password})['token']
            binary=ROOT/'target/release/yl-host.exe'
            identity=subprocess.run([str(binary),'--identity-dir',str(temp/'identity'),'--print-identity'],capture_output=True,check=True).stdout.decode('utf-8')
            device_id=re.search(r'yl-[a-f0-9]+',identity).group()
            fingerprint=re.search(r'TLS SHA-256[^:]*:\s*([a-fA-F0-9:]{64,95})',identity).group(1)
            registered=api('POST','/api/v1/devices',{'name':'Isolated quality Host','platform':'windows','address':f'127.0.0.1:{host_port}','fingerprint':fingerprint,'capabilities':{}})
            env=os.environ.copy();env['YUANLIAN_DEVICE_TOKEN']=registered['device_token']
            share=temp/'share';share.mkdir();payload=secrets.token_bytes(256*1024);(share/'payload.bin').write_bytes(payload)
            host_log=open(temp/'host.log','wb')
            sunshine=(ROOT/'third_party/moonlight/sunshine/Sunshine/sunshine.exe').resolve()
            host=subprocess.Popen([str(binary),'--listen',f'127.0.0.1:{host_port}','--identity-dir',str(temp/'identity'),
                '--server-url',base,'--file-root',str(share),'--auto-approve','--sunshine',str(sunshine),'--quality-port','48189'],env=env,stdout=host_log,stderr=host_log)
            time.sleep(2)
            live_env=os.environ.copy();live_env.update(YUANLIAN_TEST_API=base,YUANLIAN_TEST_BEARER=token,YUANLIAN_TEST_DEVICE=device_id,YUANLIAN_TEST_ADDRESS=f'127.0.0.1:{host_port}',YUANLIAN_TEST_FINGERPRINT=fingerprint)
            subprocess.run(['powershell','-NoProfile','-Command',"& 'C:/Users/Lenovo/dev/flutter/bin/flutter.bat' test --no-pub live_test/flow_pipeline.dart"],cwd=ROOT/'client',env=live_env,check=True)
            if '--flutter' not in sys.argv and '--smoke' not in sys.argv:flow_test(api,device_id,host_port,fingerprint,payload)
            nonce=secrets.token_hex(32)
            ticket=api('POST',f'/api/v1/devices/{device_id}/session-ticket',{'nonce':nonce,'mode':'quality'})
            env=os.environ.copy();env['YUANLIAN_SESSION_TICKET']=ticket['ticket']
            viewer_log=open(temp/'viewer.log','wb')
            command=[str(ROOT/'target/release/yl-viewer.exe'),'--connect',f'127.0.0.1:{host_port}',
                '--fingerprint',fingerprint,'--nonce',nonce,'--mode','quality','--view-only',
                '--moonlight',str((ROOT/'third_party/moonlight/moonlight/Moonlight.exe').resolve())]
            if '--flutter' in sys.argv:
                env['YUANLIAN_QUALITY_PREVIEW']=str(ROOT/'third_party/moonlight')
                command=['C:/Users/Lenovo/dev/yuanlian-client-build/build/windows/x64/runner/Release/yuanlian_client.exe',
                    '--auto-connect-address',f'127.0.0.1:{host_port}','--auto-connect-fingerprint',fingerprint,
                    '--auto-connect-nonce',nonce,'--auto-connect-mode','quality']
            viewer=subprocess.Popen(command,env=env,stdout=viewer_log,stderr=viewer_log)
            owned_child_id=None
            authorized=False
            for _ in range(180):
                if viewer.poll() is not None:break
                text=(temp/'viewer.log').read_text(encoding='utf-8',errors='replace')
                if '--flutter' in sys.argv:
                    found=subprocess.run(['powershell','-NoProfile','-Command',f"Get-CimInstance Win32_Process -Filter \"ParentProcessId={viewer.pid} AND Name='Moonlight.exe'\" | ForEach-Object {{ $p=Get-Process -Id $_.ProcessId; if($p.MainWindowTitle -eq 'YuanLian authorized quality - Moonlight'){{$p.Id}} }}"],capture_output=True,text=True)
                    ids=[x.strip() for x in found.stdout.splitlines() if x.strip().isdigit()]
                    if ids:owned_child_id=ids[0];authorized=True;break
                elif 'Host 已授权质量视频串流' in text:authorized=True;break
                time.sleep(.25)
            if viewer.poll() is not None or not authorized:
                # Logs below contain our own errors only, not raw upstream output.
                print('VIEWER_FAILED', (temp/'viewer.log').read_text(encoding='utf-8',errors='replace')[-1500:])
                print('HOST_STATUS', (temp/'host.log').read_text(encoding='utf-8',errors='replace')[-1500:])
                raise RuntimeError('real quality connection failed')
            print('QUALITY_AUTHORIZED: inspect the actual Moonlight stream now',flush=True)
            time.sleep(5)
            info=(temp/'viewer.log').read_text(encoding='utf-8',errors='replace')
            child_id=re.search(r'official_moonlight_pid=(\d+)',info)
            if owned_child_id:child_id=re.match(r'(\d+)',owned_child_id)
            if child_id:
                capture=subprocess.run(['powershell','-NoProfile','-File',str(ROOT/'scripts/capture-quality-window.ps1'),'-ProcessId',child_id.group(1),'-ParentId',str(viewer.pid)],capture_output=True,text=True)
                if capture.returncode==0:print('OWNED_MOONLIGHT_SCREENSHOT',capture.stdout.strip(),flush=True)
                else:print('WINDOW_CAPTURE_UNAVAILABLE (no visual pass claimed)',flush=True)
            time.sleep(0 if '--smoke' in sys.argv else 25)
            assert listening_pids(48189),'dedicated Sunshine listener missing before revoke'
            started=time.monotonic()
            api('POST',f'/api/v1/devices/{device_id}/sessions/revoke',{})
            while time.monotonic()-started<3:
                if not listening_pids(48189):break
                time.sleep(.01)
            endpoint_latency=time.monotonic()-started
            assert endpoint_latency<=2.0,('quality revoke endpoint exceeded target',endpoint_latency)
            print('QUALITY_ENDPOINT_REVOKE_SECONDS',round(endpoint_latency,3),flush=True)
            if '--flutter' in sys.argv:
                gone=False
                for _ in range(100):
                    check=subprocess.run(['powershell','-NoProfile','-Command',f"if(Get-Process -Id {owned_child_id} -ErrorAction SilentlyContinue){{exit 1}}"],capture_output=True)
                    if check.returncode==0:gone=True;break
                    time.sleep(.02)
                assert gone,'Flutter retained its Moonlight child after revocation'
                print('FLUTTER_BROKER_CHILD_STOPPED_AFTER_REVOKE',flush=True)
            else:viewer.wait(timeout=5)
            for line in (temp/'viewer.log').read_text(encoding='utf-8',errors='replace').splitlines():
                if re.fullmatch(r'official_moonlight_(received|decoded|rendered)_fps=[0-9.]+',line):print(line,flush=True)
            assert not listening_pids(48189),'quality endpoint survived revocation'
            print('QUALITY_ENDPOINT_CLOSED_AFTER_REVOKE',flush=True)
            print('REVOKE_CLIENT_EXIT_SECONDS' ,round(time.monotonic()-started,3),flush=True)
        except Exception:
            if host_log:host_log.flush()
            if (temp/'host.log').exists():print('HOST_DIAGNOSTIC', (temp/'host.log').read_text(encoding='utf-8',errors='replace')[-1800:])
            raise
        finally:
            for process in (viewer,host):
                if process and process.poll() is None:
                    process.terminate();process.wait(timeout=5)
            if host_log:host_log.close()
            if viewer_log:viewer_log.close()
            cleanup_code="import os,signal,sys,time;db=sys.argv[1];p=db+'.pid';pid=int(open(p).read()) if os.path.exists(p) else None;owner=pid and os.path.exists('/proc/'+str(pid)+'/environ') and ('YUANLIAN_DB='+db).encode() in open('/proc/'+str(pid)+'/environ','rb').read().split(bytes([0]));os.kill(pid,signal.SIGTERM) if owner else None"
            subprocess.run(['wsl','-d','Ubuntu','--','python3','-c',cleanup_code,wsl_dir+'/test.db'],stdout=subprocess.DEVNULL,check=False)
            server.terminate();server.wait(timeout=5)
            # Only our exact random test directory; never user runtime state.
            if wsl_dir.startswith('/tmp/yl-quality-'):
                subprocess.run(['wsl','-d','Ubuntu','--','python3','-c','import shutil,sys;shutil.rmtree(sys.argv[1])',wsl_dir],stdout=subprocess.DEVNULL,check=False)

if __name__=='__main__':main()
