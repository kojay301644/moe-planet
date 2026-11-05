// 萌獸星球 × Supabase:把遊戲原本用的雲端資料介面接到你自己的 Supabase 專案。
// 必須用帳號密碼登入才能遊玩(不再自動建立匿名帳號),存檔、天梯、好友、聊天都會存到雲端。
(()=>{const C=window.MOE_CFG;if(!C||!C.url||!C.key||C.url.includes('請貼上')||!window.supabase){console.warn('MOE: 未設定雲端,使用離線模式');return}
const sb=supabase.createClient(C.url,C.key,{auth:{persistSession:true,autoRefreshToken:true,storageKey:'moe-auth'},realtime:{params:{eventsPerSecond:20}}});
let uid=null;
const ready=(async()=>{const {data:{session}}=await sb.auth.getSession();uid=session?session.user.id:null;return uid})();
const parent=p=>p.split('/').slice(0,-1).join('/');
const snap=(id,data)=>({id,exists:data!=null,data:()=>data==null?undefined:JSON.parse(JSON.stringify(data))});
const err=e=>{const x=new Error(e.message||String(e));x.code=e.code==='42501'?'permission_denied':'invalid_argument';return x};
function doc(path){const id=path.split('/').pop();return{id,path,
  async get(){await ready;const {data,error}=await sb.from('docs').select('data').eq('path',path).maybeSingle();if(error)throw err(error);return snap(id,data?data.data:null)},
  async set(d){await ready;const {error}=await sb.from('docs').upsert({path,coll:parent(path),data:d,updated_at:new Date().toISOString()});if(error)throw err(error)},
  async update(d){await ready;const {error}=await sb.rpc('doc_merge',{p_path:path,p_patch:d});if(error)throw err(error)},
  async delete(){await ready;const {error}=await sb.from('docs').delete().eq('path',path);if(error)throw err(error)},
  collection:c=>coll(path+'/'+c)}}
function coll(cpath,f=[],o=null,n=100){const q={path:cpath,
  where:(a,op,v)=>coll(cpath,[...f,[a,op,v]],o,n),orderBy:(a,d)=>coll(cpath,f,[a,d||'asc'],n),limit:k=>coll(cpath,f,o,k),doc:id=>doc(cpath+'/'+id),
  async get(){await ready;const {data,error}=await sb.rpc('query_docs',{p_coll:cpath,p_filters:f,p_order:o?o[0]:null,p_desc:o?o[1]==='desc':false,p_limit:n});if(error)throw err(error);const docs=(data||[]).map(r=>snap(r.path.split('/').pop(),r.data));return{docs,size:docs.length,empty:!docs.length}},
  onSnapshot(cb,e){let stop=false;const tick=async()=>{if(stop)return;try{cb(await q.get())}catch(x){e&&e(x)}setTimeout(tick,10000)};tick();return()=>{stop=true}}};return q}
const db={doc,collection:coll};
const user={id:async()=>{await ready;return uid},me:async()=>({name:''}),can:async()=>true,isOwner:()=>false,canEdit:()=>false,profiles:async()=>({})};
window.claude={use:async k=>{try{await ready}catch(e){console.warn('MOE: 雲端連線失敗',e);return null}if(!uid)return null;return k==='db'?db:k==='user'?user:null}};
window.MOE_SB=sb;
// 帳號密碼:帳號會對應成內部用的信箱(不會寄信),第一次建立帳號時直接綁定目前的匿名帳號,進度不變
const em=u=>String(u).trim().toLowerCase()+'@player.moe-planet.app';
const isPl=e=>/@player\.moe-planet\.app$/i.test(e||'');
// Google 登入或綁定失敗時,錯誤會放在網址上帶回來
let AERR='';try{const q=new URLSearchParams(location.search+'&'+location.hash.slice(1)),d=q.get('error_description')||q.get('error');if(d){AERR=/already linked|identity_already_exists|already been linked/i.test(d)?'這個 Google 帳號已經綁定在其他遊戲帳號上了':/access_denied|cancel/i.test(d)?'已取消 Google 登入':'Google 登入失敗:'+d;history.replaceState(null,'',location.pathname)}}catch(e){}
const msg=e=>{const m=(e&&(e.message||e.code))||'';return /provider is not enabled|Unsupported provider/i.test(m)?'伺服器還沒開啟 Google 登入':/already|exists|registered/i.test(m)?'這個帳號已經有人使用':/Invalid login/i.test(m)?'帳號或密碼錯誤':/Password should|weak/i.test(m)?'密碼太簡單,請至少 6 個字元並混合英數':/rate|too many/i.test(m)?'嘗試太多次,請稍後再試':/confirm/i.test(m)?'伺服器需要關閉「Confirm email」設定':m||'發生錯誤,請稍後再試'};
window.MOE_AUTH={
  async info(){await ready.catch(()=>{});const {data:{session}}=await sb.auth.getSession();if(!session)return {uid:null,out:true};const {data:{user}}=await sb.auth.getUser();if(!user)return {uid:null,out:true};
    const e=user.email||'',pw=isPl(e),g=(user.identities||[]).find(i=>i.provider==='google'),gm=g?((g.identity_data||{}).email||(!pw?e:'')):'';
    return {uid:user.id,anon:!e&&!g,name:pw?e.split('@')[0]:g?(gm||'Google 帳號'):(e?e.split('@')[0]:null),acct:pw?e.split('@')[0]:null,hasPw:pw,google:!!g,gmail:gm,pending:!!user.new_email&&!e}},
  // Google 登入 / 綁定:會跳到 Google 頁面,登入後回到遊戲
  async google(){const {error}=await sb.auth.signInWithOAuth({provider:'google',options:{redirectTo:location.origin+location.pathname,queryParams:{prompt:'select_account'}}});if(error)throw new Error(msg(error))},
  async linkGoogle(){const {error}=await sb.auth.linkIdentity({provider:'google',options:{redirectTo:location.origin+location.pathname}});if(error)throw new Error(/manual linking/i.test(error.message||'')?'伺服器需要開啟「Allow manual linking」設定':msg(error))},
  err:AERR,
  async register(u,p){const {data:{session}}=await sb.auth.getSession();if(session){const {data,error}=await sb.auth.updateUser({email:em(u),password:p});if(error)throw new Error(msg(error));if(!isPl(data.user.email))throw new Error('伺服器需要關閉「Confirm email」與「Secure email change」設定才能設定帳號');return}
    const {data,error}=await sb.auth.signUp({email:em(u),password:p});if(error)throw new Error(msg(error));if(!data.session)throw new Error(data.user&&data.user.identities&&!data.user.identities.length?'這個帳號已經有人使用':'伺服器需要關閉「Confirm email」設定才能建立帳號')},
  async login(u,p){const {error}=await sb.auth.signInWithPassword({email:em(u),password:p});if(error)throw new Error(msg(error))},
  async verify(p){const {data:{user}}=await sb.auth.getUser();if(!user||!user.email)throw new Error('訪客帳號沒有密碼');const {error}=await sb.auth.signInWithPassword({email:user.email,password:p});if(error)throw new Error(/Invalid login/i.test(error.message||'')?'密碼錯誤':msg(error))},
  async logout(){await sb.auth.signOut()},
  async changePw(p){const {error}=await sb.auth.updateUser({password:p});if(error)throw new Error(msg(error))}};
})();
