-- 萌獸星球 伺服器驗證(第 2 份 SQL):鑽石錢包、伺服器抽卡、天梯結算、玩家交易所
-- 在 Supabase → SQL Editor 貼上整段 → Run。可以重複執行,不會刪除資料。

-- ============ 錢包 ============
-- 後台顯示用的帳號名稱:帳號密碼玩家顯示帳號,Google 玩家顯示「G:信箱」
create or replace function public.moe_acct(e text) returns text language sql immutable as $$
  select case when coalesce(e, '') = '' then '' when e ilike '%@player.moe-planet.app' then split_part(e, '@', 1) else 'G:' || e end $$;
create table if not exists public.wallet(
  uid uuid primary key default auth.uid(),
  gem int not null default 160 check (gem >= 0),
  topup int not null default 0,
  pity int not null default 0, dpity int not null default 0,
  earn_day date, earn_today int not null default 0,
  flags int not null default 0, bank int not null default 0,
  updated_at timestamptz not null default now());
alter table public.wallet add column if not exists bank int not null default 0;
alter table public.wallet add column if not exists free_at timestamptz;
create table if not exists public.gem_log(id bigserial primary key, uid uuid not null, delta int not null, reason text, at timestamptz not null default now());
create table if not exists public.pay_first(uid uuid, pkg text, primary key(uid,pkg));
alter table public.wallet enable row level security;
alter table public.gem_log enable row level security;
alter table public.pay_first enable row level security;
drop policy if exists wallet_read on public.wallet;
create policy wallet_read on public.wallet for select to authenticated using (uid = auth.uid());
drop policy if exists gem_log_read on public.gem_log;
create policy gem_log_read on public.gem_log for select to authenticated using (uid = auth.uid());

create table if not exists public.bans(uid uuid primary key, reason text, until timestamptz, at timestamptz not null default now());
alter table public.bans enable row level security;
-- 單一裝置登入:每次開遊戲產生新的登入憑證,舊裝置的憑證就失效
create table if not exists public.sessions(uid uuid primary key, sid uuid not null, dev text, at timestamptz not null default now(), seen timestamptz not null default now());
alter table public.sessions enable row level security;
create or replace function public.moe_sid() returns uuid language sql stable as $$
  select nullif(coalesce((nullif(current_setting('request.headers', true),'')::json)->>'x-moe-sid',''),'')::uuid $$;
create or replace function public.moe_sess_ok() returns boolean language sql stable security definer set search_path = public as $$
  select moe_sid() is null or auth.uid() is null or not exists (select 1 from sessions s where s.uid = auth.uid() and s.sid <> moe_sid()) $$;
create or replace function public.moe_uid() returns uuid language plpgsql stable security definer set search_path = public as $$
begin if auth.uid() is null then raise exception 'not signed in'; end if;
  if not moe_sess_ok() then raise exception 'kicked'; end if;
  if exists (select 1 from bans where uid = auth.uid() and (until is null or until > now())) then raise exception 'banned'; end if;
  if to_regclass('public.settings') is not null and exists (select 1 from settings where k = 'maint' and (v->>'on')::boolean)
     and not exists (select 1 from admins where uid = auth.uid()) then raise exception 'maintenance'; end if;
  return auth.uid(); end $$;
create or replace function public.moe_today() returns date language sql stable as $$ select (now() at time zone 'Asia/Taipei')::date $$;
create or replace function public.moe_vip(p_topup int) returns int language sql immutable as $$
  select coalesce((select max(i) from unnest(array[0,60,330,980,1980,3280,6480,9800,19800,32800,64800]) with ordinality t(v,i) where p_topup >= v),1)::int - 1 $$;

-- 第一次連線:建立錢包(新玩家 160 鑽石)
create table if not exists public.player_day(uid uuid, d date, primary key(uid, d));
alter table public.player_day enable row level security;
create or replace function public.wallet_init(p_local int) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); w wallet;
begin
  insert into wallet(uid) values (u) on conflict (uid) do nothing;
  insert into player_day values (u, moe_today()) on conflict do nothing;
  select * into w from wallet where uid = u;
  return jsonb_build_object('gem',w.gem,'topup',w.topup,'pity',w.pity,'dpity',w.dpity,'bank',w.bank,'free_at',w.free_at);
end $$;

-- 同步:遊戲中賺到的鑽石(不設每日上限,單日收入過高會列入後台異常名單)與花掉的鑽石
create or replace function public.gem_sync(p_earn int, p_spend int) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); w wallet; e int; s int;
begin
  select * into w from wallet where uid = u for update;
  if not found then insert into wallet(uid) values (u) returning * into w; end if;
  if w.earn_day is distinct from moe_today() then w.earn_day := moe_today(); w.earn_today := 0; end if;
  insert into player_day values (u, moe_today()) on conflict do nothing;
  e := w.bank + greatest(coalesce(p_earn,0),0);
  w.bank := 0;
  s := greatest(coalesce(p_spend,0),0);
  w.gem := w.gem + e; w.earn_today := w.earn_today + e;
  if s > w.gem then w.flags := w.flags + 1; s := w.gem; end if;
  w.gem := w.gem - s;
  update wallet set gem = w.gem, bank = w.bank, earn_day = w.earn_day, earn_today = w.earn_today, flags = w.flags, updated_at = now() where uid = u;
  if e > 0 then insert into gem_log(uid,delta,reason) values (u, e, 'earn'); end if;
  if s > 0 then insert into gem_log(uid,delta,reason) values (u, -s, 'spend'); end if;
  return jsonb_build_object('gem',w.gem,'topup',w.topup,'earned',e,'spent',s,'bank',w.bank);
end $$;

-- 伺服器抽卡(單抽 160、十連 1440)
drop function if exists public.summon(int,text);
create or replace function public.summon(p_n int, p_wish text default null, p_free boolean default false) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); w wallet; cost int; res jsonb := '[]'::jsonb; i int; r float; q int; k text; tot float; acc float;
  ks text[] := array['fox','otter','penguin','pango','ferret','whale','bear','dragon','bunny','mouse','mole','puffer','owl','lizard','deer','moth','armad','seal','marten','phoenix'];
  ws float[] := array[1,1,1,1,1,1,.5,.08,1,1,1,1,1,1,1,1,.5,.5,.5,.08];
  epic text[] := array['bear','armad','seal','marten']; anyhi boolean := false; up boolean;
begin
  up := to_regclass('public.game_event') is not null and exists (select 1 from game_event where kind = 'sumup' and starts <= now() and ends > now());
  if p_n not in (1,10) then raise exception 'bad n'; end if;
  cost := case when p_free then 0 when p_n = 10 then 1440 else 160 end;
  select * into w from wallet where uid = u for update;
  if not found then raise exception 'not enough gem'; end if;
  if p_free then
    if p_n <> 1 then raise exception 'bad n'; end if;
    if w.free_at is not null and w.free_at > now() - interval '24 hours' then raise exception '免費召喚還在冷卻中'; end if;
    update wallet set free_at = now() where uid = u;
  elsif w.gem < cost then raise exception 'not enough gem'; end if;
  w.gem := w.gem - cost;
  select sum(x) into tot from unnest(ws) x;
  for i in 1..p_n loop
    w.pity := w.pity + 1; w.dpity := w.dpity + 1; r := random();
    q := case when r < (case when up then .03 else .015 end) then 3 when r < (case when up then .15 else .1 end) then 2 when r < .4 then 1 else 0 end;
    if w.pity >= 80 then q := 3; end if;
    if p_n = 10 and i = 10 and not anyhi and q < 1 then q := 1; end if;
    if q >= 1 then anyhi := true; end if;
    if q = 3 then w.pity := 0; end if;
    if w.dpity >= 200 then k := case when random() < .5 then 'dragon' else 'phoenix' end;
    else r := random() * tot; acc := 0; k := ks[1];
      for j in 1..array_length(ks,1) loop acc := acc + ws[j]; if r < acc then k := ks[j]; exit; end if; end loop;
    end if;
    if q >= 2 and p_wish = any(epic) and k not in ('dragon','phoenix') and random() < .5 then k := p_wish; end if;
    if k in ('dragon','phoenix') then w.dpity := 0; end if;
    res := res || jsonb_build_object('k',k,'q',q);
  end loop;
  update wallet set gem = w.gem, pity = w.pity, dpity = w.dpity, updated_at = now() where uid = u;
  insert into gem_log(uid,delta,reason) values (u, -cost, case when p_free then 'summon_free' else 'summon'||p_n end);
  return jsonb_build_object('gem',w.gem,'pity',w.pity,'dpity',w.dpity,'res',res,'free_at',(select free_at from wallet where uid = u));
end $$;

-- 測試用儲值(之後串金流時改成由金流通知呼叫)
create or replace function public.topup_test_impl(p_pkg text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); g int; b int; first boolean; w wallet;
begin
  select v.g, v.b into g, b from (values ('p30',60,0),('p150',300,30),('p300',600,80),('p790',1580,300),('p1490',2980,700),('p3290',6580,1900),('card',300,0),('fund',600,0)) v(id,g,b) where v.id = p_pkg;
  if g is null then raise exception 'bad pkg'; end if;
  insert into pay_first(uid,pkg) values (u,p_pkg) on conflict do nothing; first := found;
  if first and p_pkg not in ('card','fund') then b := g; end if;
  insert into wallet(uid) values (u) on conflict do nothing;
  update wallet set gem = gem + g + b, topup = topup + g, updated_at = now() where uid = u returning * into w;
  insert into gem_log(uid,delta,reason) values (u, g + b, 'topup:'||p_pkg);
  return jsonb_build_object('gem',w.gem,'topup',w.topup,'bonus',b,'first',first);
end $$;

-- ============ 天梯 ============
create table if not exists public.ladder(
  uid uuid primary key default auth.uid(), ss int not null, pts int not null default 0, best int not null default 0,
  w int not null default 0, l int not null default 0, ls int not null default 0,
  day date, used int not null default 0, bought int not null default 0, flags int not null default 0,
  last_at timestamptz, updated_at timestamptz not null default now());
alter table public.ladder enable row level security;
drop policy if exists ladder_read on public.ladder;
create policy ladder_read on public.ladder for select to authenticated using (true);
create or replace function public.moe_season() returns int language sql stable as $$
  select floor(extract(epoch from (now() - timestamptz '2026-11-01 16:00:00+00')) / (14*86400))::int + 1 $$;

create or replace function public.ladder_row() returns ladder language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); L ladder; cur int := moe_season();
begin
  insert into ladder(uid, ss) values (u, cur) on conflict do nothing;
  select * into L from ladder where uid = u for update;
  if L.ss <> cur then L.pts := floor(L.pts * .5); L.best := L.pts; L.w := 0; L.l := 0; L.ls := 0; L.ss := cur; end if;
  if L.day is distinct from moe_today() then L.day := moe_today(); L.used := 0; L.bought := 0; end if;
  update ladder set ss=L.ss, pts=L.pts, best=L.best, w=L.w, l=L.l, ls=L.ls, day=L.day, used=L.used, bought=L.bought, updated_at=now() where uid = u;
  return L;
end $$;
create or replace function public.ladder_json(L ladder, p_extra int) returns jsonb language sql stable as $$
  select jsonb_build_object('ss',L.ss,'pts',L.pts,'best',L.best,'w',L.w,'l',L.l,'ls',L.ls,'tix',greatest(0,5 + p_extra + L.bought - L.used),'bought',L.bought) $$;
create or replace function public.ladder_me() returns jsonb language plpgsql security definer set search_path = public as $$
declare L ladder := ladder_row(); v int;
begin select moe_vip(topup) into v from wallet where uid = auth.uid(); v := coalesce(v,0);
  return ladder_json(L, (v>=1)::int + (v>=7)::int); end $$;

-- 回報一場天梯:伺服器檢查挑戰次數、戰力差距、戰鬥時間,再計算分數
create table if not exists public.ladder_def(id bigserial primary key, attacker uuid not null, defender uuid not null, att_win boolean not null, at timestamptz not null default now(), revenged boolean not null default false);
create index if not exists ladder_def_idx on public.ladder_def(defender, id);
alter table public.ladder_def enable row level security;
drop function if exists public.ladder_report(boolean,int,int,int,real,uuid,bigint);
create or replace function public.ladder_report(p_win boolean, p_opp_pts int, p_opp_pw int, p_my_pw int, p_secs real, p_opp_uid uuid default null, p_rev bigint default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); L ladder := ladder_row(); v int; extra int; g int; ok boolean := true; rv boolean := false;
begin
  select moe_vip(topup) into v from wallet where uid = u; v := coalesce(v,0); extra := (v>=1)::int + (v>=7)::int;
  if L.used >= 5 + extra + L.bought then raise exception 'no tickets'; end if;
  if L.last_at is not null and now() - L.last_at < interval '8 seconds' then raise exception 'too fast'; end if;
  p_opp_pts := least(greatest(coalesce(p_opp_pts, L.pts), 0), L.pts + 400);
  if p_win and (coalesce(p_secs,0) < 4 or coalesce(p_my_pw,0) * 2.5 < coalesce(p_opp_pw,0)) then ok := false; L.flags := L.flags + 1; end if;
  if p_win and ok then
    g := round(least(greatest(25 + (p_opp_pts - L.pts) / 10.0, 12), 40));
    if L.ls >= 3 then g := round(g * 1.5); end if;
    if p_rev is not null then update ladder_def set revenged = true where id = p_rev and defender = u and attacker = p_opp_uid and att_win and not revenged and at > now() - interval '1 day'; rv := found; if rv then g := g + 5; end if; end if;
    L.pts := L.pts + g; L.w := L.w + 1; L.ls := 0;
  else
    g := round(least(greatest(15 + (L.pts - p_opp_pts) / 12.0, 6), 25));
    L.pts := greatest(0, L.pts - g); L.l := L.l + 1; L.ls := L.ls + 1; g := -g;
  end if;
  L.best := greatest(L.best, L.pts); L.used := L.used + 1;
  update ladder set pts=L.pts, best=L.best, w=L.w, l=L.l, ls=L.ls, used=L.used, flags=L.flags, last_at=now(), updated_at=now() where uid = u;
  if p_opp_uid is not null and p_opp_uid <> u and p_rev is null then insert into ladder_def(attacker, defender, att_win) values (u, p_opp_uid, p_win and ok); delete from ladder_def where at < now() - interval '7 days'; end if;
  return ladder_json(L, extra) || jsonb_build_object('delta', g, 'ok', ok, 'rev', rv);
end $$;

create or replace function public.ladder_buy() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); L ladder := ladder_row(); v int;
begin
  if L.bought >= 10 then raise exception 'limit'; end if;
  update wallet set gem = gem - 30, updated_at = now() where uid = u and gem >= 30;
  if not found then raise exception 'not enough gem'; end if;
  insert into gem_log(uid,delta,reason) values (u,-30,'ladder_ticket');
  update ladder set bought = bought + 1 where uid = u;
  return ladder_me() || jsonb_build_object('gem',(select gem from wallet where uid = u));
end $$;

create or replace function public.ladder_top(p_limit int default 50) returns table(uid uuid, pts int, w int, l int, n text, av text, ti text, fr2 text, pw int)
language sql stable security definer set search_path = public as $$
  select l.uid, l.pts, l.w, l.l, d.data->>'n', d.data->>'av', d.data->>'ti', d.data->>'fr2', (d.data->>'pw')::int
  from ladder l left join docs d on d.path = 'arena/' || l.uid::text
  where l.ss = moe_season() and (l.w + l.l) > 0 and not exists (select 1 from bans b where b.uid = l.uid and (b.until is null or b.until > now())) order by l.pts desc limit least(greatest(p_limit,1),100) $$;

-- ============ 玩家交易所 ============
create table if not exists public.market(
  id bigserial primary key, seller uuid not null default auth.uid(), seller_name text, item jsonb not null, price int not null check (price > 0),
  status text not null default 'open', created timestamptz not null default now(), buyer uuid, sold_at timestamptz, ck timestamptz not null default now());
alter table public.market add column if not exists ck timestamptz not null default now();
alter table if exists public.inbox add column if not exists credit boolean not null default false;
create index if not exists market_open_idx on public.market(status, created);
create table if not exists public.inbox(id bigserial primary key, uid uuid not null, item jsonb, gem int not null default 0, note text, created timestamptz not null default now(), claimed boolean not null default false, credit boolean not null default false);
alter table public.inbox add column if not exists credit boolean not null default false;
alter table public.inbox add column if not exists title text;
alter table public.inbox add column if not exists kind text not null default 'system';
alter table public.inbox add column if not exists bonus jsonb;
create index if not exists inbox_uid_idx on public.inbox(uid, id);
create table if not exists public.mint_quota(uid uuid, wk int, kind text, n int not null default 0, primary key(uid, wk, kind));
alter table public.market enable row level security;
alter table public.inbox enable row level security;
alter table public.mint_quota enable row level security;
drop policy if exists market_read on public.market;
create policy market_read on public.market for select to authenticated using (true);
drop policy if exists inbox_read on public.inbox;
create policy inbox_read on public.inbox for select to authenticated using (uid = auth.uid());

-- 伺服器參考價(和遊戲裡的算法一致,不含市場熱度)
create or replace function public.moe_fair(it jsonb) returns int language sql immutable as $$
  select case when it ? 'mat' then greatest(1, round(coalesce((it->>'n')::numeric,1) * case it->>'mat'
      when 'stones' then 15 when 'enh' then 5 when 'ore' then 2 when 'reroll' then 20 when 'candy' then 1.5
      when 'shard' then case when it->>'pet' in ('dragon','phoenix') then 60 when it->>'pet' in ('bear','armad','seal','marten') then 25
        when it->>'pet' in ('ferret','whale','owl','lizard','deer','moth') then 12 else 6 end else 5 end))::int
  else greatest(5, round(
    (case when it ? 'uq' and coalesce(it->>'uq','') <> '' then 7000 else (array[12,40,220,2500,10000])[(it->>'rar')::int + 1] end)
    * (1 + .06 * coalesce((it->>'lv')::int,0))
    * (1 + coalesce((select sum((s->>1)::numeric) from jsonb_array_elements(coalesce(it->'subs','[]'::jsonb)) s),0) / 60)
    * (case when it->>'type' = 'bell' then 1.1 else 1 end)))::int end $$;

-- 上架:伺服器鑑定裝備數值是否合理,並限制每週可上架的高品質數量
create or replace function public.market_list(p_item jsonb, p_price int) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); rar int; lv int; ns int; f int; v_kind text; lim int; v_wk int := floor(extract(epoch from now())/(7*86400))::int; s jsonb; nm text; mx numeric;
begin
  rar := (p_item->>'rar')::int; lv := coalesce((p_item->>'lv')::int,0); ns := jsonb_array_length(coalesce(p_item->'subs','[]'::jsonb));
  if rar is null or rar < 1 or rar > 4 then raise exception '只有稀有以上的裝備可以上架'; end if;
  if lv < 0 or lv > 15 then raise exception '強化等級不合理'; end if;
  if (p_item->>'type') not in ('collar','hat','charm','bell') then raise exception '裝備種類不合理'; end if;
  if ns > rar + 1 then raise exception '副屬性數量不合理'; end if;
  if coalesce(p_item->>'set','basic') not in ('basic','fire','ice','elec','guard','wind','siege','hunt') then raise exception '套裝不合理'; end if;
  if (select count(distinct x->>0) from jsonb_array_elements(coalesce(p_item->'subs','[]'::jsonb)) x) <> ns then raise exception '副屬性重複'; end if;
  for s in select * from jsonb_array_elements(coalesce(p_item->'subs','[]'::jsonb)) loop
    mx := case s->>0 when 'atk' then 4 when 'hp' then 4 when 'def' then 4 when 'crit' then 4 when 'critd' then 12 when 'cdr' then 3 when 'boss' then 8 when 'siege' then 10 when 'heal' then 10 end;
    if mx is null or (s->>1)::numeric < 0 or (s->>1)::numeric > mx * (1 + floor(lv / 3)) + .05 then raise exception '副屬性數值不合理'; end if;
  end loop;
  if coalesce(p_item->>'uq','') <> '' and p_item->>'uq' not in ('vamp','wind','thorn','revenge') then raise exception '獨特裝備不合理'; end if;
  f := moe_fair(p_item);
  if p_price < ceil(f * .5) or p_price > floor(f * 2) then raise exception '價格要在 % ~ % 鑽石之間', ceil(f*.5), floor(f*2); end if;
  if (select count(*) from market where seller = u and status = 'open' and created > now() - interval '48 hours') >= 10 then raise exception '最多同時上架 10 件'; end if;
  v_kind := case when coalesce(p_item->>'uq','') <> '' then 'uq' else 'r' || rar end;
  lim := case v_kind when 'uq' then 1 when 'r4' then 1 when 'r3' then 2 when 'r2' then 10 else 30 end;
  insert into mint_quota(uid,wk,kind) values (u,v_wk,v_kind) on conflict do nothing;
  update mint_quota q set n = q.n + 1 where q.uid = u and q.wk = v_wk and q.kind = v_kind and q.n < lim;
  if not found then raise exception '這個品質本週上架次數已滿'; end if;
  select data->>'n' into nm from docs where path = 'arena/' || u::text;
  insert into market(seller, seller_name, item, price) values (u, coalesce(nm,'守護員'), p_item - 'id' - 'lock' - 'tb', p_price);
  return jsonb_build_object('ok', true, 'fair', f);
end $$;

create or replace function public.market_browse() returns setof market language sql stable security definer set search_path = public as $$
  select * from market where status = 'open' and created > now() - interval '48 hours' and seller <> auth.uid() order by created desc limit 60 $$;
create or replace function public.market_mine() returns setof market language sql stable security definer set search_path = public as $$
  select * from market where seller = auth.uid() and (status = 'open' or sold_at > now() - interval '7 days') order by created desc limit 30 $$;

-- 購買:同一筆交易內扣買家鑽石、給賣家 90%、裝備放進買家信箱
create or replace function public.market_buy(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); m market; g int;
begin
  select * into m from market where id = p_id for update;
  if not found or m.status <> 'open' or m.created < now() - interval '48 hours' then raise exception '這件已經賣掉或下架了'; end if;
  if m.seller = u then raise exception '不能買自己的裝備'; end if;
  update wallet set gem = gem - m.price, updated_at = now() where uid = u and gem >= m.price;
  if not found then raise exception '鑽石不足'; end if;
  g := floor(m.price * .9);
  insert into wallet(uid) values (m.seller) on conflict do nothing;
  update wallet set gem = gem + g, updated_at = now() where uid = m.seller;
  update market set status = 'sold', buyer = u, sold_at = now() where id = p_id;
  insert into inbox(uid, item, note, kind, title) values (u, m.item, '你在交易所買到的物品,領取後放進背包。', 'market', '交易所:購買成功');
  insert into inbox(uid, gem, note, kind, title) values (m.seller, g, '你上架的物品賣出了,鑽石已直接入帳(已扣 10% 手續費)。', 'market', '交易所:裝備賣出');
  insert into gem_log(uid,delta,reason) values (u, -m.price, 'market_buy:'||p_id), (m.seller, g, 'market_sell:'||p_id);
  return jsonb_build_object('gem', (select gem from wallet where uid = u), 'item', m.item);
