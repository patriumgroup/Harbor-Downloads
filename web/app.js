'use strict';
const $ = (s, parent = document) => parent.querySelector(s);
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const paths = {
 grid:'M3 3h7v7H3z M14 3h7v7h-7z M3 14h7v7H3z M14 14h7v7h-7z',
 server:'M4 3h16v7H4z M4 14h16v7H4z M7 6.5h.01 M7 17.5h.01 M11 6.5h6 M11 17.5h6',
 chart:'M4 3v17h17 M8 15l4-5 4 2 5-8', activity:'M3 12h4l3-8 4 16 3-8h4',
 shield:'M12 3l8 3v6c0 5-8 9-8 9s-8-4-8-9V6z M8.5 12l2.5 2.5 4.5-5',
 settings:'M9 3h6l1 3 3 1 2 5-2 5-3 1-1 3H9l-1-3-3-1-2-5 2-5 3-1z M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0',
 search:'M20 20l-5-5 M17 10a7 7 0 1 1-14 0 7 7 0 0 1 14 0', bell:'M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9 M10 21h4',
 chevron:'M9 5l7 7-7 7', down:'M7 10l5 5 5-5', arrow:'M4 12h16 M15 7l5 5-5 5',
 refresh:'M20 8a8 8 0 1 0 0 8 M20 3v5h-5', download:'M12 3v12 M7 10l5 5 5-5 M4 16v5h16v-5',
 cpu:'M7 7h10v10H7z M10 10h4v4h-4z M9 3v4 M15 3v4 M9 17v4 M15 17v4 M3 9h4 M3 15h4 M17 9h4 M17 15h4',
 memory:'M3 7h18v10H3z M7 10v4 M11 10v4 M15 10v4 M18 10v4 M6 17v3 M10 17v3 M14 17v3 M18 17v3',
 disk:'M5 4h14l3 12v4H2v-4z M2 16h20 M6 18h.01 M10 18h.01', clock:'M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0 M12 7v5l3 2',
 info:'M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0 M12 11v6 M12 7h.01', check:'M5 12l4 4L19 6',
 dots:'M5 12h.01 M12 12h.01 M19 12h.01', close:'M6 6l12 12 M6 18L18 6',
 lock:'M5 10h14v11H5z M8 10V6a4 4 0 0 1 8 0v4 M12 14v3', code:'M8 7l-5 5 5 5 M16 7l5 5-5 5 M14 4l-4 16',
 logout:'M9 4H4v16h5 M9 12h12 M16 7l5 5-5 5', menu:'M4 6h16 M4 12h16 M4 18h16',
 eye:'M2 12s4-7 10-7 10 7 10 7-4 7-10 7-10-7-10-7 M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0',
 database:'M20 6c0 2-4 3-8 3s-8-1-8-3 4-3 8-3 8 1 8 3 M4 6v12c0 2 4 3 8 3s8-1 8-3V6 M4 12c0 2 4 3 8 3s8-1 8-3',
 mail:'M3 5h18v14H3z M3 5l9 8 9-8', globe:'M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0 M3 12h18 M12 3c5 5 5 13 0 18-5-5-5-13 0-18',
 terminal:'M4 6l6 6-6 6 M13 18h7', heart:'M12 20S2 14 2 8a5 5 0 0 1 10-1A5 5 0 0 1 22 8c0 6-10 12-10 12'
};
const icon = name => `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="${paths[name] || paths.server}"/></svg>`;
const state = {authMode:'token',session:null,services:[],metrics:null,activity:[],jobs:{},phpExtensions:{versions:[]},waf:{installed:false,mode:'off'},view:'overview',filter:'installed',category:'all',query:'',error:'',loading:true,pending:false,samples:[],lastUpdated:null};
let refreshInFlight = false;
let modalReturnFocus = null;
const labels = {overview:'Overview',services:'Services',resources:'Resources',activity:'Activity log',security:'Security',settings:'Settings'};
const byte = (n, digits = 1) => { if(!Number.isFinite(n)) return '—'; if(n < 1024) return `${n} B`; const units=['KB','MB','GB','TB']; let i=-1; do {n/=1024;i++;}while(n>=1024&&i<3);return `${n.toFixed(digits)} ${units[i]}`; };
const uptime = s => {if(!Number.isFinite(s))return '—'; const days=Math.floor(s/86400); return days ? `${days}<small>days</small>` : `${Math.floor(s/3600)}<small>hours</small>`;};
const relative = ts => {const seconds=Math.max(0,Math.floor((Date.now()-ts)/1000));return seconds<60?'Just now':seconds<3600?`${Math.floor(seconds/60)}m ago`:seconds<86400?`${Math.floor(seconds/3600)}h ago`:`${Math.floor(seconds/86400)}d ago`;};
const installed = () => state.services.filter(s=>s.load==='loaded');
const running = () => installed().filter(s=>s.status==='active');
const titleCase = s => String(s).charAt(0).toUpperCase()+String(s).slice(1);
const statusLabel = s => ({active:'Running',inactive:'Stopped',failed:'Failed',activating:'Starting',deactivating:'Stopping',reloading:'Reloading'}[s.status] || titleCase(s.status));
async function api(path, body) {
 const response = await fetch(`/api/${path}`,{method:body===undefined?'GET':'POST',credentials:'same-origin',headers:body===undefined?{}:{'Content-Type':'application/json','X-CSRF-Token':state.session?.csrf || ''},body:body===undefined?undefined:JSON.stringify(body)});
 let data; try {data=await response.json();} catch {throw new Error('The server returned an invalid response.');}
 if(!response.ok) {if(response.status===401&&path!=='login'&&path!=='session') {state.session=null;$('#dialog').close();await syncAuthMode();renderLogin();}throw new Error(data.error || `Request failed (${response.status})`);}
 return data;
}
function toast(message,error=false) {const el=document.createElement('div');el.className=`toast${error?' error':''}`;el.textContent=message;$('#toasts').append(el);setTimeout(()=>el.remove(),7000);}
async function syncAuthMode(){try{const response=await fetch('/api/auth-mode',{credentials:'same-origin'}),data=await response.json();if(response.ok&&['token','password'].includes(data.mode)){const changed=state.authMode!==data.mode;state.authMode=data.mode;if(changed&&!state.session&&$('#login-form')&&loginMode==='admin')renderLogin();}}catch{}}
function navigate(view) {location.hash=view; if(state.view===view)renderContent();$('.sidebar')?.classList.remove('open');}
function spark(kind,color='#a493df',large=false) {
 const data=state.samples.map(s=>kind==='cpu'?s.cpu:kind==='memory'?100*s.memoryUsed/s.memoryTotal:100*s.diskUsed/s.diskTotal).filter(Number.isFinite);
 if(data.length<2) return `<svg class="spark" viewBox="0 0 200 35" preserveAspectRatio="none" aria-hidden="true"><path d="M0 30H200" stroke="#ece8f7" stroke-width="1" stroke-dasharray="4 4" fill="none"/></svg>`;
 const points=data.map((v,i)=>`${(i/(data.length-1)*200).toFixed(1)},${(31-Math.max(0,Math.min(100,v))*.26).toFixed(1)}`);
 const id=`gradient-${kind}${large?'-large':''}`;
 return `<svg class="spark" viewBox="0 0 200 35" preserveAspectRatio="none" role="img" aria-label="${kind} usage history"><defs><linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="${color}" stop-opacity=".15"/><stop offset="100%" stop-color="${color}" stop-opacity="0"/></linearGradient></defs><path d="M${points.join(' L')} L200 35 L0 35Z" fill="url(#${id})"/><path d="M${points.join(' L')}" fill="none" stroke="${color}" stroke-width="1.4" vector-effect="non-scaling-stroke"/></svg>`;
}
function metricCards() {
 const m=state.metrics;
 const cpu=m?`${m.cpu.toFixed(1)}<small>%</small>`:'—';
 const mem=m?`${(m.memoryUsed/1073741824).toFixed(1)}<small>/ ${(m.memoryTotal/1073741824).toFixed(1)} GB</small>`:'—';
 const disk=m?`${(m.diskUsed/1073741824).toFixed(1)}<small>/ ${(m.diskTotal/1073741824).toFixed(0)} GB</small>`:'—';
 return `<div class="metrics"><article class="metric"><div class="metric-head">CPU usage ${icon('cpu')}</div><div class="metric-value">${cpu}</div><div class="metric-foot"><span class="tag">${m?m.load.toFixed(2):'—'}</span>1-minute load average</div>${spark('cpu')}</article><article class="metric"><div class="metric-head">Memory ${icon('memory')}</div><div class="metric-value">${mem}</div><div class="metric-foot">${m?`${(100*m.memoryUsed/m.memoryTotal).toFixed(0)}% in use`:'Awaiting metrics'}<span>·</span>Available memory accounted</div>${spark('memory','#93a8da')}</article><article class="metric"><div class="metric-head">Storage ${icon('disk')}</div><div class="metric-value">${disk}</div><div class="metric-foot">${m?`${byte(m.diskTotal-m.diskUsed)} free`:'Awaiting metrics'}<span>·</span>Root filesystem</div>${spark('disk','#b2a1d5')}</article><article class="metric"><div class="metric-head">Server uptime ${icon('clock')}</div><div class="metric-value">${m?uptime(m.uptime):'—'}</div><div class="metric-foot"><span class="dot green"></span>${m?`Since ${new Date(Date.now()-m.uptime*1000).toLocaleDateString(undefined,{month:'short',day:'numeric'})}`:'Awaiting metrics'}<span>·</span>Host uptime</div><div class="uptime-bars" aria-hidden="true">${Array.from({length:27},()=>'<i></i>').join('')}</div></article></div>`;
}
function serviceLogo(s) {
 const type=s.id.startsWith('php')?'runtime':['nginx','apache2','mariadb','postgresql','redis-server'].includes(s.id)?s.id:'other';
 const symbol=({nginx:'N',apache2:'A',mariadb:icon('database'),postgresql:icon('database'),'redis-server':icon('server')})[s.id] || icon(s.category==='Runtime'?'code':s.category==='Mail'?'mail':s.category==='Security'?'shield':s.category==='DNS'?'globe':'terminal');
 return `<span class="service-logo ${type}">${symbol}</span>`;
}
function activityList(compact=false) {
 const rows=state.activity.slice(0,compact?3:50);
 return `<div class="activity-list ${compact?'':'full-activity'}">${rows.length?rows.map(row=>`<div class="activity-item"><span class="activity-icon">${icon(/Rejected|failed|denied/i.test(row.message)?'info':/Queued|Requested|Simulated/i.test(row.message)?'refresh':'check')}</span><div class="activity-text">${esc(row.message)}<small>${state.session.demo?'Simulated':'Audit'}${row.ip?` · IP ${esc(row.ip)}`:''}</small></div><time class="activity-time" datetime="${new Date(row.time).toISOString()}" title="${esc(new Date(row.time).toLocaleString())}">${relative(row.time)}</time></div>`).join(''):`<div class="empty">${icon('activity')}${state.loading?'Loading activity…':'No agent events yet. Service requests will appear here.'}</div>`}</div>`;
}
function activityCard(compact=false) {return `<article class="card activity-card"><div class="card-header"><div><h2>${compact?'Recent activity':'Activity'}</h2></div><button class="text-link" ${compact?'data-view="activity"':'data-action="export"'}>${compact?'View all activity':'Export report'}${icon(compact?'arrow':'download')}</button></div>${activityList(compact)}</article>`;}
function serverStrip() {const m=state.metrics;return `<div class="server-strip"><span class="server-icon">${icon('server')}</span><div><div class="server-name">${esc(m?.hostname||'Connecting to server…')}</div><div class="server-meta"><span>Ubuntu 24.04 LTS</span></div></div><div class="server-chips"><span class="status">${state.error?icon('info'):'<span class="dot"></span>'}${state.session.demo?'Demo server':state.error?'Check connection':'Connected'}</span><span class="ubuntu"><span class="ubuntu-mark">◉</span> Ubuntu</span></div><button class="icon-button" data-view="settings" aria-label="Server details">${icon('dots')}</button></div>`;}
async function refresh(announce=false) {
 if(!state.session||refreshInFlight)return;refreshInFlight=true;
 try {
  if(isOwner()){state.error='';state.session.profile=await api('owner/profile');await loadTenant();}
  else {const keys=['services','metrics','activity','owners','waf','jobs','phpExtensions'];const endpoints=['services','metrics','activity','owners','waf','jobs','php/extensions'];const grants=['services.read','services.read','logs.read','owners.read','security.read','services.read','php.read'];const results=await Promise.allSettled(endpoints.map((endpoint,index)=>can(grants[index])?api(endpoint):Promise.resolve(index===1?null:index===4?{installed:false,mode:'off'}:index===5?{}:index===6?{versions:[]}:[])));const errors=[];results.forEach((result,index)=>{if(result.status==='rejected')errors.push(result.reason.message);else{state[keys[index]]=result.value;if(index===1){state.samples.push(result.value);state.samples=state.samples.slice(-60);}}});if(!state.session)return;state.error=[...new Set(errors)].join(' ');if(!state.owners.some(o=>o.username===state.owner))state.owner=state.owners[0]?.username||'';await loadTenant();if(state.view==='adminLogs'&&can('logs.read'))await loadAdminLogs();if(state.view==='updates'&&can('updates.read'))await loadReleaseStatus();if(state.view==='admins'&&state.session.superAdmin)await loadAdmins();}
  if(!state.session)return;state.loading=false;state.lastUpdated=new Date();if(!terminalWidget)renderContent();if(announce)toast(state.error||'Workspace refreshed.',Boolean(state.error));
 }catch(error){state.error=error.message;state.loading=false;if(state.session&&!terminalWidget)renderContent();if(announce)toast(error.message,true);}finally{refreshInFlight=false;}
}
function showDialog(html) {const dialog=$('#dialog');modalReturnFocus=document.activeElement;dialog.innerHTML=`<button class="icon-button dialog-close" data-action="close-dialog" aria-label="Close dialog">${icon('close')}</button>${html}`;dialog.showModal();}
function closeDialog() {$('#dialog').close();}
$('#dialog').addEventListener('close',()=>{if(modalReturnFocus?.isConnected)modalReturnFocus.focus();});
function confirmAction(id,action) {
 const s=state.services.find(s=>s.id===id);if(!s||state.pending)return;
 const stop=action==='stop';
 const destructive=stop||action==='remove';
 if(action==='remove'&&!s.removable||action==='install'&&!s.installable)return;
 showDialog(`<h2 id="dialog-title">${titleCase(action)} ${esc(s.name)}?</h2><p>${state.session.demo?'This is a simulated action in the demonstration environment. ':''}${action==='remove'?'This removes the service packages. Existing application data and configuration may remain.':action==='install'?'This installs packages from the configured Ubuntu repositories.':'The service operation will be queued.'}</p>${s.id==='nginx'&&stop?'<p>NGINX may serve this panel. You may need SSH or console access to restore it.</p>':''}${s.id==='ssh'&&stop?'<p>Make sure you have an alternate route to the host before stopping remote access.</p>':''}${destructive?`<label for="confirm-name">Type ${esc(s.id)} to confirm</label><input id="confirm-name" autocomplete="off" spellcheck="false" data-confirm-name="${esc(s.id)}">`:''}<div class="dialog-actions"><button class="button" data-action="close-dialog">Cancel</button><button id="confirm-operation" class="button ${destructive?'danger':'primary'}" data-execute="${action}" data-service="${esc(s.id)}" ${destructive?'disabled':''}>${titleCase(action)}</button></div>`);
 if(destructive)$('#confirm-name').addEventListener('input',event=>{$('#confirm-operation').disabled=event.target.value!==id;});
}
async function executeAction(id,action) {
 if(state.pending)return;state.pending=true;closeDialog();renderContent();
 try {const result=await api(action==='install'||action==='remove'?'package':'action',{service:id,action});toast(result.message||'Request queued.');await refresh();setTimeout(()=>refresh(),3000);}
 catch(error){toast(error.message,true);}
 finally{state.pending=false;renderContent();}
}
function exportReport() {
 const report=isOwner()?{product:'Harbor',version:'0.6.0',mode:state.session.demo?'simulation':'ubuntu',owner:state.session.user,exportedAt:new Date().toISOString(),profile:state.session.profile,databases:state.database,domains:state.domains,php:state.php,email:state.mail}:{product:'Harbor',version:'0.6.0',mode:state.session.demo?'simulation':'ubuntu',exportedAt:new Date().toISOString(),lastUpdated:state.lastUpdated?.toISOString(),connectionError:state.error||null,metrics:state.metrics,services:state.services,audit:state.activity};
 const url=URL.createObjectURL(new Blob([JSON.stringify(report,null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download=`harbor-report-${new Date().toISOString().slice(0,10)}.json`;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);toast('Server report downloaded.');
}
document.addEventListener('click',async event=>{
 const button=event.target.closest('button');if(!button||button.disabled)return;
 if(button.dataset.view){if(state.view==='terminal')disposeTerminal();navigate(button.dataset.view);return;}
 if(button.dataset.filter){state.filter=button.dataset.filter;renderContent();return;}
 if(button.dataset.detail){showDetails(button.dataset.detail);return;}
 if(button.dataset.control){if($('#dialog').open)$('#dialog').close();confirmAction(button.dataset.service,button.dataset.control);return;}
 if(button.dataset.execute){executeAction(button.dataset.service,button.dataset.execute);return;}
 if(button.dataset.waf){if(state.pending)return;const action=button.dataset.waf;if(action==='blocking'&&!window.confirm('Enable blocking for website vhosts that include the WAF configuration?'))return;state.pending=true;try{const result=await api('waf',{action});toast(result.message||'WAF operation queued.');setTimeout(()=>refresh(),3000);}catch(error){toast(error.message,true);}finally{state.pending=false;renderContent();}return;}
 switch(button.dataset.action){
  case 'refresh':await refresh(true);break;
  case 'export':exportReport();break;
  case 'menu':$('.sidebar').classList.add('open');break;
  case 'close-menu':$('.sidebar').classList.remove('open');break;
  case 'close-dialog':closeDialog();break;
  case 'reveal':$('#token').type=$('#token').type==='password'?'text':'password';break;
  case 'clear-search':state.query='';$('#global-search').value='';renderContent();break;
  case 'logout':try{await api('logout',{});state.session=null;state.services=[];state.metrics=null;state.samples=[];state.activity=[];state.error='';state.owner='';state.lastUpdated=null;state.owners=[];state.database={databases:[],users:[]};state.domains={owned:[],delegated:[]};state.targets=[];state.mail={};state.dns={domain:'',records:[],page:1};await syncAuthMode();renderLogin();}catch(error){toast(error.message,true);}break;
 }
});
window.addEventListener('hashchange',()=>{state.view=location.hash.slice(1)||'overview';renderContent();});
document.addEventListener('keydown',event=>{if(event.key==='Escape')$('.sidebar')?.classList.remove('open');if((event.ctrlKey||event.metaKey)&&event.key.toLowerCase()==='k'){event.preventDefault();if(isOwner())return;const search=$('#global-search');if(search?.getClientRects().length)search.focus();else{navigate('services');setTimeout(()=>$('#service-search')?.focus(),0);}}});
setInterval(()=>{if(!document.hidden&&state.session&&!$('#dialog').open&&!document.activeElement.matches('input,select'))refresh();},15000);
let loginMode='owner';
let terminalWidget=null,terminalPoll=null,terminalReading=false,terminalInput=Promise.resolve(),terminalGeneration=0,terminalConnecting=false;
state.owners=[];state.owner='';state.database={databases:[],users:[]};state.domains={owned:[],delegated:[]};state.targets=[];state.tools={configured:false};
Object.assign(labels,{owners:'Site owners',databases:'Databases',domains:'Domains',mail:'Email',dns:'DNS',terminal:'Terminal',workspace:'My workspace'});
function isOwner(){return state.session?.role==='owner'||state.session?.role==='impersonated';}
function can(permission){return state.session?.role==='owner'||Boolean(state.session?.superAdmin)||Boolean(state.session?.permissions?.includes(permission));}
const viewPermission={overview:'services.read',services:'services.read',updates:'updates.read',adminLogs:'logs.read',owners:'owners.read',sites:'sites.read',logs:'sites.read',php:'php.read',databases:'databases.read',domains:'domains.read',mail:'mail.read',spam:'spam.read',dns:'dns.read',resources:'services.read',activity:'logs.read',security:'security.read',terminal:'terminal.manage'};
function canView(view){return view==='admins'?Boolean(state.session?.superAdmin):view==='settings'||view==='workspace'||can(viewPermission[view]||'deny');}
function selectedOwner(){return isOwner()?state.session.user:state.owner;}
function ownerPicker(){return isOwner()?'':`<div class="section-toolbar"><label for="workspace-owner">Site owner</label><select id="workspace-owner">${state.owners.map(o=>`<option value="${esc(o.username)}" ${o.username===state.owner?'selected':''}>${esc(o.username)}</option>`).join('')}</select></div>`;}
function shells(selected='none'){return [['none','No login shell'],['bash','Bash · /bin/bash'],['sh','sh · /bin/sh'],['zsh','Zsh · /usr/bin/zsh']].map(([v,n])=>`<option value="${v}" ${v===selected?'selected':''}>${n}</option>`).join('');}
function shellKey(path){return path==='/bin/bash'?'bash':path==='/bin/sh'?'sh':path==='/usr/bin/zsh'?'zsh':'none';}
function ownerRows(){return state.owners.map(o=>`<tr><td><div class="service-identity"><span class="service-logo runtime">${esc(o.username.slice(0,1).toUpperCase())}</span><div><b>${esc(o.username)}</b><small>UID ${o.uid} · ${esc(o.home)}</small></div></div></td><td><span class="inline-code">${esc(o.prefix)}*</span></td><td><span class="status-pill ${o.terminalEnabled?'':'inactive'}">${o.terminalEnabled?esc(o.shell):'No login shell'}</span></td><td><div class="row-actions"><button class="button small" data-tenant="shell" data-owner="${esc(o.username)}">Change shell</button><button class="icon-button" data-tenant="password" data-owner="${esc(o.username)}" aria-label="Reset password for ${esc(o.username)}">${icon('lock')}</button><button class="button small" data-tenant="impersonate-start" data-owner="${esc(o.username)}">Log in as owner</button></div></td></tr>`).join('');}
function tenantDialog(kind,owner=selectedOwner(),engine='mariadb',resourceKind='database'){
 let title='',fields='',note='';
 if(kind==='create-owner'){title='Create a site owner';fields=`<label>Ubuntu username<input name="owner" required pattern="[a-z][a-z0-9]{0,15}" maxlength="16" placeholder="polar"></label><label>Initial Ubuntu password<input name="password" type="password" required minlength="16" maxlength="128" autocomplete="new-password"></label><label>Login shell<select name="shell">${shells()}</select></label>`;note='A private native user and group are created. No shell is enabled by default.';}
 if(kind==='shell'){const profile=state.owners.find(o=>o.username===owner);title=`Login shell for ${owner}`;fields=`<input type="hidden" name="owner" value="${esc(owner)}"><label>Allowed shell<select name="shell">${shells(shellKey(profile.shell))}</select></label>`;note='Changing this setting revokes panel sessions and closes browser terminals. It does not terminate existing SSH sessions or background processes.';}
 if(kind==='password'){title=`Reset password for ${owner}`;fields=`<input type="hidden" name="owner" value="${esc(owner)}"><label>New Ubuntu password<input name="password" type="password" required minlength="16" maxlength="128" autocomplete="new-password"></label>`;note='All owner panel sessions will be revoked. Database passwords are separate.';}
 if(kind==='create-db'){title=`Create ${engine==='mariadb'?'MariaDB':'PostgreSQL'} ${resourceKind}`;fields=`<input type="hidden" name="engine" value="${engine}"><input type="hidden" name="kind" value="${resourceKind}"><input type="hidden" name="owner" value="${esc(owner)}"><label>Name suffix<div class="prefixed-input"><span>${esc(owner)}_</span><input name="suffix" required pattern="[a-z][a-z0-9_]{0,14}" maxlength="15" placeholder="${resourceKind==='user'?'app':'website'}"></div></label>${resourceKind==='user'?'<label>Database password<input name="password" type="password" required minlength="16" maxlength="128" autocomplete="new-password"></label>':''}`;note='The server derives your owner prefix from the authenticated session. Supplying a different owner in a request cannot change that scope.';}
 if(kind==='assign-domain'){title=`Assign a domain to ${owner}`;fields=`<input type="hidden" name="owner" value="${esc(owner)}"><label>Primary domain<input name="domain" required placeholder="example.com" spellcheck="false"></label>`;note='Creates an ownership allocation. Existing or overlapping allocations are refused. This does not change public DNS or publish a website.';}
 if(kind==='delegate'){title='Delegate a subdomain';fields=`<input type="hidden" name="owner" value="${esc(owner)}"><label>Your primary domain<select name="domain">${state.domains.owned.map(d=>`<option>${esc(d.name)}</option>`).join('')}</select></label><label>Subdomain label<input name="label" required pattern="[a-z0-9]([a-z0-9-]*[a-z0-9])?" maxlength="63" placeholder="shop"></label><label>Recipient site owner<select name="target">${state.targets.filter(n=>n!==owner).map(n=>`<option>${esc(n)}</option>`).join('')}</select></label>`;note='The recipient receives only this hostname allocation. Their files and databases use their own identity. They cannot grant access to other subdomains of your primary domain.';}
 if(kind==='revoke'){title='Revoke subdomain delegation';fields=`<input type="hidden" name="owner" value="${esc(owner)}"><input type="hidden" name="domain" value="${esc(engine)}"><input type="hidden" name="label" value="${esc(resourceKind)}">`;note=`Remove the recipient's website authorization for ${esc(resourceKind+'.'+engine)}. No user files or databases are deleted.`;}
 showDialog(`<h2 id="dialog-title">${esc(title)}</h2><form data-tenant-form="${kind}">${fields}<p class="login-error" role="alert"></p><div class="dialog-actions"><button class="button" type="button" data-action="close-dialog">Cancel</button><button class="button primary" type="submit">${state.session.demo?'Simulate ':''}${kind==='shell'?'Save shell':'Save'}</button></div></form>`);
}
async function disposeTerminal(sendClose=true){terminalGeneration++;clearInterval(terminalPoll);terminalPoll=null;if(terminalWidget){terminalWidget.dispose();terminalWidget=null;if(sendClose&&state.session)try{await api('terminal/close',{});}catch{};}terminalReading=false;}
function b64(bytes){let text='';for(const byte of bytes)text+=String.fromCharCode(byte);return btoa(text);}
async function startTerminal(){if(terminalWidget||terminalConnecting)return;terminalConnecting=true;const generation=++terminalGeneration;try{await api('terminal/open',{});if(generation!==terminalGeneration||state.view!=='terminal'||!$('#terminal-screen')){await api('terminal/close',{});return;}const screen=$('#terminal-screen');screen.innerHTML='';terminalWidget=new Terminal({cols:Math.max(20,Math.min(160,Math.floor((screen.clientWidth-36)/8))),rows:24,fontSize:13,fontFamily:'Cascadia Mono, Consolas, monospace',cursorBlink:true,screenReaderMode:true,theme:{background:'#191d32',foreground:'#e7e4f7',cursor:'#b8a6ff'}});terminalWidget.open(screen);terminalWidget.focus();terminalWidget.onData(data=>{const bytes=new TextEncoder().encode(data);for(let i=0;i<bytes.length;i+=768){const piece=b64(bytes.slice(i,i+768));terminalInput=terminalInput.then(()=>generation===terminalGeneration?api('terminal/write',{data:piece}):undefined).catch(error=>toast(error.message,true));}});await api('terminal/resize',{cols:terminalWidget.cols,rows:24});terminalPoll=setInterval(async()=>{if(terminalReading||!terminalWidget)return;terminalReading=true;try{const result=await api('terminal/read',{});if(generation!==terminalGeneration)return;if(terminalWidget&&result.data){const raw=atob(result.data);terminalWidget.write(Uint8Array.from(raw,c=>c.charCodeAt(0)));}if(result.closed){await disposeTerminal(false);toast('Terminal session ended.');renderContent();}}catch(error){toast(error.message,true);await disposeTerminal();if(state.session)renderContent();}finally{terminalReading=false;}},350);}catch(error){toast(error.message,true);await disposeTerminal();}finally{terminalConnecting=false;}}
document.addEventListener('submit',async event=>{const form=event.target;if(!form.dataset.tenantForm)return;event.preventDefault();const action=form.dataset.tenantForm,data=Object.fromEntries(new FormData(form));const submit=$('button[type=submit]',form);submit.disabled=true;try{const path=({'create-owner':'owners/create',shell:'owners/shell',password:'owners/password','create-db':'databases/create','assign-domain':'domains/assign',delegate:'domains/delegate',revoke:'domains/revoke'})[action];if(data.ttl)data.ttl=Number(data.ttl);await api(path,data);form.querySelectorAll('input[type=password]').forEach(input=>input.value='');closeDialog();toast('Saved');await refresh();}catch(error){$('.login-error',form).textContent=error.message;submit.disabled=false;}});
document.addEventListener('click',async event=>{const button=event.target.closest('[data-tenant]');if(!button||button.disabled)return;const action=button.dataset.tenant;try{if(['create-owner','shell','password','create-db','assign-domain','delegate','revoke'].includes(action))tenantDialog(action,button.dataset.owner||selectedOwner(),button.dataset.domain||button.dataset.engine,button.dataset.label||button.dataset.kind);else if(action==='terminal-open')await startTerminal();else if(action==='terminal-close'){await disposeTerminal();renderContent();}else if(action==='impersonate-start'){state.session=await api('impersonate/start',{owner:button.dataset.owner});state.session=await api('session');state.view='workspace';history.replaceState(null,'','#workspace');renderShell();await refresh();}else if(action==='impersonate-stop'){await disposeTerminal();state.session=await api('impersonate/stop',{});state.session=await api('session');state.view='owners';history.replaceState(null,'','#owners');renderShell();await refresh();}else if(action==='preview-admin'){state.session=await api('demo/role',{admin:true});state.view='owners';history.replaceState(null,'','#owners');renderShell();await refresh();}else if(action==='login-mode'){loginMode=button.dataset.mode;if(loginMode==='admin')await syncAuthMode();renderLogin();}else if(action==='tool'){if(state.session.demo)showDialog(`<h2 id="dialog-title">${button.dataset.engine==='mariadb'?'phpMyAdmin':'pgAdmin 4'}</h2><p>This preview does not run third-party database applications. The Ubuntu deployment includes protected routes and configuration for this tool.</p><p>On your server, sign in with your own ${esc(selectedOwner())}_* database credentials. Database tools never receive a shared administrative database account.</p><div class="dialog-actions"><button class="button primary" data-action="close-dialog">Understood</button></div>`);else window.open(button.dataset.engine==='mariadb'?state.tools.phpmyadmin:state.tools.pgadmin,'_blank','noopener,noreferrer');}}catch(error){toast(error.message,true);}});
document.addEventListener('change',async event=>{if(event.target.id==='workspace-owner'){state.owner=event.target.value;state.dns={domain:'',connected:false,records:[],page:1,pages:1};try{await loadTenant();renderContent();}catch(error){toast(error.message,true);}}});
window.addEventListener('hashchange',()=>{if(state.view!=='terminal')disposeTerminal();});

state.mail={enabled:false,configured:false,applied:true,mailboxes:[],domains:[]};
state.dns={domain:'',connected:false,records:[],page:1,pages:1,error:''};
let dnsLoading=false;
document.addEventListener('click',async event=>{const button=event.target.closest('[data-hosting]');if(!button||button.disabled)return;const action=button.dataset.hosting;try{if(action==='dns-prev'||action==='dns-next'){state.dns.page+=action==='dns-next'?1:-1;await loadDNS();renderContent();}else if(action==='mail-apply'){await api('mail/apply',{owner:selectedOwner()});await refresh();}else hostingDialog(action,button);}catch(error){toast(error.message,true);}});
document.addEventListener('submit',async event=>{const form=event.target;if(!form.dataset.hostingForm)return;event.preventDefault();const action=form.dataset.hostingForm,data=Object.fromEntries(new FormData(form));data.owner=selectedOwner();if('enabled'in data)data.enabled=data.enabled==='true';let payload=data;const submit=$('button[type=submit]',form);submit.disabled=true;try{const routes={'mail-choice':'mail/preference','mail-create':'mail/create','mail-password':'mail/password','mail-toggle':'mail/toggle','dns-connect':'dns/connect','dns-disconnect':'dns/disconnect','dns-create':'dns/create','dns-update':'dns/update','dns-delete':'dns/delete'};if(action==='dns-create'||action==='dns-update'){payload={owner:data.owner,domain:data.domain,record:{type:data.type,name:data.name,content:data.content,ttl:Number(data.ttl),priority:Number(data.priority),proxied:data.proxied==='true'}};if(data.type==='SRV'){payload.record.data={port:Number(data.port),priority:Number(data.priority),weight:Number(data.weight),target:data.content};delete payload.record.content;delete payload.record.priority;}if(data.id)payload.id=data.id;}await api(routes[action],payload);form.querySelectorAll('input[type=password]').forEach(input=>input.value='');closeDialog();toast('Saved');await refresh();}catch(error){$('.login-error',form).textContent=error.message;submit.disabled=false;}});
document.addEventListener('change',async event=>{if(event.target.id==='dns-domain'){state.dns={domain:event.target.value,connected:false,records:[],page:1,pages:1};await loadDNS();renderContent();}});
window.addEventListener('hashchange',async()=>{if(state.view==='dns'){await loadDNS();if(state.view==='dns')renderContent();}});




setInterval(async()=>{if(!state.session&&$('#login-form'))await syncAuthMode();},15000);
