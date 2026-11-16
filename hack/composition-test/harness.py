#!/usr/bin/env python3
# Offline test of apps/crossplane-api/composition.yaml: renders the go-template (same text/template + sprig engine as function-go-templating)
# for demo1-like XRs and compares it with BASE_REF's composition (default origin/main). No cluster needed.
#   cd hack/composition-test && go build -o render . && python3 -I harness.py
# Needs: go, python3 + pyyaml, git. Covers the VM and Talos layers (verify/platform need more observed state). See README in the PR for scenarios.
import yaml, json, subprocess, copy, sys
import os, tempfile
HERE=os.path.dirname(os.path.abspath(__file__)); ROOT=os.path.abspath(os.path.join(HERE,'..','..'))
S=tempfile.mkdtemp(prefix='comptest-')   # scratch dir for rendered templates and inputs
BASE=os.environ.get('BASE_REF','origin/main')   # composition to compare against
def tmpl(path):
    d=list(yaml.safe_load_all(open(path)))[0]
    return [s for s in d['spec']['pipeline'] if 'input' in s and 'inline' in s.get('input',{})][0]['input']['inline']['template']
open(S+'/comp-old.yaml','w').write(subprocess.check_output(['git','-C',ROOT,'show',BASE+':apps/crossplane-api/composition.yaml'],text=True))
open(S+'/old.tmpl','w').write(tmpl(S+'/comp-old.yaml'))
open(S+'/new.tmpl','w').write(tmpl(ROOT+'/apps/crossplane-api/composition.yaml'))
env=list(yaml.safe_load_all(open(ROOT+'/apps/crossplane-environment/environmentconfig.yaml')))[0]['data']
def xr(version='v1.14.5', status=None, annotations=None):
    x={'apiVersion':'platform.ellin.net/v1alpha1','kind':'TalosCluster',
       'metadata':{'name':'demo1','namespace':'default','annotations':annotations or {}},
       'spec':{'proxmoxRef':'homelab','talosVersion':version,'kubernetesVersion':'v1.37.1','storage':'truenas-fast-storage',
               'network':{'controlPlaneIP':'192.168.10.57','workerIPs':[]},'controlPlane':{},'workers':{'count':0}}}
    if status: x['status']=status
    return x
def done(): return {'resource':{'status':{'atProvider':{'manifest':{'status':{'succeeded':1}}}}}}
def render(which, x, vms_ready=True):
    obs={'vm-demo1-cp-1-r3':done()} if vms_ready else {}
    inp={'observed':{'composite':{'resource':x},'resources':obs},'context':{'apiextensions.crossplane.io/environment':env}}
    open(S+'/in.json','w').write(json.dumps(inp))
    p=subprocess.run([HERE+'/render',S+f'/{which}.tmpl',S+'/in.json'],capture_output=True,text=True)
    if p.returncode: return None,p.stderr.strip()
    docs=[d for d in yaml.safe_load_all(p.stdout) if d]
    return docs,None
def jobs(docs):
    out={}
    for d in docs:
        if d.get('kind')=='Object':
            n=d['metadata']['annotations']['gotemplating.fn.crossplane.io/composition-resource-name']
            out[n]=d['spec']['forProvider']['manifest']
    return out
def status(docs): return next(d for d in docs if d.get('kind')=='TalosCluster' and 'status' in d)['status']
def check(name, cond, extra=''): print(('PASS ' if cond else 'FAIL ')+name+(' '+extra if extra else ''))