end $$;

create or replace function public.market_cancel(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); m market;
begin
  select * into m from market where id = p_id and seller = u for update;
  if not found or m.status <> 'open' then raise exception '這件已經賣掉或下架了'; end if;
  update market set status = 'cancelled' where id = p_id;
  insert into inbox(uid, item, note, kind, title) values (u, m.item, '你下架的裝備,領取後回到背包。', 'market', '交易所:下架退回');
  return jsonb_build_object('ok', true);
end $$;

-- 其他守護員(含系統買家)也會買上架的裝備:定價越接近參考價越容易賣出(在伺服器上計算)
create or replace function public.market_tick(u uuid) returns void language plpgsql security definer set search_path = public as $$
declare m market; h float; p float; g int;
begin
  for m in select * from market where seller = u and status = 'open' for update loop
    h := greatest(0, extract(epoch from (least(now(), m.created + interval '48 hours') - m.ck)) / 3600);
    p := case when m.price > moe_fair(m.item) * 2 then 0 else greatest(.002, least(.5, .12 * power(moe_fair(m.item)::float / m.price, 4))) end;
    update market set ck = now() where id = m.id;
    if h > 0 and random() < 1 - power(1 - p, h) then
      g := floor(m.price * .9);
      update market set status = 'sold', sold_at = now() where id = m.id;
      update wallet set gem = gem + g, updated_at = now() where uid = u;
      insert into inbox(uid, gem, note, kind, title) values (u, g, '你上架的裝備賣出了,鑽石已直接入帳(已扣 10% 手續費)。', 'market', '交易所:裝備賣出');
      insert into gem_log(uid,delta,reason) values (u, g, 'market_sell_bot:'||m.id);
    end if;
  end loop;
end $$;
revoke execute on function public.market_tick(uuid) from public, anon, authenticated;

-- 信箱:列出信件(順便處理交易所過期退回、系統買家);已領取超過 30 天的信會自動刪除
create or replace function public.inbox_list() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid();
begin
  perform market_tick(u);
  insert into inbox(uid, item, note, kind, title) select seller, item, '上架 48 小時沒有賣出,領取後回到背包。', 'market', '交易所:過期退回' from market where seller = u and status = 'open' and created < now() - interval '48 hours';
  update market set status = 'expired' where seller = u and status = 'open' and created < now() - interval '48 hours';
  delete from inbox where uid = u and claimed and created < now() - interval '30 days';
  return jsonb_build_object('gem', (select gem from wallet where uid = u), 'mail', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'title', title, 'note', note, 'kind', kind, 'gem', gem, 'item', item, 'bonus', bonus, 'credit', credit, 'claimed', claimed, 'created', created) order by id desc), '[]'::jsonb)
    from (select * from inbox where uid = u order by id desc limit 100) x));
