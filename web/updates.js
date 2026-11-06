'use strict';
state.release={installedTag:'',availableTag:'',status:'not-checked',message:'',checkedAt:0,automatic:false,tokenConfigured:false};
labels.updates='Panel updates';
async function loadReleaseStatus(){if(isOwner()||!can('updates.read'))return;state.release=await api('release/status');}
function updatesView(){
 const release=state.release,installed=release.installedTag||'Source build',available=release.availableTag||'Not checked';
 const newer=release.availableTag&&release.availableTag!==release.installedTag&&['available','failed'].includes(release.status);
 const busy=['downloading','installing'].includes(release.status);
 const tag=/^v[0-9]+\.[0-9]+\.[0-9]+(?:-(?:alpha|beta)\.[0-9]+)?$/.test(release.availableTag||'')?release.availableTag:'';
 const releaseLink=tag?`<a class="text-link" href="https://github.com/patriumgroup/Harbor/releases/tag/${encodeURIComponent(tag)}" target="_blank" rel="noopener noreferrer">View release on GitHub ↗</a>`:'';
 const message=release.message?`<div class="${release.status==='failed'?'connection-error':'muted'}" role="status">${esc(release.message)}</div>`:'';
 return `<div class="detail-grid"><article class="card detail-card"><h2>Harbor version</h2>${facts([['Installed',installed],['Latest release',available],['Check status',titleCase(release.status.replaceAll('-',' '))],['Last checked',release.checkedAt?new Date(release.checkedAt*1000).toLocaleString():'Never']])}${message}<div class="dialog-actions"><button class="button" data-release-check ${!can('updates.manage')||busy?'disabled':''}>Check for updates</button><button class="button primary" data-release-apply ${!can('updates.manage')||!newer||busy?'disabled':''}>Install ${esc(tag||'update')}</button></div>${releaseLink}<p class="muted">Installing an update may briefly disconnect this panel. A private backup is created on the server first.</p></article><article class="card detail-card"><h2>Automatic updates</h2><p>Disabled by default. When enabled, Harbor checks the private release channel each day and installs a newer version. Schedule maintenance around possible service restarts.</p>${facts([['Schedule',release.automatic?'Daily, with a random delay':'Off'],['GitHub access',release.tokenConfigured?'Repository token configured':'Token needed for this private repository']])}${state.session.superAdmin?`<div class="dialog-actions"><button class="button ${release.automatic?'danger':''}" data-release-auto="${release.automatic?'false':'true'}" ${!release.automatic&&!release.tokenConfigured?'disabled':''}>${release.automatic?'Turn off automatic updates':'Turn on automatic updates'}</button></div>`:''}</article></div>${state.session.superAdmin?`<article class="card detail-card"><h2>Private repository access</h2><p>Use a fine-grained GitHub token limited to this repository with <b>Contents: read</b>. Harbor stores it in a root-only server file. The token is never returned to the browser.</p><form id="release-token-form" class="section-toolbar"><label>Repository token<input name="token" type="password" autocomplete="new-password" required minlength="24" maxlength="255" placeholder="github_pat_…"></label><button class="button primary" type="submit">Save token</button><button class="button" type="button" data-release-clear ${release.tokenConfigured?'':'disabled'}>Remove token</button></form><p class="login-error" role="alert"></p></article>`:''}`;
}
document.addEventListener('click',async event=>{
 const check=event.target.closest('[data-release-check]'),apply=event.target.closest('[data-release-apply]'),automatic=event.target.closest('[data-release-auto]'),clear=event.target.closest('[data-release-clear]');
 if(!check&&!apply&&!automatic&&!clear)return;
 const button=check||apply||automatic||clear;if(button.disabled)return;
 if(apply){const tag=state.release.availableTag;if(!/^v[0-9]+\.[0-9]+\.[0-9]+(?:-(?:alpha|beta)\.[0-9]+)?$/.test(tag||''))return;showDialog(`<h2 id="dialog-title">Install ${esc(tag)}?</h2><p>Harbor will verify the release, back up the current installation and restart panel services. You may need to sign in again.</p><form id="release-confirm-form"><button type="button" class="button" data-action="close-dialog">Cancel</button><button type="submit" class="button primary">Install update</button></form>`);return;}
 button.disabled=true;try{if(check){const result=await api('release/check',{});toast(result.message||'Release check queued.');}
  else if(automatic){state.release=await api('release/auto',{enabled:automatic.dataset.releaseAuto==='true'});toast('Automatic update preference saved.');}
  else if(clear){state.release=await api('release/token',{action:'clear'});toast('Repository token removed.');}
  await loadReleaseStatus();renderContent();
 }catch(error){toast(error.message,true);button.disabled=false;}
});
document.addEventListener('submit',async event=>{
 if(event.target.id==='release-token-form'){
  event.preventDefault();const form=event.target,token=String(new FormData(form).get('token')||''),button=$('button[type=submit]',form);button.disabled=true;
  try{state.release=await api('release/token',{action:'set',token});form.reset();renderContent();toast('Repository token saved.');}
  catch(error){$('.login-error',form).textContent=error.message;button.disabled=false;}
 }else if(event.target.id==='release-confirm-form'){
  event.preventDefault();const tag=state.release.availableTag;closeDialog();try{const result=await api('release/apply',{tag});toast(result.message||'Update queued.');await loadReleaseStatus();renderContent();}
  catch(error){toast(error.message,true);}
 }
});
window.addEventListener('hashchange',async()=>{if(state.view==='updates'&&can('updates.read'))try{await loadReleaseStatus();if(state.view==='updates')renderContent();}catch(error){toast(error.message,true);}});
