// 萌獸星球 × Supabase:把遊戲原本用的雲端資料介面接到你自己的 Supabase 專案。
// 每台裝置第一次開啟會自動建立一個匿名帳號,存檔、天梯、好友、聊天都會存到雲端。
(()=>{const C=window.MOE_CFG;if(!C||!C.url||!C.key||C.url.includes('請貼上')||!window.supabase){console.warn('MOE: 未設定雲端,使用離線模式');return}
const sb=supabase.createClient(C.url,C.key,{auth:{persistSession:true,autoRefreshToken:true,storageKey:'moe-auth'}});
let uid=null;
const ready=(async()=>{let {data:{session}}=await sb.auth.getSession();if(!session){const r=await sb.auth.signInAnonymously();if(r.error)throw r.error;session=r.data.session}uid=session.user.id;return uid})();
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
window.claude={use:async k=>{try{await ready}catch(e){console.warn('MOE: 雲端登入失敗',e);return null}return k==='db'?db:k==='user'?user:null}};
window.MOE_SB=sb;})();