end $$;
-- 領取信件(p_id 留空 = 全部領取):裝備交給遊戲放進背包,營運寄的鑽石在這裡入帳
create or replace function public.inbox_take(p_id bigint default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); out jsonb; cr int;
begin
  with c as (update inbox set claimed = true where uid = u and not claimed and (p_id is null or id = p_id) returning id, item, gem, note, title, credit, bonus)
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'item', item, 'gem', gem, 'note', note, 'title', title, 'credit', credit, 'bonus', bonus) order by id), '[]'::jsonb), coalesce(sum(gem) filter (where credit), 0) into out, cr from c;
  if cr > 0 then insert into wallet(uid) values (u) on conflict do nothing; update wallet set gem = gem + cr, updated_at = now() where uid = u; insert into gem_log(uid,delta,reason) values (u, cr, 'mail'); end if;
  -- 資源帳本:信箱附帶的星星幣、進化石、糖果、碎片由伺服器直接入帳
  if to_regprocedure('public.moe_res_add(uuid,text,bigint)') is not null then
    perform moe_res_add(u, x.k, x.n::bigint) from (
      select b.key k, sum(coalesce((b.value #>> '{}')::bigint, 0)) n from jsonb_array_elements(out) it, jsonb_each(coalesce(it->'bonus', '{}'::jsonb)) b where b.key in ('coin','stones','candy') group by b.key
      union all select it->'item'->>'mat', sum(coalesce((it->'item'->>'n')::bigint, 0)) from jsonb_array_elements(out) it where it->'item'->>'mat' in ('stones','candy','shard') group by it->'item'->>'mat') x;
  end if;
  return jsonb_build_object('items', out, 'gem', (select gem from wallet where uid = u), 'res', (select moe_res_json(w) from wallet w where uid = u and r_on));
end $$;
-- 舊版相容
create or replace function public.inbox_claim() returns jsonb language sql security definer set search_path = public as $$ select inbox_take(null) $$;

-- ============ 跑馬燈:攻城消息 ============
create table if not exists public.events(id bigserial primary key, uid uuid, kind text, txt text not null, at timestamptz not null default now());
create index if not exists events_at_idx on public.events(at);
alter table public.events enable row level security;
drop policy if exists events_read on public.events;
create policy events_read on public.events for select to authenticated using (at > now() - interval '2 hours');
grant select on public.events to authenticated;
-- 遊戲回報攻城結果,文字由伺服器組成(同一個人 20 秒內只記一次)
create or replace function public.event_siege(p_kind text, p_target text, p_loot int) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); me text; t text := left(regexp_replace(coalesce(p_target,''), '[<>]', '', 'g'), 16); l int := least(greatest(coalesce(p_loot,0),0), 5000000);
begin
  if exists (select 1 from events where uid = u and at > now() - interval '20 seconds') then return jsonb_build_object('ok', false); end if;
  select left(coalesce(data->>'n','守護員'),16) into me from docs where path = 'arena/' || u::text; me := coalesce(me,'守護員');
  if t = '' then return jsonb_build_object('ok', false); end if;
  insert into events(uid, kind, txt) values (u, p_kind, case when p_kind = 'breach' then '🔥 ' || t || ' 攻破了 ' || me || ' 的城門' || case when l > 0 then ',搶走 ⭐' || to_char(l,'FM999,999,999') else '' end
    else '⚔️ ' || me || ' 攻破了 ' || t || ' 的城門' || case when l > 0 then ',搶走 ⭐' || to_char(l,'FM999,999,999') else '' end end);
  delete from events where at < now() - interval '1 day';
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.inbox_list(), public.inbox_take(bigint), public.event_siege(text,text,int) to authenticated;

-- ============ 刪除帳號 ============
-- 玩家在設定頁按「刪除帳號」:清掉這個帳號的所有資料(存檔、鑽石、天梯、交易所上架),最後刪掉登入帳號本身
create or replace function public.delete_account() returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare u uuid := moe_uid();
begin
  update market set status = 'cancelled' where seller = u and status = 'open';
  delete from inbox where uid = u; delete from mint_quota where uid = u; delete from ladder where uid = u;
  delete from gem_log where uid = u; delete from pay_first where uid = u; delete from wallet where uid = u;
  delete from docs where owner = u;
  delete from auth.users where id = u;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.delete_account() to authenticated;

grant execute on function public.wallet_init(int), public.gem_sync(int,int), public.summon(int,text,boolean), public.topup_test_impl(text),
  public.ladder_me(), public.ladder_report(boolean,int,int,int,real), public.ladder_buy(), public.ladder_top(int),
  public.market_list(jsonb,int), public.market_browse(), public.market_mine(), public.market_buy(bigint), public.market_cancel(bigint), public.inbox_claim() to authenticated;
revoke execute on function public.ladder_row(), public.ladder_json(ladder,int) from public, anon, authenticated;
grant select on public.wallet, public.gem_log, public.ladder, public.market, public.inbox to authenticated;

-- ============ 營運後台 ============
create table if not exists public.admins(uid uuid primary key, added timestamptz not null default now());
create table if not exists public.notice(id bigserial primary key, title text not null, body text not null default '', active boolean not null default true, created timestamptz not null default now());
create table if not exists public.admin_log(id bigserial primary key, admin uuid, action text, target uuid, detail jsonb, at timestamptz not null default now());
alter table public.admins enable row level security;
alter table public.notice enable row level security;
alter table public.admin_log enable row level security;
drop policy if exists notice_read on public.notice;
create policy notice_read on public.notice for select to anon, authenticated using (active);
grant select on public.notice to anon, authenticated;

create or replace function public.moe_admin() returns uuid language plpgsql stable security definer set search_path = public as $$
begin if auth.uid() is null or not exists (select 1 from admins where uid = auth.uid()) then raise exception '沒有管理員權限'; end if; return auth.uid(); end $$;
create or replace function public.alog(a text, t uuid, d jsonb) returns void language sql security definer set search_path = public as $$
  insert into admin_log(admin, action, target, detail) values (auth.uid(), a, t, d) $$;

-- 查自己是不是管理員(後台登入時用)
create or replace function public.admin_whoami() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('uid', auth.uid(), 'admin', exists (select 1 from admins where uid = auth.uid()), 'anyAdmin', exists (select 1 from admins)) $$;

-- 第一位管理員:還沒有任何管理員時,登入的人可以自己認領(之後就關閉)
create or replace function public.admin_claim() returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare u uuid := auth.uid(); e text;
begin
  if u is null then raise exception '請先登入'; end if;
  select email into e from auth.users where id = u;
  if coalesce(e,'') = '' then raise exception '訪客帳號不能當管理員,請先在遊戲裡建立帳號密碼'; end if;
  lock table admins in exclusive mode;
  if exists (select 1 from admins) then raise exception '已經有管理員了,請現有管理員新增你'; end if;
  insert into admins(uid) values (u); perform alog('claim', u, '{}'::jsonb);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_stats() returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare a uuid := moe_admin(); t date := moe_today(); r jsonb;
begin
  select jsonb_build_object(
    'players', (select count(*) from auth.users),
    'registered', (select count(*) from auth.users where coalesce(email,'') <> ''),
    'new_today', (select count(*) from auth.users where (created_at at time zone 'Asia/Taipei')::date = t),
    'active_today', (select count(*) from wallet where (updated_at at time zone 'Asia/Taipei')::date = t),
    'active_7d', (select count(*) from wallet where updated_at > now() - interval '7 days'),
    'gem_total', (select coalesce(sum(gem),0) from wallet),
    'topup_total', (select coalesce(sum(topup),0) from wallet),
    'payers', (select count(*) from wallet where topup > 0),
    'topup_today', (select coalesce(sum(delta),0) from gem_log where reason like 'topup:%' and (at at time zone 'Asia/Taipei')::date = t),
    'flagged', (select count(*) from wallet w where w.flags > 0 or exists (select 1 from ladder l where l.uid = w.uid and l.flags > 0)),
    'banned', (select count(*) from bans where until is null or until > now()),
    'market_open', (select count(*) from market where status = 'open' and created > now() - interval '48 hours'),
    'market_sold_7d', (select count(*) from market where status = 'sold' and sold_at > now() - interval '7 days'),
    'days', (select coalesce(jsonb_agg(x order by x->>'d'), '[]'::jsonb) from (
      select jsonb_build_object('d', d::date,
        'new', (select count(*) from auth.users where (created_at at time zone 'Asia/Taipei')::date = d::date),
        'active', (select count(distinct uid) from gem_log where (at at time zone 'Asia/Taipei')::date = d::date),
        'topup', (select coalesce(sum(delta),0) from gem_log where reason like 'topup:%' and (at at time zone 'Asia/Taipei')::date = d::date)) x
      from generate_series(t - 13, t, interval '1 day') d) s)
  ) into r;
  return r;
end $$;

create or replace function public.admin_players(p_q text default '', p_sort text default 'recent', p_limit int default 50) returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare a uuid := moe_admin(); r jsonb; q text := lower(trim(coalesce(p_q,'')));
begin
  select coalesce(jsonb_agg(row_to_json(x)), '[]'::jsonb) into r from (
    select u.id uid, nullif(moe_acct(u.email),'') acct, d.data->>'n' name, coalesce((d.data->>'lv')::int,0) castle,
      coalesce(w.gem,0) gem, coalesce(w.topup,0) topup, moe_vip(coalesce(w.topup,0)) vip, coalesce(l.pts,0) pts,
      coalesce(w.flags,0) + coalesce(l.flags,0) flags, (b.uid is not null and (b.until is null or b.until > now())) banned,
      greatest(w.updated_at, u.last_sign_in_at) seen, u.created_at created
    from auth.users u left join wallet w on w.uid = u.id left join ladder l on l.uid = u.id
      left join docs d on d.path = 'arena/' || u.id::text left join bans b on b.uid = u.id
    where q = '' or lower(coalesce(u.email,'')) like '%' || q || '%' or lower(coalesce(d.data->>'n','')) like '%' || q || '%' or u.id::text like q || '%'
      or (q = '!flag' and coalesce(w.flags,0) + coalesce(l.flags,0) > 0) or (q = '!ban' and b.uid is not null) or (q = '!pay' and coalesce(w.topup,0) > 0)
    order by case when p_sort = 'gem' then coalesce(w.gem,0) when p_sort = 'topup' then coalesce(w.topup,0) when p_sort = 'pts' then coalesce(l.pts,0) when p_sort = 'flags' then coalesce(w.flags,0) + coalesce(l.flags,0) else 0 end desc,
      greatest(w.updated_at, u.last_sign_in_at) desc nulls last
    limit least(greatest(p_limit,1),200)) x;
  return r;
end $$;

create or replace function public.admin_player(p_uid uuid) returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare a uuid := moe_admin();
begin
  return jsonb_build_object(
    'user', (select jsonb_build_object('uid', id, 'acct', nullif(moe_acct(email),''), 'created', created_at, 'last', last_sign_in_at) from auth.users where id = p_uid),
    'wallet', (select to_jsonb(w) from wallet w where uid = p_uid),
    'ladder', (select to_jsonb(l) from ladder l where uid = p_uid),
    'arena', (select data - 'chat' - 'cm' from docs where path = 'arena/' || p_uid::text),
    'ban', (select to_jsonb(b) from bans b where uid = p_uid and (until is null or until > now())),
    'sess', (select jsonb_build_object('dev', dev, 'at', at, 'seen', seen, 'act', act) from sessions where uid = p_uid),
    'log', (select coalesce(jsonb_agg(to_jsonb(g) order by g.id desc), '[]'::jsonb) from (select * from gem_log where uid = p_uid order by id desc limit 60) g),
    'market', (select coalesce(jsonb_agg(to_jsonb(m) order by m.id desc), '[]'::jsonb) from (select * from market where seller = p_uid or buyer = p_uid order by id desc limit 30) m));
end $$;

-- 直接加/扣某位玩家的鑽石(玩家會在信箱看到說明)
create or replace function public.admin_gem(p_uid uuid, p_delta int, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); g int;
begin
  if coalesce(p_delta,0) = 0 or abs(p_delta) > 1000000 then raise exception '數量不合理'; end if;
  insert into wallet(uid) values (p_uid) on conflict do nothing;
  update wallet set gem = greatest(0, gem + p_delta), updated_at = now() where uid = p_uid returning gem into g;
  insert into gem_log(uid,delta,reason) values (p_uid, p_delta, 'admin:' || coalesce(p_reason,''));
  insert into inbox(uid, gem, note, kind, title) values (p_uid, p_delta, coalesce(nullif(p_reason,''),'鑽石調整') || '(鑽石已直接調整)', 'ops', '營運通知:鑽石調整');
  perform alog('gem', p_uid, jsonb_build_object('delta', p_delta, 'reason', p_reason));
  return jsonb_build_object('gem', g);
end $$;

-- 寄信(可附鑽石):指定一位玩家,或 p_uid 留空 = 全服(有玩過的玩家)
drop function if exists public.admin_mail(uuid,int,text);
drop function if exists public.admin_mail(uuid,int,text,text);
create or replace function public.admin_mail(p_uid uuid, p_gem int, p_note text, p_title text default null, p_bonus jsonb default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); n int;
begin
  if coalesce(p_gem,0) < 0 or p_gem > 100000 then raise exception '鑽石數量要在 0 ~ 100000 之間'; end if;
  if coalesce(trim(p_note),'') = '' then raise exception '請填寫信件內容'; end if;
  p_bonus := (select jsonb_object_agg(key, least(greatest((value)::text::numeric, 0), 100000000)::bigint) from jsonb_each(coalesce(p_bonus,'{}'::jsonb)) where key in ('coin','candy','stones','ore','enh','reroll','rtix') and (value)::text ~ '^[0-9]+$' and (value)::text::numeric > 0);
  if p_uid is null then
    insert into inbox(uid, gem, note, credit, kind, title, bonus) select uid, coalesce(p_gem,0), p_note, true, 'ops', coalesce(nullif(trim(p_title),''),'營運信件'), p_bonus from wallet;
  else
    insert into inbox(uid, gem, note, credit, kind, title, bonus) values (p_uid, coalesce(p_gem,0), p_note, true, 'ops', coalesce(nullif(trim(p_title),''),'營運信件'), p_bonus);
  end if;
  get diagnostics n = row_count;
  perform alog('mail', p_uid, jsonb_build_object('gem', p_gem, 'note', p_note, 'title', p_title, 'bonus', p_bonus, 'n', n));
  return jsonb_build_object('sent', n);
end $$;

create or replace function public.admin_ban(p_uid uuid, p_reason text, p_hours int) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin();
begin
  if p_uid = a then raise exception '不能停權自己'; end if;
  insert into bans(uid, reason, until) values (p_uid, p_reason, case when coalesce(p_hours,0) > 0 then now() + make_interval(hours => p_hours) end)
    on conflict (uid) do update set reason = excluded.reason, until = excluded.until, at = now();
  update market set status = 'cancelled' where seller = p_uid and status = 'open';
  perform alog('ban', p_uid, jsonb_build_object('reason', p_reason, 'hours', p_hours));
  return jsonb_build_object('ok', true);
end $$;
create or replace function public.admin_unban(p_uid uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin();
begin delete from bans where uid = p_uid; perform alog('unban', p_uid, '{}'::jsonb); return jsonb_build_object('ok', true); end $$;

create or replace function public.admin_player_set(p_uid uuid, p_field text, p_val int) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin();
begin
  if p_field = 'flags' then update wallet set flags = 0 where uid = p_uid; update ladder set flags = 0 where uid = p_uid;
  elsif p_field = 'pts' then update ladder set pts = greatest(0, p_val), best = greatest(0, p_val) where uid = p_uid;
  elsif p_field = 'bank' then update wallet set bank = greatest(0, p_val) where uid = p_uid;
  else raise exception '不支援的欄位'; end if;
  perform alog('set:' || p_field, p_uid, jsonb_build_object('val', p_val));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_market(p_status text default 'open') returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a uuid := moe_admin();
begin
  return (select coalesce(jsonb_agg(to_jsonb(m) || jsonb_build_object('fair', moe_fair(m.item)) order by m.id desc), '[]'::jsonb)
    from (select * from market where (p_status = 'all' or status = p_status) order by id desc limit 100) m);
end $$;
create or replace function public.admin_market_remove(p_id bigint, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); m market;
begin
  select * into m from market where id = p_id for update;
  if not found or m.status <> 'open' then raise exception '這件已經不在上架中'; end if;
  update market set status = 'cancelled' where id = p_id;
  insert into inbox(uid, item, note, kind, title) values (m.seller, m.item, '原因:' || coalesce(nullif(p_reason,''),'違反交易規範') || '。領取後回到背包。', 'ops', '營運通知:交易所裝備下架');
  perform alog('market_remove', m.seller, jsonb_build_object('id', p_id, 'reason', p_reason));
  return jsonb_build_object('ok', true);
end $$;

drop function if exists public.admin_notice_save(bigint,text,text,boolean);
create or replace function public.admin_notice_save(p_id bigint, p_title text, p_body text, p_active boolean, p_mail boolean default false) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); i bigint; n int := 0;
begin
  if coalesce(trim(p_title),'') = '' then raise exception '請填寫標題'; end if;
  if p_id is null then insert into notice(title, body, active) values (p_title, coalesce(p_body,''), coalesce(p_active,true)) returning id into i;
  else update notice set title = p_title, body = coalesce(p_body,''), active = coalesce(p_active,true) where id = p_id returning id into i; end if;
  if p_mail then insert into inbox(uid, gem, note, credit, kind, title) select uid, 0, coalesce(nullif(p_body,''), p_title), false, 'ops', '📢 ' || p_title from wallet; get diagnostics n = row_count; end if;
  perform alog('notice', null, jsonb_build_object('id', i, 'title', p_title, 'active', p_active, 'mail', n));
  return jsonb_build_object('id', i, 'mailed', n);
end $$;
create or replace function public.admin_notice_delete(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin();
begin delete from notice where id = p_id; perform alog('notice_delete', null, jsonb_build_object('id', p_id)); return jsonb_build_object('ok', true); end $$;
create or replace function public.admin_notices() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a uuid := moe_admin();
begin return (select coalesce(jsonb_agg(to_jsonb(n) order by n.id desc), '[]'::jsonb) from notice n); end $$;

create or replace function public.admin_admins() returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare a uuid := moe_admin();
begin return (select coalesce(jsonb_agg(jsonb_build_object('uid', x.uid, 'acct', moe_acct(u.email), 'added', x.added)), '[]'::jsonb) from admins x left join auth.users u on u.id = x.uid); end $$;
create or replace function public.admin_admin_set(p_acct text, p_add boolean) returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare a uuid := moe_admin(); t uuid;
begin
  select id into t from auth.users where lower(email) = lower(trim(p_acct)) || '@player.moe-planet.app';
  if t is null then raise exception '找不到這個帳號'; end if;
  if p_add then insert into admins(uid) values (t) on conflict do nothing;
  else if t = a then raise exception '不能移除自己'; end if; delete from admins where uid = t; end if;
  perform alog(case when p_add then 'admin_add' else 'admin_remove' end, t, '{}'::jsonb);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_logs(p_limit int default 100) returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare a uuid := moe_admin();
begin return (select coalesce(jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'target', l.target, 'detail', l.detail, 'admin', moe_acct(u.email), 'tname', d.data->>'n') order by l.id desc), '[]'::jsonb)
  from (select * from admin_log order by id desc limit least(greatest(p_limit,1),300)) l left join auth.users u on u.id = l.admin left join docs d on d.path = 'arena/' || l.target::text); end $$;

revoke execute on function public.alog(text,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.admin_whoami(), public.admin_claim(), public.admin_stats(), public.admin_players(text,text,int), public.admin_player(uuid),
  public.admin_gem(uuid,int,text), public.admin_mail(uuid,int,text,text,jsonb), public.admin_ban(uuid,text,int), public.admin_unban(uuid), public.admin_player_set(uuid,text,int),
  public.admin_market(text), public.admin_market_remove(bigint,text), public.admin_notice_save(bigint,text,text,boolean,boolean), public.admin_notice_delete(bigint), public.admin_notices(),
  public.admin_admins(), public.admin_admin_set(text,boolean), public.admin_logs(int) to authenticated;

-- ============ 後台第二批:即時廣播、活動、兌換碼、維護、聊天管理、客服、儲值紀錄、報表 ============
create table if not exists public.settings(k text primary key, v jsonb not null default '{}'::jsonb);
create table if not exists public.live_msg(id bigserial primary key, txt text not null, until timestamptz not null, at timestamptz not null default now());
create table if not exists public.game_event(id bigserial primary key, kind text not null, starts timestamptz not null, ends timestamptz not null, note text, created timestamptz not null default now());
create table if not exists public.codes(code text primary key, reward jsonb not null, max_uses int not null default 0, used int not null default 0, expires timestamptz, active boolean not null default true, created timestamptz not null default now());
create table if not exists public.code_use(code text, uid uuid, at timestamptz not null default now(), primary key(code, uid));
create table if not exists public.mutes(uid uuid primary key, until timestamptz, reason text, at timestamptz not null default now());
create table if not exists public.chat_hide(uid uuid, t bigint, at timestamptz not null default now(), primary key(uid, t));
create table if not exists public.tickets(id bigserial primary key, uid uuid not null default auth.uid(), cat text, body text not null, status text not null default 'open', reply text, at timestamptz not null default now(), replied_at timestamptz);
alter table public.settings enable row level security; alter table public.live_msg enable row level security; alter table public.game_event enable row level security;
alter table public.codes enable row level security; alter table public.code_use enable row level security; alter table public.mutes enable row level security;
alter table public.chat_hide enable row level security; alter table public.tickets enable row level security;
drop policy if exists settings_read on public.settings; create policy settings_read on public.settings for select to anon, authenticated using (k in ('maint'));
drop policy if exists live_read on public.live_msg; create policy live_read on public.live_msg for select to authenticated using (until > now());
drop policy if exists gev_read on public.game_event; create policy gev_read on public.game_event for select to anon, authenticated using (ends > now());
drop policy if exists mutes_read on public.mutes; create policy mutes_read on public.mutes for select to authenticated using (until is null or until > now());
drop policy if exists chide_read on public.chat_hide; create policy chide_read on public.chat_hide for select to authenticated using (at > now() - interval '2 days');
drop policy if exists tickets_read on public.tickets; create policy tickets_read on public.tickets for select to authenticated using (uid = auth.uid());
grant select on public.settings, public.game_event to anon, authenticated; grant select on public.live_msg, public.mutes, public.chat_hide, public.tickets to authenticated;

-- 即時廣播:所有在線玩家畫面跳出 30 秒
create or replace function public.admin_live(p_txt text, p_secs int default 30) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin();
begin
  if coalesce(trim(p_txt),'') = '' then raise exception '請輸入廣播內容'; end if;
  insert into live_msg(txt, until) values (left(p_txt, 120), now() + make_interval(secs => least(greatest(coalesce(p_secs,30),5),300)));
  delete from live_msg where until < now() - interval '1 day';
  perform alog('live', null, jsonb_build_object('txt', p_txt));
  return jsonb_build_object('ok', true);
end $$;

-- 活動:xp2 雙倍經驗、drop2 雙倍掉落、sumup 召喚機率 UP
create or replace function public.admin_events() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a uuid := moe_admin();
begin return (select coalesce(jsonb_agg(to_jsonb(e) order by e.starts desc), '[]'::jsonb) from (select * from game_event order by starts desc limit 50) e); end $$;
create or replace function public.admin_event_save(p_id bigint, p_kind text, p_starts timestamptz, p_ends timestamptz, p_note text) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); i bigint;
begin
  if p_kind not in ('xp2','drop2','sumup') then raise exception '活動種類不對'; end if;
  if p_ends <= p_starts then raise exception '結束時間要晚於開始時間'; end if;
  if p_id is null then insert into game_event(kind, starts, ends, note) values (p_kind, p_starts, p_ends, p_note) returning id into i;
  else update game_event set kind = p_kind, starts = p_starts, ends = p_ends, note = p_note where id = p_id returning id into i; end if;
  perform alog('event', null, jsonb_build_object('id', i, 'kind', p_kind, 'starts', p_starts, 'ends', p_ends));
  return jsonb_build_object('id', i);
end $$;
create or replace function public.admin_event_delete(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin();
begin delete from game_event where id = p_id; perform alog('event_delete', null, jsonb_build_object('id', p_id)); return jsonb_build_object('ok', true); end $$;

-- 兌換碼:reward = {"gem":100,"coin":5000,"candy":30,"stones":10,"rtix":1}
create or replace function public.admin_codes() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a uuid := moe_admin();
begin return (select coalesce(jsonb_agg(to_jsonb(c) order by c.created desc), '[]'::jsonb) from codes c); end $$;
create or replace function public.admin_code_save(p_code text, p_reward jsonb, p_max int, p_expires timestamptz, p_active boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); c text := upper(regexp_replace(coalesce(p_code,''), '[^A-Za-z0-9]', '', 'g'));
begin
  if length(c) < 4 or length(c) > 20 then raise exception '兌換碼要 4–20 個英文或數字'; end if;
  if coalesce((p_reward->>'gem')::int,0) > 100000 then raise exception '鑽石太多了'; end if;
  insert into codes(code, reward, max_uses, expires, active) values (c, p_reward, greatest(coalesce(p_max,0),0), p_expires, coalesce(p_active,true))
    on conflict (code) do update set reward = excluded.reward, max_uses = excluded.max_uses, expires = excluded.expires, active = excluded.active;
  perform alog('code', null, jsonb_build_object('code', c, 'reward', p_reward, 'max', p_max));
  return jsonb_build_object('code', c);
end $$;
create or replace function public.redeem(p_code text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); c codes; k text := upper(regexp_replace(coalesce(p_code,''), '[^A-Za-z0-9]', '', 'g'));
begin
  select * into c from codes where code = k for update;
  if not found or not c.active then raise exception '兌換碼不存在'; end if;
  if c.expires is not null and c.expires < now() then raise exception '兌換碼已經過期'; end if;
  if c.max_uses > 0 and c.used >= c.max_uses then raise exception '兌換碼已經被領完了'; end if;
  insert into code_use(code, uid) values (k, u) on conflict do nothing;
  if not found then raise exception '你已經兌換過這個碼了'; end if;
  update codes set used = used + 1 where code = k;
  insert into inbox(uid, gem, note, credit, kind, title, bonus) values (u, coalesce((c.reward->>'gem')::int,0), '兌換碼 ' || k || ' 的獎勵', true, 'system', '🎁 兌換碼獎勵', c.reward - 'gem');
  return jsonb_build_object('ok', true);
end $$;

-- 維護模式
create or replace function public.admin_maint(p_on boolean, p_msg text) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin();
begin
  insert into settings(k, v) values ('maint', jsonb_build_object('on', p_on, 'msg', coalesce(p_msg,''))) on conflict (k) do update set v = excluded.v;
  perform alog('maint', null, jsonb_build_object('on', p_on, 'msg', p_msg));
  return jsonb_build_object('ok', true);
end $$;

-- 聊天管理
create or replace function public.admin_chat() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a uuid := moe_admin();
begin
  return jsonb_build_object('msgs', (select coalesce(jsonb_agg(x order by (x->>'t')::bigint desc), '[]'::jsonb) from (
      select jsonb_build_object('uid', d.owner, 'name', d.data->>'n', 't', (m->>'t')::bigint, 'x', m->>'x', 'hidden', exists (select 1 from chat_hide h where h.uid = d.owner and h.t = (m->>'t')::bigint)) x
      from docs d, jsonb_array_elements(coalesce(d.data->'cw','[]'::jsonb)) m where d.coll = 'arena' and (d.data->>'cwT')::bigint > (extract(epoch from now()) * 1000)::bigint - 86400000
      order by (m->>'t')::bigint desc limit 300) s),
    'mutes', (select coalesce(jsonb_agg(jsonb_build_object('uid', m.uid, 'until', m.until, 'reason', m.reason, 'name', d.data->>'n')), '[]'::jsonb) from mutes m left join docs d on d.path = 'arena/' || m.uid::text where m.until is null or m.until > now()));
end $$;
create or replace function public.admin_chat_hide(p_uid uuid, p_t bigint, p_hide boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin();
begin
  if p_hide then insert into chat_hide(uid, t) values (p_uid, p_t) on conflict do nothing; else delete from chat_hide where uid = p_uid and t = p_t; end if;
  perform alog(case when p_hide then 'chat_hide' else 'chat_unhide' end, p_uid, jsonb_build_object('t', p_t));
  return jsonb_build_object('ok', true);
end $$;
create or replace function public.admin_mute(p_uid uuid, p_hours int, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin();
begin
  if p_hours is null or p_hours < 0 then delete from mutes where uid = p_uid; perform alog('unmute', p_uid, '{}'::jsonb); return jsonb_build_object('ok', true); end if;
  insert into mutes(uid, until, reason) values (p_uid, case when p_hours > 0 then now() + make_interval(hours => p_hours) end, p_reason)
    on conflict (uid) do update set until = excluded.until, reason = excluded.reason, at = now();
  perform alog('mute', p_uid, jsonb_build_object('hours', p_hours, 'reason', p_reason));
  return jsonb_build_object('ok', true);
end $$;

-- 客服回報
create or replace function public.ticket_submit(p_cat text, p_body text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid();
begin
  if length(trim(coalesce(p_body,''))) < 5 then raise exception '請多描述一點(至少 5 個字)'; end if;
  if (select count(*) from tickets where uid = u and at > now() - interval '1 day') >= 5 then raise exception '今天已經回報 5 次了,請明天再試'; end if;
  insert into tickets(uid, cat, body) values (u, left(coalesce(p_cat,'其他'),10), left(p_body, 1000));
  return jsonb_build_object('ok', true);
end $$;
create or replace function public.admin_tickets(p_status text default 'open') returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare a uuid := moe_admin();
begin return (select coalesce(jsonb_agg(to_jsonb(t) || jsonb_build_object('name', d.data->>'n', 'acct', moe_acct(u.email)) order by t.id desc), '[]'::jsonb)
  from (select * from tickets where case when p_status = 'err' then cat = '系統錯誤' else cat is distinct from '系統錯誤' and (p_status = 'all' or status = p_status) end order by id desc limit 100) t left join docs d on d.path = 'arena/' || t.uid::text left join auth.users u on u.id = t.uid); end $$;
create or replace function public.admin_ticket_reply(p_id bigint, p_reply text, p_close boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); t tickets;
begin
  select * into t from tickets where id = p_id for update; if not found then raise exception '找不到這張回報單'; end if;
  if coalesce(trim(p_reply),'') <> '' then
    update tickets set reply = p_reply, status = case when p_close then 'closed' else 'replied' end, replied_at = now() where id = p_id;
    insert into inbox(uid, gem, note, credit, kind, title) values (t.uid, 0, '你的回報:「' || left(t.body, 40) || '」' || chr(10) || '回覆:' || p_reply, false, 'ops', '💬 客服回覆');
  else update tickets set status = case when p_close then 'closed' else status end where id = p_id; end if;
  perform alog('ticket', t.uid, jsonb_build_object('id', p_id, 'reply', p_reply));
  return jsonb_build_object('ok', true);
end $$;

-- 儲值紀錄
create or replace function public.admin_topups(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare a uuid := moe_admin();
begin return (select coalesce(jsonb_agg(jsonb_build_object('at', g.at, 'uid', g.uid, 'pkg', substr(g.reason, 7), 'gem', g.delta, 'name', d.data->>'n', 'acct', moe_acct(u.email)) order by g.id desc), '[]'::jsonb)
  from gem_log g left join docs d on d.path = 'arena/' || g.uid::text left join auth.users u on u.id = g.uid
  where g.reason like 'topup:%' and (g.at at time zone 'Asia/Taipei')::date between coalesce(p_from, moe_today() - 30) and coalesce(p_to, moe_today())); end $$;

-- 數據報表:留存、每日召喚、熱門萌獸
create or replace function public.admin_report() returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare a uuid := moe_admin(); t date := moe_today();
begin
  return jsonb_build_object(
    'cohorts', (select coalesce(jsonb_agg(x order by x->>'d' desc), '[]'::jsonb) from (
      select jsonb_build_object('d', c.d, 'n', count(*),
        'd1', count(*) filter (where exists (select 1 from player_day p where p.uid = c.uid and p.d = c.d + 1)),
        'd3', count(*) filter (where exists (select 1 from player_day p where p.uid = c.uid and p.d = c.d + 3)),
        'd7', count(*) filter (where exists (select 1 from player_day p where p.uid = c.uid and p.d = c.d + 7)),
        'ok1', c.d + 1 <= t, 'ok3', c.d + 3 <= t, 'ok7', c.d + 7 <= t) x
      from (select id uid, (created_at at time zone 'Asia/Taipei')::date d from auth.users) c where c.d > t - 21 group by c.d) s),
    'summons', (select coalesce(jsonb_agg(jsonb_build_object('d', d, 'n', n) order by d), '[]'::jsonb) from (
      select (at at time zone 'Asia/Taipei')::date d, sum(case when reason = 'summon10' then 10 else 1 end) n from gem_log where reason like 'summon%' and at > now() - interval '14 days' group by 1) s),
    'pets', (select coalesce(jsonb_agg(jsonb_build_object('k', k, 'n', n) order by n desc), '[]'::jsonb) from (
      select split_part(tm, ',', 1) k, count(*) n from docs d, jsonb_array_elements_text(coalesce(d.data->'team','[]'::jsonb)) tm where d.coll = 'arena' group by 1 order by 2 desc limit 20) s),
    'anom', (select coalesce(jsonb_agg(jsonb_build_object('uid', g.uid, 'n', coalesce(d.data->>'n','守護員'), 'acct', nullif(moe_acct(u.email),''), 'earn', g.e, 'gem', w.gem) order by g.e desc), '[]'::jsonb) from (
      select uid, sum(delta) e from gem_log where reason = 'earn' and at > now() - interval '24 hours' group by uid having sum(delta) > 3000) g
      left join docs d on d.path = 'arena/' || g.uid::text left join auth.users u on u.id = g.uid left join wallet w on w.uid = g.uid));
end $$;

revoke execute on function public.redeem(text) from anon;
grant execute on function public.admin_live(text,int), public.admin_events(), public.admin_event_save(bigint,text,timestamptz,timestamptz,text), public.admin_event_delete(bigint),
  public.admin_codes(), public.admin_code_save(text,jsonb,int,timestamptz,boolean), public.redeem(text), public.admin_maint(boolean,text),
  public.admin_chat(), public.admin_chat_hide(uuid,bigint,boolean), public.admin_mute(uuid,int,text), public.ticket_submit(text,text), public.admin_tickets(text),
  public.admin_ticket_reply(bigint,text,boolean), public.admin_topups(date,date), public.admin_report() to authenticated;

-- ============ 電腦玩家管理 ============
create table if not exists public.bots(id bigserial primary key, name text not null unique, role text not null check (role in ('lord','player')), mul real not null default 1,
  active boolean not null default true, reset_at timestamptz, sort int not null default 0, created timestamptz not null default now());
alter table public.bots enable row level security;
drop policy if exists bots_read on public.bots; create policy bots_read on public.bots for select to anon, authenticated using (true);
grant select on public.bots to anon, authenticated;
insert into public.bots(name, role, sort) select * from (values ('長安小霸王','lord',0),('草原狼王','lord',1),('洛陽老街','lord',2),('尼羅河午夜','lord',3),('不勝不歸','lord',4),('奶茶去冰','lord',5),('肝帝阿明','lord',6),('小熊軟糖','lord',7),('雷霆一擊','lord',8),('睡到自然醒','lord',9),('星空下的貓','lord',10),('佛系守護員','lord',11),('鍋貼大王','lord',12),('月光餅乾','lord',13),('鹹魚翻身','lord',14),('阿喵不睡覺','player',100),('布丁大隊長','player',101),('小熊愛吃蜜','player',102),('炸雞配可樂','player',103),('夜貓子阿哲','player',104),('珍奶少冰','player',105),('一隻小企鵝','player',106),('曬太陽的龍','player',107),('山頂洞人','player',108),('拿鐵不加糖','player',109),('肥宅快樂水','player',110),('今天也要加油','player',111),('跳跳虎','player',112),('火鍋第一名','player',113),('雨天的狐狸','player',114),('阿福的寵物店','player',115),('雲端漫步','player',116),('黑糖饅頭','player',117),('路過的勇者','player',118),('鳳梨酥','player',119),('綠茶凍','player',120),('小籠包','player',121),('午夜電台','player',122),('海邊的鯨魚','player',123),('滷肉飯大師','player',124)) v(name, role, sort) where not exists (select 1 from public.bots);
create or replace function public.admin_bot_save(p_id bigint, p_name text, p_role text, p_mul real, p_active boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); n text := left(trim(coalesce(p_name,'')), 12); i bigint;
begin
  if n = '' then raise exception '請填寫名字'; end if;
  p_role := coalesce(nullif(p_role,''),'lord'); if p_role not in ('lord','player') then p_role := 'lord'; end if;
  if exists (select 1 from bots where name = n and id is distinct from p_id) then raise exception '這個名字已經有了'; end if;
  if p_id is null then insert into bots(name, role, mul, active, sort) values (n, p_role, least(greatest(coalesce(p_mul,1),.5),2), coalesce(p_active,true), coalesce((select max(sort) from bots),0) + 1) returning id into i;
  else update bots set name = n, role = p_role, mul = least(greatest(coalesce(p_mul,1),.5),2), active = coalesce(p_active,true) where id = p_id returning id into i; end if;
  perform alog('bot', null, jsonb_build_object('id', i, 'name', n, 'role', p_role, 'mul', p_mul, 'active', p_active));
  return jsonb_build_object('id', i);
end $$;
create or replace function public.admin_bot_delete(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); n text;
begin delete from bots where id = p_id returning name into n; perform alog('bot_delete', null, jsonb_build_object('id', p_id, 'name', n)); return jsonb_build_object('ok', true); end $$;
-- 重玩:p_id 留空 = 全部電腦玩家
create or replace function public.admin_bot_reset(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); n int;
begin
  update bots set reset_at = now() where p_id is null or id = p_id; get diagnostics n = row_count;
  perform alog('bot_reset', null, jsonb_build_object('id', p_id, 'n', n));
  return jsonb_build_object('n', n);
end $$;
grant execute on function public.admin_bot_save(bigint,text,text,real,boolean), public.admin_bot_delete(bigint), public.admin_bot_reset(bigint) to authenticated;

-- ============ 交易所:材料與碎片(封測期間不限上架數量) ============
create or replace function public.market_list_mat(p_mat text, p_pet text, p_n int, p_price int) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); it jsonb; f int; nm text;
begin
  if p_mat not in ('stones','enh','ore','reroll','candy','shard') then raise exception '這個物品不能交易'; end if;
  if coalesce(p_n,0) < 1 or p_n > 9999 then raise exception '數量要在 1 ~ 9999 之間'; end if;
  if p_mat = 'shard' and coalesce(p_pet,'') not in ('fox','otter','penguin','pango','ferret','whale','bear','dragon','bunny','mouse','mole','puffer','owl','lizard','deer','moth','armad','seal','marten','phoenix') then raise exception '萌獸種類不對'; end if;
  it := jsonb_build_object('mat', p_mat, 'n', p_n) || case when p_mat = 'shard' then jsonb_build_object('pet', p_pet) else '{}'::jsonb end;
  f := moe_fair(it);
  if p_price < ceil(f * .5) or p_price > floor(f * 2) then raise exception '價格要在 % ~ % 鑽石之間', ceil(f*.5), floor(f*2); end if;
  if (select count(*) from market where seller = u and status = 'open' and created > now() - interval '48 hours') >= 10 then raise exception '最多同時上架 10 件'; end if;
  if p_mat in ('stones','candy') and to_regprocedure('public.moe_res_add(uuid,text,bigint)') is not null and exists (select 1 from wallet where uid = u and r_on) then
    if (select case p_mat when 'stones' then r_stones else r_candy end from wallet where uid = u) < p_n then raise exception '數量不足'; end if;
  end if;
  select data->>'n' into nm from docs where path = 'arena/' || u::text;
  insert into market(seller, seller_name, item, price) values (u, coalesce(nm,'守護員'), it, p_price);
  if to_regprocedure('public.moe_res_add(uuid,text,bigint)') is not null then perform moe_res_add(u, p_mat, -p_n); end if;
  return jsonb_build_object('ok', true, 'fair', f, 'res', (select moe_res_json(w) from wallet w where uid = u and r_on));
end $$;
grant execute on function public.market_list_mat(text,text,int,int) to authenticated;

-- ============ 電腦玩家真實活動:攻城、天梯、團隊 Boss(有玩家在線時,伺服器每 10 分鐘補跑一次) ============
alter table public.bots add column if not exists power int not null default 0;
alter table public.bots add column if not exists stock bigint not null default 20000;
alter table public.bots add column if not exists w int not null default 0;
alter table public.bots add column if not exists l int not null default 0;
alter table public.bots add column if not exists ticked timestamptz;
alter table public.bots add column if not exists pts int not null default 0;
alter table public.bots add column if not exists ss int not null default 0;
alter table public.bots add column if not exists lw int not null default 0;
alter table public.bots add column if not exists ll int not null default 0;
alter table public.bots add column if not exists wk int not null default 0;
alter table public.bots add column if not exists wk_w int not null default 0;
alter table public.bots add column if not exists wk_loot bigint not null default 0;
alter table public.bots add column if not exists wk_d int not null default 0;
alter table public.bots add column if not exists rid int not null default 0;
alter table public.bots add column if not exists rdmg bigint not null default 0;
alter table public.bots add column if not exists rt timestamptz;
create or replace function public.moe_week() returns int language sql stable as $$ select floor(extract(epoch from (now() - timestamptz '2026-11-01 16:00:00+00')) / (7*86400))::int + 1 $$;
create or replace function public.moe_raid() returns int language sql stable as $$ select floor(extract(epoch from (now() - timestamptz '2026-11-01 16:00:00+00')) / (3*86400))::int + 1 $$;
create or replace function public.bot_power(b bots) returns int language sql stable as $$
  select greatest(300, round((2500 + (b.id % 7) * 450 + least(extract(epoch from now() - b.created) / 86400, 60) * 120)
    * b.mul * case when b.reset_at is null then 1 else least(1, greatest(.15, extract(epoch from now() - b.reset_at) / (3*86400))) end))::int $$;
create or replace function public.bot_tick() returns int language plpgsql security definer set search_path = public as $$
declare last timestamptz; rounds int; n int := 0; a bots; d bots; ap int; dp int; win boolean; loot int; g int; kk int; rr int; cs int := moe_season(); cw int := moe_week(); cr int := moe_raid(); tot float;
begin
  if not pg_try_advisory_xact_lock(7781) then return 0; end if;
  select (v->>'t')::timestamptz into last from settings where k = 'bot_tick';
  if last is not null and last > now() - interval '10 minutes' then return 0; end if;
  rounds := case when last is null then 1 else least(6, floor(extract(epoch from now() - last) / 600))::int end;
  insert into settings(k, v) values ('bot_tick', jsonb_build_object('t', now())) on conflict (k) do update set v = excluded.v;
  -- 換季、換週、換團隊 Boss、重玩;庫存隨時間增加;更新戰力
  update bots set pts = floor(pts * .5), lw = 0, ll = 0, ss = cs where ss <> cs;
  update bots set wk_w = 0, wk_loot = 0, wk_d = 0, wk = cw where wk <> cw;
  update bots set rdmg = 0, rid = cr, rt = greatest(timestamptz '2026-11-01 16:00:00+00' + make_interval(days => (cr - 1) * 3), coalesce(rt, now())) where rid <> cr;
  update bots set pts = 0, lw = 0, ll = 0, wk_w = 0, wk_loot = 0, wk_d = 0, rdmg = 0, stock = 20000, w = 0, l = 0 where reset_at is not null and reset_at > coalesce(last, now() - interval '1 day');
  update bots set stock = least(300000, stock + floor(extract(epoch from now() - coalesce(ticked, now())) / 3600 * (1500 + (id % 4) * 800))), ticked = now(), power = bot_power(bots) where active;
  -- 團隊 Boss:依經過時間和戰力累積傷害(全部電腦合計約打掉 95% 血量 / 3 天)
  select sum(power) into tot from bots where active;
  update bots set rdmg = rdmg + floor(4000000 * .95 * extract(epoch from now() - coalesce(rt, now())) / (3*86400) * power / greatest(tot,1) * (.7 + random() * .6)), rt = now() where active;
  for rr in 1..rounds loop
    -- 攻城 1~3 場
    for kk in 1..(1 + floor(random() * 3))::int loop
      select * into a from bots where active order by random() limit 1;
      select * into d from bots where active and id <> coalesce(a.id, 0) order by random() limit 1;
      exit when a.id is null or d.id is null;
      ap := a.power; dp := d.power;
      win := random() < (ap::float ^ 2) / (ap::float ^ 2 + (dp * 1.1)::float ^ 2);
      if win then
        loot := floor(d.stock * (.08 + random() * .07));
        update bots set stock = stock + loot, w = w + 1, wk_w = wk_w + 1, wk_loot = wk_loot + loot where id = a.id;
        update bots set stock = greatest(0, stock - loot), l = l + 1 where id = d.id;
        insert into events(uid, kind, txt, at) values (null, 'bot', '⚔️ ' || a.name || ' 攻破了 ' || d.name || ' 的城門,搶走 ⭐' || to_char(loot, 'FM999,999,999'), now() - make_interval(secs => floor(random() * 590)::int));
      else
        update bots set l = l + 1 where id = a.id;
        update bots set w = w + 1, wk_d = wk_d + 1 where id = d.id;
        if random() < .5 then insert into events(uid, kind, txt, at) values (null, 'bot', '🛡️ ' || d.name || ' 擋下了 ' || a.name || ' 的進攻', now() - make_interval(secs => floor(random() * 590)::int)); end if;
      end if;
      n := n + 1;
    end loop;
    -- 天梯 2 場:找分數接近的對手(每位電腦一天約打 7 場,和一般玩家差不多)
    for kk in 1..2 loop
      select * into a from bots where active order by random() limit 1;
      exit when a.id is null;
      select * into d from bots where active and id <> a.id order by abs(pts - a.pts) + random() * 150 limit 1;
      exit when d.id is null;
      win := random() < (a.power::float ^ 2) / (a.power::float ^ 2 + d.power::float ^ 2);
      if win then g := round(least(greatest(25 + (d.pts - a.pts) / 10.0, 12), 40));
        update bots set pts = pts + g, lw = lw + 1 where id = a.id;
        update bots set pts = greatest(0, pts - round(least(greatest(15 + (d.pts - a.pts) / 12.0, 6), 25))), ll = ll + 1 where id = d.id;
      else g := round(least(greatest(15 + (a.pts - d.pts) / 12.0, 6), 25));
        update bots set pts = greatest(0, pts - g), ll = ll + 1 where id = a.id;
        update bots set pts = pts + round(least(greatest(25 + (a.pts - d.pts) / 10.0, 12), 40)), lw = lw + 1 where id = d.id;
      end if;
    end loop;
  end loop;
  delete from events where at < now() - interval '1 day';
  perform bot_td();
  return n;
end $$;
-- 跑馬燈讀取:順便讓電腦玩家活動,回傳最近 1 小時最新 5 則
create or replace function public.events_feed() returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform bot_tick();
  return (select coalesce(jsonb_agg(jsonb_build_object('txt', txt, 'at', at) order by at desc), '[]'::jsonb) from (select txt, at from events where at > now() - interval '1 hour' order by at desc limit 5) x);
end $$;
revoke execute on function public.bot_tick() from public, anon, authenticated;
grant execute on function public.events_feed() to authenticated;

-- ============ 遊戲錯誤自動回報(顯示在後台「客服回報 → 系統錯誤」) ============
create or replace function public.report_error(p_msg text, p_stack text, p_ctx text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); b text := left(coalesce(p_msg,''),300) || chr(10) || left(coalesce(p_ctx,''),300) || chr(10) || left(coalesce(p_stack,''),900);
begin
  if u is null then return jsonb_build_object('ok', false); end if;
  if (select count(*) from tickets where uid = u and cat = '系統錯誤' and at > now() - interval '1 hour') >= 10 then return jsonb_build_object('ok', false); end if;
  if exists (select 1 from tickets where uid = u and cat = '系統錯誤' and left(body, 300) = left(b, 300) and at > now() - interval '1 day') then return jsonb_build_object('ok', false); end if;
  insert into tickets(uid, cat, body) values (u, '系統錯誤', b);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.report_error(text,text,text) to authenticated;

-- 天梯防守紀錄:誰挑戰過我(最近 20 筆)
create or replace function public.ladder_defs() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare u uuid := moe_uid();
begin return (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'uid', x.attacker, 'win', x.att_win, 'at', x.at, 'rev', x.revenged, 'n', d.data->>'n', 'team', d.data->'team', 'pw', (d.data->>'pw')::int, 'pts', coalesce(l.pts,0)) order by x.id desc), '[]'::jsonb)
  from (select * from ladder_def where defender = u order by id desc limit 20) x left join docs d on d.path = 'arena/' || x.attacker::text left join ladder l on l.uid = x.attacker); end $$;
grant execute on function public.ladder_defs() to authenticated;

-- ============ 守塔挑戰:無盡模式週排行 ============
create table if not exists public.td_week(uid uuid not null, wk int not null, best int not null default 0, secs int not null default 0, at timestamptz not null default now(), claimed boolean not null default false, primary key(uid, wk));
alter table public.td_week enable row level security;
alter table public.bots add column if not exists td_wk int not null default 0;
alter table public.bots add column if not exists td_best int not null default 0;
create or replace function public.td_report(p_wave int, p_secs int) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); w int := moe_week(); b int;
begin
  if p_wave is null or p_wave < 1 or p_wave > 500 then return jsonb_build_object('ok',false); end if;
  if p_secs < p_wave * 6 then return jsonb_build_object('ok',false,'err','too fast'); end if;
  if not moe_td_ok(u, p_wave) then return jsonb_build_object('ok',false,'err','review'); end if;
  insert into td_week(uid, wk, best, secs) values (u, w, p_wave, p_secs)
    on conflict (uid, wk) do update set best = greatest(td_week.best, excluded.best), secs = case when excluded.best > td_week.best then excluded.secs else td_week.secs end, at = case when excluded.best > td_week.best then now() else td_week.at end;
  select best into b from td_week where uid = u and wk = w;
  return jsonb_build_object('ok',true,'best',b);
end $$;
create or replace function public.td_board(p_wk int) returns table(uid uuid, bot bigint, n text, w int, at timestamptz) language sql stable security definer set search_path = public as $$
  select * from (
    select t.uid, null::bigint, coalesce(d.data->>'n','守護員'), t.best, t.at from td_week t left join docs d on d.path = 'arena/' || t.uid::text
      where t.wk = p_wk and not exists (select 1 from bans x where x.uid = t.uid and (x.until is null or x.until > now()))
    union all
    select null::uuid, b.id, b.name, b.td_best, b.created from bots b where b.active and b.td_wk = p_wk and b.td_best > 0) q
  order by 4 desc, 5 asc $$;
create or replace function public.td_top(p_limit int default 50) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('n',n,'w',w,'me',coalesce(uid = auth.uid(),false))), '[]'::jsonb) from (select * from td_board(moe_week()) limit least(greatest(p_limit,1),100)) q $$;
create or replace function public.td_claim() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); pw int := moe_week() - 1; r int; g int; T td_week;
begin
  select * into T from td_week where uid = u and wk = pw for update;
  if T.uid is null or T.claimed then return jsonb_build_object('gem',0); end if;
  select rn into r from (select uid, row_number() over () rn from td_board(pw)) q where q.uid = u;
  update td_week set claimed = true where uid = u and wk = pw;
  g := case when r is null then 0 when r = 1 then 600 when r <= 3 then 400 when r <= 10 then 200 when r <= 50 then 60 else 0 end;
  if g > 0 then
    insert into inbox(uid, gem, note, title, kind) values (u, g, '上週守塔挑戰無盡模式第 ' || r || ' 名(' || T.best || ' 波),獎勵請收下!', '🛡️ 守塔排行獎勵', 'system');
  end if;
  return jsonb_build_object('gem',g,'rank',r);