# A: old vs new on demo1 as it is today (v1.14.5, no status)
o,e=render('old',xr()); n,e2=render('new',xr()); assert o and n,(e,e2)
jo,jn=jobs(o),jobs(n)
print('resources:',sorted(jn))
check('A  same resource set old/new', sorted(jo)==sorted(jn))
check('A  all Objects identical old/new', jo==jn)
check('A  new status records createdTalosVersion v1.14.5', status(n).get('createdTalosVersion')=='v1.14.5', str(status(n).get('createdTalosVersion')))
# B: spec bumped to 1.14.6 but status holds the creation version -> VM/Talos Jobs unchanged
b,e=render('new',xr('v1.14.6',{'createdTalosVersion':'v1.14.5'})); assert b,e
jb=jobs(b)
check('B  bumped spec, status=v1.14.5: all Objects identical to A', jb==jn)
check('B  status stays v1.14.5', status(b)['createdTalosVersion']=='v1.14.5')
# B2: what the OLD composition would do on the same bump (the problem)
ob,e=render('old',xr('v1.14.6')); job=jobs(ob)
diff=[k for k in jo if jo[k]!=job.get(k)]
check('B2 OLD composition + bump changes Jobs (confirms the problem)', len(diff)>0, str(diff))
# C: brand-new cluster at v1.14.6 uses template 9101
c,e=render('new',xr('v1.14.6'),vms_ready=False); jc=jobs(c)
vm=jc['vm-demo1-cp-1-r3']['spec']['template']['spec']['containers'][0]['env']
tid=[x['value'] for x in vm if x['name']=='TEMPLATE_ID'][0]
check('C  new v1.14.6 cluster clones template 9101', tid=='9101', tid)
check('C  status createdTalosVersion v1.14.6', status(c)['createdTalosVersion']=='v1.14.6')
# A2: template used for the unchanged case
vm=jn['vm-demo1-cp-1-r3']['spec']['template']['spec']['containers'][0]['env']
tid=[x['value'] for x in vm if x['name']=='TEMPLATE_ID'][0]
check('A  v1.14.5 cluster clones template 9100', tid=='9100', tid)
# D: missing template -> clear failure
d,e=render('new',xr('v1.14.7'),vms_ready=False)
check('D  missing template fails with a clear message', d is None and 'no Proxmox template' in (e or ''), (e or '')[:140])
# E: teardown of a cluster whose template is missing must still render
t,e=render('new',xr('v1.14.7',annotations={'platform.ellin.net/teardown':'true'}),vms_ready=False)
check('E  teardown not blocked by a missing template', t is not None and any('teardown-demo1' in k for k in jobs(t)), e or '')

# ---- F2 upgrade layer ----
def obs_built(extra=None):
    o={k:done() for k in ['vm-demo1-cp-1-r3','talos-demo1-r3','verify-demo1-r3','platform-demo1-p2']}
    o.update(extra or {}); return o
def render_obs(which, x, obs):
    inp={'observed':{'composite':{'resource':x},'resources':obs},'context':{'apiextensions.crossplane.io/environment':env}}
    open(S+'/in.json','w').write(json.dumps(inp))
    p=subprocess.run([HERE+'/render',S+f'/{which}.tmpl',S+'/in.json'],capture_output=True,text=True)
    return (None,p.stderr) if p.returncode else ([d for d in yaml.safe_load_all(p.stdout) if d],None)
