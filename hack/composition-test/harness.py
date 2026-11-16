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