end $$;
-- 電腦玩家每週也會挑戰無盡模式(依戰力決定撐幾波)
-- 戰力→波數對照表(來自實際模擬:第 20 波後怪物血量每波 ×1.12)
create or replace function public.bot_td_waves(p int) returns float language sql immutable as $$
  with t(pw, w) as (values (0,18.0),(1000,20.0),(5500,25.0),(24000,34.0),(38000,36.0),(72000,39.0),(117000,42.0),(183000,48.0),(400000,55.0)),
  s as (select pw, w, lead(pw) over (order by pw) pw2, lead(w) over (order by pw) w2 from t)
  select coalesce((select w + (w2 - w) * (greatest(p,0) - pw)::float / (pw2 - pw) from s where pw2 is not null and greatest(p,0) >= pw and greatest(p,0) < pw2), 55.0) $$;
create or replace function public.bot_td() returns void language sql security definer set search_path = public as $$
  update bots set td_wk = moe_week(), td_best = case when td_wk <> moe_week() then 0 else td_best end where active and td_wk <> moe_week();
  update bots set td_best = greatest(td_best, round(bot_td_waves(power) * (.85 + random() * .25))::int) where active and random() < .08;
$$;
revoke execute on function public.bot_td(), public.td_board(int) from public, anon, authenticated;
grant execute on function public.td_report(int,int), public.td_top(int), public.td_claim() to authenticated;

-- ============ 單一裝置登入 ============
create or replace function public.session_start(p_dev text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); s uuid := gen_random_uuid();
begin if u is null then raise exception 'not signed in'; end if;
  if to_regprocedure('public.moe_cleanup_maybe()') is not null then perform moe_cleanup_maybe(); end if;
  insert into sessions(uid, sid, dev, at, seen) values (u, s, left(coalesce(p_dev,''),60), now(), now())
    on conflict (uid) do update set sid = excluded.sid, dev = excluded.dev, at = now(), seen = now();
  return jsonb_build_object('sid', s); end $$;
alter table public.sessions add column if not exists act text;
drop function if exists public.session_ping(uuid);
create or replace function public.session_ping(p_sid uuid, p_act text default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); S sessions; n int; pk jsonb;
begin if u is null then return jsonb_build_object('ok', true); end if;
  select * into S from sessions where uid = u;
  if S.uid is null then return jsonb_build_object('ok', true); end if;
  if S.sid <> p_sid then return jsonb_build_object('ok', false, 'dev', S.dev); end if;
  update sessions set seen = now(), act = coalesce(left(p_act,30), act) where uid = u;
  if random() < .2 then
    select count(*) into n from sessions where seen > now() - interval '2 minutes';
    select v into pk from settings where k = 'peak';
    if pk is null or (pk->>'d') is distinct from moe_today()::text or n > (pk->>'n')::int then
      insert into settings(k, v) values ('peak', jsonb_build_object('d', moe_today()::text, 'n', n, 'at', now())) on conflict (k) do update set v = excluded.v;
    end if;
  end if;
  return jsonb_build_object('ok', true); end $$;
grant execute on function public.session_start(text), public.session_ping(uuid,text) to authenticated;
-- 後台:即時在線與各模式人數
create or replace function public.admin_live_status() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a uuid := moe_admin();
begin return jsonb_build_object(
  'online', (select count(*) from sessions where seen > now() - interval '2 minutes'),
  'peak', (select v from settings where k = 'peak' and v->>'d' = moe_today()::text),
  'players', (select coalesce(jsonb_agg(jsonb_build_object('uid', s.uid, 'act', coalesce(s.act,'town'), 'dev', s.dev, 'seen', s.seen, 'n', coalesce(d.data->>'n','守護員')) order by s.seen desc), '[]'::jsonb)
     from sessions s left join docs d on d.path = 'arena/' || s.uid::text where s.seen > now() - interval '2 minutes'));
end $$;
grant execute on function public.admin_live_status() to authenticated;
-- 被擠掉的裝置不能再寫入存檔
drop policy if exists docs_sess on public.docs;
create policy docs_sess on public.docs as restrictive for all to authenticated using (moe_sess_ok()) with check (moe_sess_ok());

-- ============ 好友共同守塔:雙人無盡排行榜(每週) ============
create table if not exists public.td_duo(wk int not null, a uuid not null, b uuid not null, an text not null default '', bn text not null default '', best int not null default 0, secs int not null default 0, at timestamptz not null default now(), primary key(wk, a, b));
alter table public.td_duo enable row level security;
create or replace function public.td_report2(p_mate uuid, p_mate_n text, p_my_n text, p_wave int, p_secs int) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); w int := moe_week(); xa uuid; xb uuid; xan text; xbn text; mn text := left(coalesce(nullif(trim(p_my_n),''),'守護員'),20); on2 text := left(coalesce(nullif(trim(p_mate_n),''),'守護員'),20); r int;
begin
  if p_mate is null or p_mate = u or p_wave is null or p_wave < 1 or p_wave > 500 or coalesce(p_secs,0) < p_wave * 6 then return jsonb_build_object('ok',false); end if;
  if not moe_td_ok(u, p_wave) then return jsonb_build_object('ok',false,'err','review'); end if;
  if u < p_mate then xa := u; xb := p_mate; xan := mn; xbn := on2; else xa := p_mate; xb := u; xan := on2; xbn := mn; end if;
  insert into td_duo(wk, a, b, an, bn, best, secs) values (w, xa, xb, xan, xbn, p_wave, p_secs)
  on conflict (wk, a, b) do update set best = greatest(td_duo.best, excluded.best), an = excluded.an, bn = excluded.bn,
    secs = case when excluded.best > td_duo.best then excluded.secs else td_duo.secs end, at = case when excluded.best > td_duo.best then now() else td_duo.at end
  returning td_duo.best into r;
  return jsonb_build_object('ok',true,'best',r);
end $$;
create or replace function public.td_top2(p_limit int default 50) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('a',an,'b',bn,'w',best,'me',(a = auth.uid() or b = auth.uid())) order by best desc, at), '[]'::jsonb)
  from (select * from td_duo where wk = moe_week() order by best desc, at limit least(greatest(p_limit,1),100)) q $$;
revoke all on public.td_duo from anon, authenticated;
grant execute on function public.td_report2(uuid,text,text,int,int), public.td_top2(int) to authenticated;

-- ============ 防作弊第一階段:存檔成長檢查、存檔歷史、後台還原 ============
create table if not exists public.save_hist(id bigserial primary key, uid uuid not null, at timestamptz not null default now(), data jsonb not null);
create index if not exists save_hist_uid on public.save_hist(uid, at desc);
create table if not exists public.save_flags(id bigserial primary key, uid uuid not null, at timestamptz not null default now(), lvl text not null, detail jsonb not null default '{}'::jsonb, attempted jsonb, status text not null default 'open');
create index if not exists save_flags_st on public.save_flags(status, at desc);
alter table public.save_hist enable row level security;
alter table public.save_flags enable row level security;
revoke all on public.save_hist, public.save_flags from anon, authenticated;

create or replace function public.moe_save_stats(d jsonb) returns jsonb language plpgsql immutable as $$
declare s jsonb; sh numeric := 0; np int := 0; neg boolean := false; k text; v jsonb;
begin
  begin s := (d->>'json')::jsonb; exception when others then return null; end;
  if s is null then return null; end if;
  if jsonb_typeof(s->'pets') = 'object' then
    for k, v in select * from jsonb_each(s->'pets') loop
      np := np + 1; sh := sh + coalesce((v->>'shards')::numeric, 0);
      if coalesce((v->>'shards')::numeric,0) < 0 or coalesce((v->>'lv')::numeric,1) < 0 then neg := true; end if;
    end loop;
  end if;
  return jsonb_build_object('coin', coalesce((s->>'coin')::numeric,0), 'stones', coalesce((s->>'stones')::numeric,0), 'candy', coalesce((s->>'candy')::numeric,0), 'shards', sh, 'pets', np, 'eqs', case when jsonb_typeof(s->'equips') = 'array' then jsonb_array_length(s->'equips') else 0 end,
    'neg', neg or coalesce((s->>'coin')::numeric,0) < 0 or coalesce((s->>'stones')::numeric,0) < 0 or coalesce((s->>'candy')::numeric,0) < 0);
exception when others then return null;
end $$;

create or replace function public.moe_save_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare u uuid; o jsonb; n jsonb; h numeric; r numeric := 0; d jsonb := '{}'::jsonb; lim numeric; dv numeric; f text; bad boolean := false; lv text; last timestamptz; ni text[];
begin
  if NEW.path not like 'data/users/%/save' or current_setting('moe.skip', true) = '1' then return NEW; end if;
  begin u := split_part(NEW.path, '/', 3)::uuid; exception when others then return NEW; end;
  if TG_OP = 'UPDATE' then
    -- 存檔歷史:每 10 分鐘最多一份,保留 10 份
    select max(at) into last from save_hist where uid = u;
    if last is null or now() - last > interval '10 minutes' then
      insert into save_hist(uid, data) values (u, OLD.data);
      delete from save_hist where uid = u and id not in (select id from save_hist where uid = u order by at desc limit 10);
    end if;
    o := moe_save_stats(OLD.data); n := moe_save_stats(NEW.data);
    if o is null or n is null then return NEW; end if;
    h := greatest(.25, least(48, extract(epoch from now() - coalesce(OLD.updated_at, now() - interval '1 hour')) / 3600));
    foreach f in array array['coin','stones','candy','shards','pets','eqs'] loop
      lim := case f when 'coin' then greatest(2000000 + 3000000 * h, (o->>'coin')::numeric * .5) when 'stones' then 300 + 400 * h when 'candy' then 1000 + 1500 * h when 'shards' then 300 + 400 * h when 'eqs' then 30 + 40 * h else 12 + 20 * h end;
      dv := coalesce((n->>f)::numeric, 0) - coalesce((o->>f)::numeric, 0);
      if dv > lim then r := greatest(r, dv / lim); d := d || jsonb_build_object(f, jsonb_build_object('from', o->f, 'to', n->f, 'limit', round(lim))); end if;
    end loop;
    -- 萌獸、裝備數值超出遊戲規則(只看這次新出現的問題)
    if to_regprocedure('public.moe_save_issues(jsonb)') is not null then
      begin ni := array(select unnest(moe_save_issues((NEW.data->>'json')::jsonb)) except select unnest(moe_save_issues((OLD.data->>'json')::jsonb)));
      exception when others then ni := '{}'; end;
      if coalesce(array_length(ni, 1), 0) > 0 then bad := true; d := d || jsonb_build_object('bad', to_jsonb(ni[1:12])); end if;
    end if;
    if (n->>'neg')::boolean or (n->>'coin')::numeric > 2000000000 or (n->>'stones')::numeric > 50000000 or (n->>'candy')::numeric > 50000000 then bad := true; d := d || jsonb_build_object('invalid', true); end if;
    if bad or r > 5 then lv := 'block'; elsif r > 1 then lv := 'warn'; else return NEW; end if;
    d := d || jsonb_build_object('hours', round(h, 2), 'ratio', round(r, 1));
    if not exists (select 1 from save_flags where uid = u and status = 'open' and lvl = lv and at > now() - interval '10 minutes') then
      insert into save_flags(uid, lvl, detail, attempted) values (u, lv, d, case when lv = 'block' then NEW.data else null end);
    else
      update save_flags set detail = d, attempted = case when lv = 'block' then NEW.data else attempted end, at = now() where id = (select id from save_flags where uid = u and status = 'open' and lvl = lv order by at desc limit 1);
    end if;
    if lv = 'block' then
      NEW.data := jsonb_set(OLD.data, '{t}', to_jsonb((extract(epoch from now()) * 1000)::bigint));
    end if;
  end if;
  return NEW;
end $$;
drop trigger if exists docs_save_guard on public.docs;
create trigger docs_save_guard before update on public.docs for each row execute function public.moe_save_guard();

create or replace function public.admin_save_flags(p_status text default 'open') returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'uid', f.uid, 'at', f.at, 'lvl', f.lvl, 'detail', f.detail, 'status', f.status, 'has', f.attempted is not null, 'name', coalesce(d.data->>'n', '守護員')) order by f.at desc)
    from (select * from save_flags where (p_status = 'all' or status = p_status) order by at desc limit 200) f left join docs d on d.path = 'arena/' || f.uid::text), '[]'::jsonb); end $$;
create or replace function public.admin_save_hist(p_uid uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'at', at, 's', moe_save_stats(data)) order by at desc) from save_hist where uid = p_uid), '[]'::jsonb); end $$;
create or replace function public.admin_save_restore(p_uid uuid, p_hist bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); dd jsonb; begin
  select data into dd from save_hist where id = p_hist and uid = p_uid; if dd is null then raise exception '找不到這份存檔'; end if;
  perform set_config('moe.skip', '1', true);
  update docs set data = jsonb_set(dd, '{t}', to_jsonb((extract(epoch from now()) * 1000)::bigint)), updated_at = now() where path = 'data/users/' || p_uid::text || '/save';
  update save_flags set status = 'restored' where uid = p_uid and status = 'open';
  if to_regprocedure('public.moe_res_from_save(uuid)') is not null then perform moe_res_from_save(p_uid); end if;
  perform alog('save_restore', p_uid, jsonb_build_object('hist', p_hist)); return jsonb_build_object('ok', true); end $$;