def cond(docs,t): return next(c for d in docs if d.get('kind')=='ClaimConditions' for c in d['conditions'] if c['type']==t)
UP='upgrade-demo1-v1-14-6'
base_status={'createdTalosVersion':'v1.14.5','talosVersion':'v1.14.5'}
# U1: nothing to upgrade
u,e=render_obs('new',xr('v1.14.5',base_status),obs_built()); ju=jobs(u)
check('U1 same version: no upgrade Object, phase Ready', not any(k.startswith('upgrade-') for k in ju) and status(u)['phase']=='Ready')
check('U1 Upgrading condition False', cond(u,'Upgrading')['status']=='False')
# U2: bump -> upgrade Job
u2,e=render_obs('new',xr('v1.14.6',base_status),obs_built()); j2=jobs(u2)
check('U2 bump: upgrade Object rendered', UP in j2, str(sorted(j2)))
env2={x['name']:x['value'] for x in j2[UP]['spec']['template']['spec']['containers'][0]['env']}
check('U2 Job env', env2.get('TARGET_VERSION')=='v1.14.6' and env2.get('CP_IP')=='192.168.10.57' and len(env2.get('SCHEMATIC',''))==64 and env2.get('WORKER_IPS')=='', str(env2))
check('U2 phase Upgrading, condition True/InProgress', status(u2)['phase']=='Upgrading' and cond(u2,'Upgrading')['status']=='True' and cond(u2,'Upgrading')['reason']=='InProgress')
check('U2 status.talosVersion still v1.14.5, created unchanged', status(u2)['talosVersion']=='v1.14.5' and status(u2)['createdTalosVersion']=='v1.14.5')
same=all(j2[k]==ju[k] for k in ju if not k.startswith('upgrade-'))
check('U2 VM/Talos/verify/platform Objects identical to U1 (bump does not touch them)', same)
check('U2 Job mounts the script ConfigMap and both secrets', [v.get('configMap',{}).get('name') or v.get('secret',{}).get('secretName') for v in j2[UP]['spec']['template']['spec']['volumes']]==['upgrade-cluster','demo1-kubeconfig','demo1-talosconfig'])
# U3: succeeded -> status.talosVersion = target, Ready
u3,e=render_obs('new',xr('v1.14.6',base_status),obs_built({UP:done()}))
check('U3 succeeded: status.talosVersion v1.14.6, phase Ready, Object still rendered once', status(u3)['talosVersion']=='v1.14.6' and status(u3)['phase']=='Ready' and UP in jobs(u3))
# U4: next reconcile, status holds the target -> Object no longer rendered
u4,e=render_obs('new',xr('v1.14.6',{'createdTalosVersion':'v1.14.5','talosVersion':'v1.14.6'}),obs_built({UP:done()}))
check('U4 settled: upgrade Object dropped, status stays v1.14.6', UP not in jobs(u4) and status(u4)['talosVersion']=='v1.14.6' and status(u4)['phase']=='Ready')
# U5/U7: platform not finished
partial={k:done() for k in ['vm-demo1-cp-1-r3','talos-demo1-r3']}
u5,e=render_obs('new',xr('v1.14.6',base_status),partial)
check('U5 bump while the cluster is still being built: no upgrade yet', UP not in jobs(u5))
u7,e=render_obs('new',xr('v1.14.6',base_status),{**partial,UP:{}} | {UP:{'resource':{'status':{}}}})
check('U7 running upgrade survives platformDone blip', UP in jobs(u7))
# U6: failed
u6,e=render_obs('new',xr('v1.14.6',base_status),obs_built({UP:{'resource':{'status':{'atProvider':{'manifest':{'status':{'failed':1}}}}}}}))
c=cond(u6,'Upgrading'); check('U6 failed: UpgradeFailed with a hint', c['reason']=='UpgradeFailed' and 'delete that Job' in c.get('message',''))
# U8: cluster with workers gets the worker IPs
xw=xr('v1.14.6',base_status); xw['spec']['network']['workerIPs']=['192.168.10.58','192.168.10.59']; xw['spec']['workers']={'count':2}
ow=obs_built({k:done() for k in ['vm-demo1-w-1-r3','vm-demo1-w-2-r3']})
u8,e=render_obs('new',xw,ow); j8=jobs(u8)
check('U8 workers: WORKER_IPS passed', UP in j8 and {x['name']:x['value'] for x in j8[UP]['spec']['template']['spec']['containers'][0]['env']}['WORKER_IPS']=='192.168.10.58,192.168.10.59')
# U9: demo1 case: no status.talosVersion yet (falls back to the creation version)
u9,e=render_obs('new',xr('v1.14.5',{'createdTalosVersion':'v1.14.5'}),obs_built())
check('U9 no status.talosVersion yet: falls back and records it', status(u9)['talosVersion']=='v1.14.5')
# U10: teardown never renders an upgrade
ut,e=render_obs('new',xr('v1.14.6',base_status,annotations={'platform.ellin.net/teardown':'true'}),obs_built())
check('U10 teardown: no upgrade Object', not any(k.startswith('upgrade-') for k in jobs(ut)))
