/* Salva o progresso dos jogos por USUÁRIO (nuvem). Carregue depois de questoes/config.js */
(function(){
 var C=window.QCFG||{};if(!C.url||!C.key)return;
 var PRE='fabricaRele_',LS=window.localStorage,SET=Storage.prototype.setItem,REM=Storage.prototype.removeItem;
 function g(k){try{return LS.getItem(k)}catch(e){return null}}
 function s(k,v){try{SET.call(LS,k,v)}catch(e){}}
 function user(){try{return JSON.parse(g('fr_user')||'null')}catch(e){return null}}
 function rpc(fn,a,keep){return fetch(C.url+'/rest/v1/rpc/'+fn,{method:'POST',keepalive:!!keep,headers:{apikey:C.key,Authorization:'Bearer '+C.key,'Content-Type':'application/json'},body:JSON.stringify(a)}).then(function(r){return r.json().catch(function(){return null})})}
 var U=user(),dirty={},timer=null;
 function creds(u){return {p_name:u.name,p_class:u.cls,p_pin:u.pin}}
 function push(keep){clearTimeout(timer);var u=user();if(!u)return;Object.keys(dirty).forEach(function(k){var v=g(k);if(v===null)return;var a=creds(u);a.p_key=k;try{a.p_data=JSON.parse(v)}catch(e){return}delete dirty[k];rpc('progress_save',a,keep).then(function(j){if(j&&j.error&&/PIN|encontrado/.test(j.error)){clearUser(true)}}).catch(function(){dirty[k]=1})})}
 Storage.prototype.setItem=function(k,v){SET.call(this,k,v);if(this===LS&&String(k).indexOf(PRE)===0&&user()){dirty[k]=1;clearTimeout(timer);timer=setTimeout(function(){push()},1200)}};
 window.addEventListener('pagehide',function(){push(true)});document.addEventListener('visibilitychange',function(){if(document.hidden)push(true)});
 function wipe(){try{Object.keys(LS).filter(function(k){return k.indexOf(PRE)===0}).forEach(function(k){REM.call(LS,k)})}catch(e){}}
 function sum(o){var t=0;if(o&&o.stars)Object.keys(o.stars).forEach(function(k){t+=+o.stars[k]||0});return t}
 function merge(a,b){/* a=local b=servidor */var base=sum(b)>sum(a)?b:a,o=JSON.parse(JSON.stringify(base)),other=base===a?b:a;
  ['stars','best'].forEach(function(f){if(other&&other[f]){o[f]=o[f]||{};Object.keys(other[f]).forEach(function(k){if(!(k in o[f])||(+other[f][k]||0)>(+o[f][k]||0))o[f][k]=other[f][k]})}});
  if(other&&other.tries){o.tries=o.tries||{};Object.keys(other.tries).forEach(function(k){o.tries[k]=Math.max(+o.tries[k]||0,+other.tries[k]||0)})}return o}
 function pull(u,cb,auth){rpc('progress_load',creds(u)).then(function(j){if(!j||j.error){cb(j&&j.error||'Sem conexão');return}
   var changed=false,srv=j.data||{};
   var lu=g('fr_last');if(lu!==u.name+'|'+u.cls){if(lu){wipe();changed=true}s('fr_last',u.name+'|'+u.cls)}
   Object.keys(srv).forEach(function(k){var loc=null;try{loc=JSON.parse(g(k)||'null')}catch(e){}var m=loc?merge(loc,srv[k]):srv[k],t=JSON.stringify(m);if(t!==g(k)){s(k,t);changed=true}if(!loc||t!==JSON.stringify(srv[k]))dirty[k]=1});
   Object.keys(LS).forEach(function(k){if(k.indexOf(PRE)===0&&!(k in srv)){if(auth){REM.call(LS,k);changed=true}else dirty[k]=1}});
   if(Object.keys(dirty).length)push();cb(null,changed)}).catch(function(){cb('Sem conexão')})}
 function clearUser(bad){try{REM.call(LS,'fr_user')}catch(e){}wipe();try{REM.call(LS,'fr_last')}catch(e){}U=null;if(bad)alert('Seu login expirou ou o PIN mudou. Entre de novo.');location.reload()}
 /* interface */
 function ui(){
  var st=document.createElement('style');st.textContent='#frb{position:fixed;bottom:8px;left:8px;z-index:99999;font:800 13px/1.2 system-ui,sans-serif;background:#fff;color:#2b2250;border:3px solid #2b2250;border-radius:12px;padding:6px 10px;cursor:pointer;box-shadow:0 3px 0 #2b2250;max-width:62vw;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}#frb.on{background:#c8f7d2}#frm{position:fixed;inset:0;z-index:100000;background:rgba(43,34,80,.6);display:flex;align-items:center;justify-content:center;font-family:system-ui,sans-serif}#frm .c{background:#fff;border:4px solid #2b2250;border-radius:18px;padding:16px;width:min(92vw,340px);color:#2b2250}#frm h3{margin:0 0 8px}#frm input{width:100%;box-sizing:border-box;font:inherit;padding:8px;margin:4px 0;border:3px solid #2b2250;border-radius:10px}#frm button{font:inherit;font-weight:900;border:3px solid #2b2250;border-radius:12px;padding:7px 12px;margin:6px 6px 0 0;cursor:pointer;background:#ffd23f;color:#2b2250}#frm .e{color:#c62828;font-weight:700;min-height:18px;font-size:13px}#frm small{display:block;opacity:.75;margin-top:6px}';
  document.head.appendChild(st);
  var b=document.createElement('div');b.id='frb';document.body.appendChild(b);
  function paint(){b.className=U?'on':'';b.textContent=U?'👤 '+U.name+' · '+U.cls+' ☁':'👤 Entrar para salvar na nuvem';b.title=U?'Progresso salvo na sua conta':'Seu progresso hoje fica só neste navegador'}
  paint();b.onclick=function(){U?out():login()};
  function m(h){var d=document.createElement('div');d.id='frm';d.innerHTML='<div class="c">'+h+'</div>';d.onclick=function(e){if(e.target===d)d.remove()};document.body.appendChild(d);return d}
  function out(){var d=m('<h3>👤 '+U.name+'</h3><p>Turma '+U.cls+'. Seu progresso está salvo na nuvem.</p><button id="so">Sair desta conta</button><button id="sc" style="background:#eee">Fechar</button>');d.querySelector('#sc').onclick=function(){d.remove()};d.querySelector('#so').onclick=function(){push(true);setTimeout(function(){clearUser(false)},400)}}
  function login(){var d=m('<h3>Entrar na minha conta</h3><input id="fn" placeholder="Nome completo"><input id="fc" placeholder="Turma (ex.: 2A)"><input id="fp" placeholder="PIN de 4 números" inputmode="numeric" maxlength="4" type="password"><div class="e" id="fe"></div><button id="fi">Entrar</button><button id="fk">Criar usuário</button><button id="fx" style="background:#eee">Agora não</button><small>É o mesmo usuário da Sala de Questões. O que você já jogou neste navegador será guardado na sua conta.</small>');
   var $=function(i){return d.querySelector(i)};$('#fx').onclick=function(){d.remove()};
   function go(fn){var u={name:$('#fn').value.trim().replace(/\s+/g,' '),cls:$('#fc').value.trim(),pin:$('#fp').value.trim()};if(u.name.length<2||!u.cls||!/^\d{4}$/.test(u.pin)){$('#fe').textContent='Preencha nome, turma e PIN de 4 números.';return}
    $('#fe').textContent='Aguarde…';rpc(fn,{p_name:u.name,p_class:u.cls,p_pin:u.pin}).then(function(j){if(!j||j.error||j.message){$('#fe').textContent=(j&&(j.error||j.message))||'Sem conexão.';return}
     u.name=j.name||u.name;u.cls=j.class||u.cls;s('fr_user',JSON.stringify(u));U=u;pull(u,function(err,ch){d.remove();paint();if(ch)location.reload()})}).catch(function(){$('#fe').textContent='Sem conexão com a internet.'})}
   $('#fi').onclick=function(){go('student_login')};$('#fk').onclick=function(){go('student_signup')}}
 }
 function boot(){ui();if(U)pull(U,function(err,ch){if(err&&/PIN|encontrado/.test(err)){clearUser(true);return}if(ch){var f='fr_rl_'+Date.now()%1e9;if(window.refresh&&document.querySelector('[data-game]'))window.refresh();else if(!sessionStorage.getItem('fr_rl')){try{sessionStorage.setItem('fr_rl','1')}catch(e){}location.reload()}}},true)}
 if(document.body)boot();else document.addEventListener('DOMContentLoaded',boot);
})();