create or replace function public.admin_save_accept(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); f save_flags; begin
  select * into f from save_flags where id = p_id; if f.id is null then raise exception '找不到'; end if;
  if f.attempted is not null then perform set_config('moe.skip', '1', true);
    update docs set data = jsonb_set(f.attempted, '{t}', to_jsonb((extract(epoch from now()) * 1000)::bigint)), updated_at = now() where path = 'data/users/' || f.uid::text || '/save'; end if;
  if to_regprocedure('public.moe_res_from_save(uuid)') is not null then perform moe_res_from_save(f.uid); end if;
  update save_flags set status = 'ok' where id = p_id; perform alog('save_accept', f.uid, jsonb_build_object('flag', p_id)); return jsonb_build_object('ok', true); end $$;
create or replace function public.admin_save_close(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); begin update save_flags set status = 'closed' where id = p_id; return jsonb_build_object('ok', true); end $$;
revoke execute on function public.moe_save_stats(jsonb), public.moe_save_guard() from public, anon, authenticated;
grant execute on function public.admin_save_flags(text), public.admin_save_hist(uuid), public.admin_save_restore(uuid,bigint), public.admin_save_accept(bigint), public.admin_save_close(bigint) to authenticated;

-- 測試儲值:已關閉(正式金流上線前)

create or replace function public.topup_test(p_pkg text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  -- 儲值功能關閉中:正式串接金流後改由金流通知入帳
  raise exception '儲值功能即將開放,敬請期待';
end $$;
revoke execute on function public.topup_test_impl(text) from public, anon, authenticated;
grant execute on function public.topup_test(text) to authenticated;

-- ============ 後台備份(#43):匯出全部資料、從備份還原單一玩家 ============
-- 要備份的資料表(暫存性質的 events / live_msg / sessions / save_hist 不備份)
create or replace function public.moe_backup_list() returns text[] language sql stable set search_path = public as $$
  select coalesce(array_agg(t order by t), '{}') from unnest(array['docs','wallet','admins','notice','admin_log','bans','bots','chat_hide','code_use','codes','game_event','gem_log','inbox','ladder','ladder_def','market','mint_quota','mutes','pay_first','player_day','save_flags','settings','td_duo','td_week','tickets']) t
  where to_regclass('public.' || t) is not null $$;
create or replace function public.admin_backup_tables() returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); r jsonb := '[]'::jsonb; t text; n bigint;
begin
  foreach t in array moe_backup_list() loop execute format('select count(*) from public.%I', t) into n; r := r || jsonb_build_array(jsonb_build_object('t', t, 'n', n)); end loop;
  r := r || jsonb_build_array(jsonb_build_object('t', 'auth_users', 'n', (select count(*) from auth.users)));
  return jsonb_build_object('tables', r, 'last', (select v from settings where k = 'backup'));
end $$;
-- 分頁讀取一個資料表:依主鍵排序,p_after 傳上一頁最後一筆的 key
create or replace function public.admin_backup_page(p_table text, p_after text default '', p_limit int default 500) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); k text; nk int; ke text; rws jsonb; lst text; lim int := greatest(1, least(coalesce(p_limit, 500), 2000));
begin
  if p_table = 'auth_users' then
    select coalesce(jsonb_agg(j order by kk), '[]'::jsonb), max(kk) into rws, lst from (
      select jsonb_build_object('id', id, 'acct', moe_acct(email), 'created_at', created_at, 'last_sign_in_at', last_sign_in_at) j, id::text collate "C" kk
      from auth.users where id::text collate "C" > coalesce(p_after, '') order by 2 limit lim) s;
    return jsonb_build_object('rows', rws, 'last', lst, 'done', jsonb_array_length(rws) < lim);
  end if;
  if not (p_table = any(moe_backup_list())) then raise exception '不能備份這個資料表'; end if;
  select string_agg('x.' || quote_ident(at.attname), ',' order by array_position(i.indkey::int2[], at.attnum)), count(*) into k, nk
    from pg_index i join pg_attribute at on at.attrelid = i.indrelid and at.attnum = any(i.indkey) where i.indrelid = ('public.' || p_table)::regclass and i.indisprimary;
  ke := case when k is null then 'x::text' when nk = 1 then k || '::text' else 'row(' || k || ')::text' end;
  execute format('select coalesce(jsonb_agg(j order by kk), ''[]''::jsonb), max(kk) from (select to_jsonb(x) j, (%1$s) collate "C" kk from public.%2$I x where (%1$s) collate "C" > $1 order by 2 limit $2) s', ke, p_table)
    into rws, lst using coalesce(p_after, ''), lim;
  return jsonb_build_object('rows', rws, 'last', lst, 'done', jsonb_array_length(rws) < lim);
end $$;
create or replace function public.admin_backup_done(p_rows bigint, p_bytes bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); v jsonb; begin
  v := jsonb_build_object('at', now(), 'rows', p_rows, 'bytes', p_bytes, 'by', (select moe_acct(email) from auth.users where id = a));
  insert into settings(k, v) values ('backup', v) on conflict (k) do update set v = excluded.v;
  perform alog('backup', null, v); return v; end $$;
-- 從備份還原單一玩家:存檔 + 鑽石錢包(不動儲值累計)。還原前先把目前存檔放進存檔歷史,並讓玩家在線的裝置登出,避免舊進度又被存回來
create or replace function public.admin_backup_restore(p_uid uuid, p_save jsonb, p_wallet jsonb default null, p_from text default '') returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); pth text := 'data/users/' || p_uid::text || '/save'; cur jsonb; begin
  if p_save is null or p_save->>'json' is null then raise exception '備份裡沒有這位玩家的存檔'; end if;
  if not exists (select 1 from auth.users where id = p_uid) then raise exception '這個帳號已經不存在,無法還原'; end if;
  select data into cur from docs where path = pth;
  if cur is not null then insert into save_hist(uid, data) values (p_uid, cur); end if;
  perform set_config('moe.skip', '1', true);
  update docs set data = jsonb_set(p_save, '{t}', to_jsonb((extract(epoch from now()) * 1000)::bigint)), updated_at = now() where path = pth;
  if not found then insert into docs(path, coll, owner, data, updated_at) values (pth, 'data/users/' || p_uid::text, p_uid, jsonb_set(p_save, '{t}', to_jsonb((extract(epoch from now()) * 1000)::bigint)), now()); end if;
  if p_wallet is not null and p_wallet ? 'gem' then
    update wallet set gem = greatest(0, (p_wallet->>'gem')::int), pity = coalesce((p_wallet->>'pity')::int, pity), dpity = coalesce((p_wallet->>'dpity')::int, dpity), updated_at = now() where uid = p_uid;
  end if;
  if to_regprocedure('public.moe_res_from_save(uuid)') is not null then perform moe_res_from_save(p_uid); end if;
  update sessions set sid = gen_random_uuid(), dev = '管理員還原存檔', seen = now() where uid = p_uid;
  perform alog('backup_restore', p_uid, jsonb_build_object('from', p_from, 'gem', p_wallet->'gem'));
  return jsonb_build_object('ok', true); end $$;
revoke execute on function public.moe_backup_list() from public, anon, authenticated;
grant execute on function public.admin_backup_tables(), public.admin_backup_page(text,text,int), public.admin_backup_done(bigint,bigint), public.admin_backup_restore(uuid,jsonb,jsonb,text) to authenticated;
create or replace function public.admin_backup_last() returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); begin return (select v from settings where k = 'backup'); end $$;
grant execute on function public.admin_backup_last() to authenticated;

-- ============ 防作弊第二階段 A:主要資源改由伺服器記帳(星星幣、進化石、糖果;碎片只監控) ============
alter table public.wallet add column if not exists r_on boolean not null default false;
alter table public.wallet add column if not exists r_coin bigint not null default 3000;
alter table public.wallet add column if not exists r_stones int not null default 5;
alter table public.wallet add column if not exists r_candy int not null default 30;
alter table public.wallet add column if not exists r_shards int not null default 0;
alter table public.wallet add column if not exists r_day date;
alter table public.wallet add column if not exists r_today jsonb not null default '{}'::jsonb;
alter table public.wallet add column if not exists r_bank jsonb not null default '{}'::jsonb;
alter table public.wallet add column if not exists r_flag date;
-- 每日收入上限 = 基本 + 每級主城 × 主城等級(可在 settings 表的 res_caps 調整,不用改程式)
drop function if exists public.moe_res_cap(text,int);
create or replace function public.moe_res_cap(p_k text, p_castle int) returns bigint language plpgsql stable set search_path = public as $$
declare c jsonb := coalesce((select st.v from settings st where st.k = 'res_caps'), '{}'::jsonb); d jsonb := '{"coin":[2000000,1000000],"stones":[300,40],"candy":[2000,250],"shards":[300,30]}'::jsonb; x jsonb;
begin x := coalesce(c->p_k, d->p_k); return ((x->>0)::bigint + (x->>1)::bigint * greatest(1, least(coalesce(p_castle, 1), 50))); end $$;
create or replace function public.moe_castle(u uuid) returns int language plpgsql stable set search_path = public as $$
declare c int; begin
  begin select ((data->>'json')::jsonb->>'castle')::int into c from docs where path = 'data/users/' || u::text || '/save'; exception when others then c := 1; end;
  return coalesce(c, 1); end $$;
-- 依存檔內容設定帳本(第一次啟用,或管理員還原存檔後)
create or replace function public.moe_res_from_save(u uuid) returns void language plpgsql security definer set search_path = public as $$
declare s jsonb; begin
  select moe_save_stats(data) into s from docs where path = 'data/users/' || u::text || '/save';
  insert into wallet(uid) values (u) on conflict do nothing;
  update wallet set r_on = true, r_coin = greatest(0, coalesce((s->>'coin')::bigint, 3000)), r_stones = greatest(0, coalesce((s->>'stones')::int, 5)),
    r_candy = greatest(0, coalesce((s->>'candy')::int, 30)), r_shards = greatest(0, coalesce((s->>'shards')::int, 0)), r_bank = '{}'::jsonb, updated_at = now() where uid = u; end $$;
create or replace function public.moe_res_json(w wallet) returns jsonb language sql immutable as $$
  select jsonb_build_object('coin', w.r_coin, 'stones', w.r_stones, 'candy', w.r_candy, 'shards', w.r_shards, 'bank', w.r_bank) $$;
-- 伺服器直接入帳(信箱、兌換碼、交易所這類伺服器知道內容的獎勵,不算每日上限)
create or replace function public.moe_res_add(u uuid, k text, n bigint) returns void language plpgsql security definer set search_path = public as $$
begin
  if n = 0 or k not in ('coin','stones','candy','shard','shards') then return; end if;
  update wallet set r_coin = case when k = 'coin' then greatest(0, r_coin + n) else r_coin end, r_stones = case when k = 'stones' then greatest(0, r_stones + n) else r_stones end,
    r_candy = case when k = 'candy' then greatest(0, r_candy + n) else r_candy end, r_shards = case when k in ('shard','shards') then greatest(0, r_shards + n) else r_shards end, updated_at = now()
  where uid = u and r_on; end $$;

-- 同步:鑽石 + 資源一次處理(取代單獨的 gem_sync)
create or replace function public.wallet_sync(p_earn int, p_spend int, p_re jsonb default '{}'::jsonb, p_rs jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); g jsonb; w wallet; cs int; k text; e bigint; s bigint; cap bigint; today bigint; ok bigint; bal bigint; bad jsonb := '{}'::jsonb;
begin
  g := gem_sync(p_earn, p_spend);
  select * into w from wallet where uid = u for update;
  if not w.r_on then perform moe_res_from_save(u); select * into w from wallet where uid = u for update; end if;
  if w.r_day is distinct from moe_today() then w.r_day := moe_today(); w.r_today := '{}'::jsonb; end if;
  cs := moe_castle(u);
  foreach k in array array['coin','stones','candy','shards'] loop
    e := greatest(0, least(coalesce((p_re->>k)::bigint, 0), 1000000000)); s := greatest(0, least(coalesce((p_rs->>k)::bigint, 0), 1000000000));
    e := e + coalesce((w.r_bank->>k)::bigint, 0);
    cap := moe_res_cap(k, cs); today := coalesce((w.r_today->>k)::bigint, 0);
    if k = 'shards' then ok := e;  -- 碎片只監控,超過上限記一筆異常
      if today + e > cap and w.r_flag is distinct from moe_today() then bad := bad || jsonb_build_object('shards', jsonb_build_object('today', today + e, 'cap', cap)); end if;
    else ok := least(e, greatest(0, cap - today)); end if;
    w.r_bank := case when e - ok > 0 then w.r_bank || jsonb_build_object(k, e - ok) else w.r_bank - k end;
    w.r_today := w.r_today || jsonb_build_object(k, today + ok);
    bal := case k when 'coin' then w.r_coin when 'stones' then w.r_stones when 'candy' then w.r_candy else w.r_shards end + ok;
    if s > bal then if k <> 'shards' then w.flags := w.flags + 1; bad := bad || jsonb_build_object(k || '_spend', jsonb_build_object('spend', s, 'have', bal)); end if; s := bal; end if;
    bal := bal - s;
    if k = 'coin' then w.r_coin := bal; elsif k = 'stones' then w.r_stones := bal; elsif k = 'candy' then w.r_candy := bal; else w.r_shards := bal; end if;
    if e - ok > cap and w.r_flag is distinct from moe_today() then bad := bad || jsonb_build_object(k, jsonb_build_object('bank', e - ok, 'cap', cap)); end if;
  end loop;
  if bad <> '{}'::jsonb then w.r_flag := moe_today(); insert into save_flags(uid, lvl, detail) values (u, 'warn', jsonb_build_object('res', bad, 'castle', cs)); end if;
  update wallet set r_coin = w.r_coin, r_stones = w.r_stones, r_candy = w.r_candy, r_shards = w.r_shards, r_day = w.r_day, r_today = w.r_today, r_bank = w.r_bank, r_flag = w.r_flag, flags = w.flags, updated_at = now() where uid = u;
  return g || jsonb_build_object('res', moe_res_json(w));
end $$;
grant execute on function public.wallet_sync(int,int,jsonb,jsonb) to authenticated;
revoke execute on function public.moe_res_from_save(uuid), public.moe_res_add(uuid,text,bigint), public.moe_castle(uuid) from public, anon, authenticated;

-- 登入時:回傳伺服器帳本(第一次啟用時以目前存檔為起始值)
create or replace function public.wallet_init(p_local int) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); w wallet;
begin
  insert into wallet(uid) values (u) on conflict (uid) do nothing;
  insert into player_day values (u, moe_today()) on conflict do nothing;
  select * into w from wallet where uid = u;
  if not w.r_on then perform moe_res_from_save(u); select * into w from wallet where uid = u; end if;
  return jsonb_build_object('gem',w.gem,'topup',w.topup,'pity',w.pity,'dpity',w.dpity,'bank',w.bank,'free_at',w.free_at,'res',moe_res_json(w));
end $$;

-- 存檔寫入時:星星幣、進化石、糖果一律改成伺服器帳本的數字;碎片總數超過帳本太多就記異常
create or replace function public.moe_save_ledger() returns trigger language plpgsql security definer set search_path = public as $$
declare u uuid; w wallet; j jsonb; sh numeric := 0; v jsonb;
begin
  if NEW.path not like 'data/users/%/save' or current_setting('moe.skip', true) = '1' then return NEW; end if;
  begin u := split_part(NEW.path, '/', 3)::uuid; exception when others then return NEW; end;
  select * into w from wallet where uid = u; if not found or not w.r_on then return NEW; end if;
  begin j := (NEW.data->>'json')::jsonb; exception when others then return NEW; end;
  if j is null then return NEW; end if;
  j := j || jsonb_build_object('coin', w.r_coin, 'stones', w.r_stones, 'candy', w.r_candy);
  NEW.data := jsonb_set(NEW.data, '{json}', to_jsonb(j::text));
  if jsonb_typeof(j->'pets') = 'object' then for v in select value from jsonb_each(j->'pets') loop sh := sh + coalesce((v->>'shards')::numeric, 0); end loop; end if;
  if jsonb_typeof(j->'xs') = 'object' then for v in select value from jsonb_each(j->'xs') loop sh := sh + coalesce((v #>> '{}')::numeric, 0); end loop; end if;
  if sh > w.r_shards + 200 and not exists (select 1 from save_flags where uid = u and status = 'open' and detail ? 'shards_over' and at > now() - interval '1 day') then
    insert into save_flags(uid, lvl, detail) values (u, 'warn', jsonb_build_object('shards_over', jsonb_build_object('save', sh, 'ledger', w.r_shards)));
  end if;
  return NEW;
end $$;
drop trigger if exists docs_save_ledger on public.docs;
create trigger docs_save_ledger before insert or update on public.docs for each row execute function public.moe_save_ledger();
revoke execute on function public.moe_save_ledger() from public, anon, authenticated;

-- ============ 防作弊第二階段 B:萌獸與裝備合理性檢查 ============
-- 回傳存檔裡不合理的地方(只有「這次存檔新出現」的問題才會擋下,舊資料不會卡住)
create or replace function public.moe_save_issues(s jsonb) returns text[] language plpgsql immutable as $$
declare r text[] := '{}'; k text; v jsonb; t text; x jsonb; st int; lv int; bt int; cap int; e jsonb; sb jsonb; mx numeric; i int := 0;
  pk text[] := array['fox','otter','penguin','pango','ferret','whale','bear','dragon','bunny','mouse','mole','puffer','owl','lizard','deer','moth','armad','seal','marten','phoenix'];
  sm jsonb := '{"atk":4,"hp":4,"def":4,"crit":4,"critd":12,"cdr":3,"boss":8,"siege":10,"heal":10}'::jsonb;
begin
  if s is null then return r; end if;
  begin
    if jsonb_typeof(s->'pets') = 'object' then
      for k, v in select * from jsonb_each(s->'pets') loop
        if not (k = any(pk)) then r := r || ('pet:' || k); continue; end if;
        st := coalesce((v->>'st')::numeric, 0)::int; lv := coalesce((v->>'lv')::numeric, 1)::int; bt := coalesce((v->>'bt')::numeric, 0)::int;
        if st < 0 or st > 2 then r := r || (k || '.st'); end if;
        if bt < 0 or bt > 2 or (bt > 0 and st < 2) then r := r || (k || '.bt'); end if;
        cap := case when st = 0 then 10 when st = 1 then 20 else 30 + 10 * least(greatest(bt, 0), 2) end;
        if lv < 1 or lv > cap then r := r || (k || '.lv'); end if;
        if coalesce((v->>'stars')::numeric, 1) not between 1 and 5 then r := r || (k || '.stars'); end if;
        if coalesce((v->>'q')::numeric, 0) not between 0 and 3 then r := r || (k || '.q'); end if;
        if coalesce((v->>'sk')::numeric, 1) not between 0 and 5 then r := r || (k || '.sk'); end if;
      end loop;
    end if;
    if jsonb_typeof(s->'pot') = 'object' then
      for k, v in select * from jsonb_each(s->'pot') loop
        if jsonb_typeof(v) = 'object' then for t, x in select * from jsonb_each(v) loop
          if coalesce((x #>> '{}')::numeric, 0) not between 0 and 20 then r := r || (k || '.pot.' || t); end if; end loop; end if;
      end loop;
    end if;
    if jsonb_typeof(s->'equips') = 'array' then
      for e in select value from jsonb_array_elements(s->'equips') loop
        i := i + 1; exit when i > 2000;
        k := 'eq' || coalesce(e->>'id', '?');
        if coalesce(e->>'type', '') not in ('collar','hat','charm','bell') then r := r || (k || '.type'); continue; end if;
        if coalesce((e->>'rar')::numeric, 0) not between 0 and 4 then r := r || (k || '.rar'); end if;
        if coalesce((e->>'lv')::numeric, 0) not between 0 and 15 then r := r || (k || '.lv'); end if;
        if jsonb_typeof(e->'subs') = 'array' then
          if jsonb_array_length(e->'subs') > 4 then r := r || (k || '.subs'); end if;
          for sb in select value from jsonb_array_elements(e->'subs') loop
            mx := (sm->>(sb->>0))::numeric;
            if mx is null then r := r || (k || '.sub.' || coalesce(sb->>0, '?'));
            elsif coalesce((sb->>1)::numeric, 0) < 0 or (sb->>1)::numeric > mx * 6 + .05 then r := r || (k || '.sub.' || (sb->>0)); end if;
          end loop;
        end if;
      end loop;
    end if;
  exception when others then return r || 'parse'::text; end;
  return r;
end $$;
revoke execute on function public.moe_save_issues(jsonb) from public, anon, authenticated;


-- ============ 防作弊:鑽石依來源驗證(A 方案) ============
-- 遊戲每次給鑽石都附上來源;伺服器依規則表核對:一次性獎勵只能領一次、每日/每週有次數上限、重複獎勵有每日總量上限
create table if not exists public.gem_rule(p text primary key, per text not null, lim int not null default 1, maxn int not null, cap int, re text, need text, note text);
create table if not exists public.gem_once(uid uuid not null, k text not null, n int not null, at timestamptz not null default now(), primary key(uid, k));
create table if not exists public.gem_cnt(uid uuid not null, p text not null, pid text not null, cnt int not null default 0, sum int not null default 0, primary key(uid, p, pid));
alter table public.gem_rule enable row level security;
alter table public.gem_once enable row level security;
alter table public.gem_cnt enable row level security;
alter table public.wallet add column if not exists g_flag date;
-- per: once = 同一個來源一輩子一次;day / week = 每天/每週的次數上限 lim;re = 來源編號必須符合的格式;cap = 每段期間的鑽石總量上限
insert into gem_rule(p, per, lim, maxn, cap, re, need, note) values
 ('ach','once',1,400,null,'^(w5|w20|w100|w500|st60|st150|ch3|ch6|s10|s100|e1|e5|e15|q2|q2x5|q3|div|all8|all14|all20|c3|c5|c10|g10|g30|g50|sg3|sg50|df3|df30|lg|ld|tr10|tr30|tr50|pb5|pb10|rk5|eq2|eq3|eq4|eq15|mk1|mk10|fr5|ht30)$',null,'成就'),
 ('stage','once',1,80,null,'^([0-9]|[1-5][0-9])$',null,'冒險關卡首通'),
 ('hard','once',1,40,null,'^([0-9]|[1-5][0-9])$',null,'困難首通'),
 ('trial','once',1,30,null,'^[0-9]{1,3}$',null,'試煉塔首通'),
 ('pboss','once',1,450,null,'^(rhino|turtle|eagle|octo|treant|wolf):([1-9]|1[0-5])$',null,'個人副本首通'),
 ('chest','once',1,100,null,'^[0-5]:[0-2]$',null,'章節星數寶箱'),
 ('gl','once',1,160,null,'^([1-9]|[1-9][0-9]|1[0-9][0-9])$',null,'守護員升級'),
 ('tdfirst','once',1,400,null,'^[0-2]$',null,'守塔首次通關'),
 ('fund','once',1,500,null,'^(10|20|30|40|50)$','fund','成長基金'),
 ('vip','once',1,900,null,'^([1-9]|1[0-5])$','viplv','VIP 等級禮'),
 ('q','day',6,30,null,'^(adv|farm|up|heart|battle|all)$',null,'每日任務'),
 ('sign','day',1,110,null,null,null,'每日簽到'),
 ('play','day',1,10,null,null,null,'樂園禮物'),
 ('event','day',1,30,null,null,null,'每日活動'),
 ('tdday','day',3,80,null,'^[0-2]$',null,'守塔每日首勝'),
 ('card','day',1,50,null,null,'card','月卡'),
 ('vipday','day',1,64,null,null,'vip','VIP 每日'),
 ('siege','day',150,22,400,null,null,'攻城勝利'),
 ('ladwin','day',40,4,160,null,null,'天梯勝利'),
 ('endless','day',30,150,500,null,null,'守塔無盡'),
 ('wish','day',200,20,600,null,null,'星辰祈願'),
 ('mksell','day',50,5000,1000,null,null,'舊版交易所售出'),
 ('wq','week',6,100,null,'^(adv|siege|pvp|raid|trial|all)$',null,'每週任務'),
 ('trialwk','week',1,300,null,null,null,'試煉塔週結算'),
 ('siegewk','week',1,190,null,null,null,'攻城週排行'),
 ('season','week',1,400,null,null,null,'天梯賽季結算'),
 ('raidrank','week',3,225,null,null,null,'團隊 Boss 排名'),
 ('raidkill','week',3,100,null,null,null,'團隊 Boss 擊殺'),
 ('misc','day',1000000,1000000,100,null,null,'未標示來源(每日上限,超過暫緩)')
on conflict (p) do update set per = excluded.per, lim = excluded.lim, maxn = excluded.maxn, cap = excluded.cap, re = excluded.re, need = excluded.need, note = excluded.note;

-- 核對一批來源,回傳通過的鑽石總數與被拒絕的來源
create or replace function public.moe_gem_src(u uuid, src jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare x jsonb; k text; n int; pp text; suf text; r gem_rule; ok int := 0; rej jsonb := '[]'::jsonb; v_pid text; c gem_cnt; tp int; why text; i int := 0;
begin
  if src is null or jsonb_typeof(src) <> 'array' then return jsonb_build_object('ok', 0, 'rej', rej); end if;
  select topup into tp from wallet where uid = u; tp := coalesce(tp, 0);
  for x in select value from jsonb_array_elements(src) loop
    i := i + 1; exit when i > 300; why := null;
    k := left(coalesce(x->>0, ''), 80); n := coalesce((x->>1)::numeric, 0)::int;
    pp := split_part(k, ':', 1); suf := substr(k, length(pp) + 2);
    select * into r from gem_rule where p = pp and p <> 'misc';
    if not found then why := 'unknown';
    elsif n <= 0 or n > r.maxn then why := 'amount';
    elsif r.re is not null and suf !~ r.re then why := 'id';
    elsif r.need = 'vip' and moe_vip(tp) < 1 then why := 'need';
    elsif r.need = 'viplv' and (suf !~ '^[0-9]+$' or suf::int > moe_vip(tp)) then why := 'need';
    elsif r.need = 'card' and not exists (select 1 from gem_log where uid = u and reason = 'topup:card' and at > now() - interval '31 days') then why := 'need';
    elsif r.need = 'fund' and not exists (select 1 from gem_log where uid = u and reason = 'topup:fund') then why := 'need';
    end if;
    if why is null and r.per = 'once' then
      insert into gem_once(uid, k, n) values (u, k, n) on conflict do nothing; if not found then why := 'dup'; end if;
    elsif why is null then
      v_pid := case r.per when 'week' then moe_week()::text else moe_today()::text end;
      if r.re is not null then insert into gem_once(uid, k, n) values (u, k || '@' || v_pid, n) on conflict do nothing; if not found then why := 'dup'; end if; end if;
      if why is null then
        insert into gem_cnt(uid, p, pid) values (u, pp, v_pid) on conflict do nothing;
        select * into c from gem_cnt where uid = u and gem_cnt.p = pp and gem_cnt.pid = v_pid for update;
        if c.cnt >= r.lim then why := 'limit'; elsif r.cap is not null and c.sum + n > r.cap then n := greatest(0, r.cap - c.sum); if n = 0 then why := 'cap'; end if; end if;
        if why is null then update gem_cnt set cnt = cnt + 1, sum = sum + n where uid = u and gem_cnt.p = pp and gem_cnt.pid = v_pid; end if;
      end if;
    end if;
    if why is null then ok := ok + n; else rej := rej || jsonb_build_array(jsonb_build_object('k', k, 'n', n, 'why', why)); end if;
  end loop;
  return jsonb_build_object('ok', ok, 'rej', rej);
end $$;

-- 鑽石入帳:通過驗證的來源直接入帳;未標示來源的收入每天最多 misc 上限,超過暫緩之後陸續入帳
create or replace function public.moe_gem_apply(u uuid, p_ok int, p_misc int, p_spend int, p_rej jsonb default '[]'::jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare w wallet; m int; cap int; used int; mo int; s int; e int;
begin
  select * into w from wallet where uid = u for update;
  if not found then insert into wallet(uid) values (u) returning * into w; end if;
  if w.earn_day is distinct from moe_today() then w.earn_day := moe_today(); w.earn_today := 0; end if;
  insert into player_day values (u, moe_today()) on conflict do nothing;
  select coalesce(r.cap, 100) into cap from gem_rule r where r.p = 'misc'; cap := coalesce(cap, 100);
  insert into gem_cnt(uid, p, pid) values (u, 'misc', moe_today()::text) on conflict do nothing;
  select sum into used from gem_cnt where uid = u and p = 'misc' and pid = moe_today()::text;
  m := w.bank + greatest(coalesce(p_misc, 0), 0);
  mo := least(m, greatest(0, cap - coalesce(used, 0)));
  w.bank := m - mo;
  update gem_cnt set sum = sum + mo where uid = u and p = 'misc' and pid = moe_today()::text;
  e := greatest(coalesce(p_ok, 0), 0) + mo;
  s := greatest(coalesce(p_spend, 0), 0);
  w.gem := w.gem + e; w.earn_today := w.earn_today + e;
  if s > w.gem then w.flags := w.flags + 1; s := w.gem; end if;
  w.gem := w.gem - s;
  if (jsonb_array_length(coalesce(p_rej, '[]'::jsonb)) > 0 or w.bank > cap * 3) and w.g_flag is distinct from moe_today() then
    w.g_flag := moe_today();
    insert into save_flags(uid, lvl, detail) values (u, 'warn', jsonb_build_object('gem', jsonb_build_object('rej', coalesce(p_rej, '[]'::jsonb), 'bank', w.bank)));
  end if;
  update wallet set gem = w.gem, bank = w.bank, earn_day = w.earn_day, earn_today = w.earn_today, flags = w.flags, g_flag = w.g_flag, updated_at = now() where uid = u;
  if e > 0 then insert into gem_log(uid, delta, reason) values (u, e, 'earn'); end if;
  if s > 0 then insert into gem_log(uid, delta, reason) values (u, -s, 'spend'); end if;
  return jsonb_build_object('gem', w.gem, 'topup', w.topup, 'earned', e, 'spent', s, 'bank', w.bank, 'rej', coalesce(p_rej, '[]'::jsonb));
end $$;

-- 舊版同步(只剩相容用途):沒有來源的鑽石一律當作「未標示來源」,受每日上限限制
create or replace function public.gem_sync(p_earn int, p_spend int) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); begin return moe_gem_apply(u, 0, p_earn, p_spend); end $$;

-- 同步:鑽石(含來源)+ 資源一次處理
drop function if exists public.wallet_sync(int,int,jsonb,jsonb);
create or replace function public.wallet_sync(p_earn int, p_spend int, p_re jsonb default '{}'::jsonb, p_rs jsonb default '{}'::jsonb, p_src jsonb default '[]'::jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); v jsonb; g jsonb; w wallet; cs int; k text; e bigint; s bigint; cap bigint; today bigint; ok bigint; bal bigint; bad jsonb := '{}'::jsonb;
begin
  v := moe_gem_src(u, p_src);
  g := moe_gem_apply(u, (v->>'ok')::int, p_earn, p_spend, v->'rej');
  select * into w from wallet where uid = u for update;
  if not w.r_on then perform moe_res_from_save(u); select * into w from wallet where uid = u for update; end if;
  if w.r_day is distinct from moe_today() then w.r_day := moe_today(); w.r_today := '{}'::jsonb; end if;
  cs := moe_castle(u);
  foreach k in array array['coin','stones','candy','shards'] loop
    e := greatest(0, least(coalesce((p_re->>k)::bigint, 0), 1000000000)); s := greatest(0, least(coalesce((p_rs->>k)::bigint, 0), 1000000000));
    e := e + coalesce((w.r_bank->>k)::bigint, 0);
    cap := moe_res_cap(k, cs); today := coalesce((w.r_today->>k)::bigint, 0);
    if k = 'shards' then ok := e;
      if today + e > cap and w.r_flag is distinct from moe_today() then bad := bad || jsonb_build_object('shards', jsonb_build_object('today', today + e, 'cap', cap)); end if;
    else ok := least(e, greatest(0, cap - today)); end if;
    w.r_bank := case when e - ok > 0 then w.r_bank || jsonb_build_object(k, e - ok) else w.r_bank - k end;
    w.r_today := w.r_today || jsonb_build_object(k, today + ok);
    bal := case k when 'coin' then w.r_coin when 'stones' then w.r_stones when 'candy' then w.r_candy else w.r_shards end + ok;
    if s > bal then if k <> 'shards' then w.flags := w.flags + 1; bad := bad || jsonb_build_object(k || '_spend', jsonb_build_object('spend', s, 'have', bal)); end if; s := bal; end if;
    bal := bal - s;
    if k = 'coin' then w.r_coin := bal; elsif k = 'stones' then w.r_stones := bal; elsif k = 'candy' then w.r_candy := bal; else w.r_shards := bal; end if;
    if e - ok > cap and w.r_flag is distinct from moe_today() then bad := bad || jsonb_build_object(k, jsonb_build_object('bank', e - ok, 'cap', cap)); end if;
  end loop;
  if bad <> '{}'::jsonb then w.r_flag := moe_today(); insert into save_flags(uid, lvl, detail) values (u, 'warn', jsonb_build_object('res', bad, 'castle', cs)); end if;
  update wallet set r_coin = w.r_coin, r_stones = w.r_stones, r_candy = w.r_candy, r_shards = w.r_shards, r_day = w.r_day, r_today = w.r_today, r_bank = w.r_bank, r_flag = w.r_flag, flags = w.flags, updated_at = now() where uid = u;
  return g || jsonb_build_object('res', moe_res_json(w));
end $$;
grant execute on function public.wallet_sync(int,int,jsonb,jsonb,jsonb) to authenticated;
revoke execute on function public.moe_gem_src(uuid,jsonb), public.moe_gem_apply(uuid,int,int,int,jsonb) from public, anon, authenticated;


-- ============ 守塔排行:回報的波數要合理(依隊伍戰力推算的波數 ×1.3 + 15),太高不列入排行並記異常 ============
create or replace function public.moe_td_ok(u uuid, p_wave int) returns boolean language plpgsql security definer set search_path = public as $$
declare pw int; lim int; begin
  begin select coalesce((data->>'pw')::numeric, 0)::int into pw from docs where path = 'arena/' || u::text; exception when others then pw := 0; end;
  lim := floor(bot_td_waves(greatest(coalesce(pw, 0), 5500)) * 1.3 + 15)::int;
  if p_wave <= lim then return true; end if;
  if not exists (select 1 from save_flags where uid = u and status = 'open' and detail ? 'td' and at > now() - interval '1 day') then
    insert into save_flags(uid, lvl, detail) values (u, 'warn', jsonb_build_object('td', jsonb_build_object('wave', p_wave, 'limit', lim, 'pw', pw)));
  end if;
  return false; end $$;
revoke execute on function public.moe_td_ok(uuid,int) from public, anon, authenticated;

-- ============ 管理員:不再開放「設定第一位管理員」,只能由現有管理員在後台新增 ============
create or replace function public.admin_claim() returns jsonb language plpgsql security definer set search_path = public, auth as $$
begin raise exception '新增管理員請由現有管理員在後台「維護 / 管理員」頁操作'; end $$;

-- ============ 自動清理舊紀錄(玩家登入時偶爾執行一次,不影響遊戲) ============
create or replace function public.moe_cleanup() returns void language plpgsql security definer set search_path = public as $$
begin
  delete from gem_log where reason not like 'topup%' and at < now() - interval '365 days';
  delete from player_day where d < moe_today() - 180;
  delete from admin_log where at < now() - interval '180 days';
  delete from market where status <> 'open' and created < now() - interval '90 days';
  delete from save_flags where status <> 'open' and at < now() - interval '180 days';
  delete from gem_cnt where (pid ~ '^\d{4}-' and pid < (moe_today() - 30)::text) or (pid ~ '^\d+$' and pid::int < moe_week() - 5);
  delete from gem_once where k like '%@%' and at < now() - interval '30 days';
  insert into settings(k, v) values ('cleanup', jsonb_build_object('at', now())) on conflict (k) do update set v = excluded.v;
end $$;
revoke execute on function public.moe_cleanup() from public, anon, authenticated;
create or replace function public.moe_cleanup_maybe() returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce((select (v->>'at')::timestamptz from settings where k = 'cleanup'), now() - interval '2 days') < now() - interval '1 day' then perform moe_cleanup(); end if;
exception when others then null; end $$;
revoke execute on function public.moe_cleanup_maybe() from public, anon, authenticated;

-- ============ 交易所關閉:上架中的物品全部用信件退回賣家,交易功能停用 ============
do $$ begin
  if to_regclass('public.market') is not null then
    insert into inbox(uid, item, note, kind, title)
      select seller, item, '交易所已關閉,你上架的物品退回給你,領取後回到背包。', 'market', '交易所關閉:上架物品退回' from market where status = 'open';
    update market set status = 'cancelled' where status = 'open';
  end if;
end $$;
create or replace function public.market_list(p_item jsonb, p_price int) returns jsonb language plpgsql security definer set search_path = public as $$
begin raise exception '交易所已關閉'; end $$;
create or replace function public.market_list_mat(p_mat text, p_pet text, p_n int, p_price int) returns jsonb language plpgsql security definer set search_path = public as $$
begin raise exception '交易所已關閉'; end $$;
create or replace function public.market_buy(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
begin raise exception '交易所已關閉'; end $$;
create or replace function public.market_tick(u uuid) returns void language plpgsql security definer set search_path = public as $$
begin return; end $$;

-- ============ 公會系統(第一階段) ============
create table if not exists public.guilds(id bigserial primary key, name text not null, emb text not null default 'fox', intro text not null default '', notice text not null default '',
  mode text not null default 'open' check (mode in ('open','apply')), minlv int not null default 15, owner uuid, lv int not null default 1, exp bigint not null default 0, created timestamptz not null default now());
create unique index if not exists guilds_name_uq on public.guilds(lower(name));
create table if not exists public.guild_mem(uid uuid primary key references auth.users(id) on delete cascade, gid bigint not null references public.guilds(id) on delete cascade,
  role text not null default 'member' check (role in ('leader','vice','member')), joined timestamptz not null default now(), contrib bigint not null default 0, wk int not null default 0, wk_contrib bigint not null default 0,
  gc int not null default 0, don_d date, don jsonb not null default '[]'::jsonb, shop_d date, shop jsonb not null default '{}'::jsonb, chat_t timestamptz);
create index if not exists guild_mem_gid on public.guild_mem(gid);
create table if not exists public.guild_req(gid bigint not null references public.guilds(id) on delete cascade, uid uuid not null references auth.users(id) on delete cascade, at timestamptz not null default now(), primary key(gid, uid));
create table if not exists public.guild_quit(uid uuid primary key, at timestamptz not null default now());
create table if not exists public.guild_log(id bigserial primary key, gid bigint not null references public.guilds(id) on delete cascade, txt text not null, at timestamptz not null default now());
create index if not exists guild_log_gid on public.guild_log(gid, id);
create table if not exists public.guild_chat(id bigserial primary key, gid bigint not null references public.guilds(id) on delete cascade, uid uuid not null, x text not null, t bigint not null, at timestamptz not null default now());
create index if not exists guild_chat_gid on public.guild_chat(gid, id);
alter table public.guilds enable row level security; alter table public.guild_mem enable row level security; alter table public.guild_req enable row level security;
alter table public.guild_quit enable row level security; alter table public.guild_log enable row level security; alter table public.guild_chat enable row level security;

-- 等級:升到 lv 需要的累積經驗、人數上限、商店
create or replace function public.moe_gneed(lv int) returns bigint language sql immutable as $$
  select (array[0,3000,9000,20000,40000,70000,110000,160000,230000,320000])[greatest(1, least(lv, 10))]::bigint $$;
create or replace function public.moe_gcap(lv int) returns int language sql immutable as $$
  select (array[20,22,24,26,28,30,32,34,37,40])[greatest(1, least(lv, 10))] $$;
create or replace function public.moe_gshop() returns jsonb language sql immutable as $$ select '{
  "coin":   {"n":"星星幣 ×30,000","gc":30,"lim":3,"lv":1,"b":{"coin":30000}},
  "candy":  {"n":"經驗糖果 ×50","gc":40,"lim":3,"lv":1,"b":{"candy":50}},
  "stones": {"n":"進化石 ×5","gc":60,"lim":3,"lv":1,"b":{"stones":5}},
  "ore":    {"n":"鍛造礦石 ×10","gc":50,"lim":2,"lv":2,"b":{"ore":10}},
  "enh":    {"n":"強化石 ×5","gc":60,"lim":2,"lv":3,"b":{"enh":5}},
  "reroll": {"n":"洗練石 ×3","gc":80,"lim":1,"lv":4,"b":{"reroll":3}},
  "rtix":   {"n":"稀有召喚券 ×1","gc":150,"lim":1,"lv":6,"b":{"rtix":1}}}'::jsonb $$;
create or replace function public.moe_gdon() returns jsonb language sql immutable as $$ select '[
  {"n":"小額捐獻","coin":20000,"gem":0,"exp":20,"gc":20},
  {"n":"大額捐獻","coin":100000,"gem":0,"exp":80,"gc":80},
  {"n":"豪華捐獻","coin":0,"gem":50,"exp":150,"gc":150}]'::jsonb $$;
create or replace function public.moe_pname(u uuid) returns text language sql stable security definer set search_path = public as $$
  select coalesce(nullif(d.data->>'n',''), '萌獸守護員') from (select 1) x left join docs d on d.path = 'arena/' || u::text $$;
create or replace function public.moe_glog(g bigint, t text) returns void language sql security definer set search_path = public as $$
  insert into guild_log(gid, txt) values (g, left(t, 120)) $$;
-- 會長不在了(刪帳號)或 14 天沒上線:交給最活躍的副會長/成員;沒人了就解散
create or replace function public.moe_gfix(g bigint) returns void language plpgsql security definer set search_path = public as $$
declare L uuid; n uuid; lseen timestamptz;
begin
  if not exists (select 1 from guild_mem where gid = g) then delete from guilds where id = g; return; end if;
  select uid into L from guild_mem where gid = g and role = 'leader' limit 1;
  if L is not null then
    select coalesce(s.seen, s.at) into lseen from sessions s where s.uid = L;
    if lseen is null or lseen > now() - interval '14 days' then update guilds set owner = L where id = g and owner is distinct from L; return; end if;
  end if;
  select m.uid into n from guild_mem m left join sessions s on s.uid = m.uid where m.gid = g and m.uid is distinct from L and coalesce(s.seen, s.at, m.joined) > now() - interval '3 days'
    order by (m.role = 'vice') desc, m.contrib desc, m.joined limit 1;
  if n is null and L is null then select uid into n from guild_mem where gid = g order by (role = 'vice') desc, contrib desc, joined limit 1; end if;
  if n is null then return; end if;
  update guild_mem set role = 'vice' where uid = L; update guild_mem set role = 'leader' where uid = n; update guilds set owner = n where id = g;
  perform moe_glog(g, moe_pname(n) || ' 接任會長(原會長太久沒上線)');
end $$;
-- 公會資訊(我在公會裡)/ 沒加入時回傳冷卻與申請中的公會
create or replace function public.guild_me() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); m guild_mem; g guilds; w int := moe_week(); r jsonb;
begin
  select * into m from guild_mem where uid = u;
  if m.uid is null then
    return jsonb_build_object('g', null, 'cd', (select greatest(0, extract(epoch from (at + interval '24 hours' - now())))::int from guild_quit where uid = u),
      'reqs', (select coalesce(jsonb_agg(gid), '[]'::jsonb) from guild_req where uid = u));
  end if;
  perform moe_gfix(m.gid);
  select * into m from guild_mem where uid = u; if m.uid is null then return guild_me(); end if;
  select * into g from guilds where id = m.gid;
  if m.wk <> w then update guild_mem set wk = w, wk_contrib = 0 where uid = u; m.wk_contrib := 0; end if;
  r := jsonb_build_object('g', jsonb_build_object('id', g.id, 'name', g.name, 'emb', g.emb, 'intro', g.intro, 'notice', g.notice, 'mode', g.mode, 'minlv', g.minlv, 'lv', g.lv, 'exp', g.exp,
      'need', case when g.lv >= 10 then null else moe_gneed(g.lv + 1) end, 'base', moe_gneed(g.lv), 'cap', moe_gcap(g.lv), 'n', (select count(*) from guild_mem where gid = g.id), 'created', g.created),
    'me', jsonb_build_object('role', m.role, 'gc', m.gc, 'contrib', m.contrib, 'wk_contrib', m.wk_contrib, 'don', case when m.don_d = moe_today() then m.don else '[]'::jsonb end,
      'shop', case when m.shop_d = moe_today() then m.shop else '{}'::jsonb end, 'joined', m.joined),
    'mem', (select coalesce(jsonb_agg(jsonb_build_object('uid', x.uid, 'role', x.role, 'contrib', x.contrib, 'wk', case when x.wk = w then x.wk_contrib else 0 end, 'n', coalesce(nullif(d.data->>'n',''),'萌獸守護員'),
        'av', d.data->>'av', 'gl', (d.data->>'gl')::int, 'pw', (d.data->>'pw')::int, 'seen', coalesce(s.seen, s.at)) order by case x.role when 'leader' then 0 when 'vice' then 1 else 2 end, x.contrib desc), '[]'::jsonb)
      from guild_mem x left join docs d on d.path = 'arena/' || x.uid::text left join sessions s on s.uid = x.uid where x.gid = g.id),
    'log', (select coalesce(jsonb_agg(jsonb_build_object('t', txt, 'at', at) order by id desc), '[]'::jsonb) from (select * from guild_log where gid = g.id order by id desc limit 20) l),
    'don', moe_gdon(), 'shop', moe_gshop());
  if m.role in ('leader','vice') then
    r := r || jsonb_build_object('reqs', (select coalesce(jsonb_agg(jsonb_build_object('uid', q.uid, 'at', q.at, 'n', coalesce(nullif(d.data->>'n',''),'萌獸守護員'), 'av', d.data->>'av', 'gl', (d.data->>'gl')::int, 'pw', (d.data->>'pw')::int) order by q.at), '[]'::jsonb)
      from guild_req q left join docs d on d.path = 'arena/' || q.uid::text where q.gid = g.id));
  end if;
  return r;
end $$;
-- 公會列表 / 搜尋
create or replace function public.guild_list(p_q text default '') returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid();
begin
  return (select coalesce(jsonb_agg(x order by x.full, x.lv desc, x.act desc), '[]'::jsonb) from (
    select g.id, g.name, g.emb, g.intro, g.mode, g.minlv, g.lv, moe_gcap(g.lv) cap, c.n, (c.n >= moe_gcap(g.lv)) full, c.act, moe_pname(g.owner) leader,
      exists (select 1 from guild_req q where q.gid = g.id and q.uid = u) applied
    from guilds g join lateral (select count(*) n, count(*) filter (where coalesce(s.seen, s.at) > now() - interval '3 days') act from guild_mem m left join sessions s on s.uid = m.uid where m.gid = g.id) c on true
    where coalesce(trim(p_q),'') = '' or g.name ilike '%' || trim(p_q) || '%' or g.id::text = trim(p_q)
    order by (c.n >= moe_gcap(g.lv)), g.lv desc, c.act desc limit 30) x);
end $$;
create or replace function public.moe_gname_ok(p text) returns text language plpgsql immutable as $$
declare n text := regexp_replace(trim(coalesce(p,'')), '\s+', ' ', 'g');
begin
  if char_length(n) < 2 or char_length(n) > 10 then raise exception '公會名稱要 2~10 個字'; end if;
  if n ~* '(https?:|www\.|\.com|\.tw|line\.me|@)' then raise exception '公會名稱不能有網址'; end if;
  return n; end $$;
create or replace function public.moe_gtext_ok(p text, mx int) returns text language plpgsql immutable as $$
declare n text := left(trim(coalesce(p,'')), mx);
begin if n ~* '(https?:|www\.|line\.me)' then raise exception '不能貼網址'; end if; return n; end $$;
create or replace function public.moe_gcd(u uuid) returns void language plpgsql stable security definer set search_path = public as $$
begin
  if exists (select 1 from guild_mem where uid = u) then raise exception '你已經在公會裡了'; end if;
  if exists (select 1 from guild_quit where uid = u and at > now() - interval '24 hours') then raise exception '退出公會後 24 小時內不能加入新公會'; end if;
end $$;
-- 建立公會:花 50 萬星星幣(伺服器帳本扣款)
create or replace function public.guild_create(p_name text, p_emb text, p_intro text, p_mode text, p_lv int) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); n text := moe_gname_ok(p_name); w wallet; gid bigint; cost int := 500000;
begin
  perform moe_gcd(u);
  if coalesce(p_lv, 0) < 15 then raise exception '守護員 Lv.15 才能建立公會'; end if;
  if exists (select 1 from guilds where lower(name) = lower(n)) then raise exception '這個公會名稱已經有人用了'; end if;
  select * into w from wallet where uid = u for update;
  if w.uid is null then raise exception '還沒連上伺服器,請重新整理'; end if;
  if not w.r_on then perform moe_res_from_save(u); select * into w from wallet where uid = u for update; end if;
  if w.r_coin < cost then raise exception '星星幣不足(需要 500,000)'; end if;
  update wallet set r_coin = r_coin - cost, updated_at = now() where uid = u;
  insert into guilds(name, emb, intro, mode, owner) values (n, coalesce(nullif(left(p_emb,20),''),'fox'), moe_gtext_ok(p_intro, 80), case when p_mode = 'apply' then 'apply' else 'open' end, u) returning id into gid;
  insert into guild_mem(uid, gid, role, wk) values (u, gid, 'leader', moe_week());
  delete from guild_req where uid = u;
  perform moe_glog(gid, moe_pname(u) || ' 建立了公會');
  return guild_me() || jsonb_build_object('res', (select moe_res_json(x) from wallet x where uid = u));
end $$;
-- 加入(自由加入)或送出申請(需要審核)
create or replace function public.guild_join(p_gid bigint, p_lv int) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); g guilds; c int;
begin
  perform moe_gcd(u);
  select * into g from guilds where id = p_gid for update; if g.id is null then raise exception '找不到這個公會'; end if;
  if coalesce(p_lv, 0) < greatest(15, g.minlv) then raise exception '這個公會要守護員 Lv.% 以上才能加入', greatest(15, g.minlv); end if;
  select count(*) into c from guild_mem where gid = g.id;
  if c >= moe_gcap(g.lv) then raise exception '這個公會人數已滿'; end if;
  if g.mode = 'apply' then
    if (select count(*) from guild_req where uid = u) >= 5 then raise exception '最多同時申請 5 個公會'; end if;
    insert into guild_req(gid, uid) values (g.id, u) on conflict do nothing;
    return guild_me() || jsonb_build_object('applied', true);
  end if;
  insert into guild_mem(uid, gid, wk) values (u, g.id, moe_week()); delete from guild_req where uid = u;
  perform moe_glog(g.id, moe_pname(u) || ' 加入了公會');
  return guild_me();
end $$;
create or replace function public.guild_unapply(p_gid bigint) returns jsonb language plpgsql security definer set search_path = public as $$
begin delete from guild_req where uid = moe_uid() and gid = p_gid; return guild_me(); end $$;
create or replace function public.moe_grole(u uuid) returns guild_mem language plpgsql stable security definer set search_path = public as $$
declare m guild_mem; begin select * into m from guild_mem where uid = u; if m.uid is null then raise exception '你不在公會裡'; end if; return m; end $$;
-- 審核申請
create or replace function public.guild_review(p_uid uuid, p_ok boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); m guild_mem := moe_grole(u); g guilds;
begin
  if m.role not in ('leader','vice') then raise exception '只有會長、副會長可以審核'; end if;
  if not exists (select 1 from guild_req where gid = m.gid and uid = p_uid) then raise exception '這個申請已經不在了'; end if;
  delete from guild_req where gid = m.gid and uid = p_uid;
  if p_ok then
    select * into g from guilds where id = m.gid for update;
    if exists (select 1 from guild_mem where uid = p_uid) then raise exception '對方已經加入別的公會了'; end if;
    if (select count(*) from guild_mem where gid = g.id) >= moe_gcap(g.lv) then raise exception '公會人數已滿'; end if;
    insert into guild_mem(uid, gid, wk) values (p_uid, g.id, moe_week()); delete from guild_req where uid = p_uid;
    perform moe_glog(g.id, moe_pname(p_uid) || ' 加入了公會(' || moe_pname(u) || ' 核准)');
  end if;
  return guild_me();
end $$;
-- 退出:會長要先轉讓;只剩自己就解散
create or replace function public.guild_leave() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); m guild_mem := moe_grole(u); c int;
begin
  select count(*) into c from guild_mem where gid = m.gid;
  if m.role = 'leader' and c > 1 then raise exception '會長要先把會長轉讓給別人才能退出'; end if;
  delete from guild_mem where uid = u;
  insert into guild_quit(uid, at) values (u, now()) on conflict (uid) do update set at = now();
  if c <= 1 then delete from guilds where id = m.gid; else perform moe_glog(m.gid, moe_pname(u) || ' 退出了公會'); end if;
  return guild_me();
end $$;
create or replace function public.guild_kick(p_uid uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); m guild_mem := moe_grole(u); t guild_mem;
begin
  select * into t from guild_mem where uid = p_uid and gid = m.gid; if t.uid is null then raise exception '對方不在公會裡'; end if;
  if p_uid = u then raise exception '不能踢自己'; end if;
  if not (m.role = 'leader' or (m.role = 'vice' and t.role = 'member')) then raise exception '你沒有權限踢這位成員'; end if;
  delete from guild_mem where uid = p_uid;
  perform moe_glog(m.gid, moe_pname(p_uid) || ' 被 ' || moe_pname(u) || ' 請出公會');
  return guild_me();
end $$;
-- 職位:vice / member;leader = 轉讓會長(自己變副會長)
create or replace function public.guild_role(p_uid uuid, p_role text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); m guild_mem := moe_grole(u); t guild_mem;
begin
  if m.role <> 'leader' then raise exception '只有會長可以調整職位'; end if;
  select * into t from guild_mem where uid = p_uid and gid = m.gid; if t.uid is null or p_uid = u then raise exception '對方不在公會裡'; end if;
  if p_role = 'leader' then
    update guild_mem set role = 'vice' where uid = u; update guild_mem set role = 'leader' where uid = p_uid; update guilds set owner = p_uid where id = m.gid;
    perform moe_glog(m.gid, moe_pname(u) || ' 把會長轉讓給 ' || moe_pname(p_uid));
  elsif p_role = 'vice' then
    if (select count(*) from guild_mem where gid = m.gid and role = 'vice') >= 2 then raise exception '副會長最多 2 位'; end if;
    update guild_mem set role = 'vice' where uid = p_uid; perform moe_glog(m.gid, moe_pname(p_uid) || ' 升為副會長');
  else update guild_mem set role = 'member' where uid = p_uid; perform moe_glog(m.gid, moe_pname(p_uid) || ' 改為一般成員'); end if;
  return guild_me();
end $$;
create or replace function public.guild_edit(p_intro text, p_notice text, p_mode text, p_emb text, p_minlv int) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); m guild_mem := moe_grole(u);
begin
  if m.role not in ('leader','vice') then raise exception '只有會長、副會長可以修改'; end if;
  update guilds set intro = moe_gtext_ok(p_intro, 80), notice = moe_gtext_ok(p_notice, 120), mode = case when p_mode = 'apply' then 'apply' else 'open' end,
    emb = coalesce(nullif(left(p_emb,20),''), emb), minlv = greatest(15, least(coalesce(p_minlv, 15), 99)) where id = m.gid;
  return guild_me();
end $$;
-- 每日捐獻(3 種各一次):伺服器扣星星幣/鑽石,加公會經驗、個人貢獻與公會幣
create or replace function public.guild_donate(p_tier int) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); m guild_mem := moe_grole(u); d jsonb := moe_gdon() -> p_tier; w wallet; g guilds; dn jsonb; up boolean := false;
begin
  if d is null then raise exception '沒有這種捐獻'; end if;
  dn := case when m.don_d = moe_today() then m.don else '[]'::jsonb end;
  if dn @> to_jsonb(p_tier) then raise exception '今天已經捐過這一種了'; end if;
  select * into w from wallet where uid = u for update;
  if w.uid is null then raise exception '還沒連上伺服器,請重新整理'; end if;
  if (d->>'coin')::int > 0 then
    if not w.r_on then perform moe_res_from_save(u); select * into w from wallet where uid = u for update; end if;
    if w.r_coin < (d->>'coin')::int then raise exception '星星幣不足'; end if;
    update wallet set r_coin = r_coin - (d->>'coin')::int, updated_at = now() where uid = u;
  end if;
  if (d->>'gem')::int > 0 then
    if w.gem < (d->>'gem')::int then raise exception 'not enough gem'; end if;
    update wallet set gem = gem - (d->>'gem')::int, updated_at = now() where uid = u; insert into gem_log(uid, delta, reason) values (u, -(d->>'gem')::int, 'guild_donate');
  end if;
  update guild_mem set don_d = moe_today(), don = dn || to_jsonb(p_tier), gc = gc + (d->>'gc')::int, contrib = contrib + (d->>'exp')::int,
    wk_contrib = case when wk = moe_week() then wk_contrib else 0 end + (d->>'exp')::int, wk = moe_week() where uid = u;
  select * into g from guilds where id = m.gid for update;
  g.exp := g.exp + (d->>'exp')::int;
  while g.lv < 10 and g.exp >= moe_gneed(g.lv + 1) loop g.lv := g.lv + 1; up := true; end loop;
  update guilds set exp = g.exp, lv = g.lv where id = g.id;
  perform moe_glog(g.id, moe_pname(u) || ' ' || (d->>'n') || ',公會經驗 +' || (d->>'exp'));
  if up then perform moe_glog(g.id, '🎉 公會升到 Lv.' || g.lv || '!'); end if;
  return guild_me() || jsonb_build_object('gem', (select gem from wallet where uid = u), 'res', (select moe_res_json(x) from wallet x where uid = u and r_on), 'up', up);
end $$;
-- 公會商店:扣公會幣,商品寄到信箱
create or replace function public.guild_buy(p_item text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); m guild_mem := moe_grole(u); it jsonb := moe_gshop() -> p_item; g guilds; sh jsonb; c int;
begin
  if it is null then raise exception '沒有這個商品'; end if;
  select * into g from guilds where id = m.gid;
  if g.lv < (it->>'lv')::int then raise exception '公會 Lv.% 才能買', it->>'lv'; end if;
  select * into m from guild_mem where uid = u for update;
  sh := case when m.shop_d = moe_today() then m.shop else '{}'::jsonb end; c := coalesce((sh->>p_item)::int, 0);
  if c >= (it->>'lim')::int then raise exception '今天已經買滿了'; end if;
  if m.gc < (it->>'gc')::int then raise exception '公會幣不足'; end if;
  update guild_mem set gc = gc - (it->>'gc')::int, shop_d = moe_today(), shop = sh || jsonb_build_object(p_item, c + 1) where uid = u;
  insert into inbox(uid, gem, note, credit, kind, title, bonus) values (u, 0, '你在公會商店買了「' || (it->>'n') || '」,領取後入帳。', false, 'guild', '公會商店', it->'b');
  return guild_me() || jsonb_build_object('mail', true);
end $$;
-- 公會聊天
create or replace function public.guild_chat_send(p_x text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); m guild_mem := moe_grole(u); x text := trim(coalesce(p_x,''));
begin
  if x = '' then raise exception '請輸入內容'; end if;
  if char_length(x) > 40 then raise exception '最多 40 個字'; end if;
  if x ~* '(https?:|www\.|line\.me|\.com|\.tw)' then raise exception '不能貼網址'; end if;
  if exists (select 1 from mutes where uid = u and (until is null or until > now())) then raise exception '你目前被禁言'; end if;
  if m.chat_t is not null and m.chat_t > now() - interval '2 seconds' then raise exception 'too fast'; end if;
  update guild_mem set chat_t = now() where uid = u;
  insert into guild_chat(gid, uid, x, t) values (m.gid, u, x, (extract(epoch from now()) * 1000)::bigint);
  delete from guild_chat where gid = m.gid and id < (select min(id) from (select id from guild_chat where gid = m.gid order by id desc limit 100) z);
  return guild_chat_list(0);
end $$;
create or replace function public.guild_chat_list(p_after bigint default 0) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); g bigint;
begin
  select gid into g from guild_mem where uid = u; if g is null then return '[]'::jsonb; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'uid', c.uid, 'x', c.x, 't', c.t, 'n', coalesce(nullif(d.data->>'n',''),'萌獸守護員'), 'av', d.data->>'av', 'me', c.uid = u) order by c.id), '[]'::jsonb)
    from (select * from guild_chat where gid = g and id > coalesce(p_after, 0) order by id desc limit 50) c left join docs d on d.path = 'arena/' || c.uid::text
    where not exists (select 1 from chat_hide h where h.uid = c.uid and h.t = c.t));
end $$;
-- 後台
create or replace function public.admin_guilds(p_q text default '') returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin();
begin
  return (select coalesce(jsonb_agg(x order by x.lv desc, x.exp desc), '[]'::jsonb) from (
    select g.id, g.name, g.emb, g.intro, g.notice, g.mode, g.lv, g.exp, g.created, moe_gcap(g.lv) cap, moe_pname(g.owner) leader, g.owner,
      (select count(*) from guild_mem m where m.gid = g.id) n
    from guilds g where coalesce(trim(p_q),'') = '' or g.name ilike '%' || trim(p_q) || '%' or g.id::text = trim(p_q) order by g.lv desc, g.exp desc limit 200) x);
end $$;
create or replace function public.admin_guild(p_gid bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin();
begin
  return jsonb_build_object('mem', (select coalesce(jsonb_agg(jsonb_build_object('uid', m.uid, 'role', m.role, 'contrib', m.contrib, 'gc', m.gc, 'joined', m.joined, 'n', moe_pname(m.uid)) order by m.contrib desc), '[]'::jsonb) from guild_mem m where m.gid = p_gid),
    'log', (select coalesce(jsonb_agg(jsonb_build_object('t', txt, 'at', at) order by id desc), '[]'::jsonb) from (select * from guild_log where gid = p_gid order by id desc limit 50) l),
    'chat', (select coalesce(jsonb_agg(jsonb_build_object('uid', c.uid, 'x', c.x, 't', c.t, 'n', moe_pname(c.uid)) order by c.id desc), '[]'::jsonb) from (select * from guild_chat where gid = p_gid order by id desc limit 50) c));
end $$;
create or replace function public.admin_guild_set(p_gid bigint, p_name text, p_intro text, p_notice text) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); n text := moe_gname_ok(p_name);
begin
  if exists (select 1 from guilds where lower(name) = lower(n) and id <> p_gid) then raise exception '這個公會名稱已經有人用了'; end if;
  update guilds set name = n, intro = left(coalesce(p_intro,''), 80), notice = left(coalesce(p_notice,''), 120) where id = p_gid;
  perform moe_glog(p_gid, '營運團隊修改了公會資料'); perform alog('guild_set', null, jsonb_build_object('gid', p_gid, 'name', n));
  return jsonb_build_object('ok', true);
end $$;
create or replace function public.admin_guild_disband(p_gid bigint, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); gn text;
begin
  select name into gn from guilds where id = p_gid; if gn is null then raise exception '找不到公會'; end if;
  insert into inbox(uid, gem, note, credit, kind, title) select uid, 0, '你所在的公會「' || gn || '」已被營運團隊解散。原因:' || coalesce(nullif(trim(p_reason),''), '違反遊戲規範'), false, 'ops', '公會解散通知' from guild_mem where gid = p_gid;
  delete from guilds where id = p_gid;
  perform alog('guild_disband', null, jsonb_build_object('gid', p_gid, 'name', gn, 'reason', p_reason));
  return jsonb_build_object('ok', true);
end $$;
create or replace function public.admin_guild_kick(p_uid uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin(); g bigint;
begin
  select gid into g from guild_mem where uid = p_uid; if g is null then raise exception '對方不在公會裡'; end if;
  delete from guild_mem where uid = p_uid; perform moe_glog(g, moe_pname(p_uid) || ' 被營運團隊移出公會'); perform moe_gfix(g);
  perform alog('guild_kick', p_uid, jsonb_build_object('gid', g)); return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.moe_gfix(bigint), public.moe_glog(bigint,text), public.moe_gcd(uuid), public.moe_grole(uuid), public.moe_pname(uuid) from public, anon, authenticated;
grant execute on function public.guild_me(), public.guild_list(text), public.guild_create(text,text,text,text,int), public.guild_join(bigint,int), public.guild_unapply(bigint), public.guild_review(uuid,boolean),
  public.guild_leave(), public.guild_kick(uuid), public.guild_role(uuid,text), public.guild_edit(text,text,text,text,int), public.guild_donate(int), public.guild_buy(text),
  public.guild_chat_send(text), public.guild_chat_list(bigint), public.admin_guilds(text), public.admin_guild(bigint), public.admin_guild_set(bigint,text,text,text), public.admin_guild_disband(bigint,text), public.admin_guild_kick(uuid) to authenticated;
-- 清理:公會聊天 7 天、公會紀錄 60 天、退會冷卻 2 天
create or replace function public.moe_cleanup() returns void language plpgsql security definer set search_path = public as $$
begin
  delete from gem_log where reason not like 'topup%' and at < now() - interval '365 days';
  delete from player_day where d < moe_today() - 180;
  delete from admin_log where at < now() - interval '180 days';
  delete from market where status <> 'open' and created < now() - interval '90 days';
  delete from save_flags where status <> 'open' and at < now() - interval '180 days';
  delete from gem_cnt where (pid ~ '^\d{4}-' and pid < (moe_today() - 30)::text) or (pid ~ '^\d+$' and pid::int < moe_week() - 5);
  delete from gem_once where k like '%@%' and at < now() - interval '30 days';
  delete from guild_chat where at < now() - interval '7 days';
  delete from guild_log where at < now() - interval '60 days';
  delete from guild_quit where at < now() - interval '2 days';
  insert into settings(k, v) values ('cleanup', jsonb_build_object('at', now())) on conflict (k) do update set v = excluded.v;
end $$;
revoke execute on function public.moe_cleanup() from public, anon, authenticated;
-- 備份清單加入公會資料表
create or replace function public.moe_backup_list() returns text[] language sql stable set search_path = public as $$
  select coalesce(array_agg(t order by t), '{}') from unnest(array['docs','wallet','admins','notice','admin_log','bans','bots','chat_hide','code_use','codes','game_event','gem_log','inbox','ladder','ladder_def','market','mint_quota','mutes','pay_first','player_day','save_flags','settings','td_duo','td_week','tickets','guilds','guild_mem','guild_req','guild_quit','guild_log','guild_chat']) t
  where to_regclass('public.' || t) is not null $$;

-- 新手教學完成禮物(一次)
insert into gem_rule(p, per, lim, maxn, cap, re, need, note) values ('tut','once',1,100,null,null,null,'新手教學完成')
on conflict (p) do update set per = excluded.per, lim = excluded.lim, maxn = excluded.maxn, cap = excluded.cap, re = excluded.re, need = excluded.need, note = excluded.note;

-- ============ 平衡調整(2026-11-05):單筆鑽石超過上限時只截掉超過的部分;資源每日上限收斂到實際最高收入約 2 倍 ============
create or replace function public.moe_gem_src(u uuid, src jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare x jsonb; k text; n int; pp text; suf text; r gem_rule; ok int := 0; rej jsonb := '[]'::jsonb; v_pid text; c gem_cnt; tp int; why text; i int := 0;
begin
  if src is null or jsonb_typeof(src) <> 'array' then return jsonb_build_object('ok', 0, 'rej', rej); end if;
  select topup into tp from wallet where uid = u; tp := coalesce(tp, 0);
  for x in select value from jsonb_array_elements(src) loop
    i := i + 1; exit when i > 300; why := null;
    k := left(coalesce(x->>0, ''), 80); n := coalesce((x->>1)::numeric, 0)::int;
    pp := split_part(k, ':', 1); suf := substr(k, length(pp) + 2);
    select * into r from gem_rule where p = pp and p <> 'misc';
    if not found then why := 'unknown';
    elsif n <= 0 then why := 'amount';
    elsif r.re is not null and suf !~ r.re then why := 'id';
    elsif r.need = 'vip' and moe_vip(tp) < 1 then why := 'need';
    elsif r.need = 'viplv' and (suf !~ '^[0-9]+$' or suf::int > moe_vip(tp)) then why := 'need';
    elsif r.need = 'card' and not exists (select 1 from gem_log where uid = u and reason = 'topup:card' and at > now() - interval '31 days') then why := 'need';
    elsif r.need = 'fund' and not exists (select 1 from gem_log where uid = u and reason = 'topup:fund') then why := 'need';
    end if;
    if why is null and n > r.maxn then n := r.maxn; end if;
    if why is null and r.per = 'once' then
      insert into gem_once(uid, k, n) values (u, k, n) on conflict do nothing; if not found then why := 'dup'; end if;
    elsif why is null then
      v_pid := case r.per when 'week' then moe_week()::text else moe_today()::text end;
      if r.re is not null then insert into gem_once(uid, k, n) values (u, k || '@' || v_pid, n) on conflict do nothing; if not found then why := 'dup'; end if; end if;
      if why is null then
        insert into gem_cnt(uid, p, pid) values (u, pp, v_pid) on conflict do nothing;
        select * into c from gem_cnt where uid = u and gem_cnt.p = pp and gem_cnt.pid = v_pid for update;
        if c.cnt >= r.lim then why := 'limit'; elsif r.cap is not null and c.sum + n > r.cap then n := greatest(0, r.cap - c.sum); if n = 0 then why := 'cap'; end if; end if;
        if why is null then update gem_cnt set cnt = cnt + 1, sum = sum + n where uid = u and gem_cnt.p = pp and gem_cnt.pid = v_pid; end if;
      end if;
    end if;
    if why is null then ok := ok + n; else rej := rej || jsonb_build_array(jsonb_build_object('k', k, 'n', n, 'why', why)); end if;
  end loop;
  return jsonb_build_object('ok', ok, 'rej', rej);
end $$;
revoke execute on function public.moe_gem_src(uuid,jsonb) from public, anon, authenticated;
create or replace function public.moe_res_cap(p_k text, p_castle int) returns bigint language plpgsql stable set search_path = public as $$
declare c jsonb := coalesce((select st.v from settings st where st.k = 'res_caps'), '{}'::jsonb); d jsonb := '{"coin":[300000,70000],"stones":[100,15],"candy":[800,80],"shards":[300,30]}'::jsonb; x jsonb;
begin x := coalesce(c->p_k, d->p_k); return ((x->>0)::bigint + (x->>1)::bigint * greatest(1, least(coalesce(p_castle, 1), 50))); end $$;

-- 新角色起始鑽石改為 0(只影響之後新建立的帳號)
alter table public.wallet alter column gem set default 0;

-- ============ 內測大禮包:每個帳號自動寄一次(settings 的 beta.gift 設成 false 就停止寄送) ============
insert into settings(k, v) values ('beta', '{"gift": true}'::jsonb) on conflict (k) do nothing;
create or replace function public.moe_beta_gift(u uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  if u is null or not coalesce((select (v->>'gift')::boolean from settings where k = 'beta'), false) then return; end if;
  if exists (select 1 from inbox where uid = u and kind = 'beta') then return; end if;
  insert into inbox(uid, gem, note, credit, kind, title, bonus) values (u, 3000,
    '感謝參加萌獸星球內測!這是給測試玩家的大禮包,領取後還可以「自選一隻傳說品質的萌獸」。正式上線前會刪檔,請盡量體驗各種功能,有問題到「設定 → 回報問題」告訴我們!',
    true, 'beta', '🎁 內測大禮包', '{"coin":500000,"candy":500,"stones":100,"rtix":3,"lpick":1}'::jsonb);
end $$;
revoke execute on function public.moe_beta_gift(uuid) from public, anon, authenticated;
create or replace function public.session_start(p_dev text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); s uuid := gen_random_uuid();
begin if u is null then raise exception 'not signed in'; end if;
  if to_regprocedure('public.moe_cleanup_maybe()') is not null then perform moe_cleanup_maybe(); end if;
  insert into sessions(uid, sid, dev, at, seen) values (u, s, left(coalesce(p_dev,''),60), now(), now())
    on conflict (uid) do update set sid = excluded.sid, dev = excluded.dev, at = now(), seen = now();
  begin perform moe_beta_gift(u); exception when others then null; end;
  return jsonb_build_object('sid', s); end $$;
grant execute on function public.session_start(text) to authenticated;

-- ============ 封測前調整:上限、預設值、內測禮包改為分 3 天寄 ============
create or replace function public.moe_res_from_save(u uuid) returns void language plpgsql security definer set search_path = public as $$
declare s jsonb; begin
  select moe_save_stats(data) into s from docs where path = 'data/users/' || u::text || '/save';
  insert into wallet(uid) values (u) on conflict do nothing;
  update wallet set r_on = true, r_coin = greatest(0, coalesce((s->>'coin')::bigint, 3000)), r_stones = greatest(0, coalesce((s->>'stones')::int, 0)),
    r_candy = greatest(0, coalesce((s->>'candy')::int, 0)), r_shards = greatest(0, coalesce((s->>'shards')::int, 0)), r_bank = '{}'::jsonb, updated_at = now() where uid = u; end $$;
create or replace function public.moe_res_cap(p_k text, p_castle int) returns bigint language plpgsql stable set search_path = public as $$
declare c jsonb := coalesce((select st.v from settings st where st.k = 'res_caps'), '{}'::jsonb); d jsonb := '{"coin":[300000,100000],"stones":[150,15],"candy":[800,80],"shards":[300,30]}'::jsonb; x jsonb;
begin x := coalesce(c->p_k, d->p_k); return ((x->>0)::bigint + (x->>1)::bigint * greatest(1, least(coalesce(p_castle, 1), 50))); end $$;
create or replace function public.moe_beta_gift(u uuid) returns void language plpgsql security definer set search_path = public as $$
declare b inbox; n int;
begin
  if u is null or not coalesce((select (v->>'gift')::boolean from settings where k = 'beta'), false) then return; end if;
  select * into b from inbox where uid = u and kind = 'beta' order by id limit 1;
  if b.id is null then
    insert into inbox(uid, gem, note, credit, kind, title, bonus) values (u, 1000,
      '感謝參加萌獸星球內測!這是給測試玩家的大禮包,領取後還可以「自選一隻傳說品質的萌獸」。明天、後天登入還會再各收到 💎1,000。正式上線前會刪檔,請盡量體驗各種功能,有問題到「設定 → 回報問題」告訴我們!',
      true, 'beta', '🎁 內測大禮包(第 1 天)', '{"coin":100000,"candy":500,"stones":100,"rtix":3,"lpick":1}'::jsonb);
    return;
  end if;
  if b.gem <> 1000 then return; end if; -- 舊版一次給 3000 的不再補寄
  select count(*) into n from inbox where uid = u and kind in ('beta2','beta3');
  if n >= 2 then return; end if;
  if exists (select 1 from inbox where uid = u and kind in ('beta','beta2','beta3') and (created at time zone 'Asia/Taipei')::date >= moe_today()) then return; end if;
  insert into inbox(uid, gem, note, credit, kind, title) values (u, 1000, '內測大禮包第 ' || (n + 2) || ' 天:💎1,000!謝謝你持續幫忙測試。', true, case when n = 0 then 'beta2' else 'beta3' end, '🎁 內測大禮包(第 ' || (n + 2) || ' 天)');
end $$;
revoke execute on function public.moe_beta_gift(uuid) from public, anon, authenticated;

-- 全服重置編號:玩家的遊戲要讀得到
drop policy if exists settings_read on public.settings; create policy settings_read on public.settings for select to anon, authenticated using (k in ('maint','wipe'));

-- ============ 修正:沒有附加資源的信件領取失敗;內測禮包第 2、3 天至少間隔 20 小時 ============
create or replace function public.inbox_take(p_id bigint default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); out jsonb; cr int;
begin
  with c as (update inbox set claimed = true where uid = u and not claimed and (p_id is null or id = p_id) returning id, item, gem, note, title, credit, bonus)
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'item', item, 'gem', gem, 'note', note, 'title', title, 'credit', credit, 'bonus', bonus) order by id), '[]'::jsonb), coalesce(sum(gem) filter (where credit), 0) into out, cr from c;
  if cr > 0 then insert into wallet(uid) values (u) on conflict do nothing; update wallet set gem = gem + cr, updated_at = now() where uid = u; insert into gem_log(uid,delta,reason) values (u, cr, 'mail'); end if;
  -- 資源帳本:信箱附帶的星星幣、進化石、糖果、碎片由伺服器直接入帳
  if to_regprocedure('public.moe_res_add(uuid,text,bigint)') is not null then
    perform moe_res_add(u, x.k, x.n::bigint) from (
      select b.key k, sum(coalesce((b.value #>> '{}')::bigint, 0)) n from jsonb_array_elements(out) it, jsonb_each(case when jsonb_typeof(it->'bonus') = 'object' then it->'bonus' else '{}'::jsonb end) b where b.key in ('coin','stones','candy') group by b.key
      union all select it->'item'->>'mat', sum(coalesce((it->'item'->>'n')::bigint, 0)) from jsonb_array_elements(out) it where it->'item'->>'mat' in ('stones','candy','shard') group by it->'item'->>'mat') x;
  end if;
  return jsonb_build_object('items', out, 'gem', (select gem from wallet where uid = u), 'res', (select moe_res_json(w) from wallet w where uid = u and r_on));
end $$;
create or replace function public.moe_beta_gift(u uuid) returns void language plpgsql security definer set search_path = public as $$
declare b inbox; n int;
begin
  if u is null or not coalesce((select (v->>'gift')::boolean from settings where k = 'beta'), false) then return; end if;
  select * into b from inbox where uid = u and kind = 'beta' order by id limit 1;
  if b.id is null then
    insert into inbox(uid, gem, note, credit, kind, title, bonus) values (u, 1000,
      '感謝參加萌獸星球內測!這是給測試玩家的大禮包,領取後還可以「自選一隻傳說品質的萌獸」。明天、後天登入還會再各收到 💎1,000。正式上線前會刪檔,請盡量體驗各種功能,有問題到「設定 → 回報問題」告訴我們!',
      true, 'beta', '🎁 內測大禮包(第 1 天)', '{"coin":100000,"candy":500,"stones":100,"rtix":3,"lpick":1}'::jsonb);
    return;
  end if;
  if b.gem <> 1000 then return; end if; -- 舊版一次給 3000 的不再補寄
  select count(*) into n from inbox where uid = u and kind in ('beta2','beta3');
  if n >= 2 then return; end if;
  if exists (select 1 from inbox where uid = u and kind in ('beta','beta2','beta3') and (created > now() - interval '20 hours' or (created at time zone 'Asia/Taipei')::date >= moe_today())) then return; end if;
  insert into inbox(uid, gem, note, credit, kind, title) values (u, 1000, '內測大禮包第 ' || (n + 2) || ' 天:💎1,000!謝謝你持續幫忙測試。', true, case when n = 0 then 'beta2' else 'beta3' end, '🎁 內測大禮包(第 ' || (n + 2) || ' 天)');
end $$;
revoke execute on function public.moe_beta_gift(uuid) from public, anon, authenticated;

-- ================= 封測抽獎轉盤 =================
insert into settings(k, v) values ('raffle', '{"on":false,"start":"2026-11-13","end":"2026-12-03","spin_end":"2026-12-07","p":0.01,"cap":20,"lv":0}'::jsonb) on conflict (k) do nothing;
create table if not exists public.raffle_tix(uid uuid not null, kind text not null, key text not null, n int not null, at timestamptz not null default now(), primary key(uid, kind, key));
create table if not exists public.raffle_spin(id bigserial primary key, uid uuid not null, at timestamptz not null default now(), prize text not null, cash boolean not null default false, slot text, ip text, dev text);
create table if not exists public.raffle_win(id bigserial primary key, uid uuid not null unique, serial text unique, won_at timestamptz not null default now(), day date not null default moe_today(), slot text,
  ck int not null default 0, ck_day date, name text, phone text, bank text, status text not null default 'checkin', note text, invited boolean not null default false, ip text, dev text);
create index if not exists raffle_spin_uid on public.raffle_spin(uid);
alter table public.raffle_tix enable row level security; alter table public.raffle_spin enable row level security; alter table public.raffle_win enable row level security;
drop policy if exists settings_read on public.settings;
create policy settings_read on public.settings for select to anon, authenticated using (k in ('maint','wipe','raffle'));

create or replace function public.moe_rf() returns jsonb language sql stable security definer set search_path = public as $$ select coalesce((select v from settings where k = 'raffle'), '{}'::jsonb) $$;
create or replace function public.moe_ip() returns text language sql stable as $$
  select left(split_part(coalesce((nullif(current_setting('request.headers', true),'')::json)->>'cf-connecting-ip', (nullif(current_setting('request.headers', true),'')::json)->>'x-forwarded-for', ''), ',', 1), 60) $$;
create or replace function public.moe_rf_left(u uuid) returns int language sql stable security definer set search_path = public as $$
  select (coalesce((select sum(n) from raffle_tix where uid = u), 0) - (select count(*) from raffle_spin where uid = u))::int $$;
create or replace function public.moe_rf_slot() returns text language sql stable as $$
  select case when extract(hour from now() at time zone 'Asia/Taipei') between 10 and 15 then 'A' when extract(hour from now() at time zone 'Asia/Taipei') between 16 and 22 then 'B' else null end $$;
create or replace function public.moe_rf_expire() returns void language sql security definer set search_path = public as $$
  update raffle_win set status = 'expired' where status in ('checkin','form') and won_at < now() - interval '14 days' $$;

-- 領券:伺服器以 (帳號, 種類, 鍵) 去重;只在活動期間發券
create or replace function public.raffle_earn(p_kind text, p_key text, p_lv int default 0) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); c jsonb := moe_rf(); d date := moe_today(); n int; k text := coalesce(p_key,'');
begin
  if not coalesce((c->>'on')::boolean, false) or d < (c->>'start')::date or d > (c->>'end')::date then return jsonb_build_object('ok', false, 'left', moe_rf_left(u)); end if;
  if p_kind = 'quest' then k := d::text; n := 2;
  elsif p_kind = 'lv' then if k not in ('5','10','15','20','25') or coalesce(p_lv,0) < k::int then raise exception 'bad'; end if; n := 2;
  elsif p_kind = 'boss' then if k !~ '^[0-9]{1,2}$' or k::int > 20 then raise exception 'bad'; end if; n := 1;
  else raise exception 'bad'; end if;
  insert into raffle_tix(uid, kind, key, n) values (u, p_kind, k, n) on conflict do nothing;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', n > 0, 'got', case when n > 0 then (select t.n from raffle_tix t where t.uid = u and t.kind = p_kind and t.key = k) else 0 end, 'left', moe_rf_left(u));
end $$;

-- 轉盤:每轉 p 機率中現金;每天兩個時段各 1 份;總量 cap;每帳號限中 1 次
create or replace function public.raffle_spin(p_dev text default '', p_lv int default 0) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); c jsonb := moe_rf(); d date := moe_today(); sl text := moe_rf_slot(); r float8; pz text; win raffle_win; mid bigint; g int := 0; bo jsonb := '{}'::jsonb; ttl text;
begin
  if not coalesce((c->>'on')::boolean, false) or d < (c->>'start')::date or d > coalesce((c->>'spin_end')::date, (c->>'end')::date) then raise exception '抽獎轉盤目前沒有開放'; end if;
  if coalesce(p_lv,0) < coalesce((c->>'lv')::int, 0) then raise exception '守護員 Lv.% 以上才能轉', coalesce((c->>'lv')::int, 0); end if;
  perform pg_advisory_xact_lock(hashtext('raffle_spin'));
  if moe_rf_left(u) < 1 then raise exception '沒有抽獎券了'; end if;
  if not exists (select 1 from raffle_win where uid = u)
     and (coalesce((c->>'cap')::int, 0) <= 0 or (select count(*) from raffle_win where status <> 'void') < (c->>'cap')::int)
     and random() < coalesce((c->>'p')::float8, 0.003) then
    insert into raffle_win(uid, day, slot, ip, dev) values (u, d, sl, moe_ip(), left(coalesce(p_dev,''),80)) returning * into win;
    update raffle_win set serial = 'MOE-1000-' || lpad(win.id::text, 4, '0') where id = win.id returning * into win;
    insert into raffle_spin(uid, prize, cash, slot, ip, dev) values (u, 'cash', true, sl, moe_ip(), left(coalesce(p_dev,''),80));
    return jsonb_build_object('prize', 'cash', 'serial', win.serial, 'left', moe_rf_left(u));
  end if;
  r := random() * 100;
  pz := case when r < 40 then 'gem100' when r < 60 then 'coin' when r < 75 then 'rtix' when r < 90 then 'gem300' when r < 97 then 'gem1000' when r < 99.5 then 'pack' else 'skin' end;
  insert into raffle_spin(uid, prize, slot, ip, dev) values (u, pz, sl, moe_ip(), left(coalesce(p_dev,''),80));
  if pz in ('gem100','gem300','gem1000','coin','rtix') then
    g := case pz when 'gem100' then 100 when 'gem300' then 300 when 'gem1000' then 1000 else 0 end;
    bo := case pz when 'coin' then '{"coin":100000}'::jsonb when 'rtix' then '{"rtix":1}'::jsonb else '{}'::jsonb end;
    ttl := '🎡 轉盤獎勵';
    insert into inbox(uid, gem, credit, kind, title, note, bonus) values (u, g, g > 0, 'raffle', ttl, '抽獎轉盤獎勵', bo) returning id into mid;
  end if;
  return jsonb_build_object('prize', pz, 'mail', mid, 'left', moe_rf_left(u));
end $$;

-- 中獎者每天簽到(連續 3 天)
create or replace function public.raffle_checkin() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); d date := moe_today(); w raffle_win;
begin
  perform moe_rf_expire();
  select * into w from raffle_win where uid = u;
  if w.id is null then return null; end if;
  if w.status = 'checkin' and (w.ck_day is null or w.ck_day < d) then
    update raffle_win set ck = case when ck_day = d - 1 then ck + 1 else 1 end, ck_day = d where id = w.id returning * into w;
    if w.ck >= 3 then update raffle_win set status = 'form' where id = w.id returning * into w; end if;
  end if;
  return jsonb_build_object('serial', w.serial, 'won_at', w.won_at, 'ck', w.ck, 'ck_day', w.ck_day, 'status', w.status, 'deadline', (w.won_at + interval '14 days'));
end $$;

create or replace function public.raffle_form(p_name text, p_phone text, p_bank text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); w raffle_win; ph text := regexp_replace(coalesce(p_phone,''), '\D', '', 'g'); bk text := regexp_replace(coalesce(p_bank,''), '[^0-9-]', '', 'g');
begin
  select * into w from raffle_win where uid = u;
  if w.id is null or w.status <> 'form' then raise exception '目前不能填寫領獎資料'; end if;
  if length(trim(coalesce(p_name,''))) < 2 or length(p_name) > 30 then raise exception '請填寫真實姓名'; end if;
  if ph !~ '^09[0-9]{8}$' then raise exception '手機號碼格式不對(09 開頭 10 碼)'; end if;
  if length(regexp_replace(bk,'-','','g')) < 10 or length(bk) > 30 then raise exception '請填寫「銀行代碼-帳號」,例如 812-12345678901'; end if;
  update raffle_win set name = trim(p_name), phone = ph, bank = bk, status = 'review' where id = w.id;
  return jsonb_build_object('ok', true);
end $$;

-- 給玩家看:我的券、今日領券進度、中獎狀態、今日中獎跑馬燈
create or replace function public.raffle_me() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); d date := moe_today();
begin
  perform moe_rf_expire();
  return jsonb_build_object('cfg', moe_rf(), 'today', d, 'slot', moe_rf_slot(), 'left', moe_rf_left(u),
    'earned', coalesce((select sum(n) from raffle_tix where uid = u), 0),
    'got', coalesce((select jsonb_agg(kind || ':' || key) from raffle_tix where uid = u), '[]'::jsonb),
    'spins', coalesce((select jsonb_agg(jsonb_build_object('p', prize, 'at', at) order by id desc) from (select * from raffle_spin where uid = u order by id desc limit 30) s), '[]'::jsonb),
    'win', (select jsonb_build_object('serial', serial, 'won_at', won_at, 'ck', ck, 'ck_day', ck_day, 'status', status, 'deadline', won_at + interval '14 days') from raffle_win where uid = u),
    'given', (select count(*) from raffle_win where status <> 'void'),
    'feed', coalesce((select jsonb_agg(moe_pname(uid)) from raffle_win where day = d and status <> 'void'), '[]'::jsonb));
end $$;

-- 後台
create or replace function public.admin_raffle() returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin();
begin
  return jsonb_build_object('cfg', moe_rf(),
    'stats', jsonb_build_object('players', (select count(distinct uid) from raffle_spin), 'spins', (select count(*) from raffle_spin), 'spins_today', (select count(*) from raffle_spin where (at at time zone 'Asia/Taipei')::date = moe_today()),
       'tix', (select coalesce(sum(n),0) from raffle_tix), 'holders', (select count(distinct uid) from raffle_tix), 'given', (select count(*) from raffle_win where status <> 'void')),
    'wins', coalesce((select jsonb_agg(x order by x.id) from (select w.id, w.uid, moe_pname(w.uid) pname, w.serial, w.won_at, w.slot, w.ck, w.status, w.name, w.phone, w.bank, w.note, w.invited, w.ip, w.dev,
        (select count(distinct s.uid) from raffle_spin s where s.uid <> w.uid and ((w.ip <> '' and s.ip = w.ip) or (w.dev <> '' and s.dev = w.dev))) same_net,
        (select count(*) from raffle_win w2 where w2.id <> w.id and w2.status <> 'void' and ((w.phone is not null and w2.phone = w.phone) or (w.bank is not null and w2.bank = w.bank) or (w.name is not null and w2.name = w.name))) dup
      from raffle_win w) x), '[]'::jsonb));
end $$;
create or replace function public.admin_raffle_set(p_id bigint, p_status text, p_note text default null, p_invited boolean default null) returns void language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin();
begin
  if p_status is not null and p_status not in ('checkin','form','review','approved','paid','void','expired') then raise exception 'bad status'; end if;
  update raffle_win set status = coalesce(p_status, status), note = coalesce(p_note, note), invited = coalesce(p_invited, invited) where id = p_id;
  perform alog('raffle_set', (select uid from raffle_win where id = p_id), jsonb_build_object('id', p_id, 'status', p_status, 'note', p_note));
end $$;
create or replace function public.admin_raffle_cfg(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare a uuid := moe_admin();
begin
  update settings set v = v || (p - array(select k from jsonb_object_keys(p) k where k not in ('on','start','end','spin_end','p','cap','lv'))) where k = 'raffle';
  perform alog('raffle_cfg', null, p);
  return moe_rf();
end $$;
create or replace function public.raffle_feed() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_agg(moe_pname(uid)) from raffle_win where day = moe_today() and status <> 'void'), '[]'::jsonb) $$;
revoke execute on function public.moe_rf_expire() from public, anon, authenticated;
update settings set v = v || '{"lv":0,"p":0.003,"cap":0}'::jsonb where k = 'raffle';
