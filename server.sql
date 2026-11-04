-- 萌獸星球 伺服器驗證(第 2 份 SQL):鑽石錢包、伺服器抽卡、天梯結算、玩家交易所
-- 在 Supabase → SQL Editor 貼上整段 → Run。可以重複執行,不會刪除資料。

-- ============ 錢包 ============
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
create or replace function public.topup_test(p_pkg text) returns jsonb language plpgsql security definer set search_path = public as $$
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
  return jsonb_build_object('items', out, 'gem', (select gem from wallet where uid = u));
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

grant execute on function public.wallet_init(int), public.gem_sync(int,int), public.summon(int,text,boolean), public.topup_test(text),
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
    select u.id uid, nullif(split_part(coalesce(u.email,''),'@',1),'') acct, d.data->>'n' name, coalesce((d.data->>'lv')::int,0) castle,
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
    'user', (select jsonb_build_object('uid', id, 'acct', nullif(split_part(coalesce(email,''),'@',1),''), 'created', created_at, 'last', last_sign_in_at) from auth.users where id = p_uid),
    'wallet', (select to_jsonb(w) from wallet w where uid = p_uid),
    'ladder', (select to_jsonb(l) from ladder l where uid = p_uid),
    'arena', (select data - 'chat' - 'cm' from docs where path = 'arena/' || p_uid::text),
    'ban', (select to_jsonb(b) from bans b where uid = p_uid and (until is null or until > now())),
    'sess', (select jsonb_build_object('dev', dev, 'at', at, 'seen', seen) from sessions where uid = p_uid),
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
begin return (select coalesce(jsonb_agg(jsonb_build_object('uid', x.uid, 'acct', split_part(coalesce(u.email,''),'@',1), 'added', x.added)), '[]'::jsonb) from admins x left join auth.users u on u.id = x.uid); end $$;
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
begin return (select coalesce(jsonb_agg(jsonb_build_object('at', l.at, 'action', l.action, 'target', l.target, 'detail', l.detail, 'admin', split_part(coalesce(u.email,''),'@',1), 'tname', d.data->>'n') order by l.id desc), '[]'::jsonb)
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
begin return (select coalesce(jsonb_agg(to_jsonb(t) || jsonb_build_object('name', d.data->>'n', 'acct', split_part(coalesce(u.email,''),'@',1)) order by t.id desc), '[]'::jsonb)
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
begin return (select coalesce(jsonb_agg(jsonb_build_object('at', g.at, 'uid', g.uid, 'pkg', substr(g.reason, 7), 'gem', g.delta, 'name', d.data->>'n', 'acct', split_part(coalesce(u.email,''),'@',1)) order by g.id desc), '[]'::jsonb)
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
    'anom', (select coalesce(jsonb_agg(jsonb_build_object('uid', g.uid, 'n', coalesce(d.data->>'n','守護員'), 'acct', nullif(split_part(coalesce(u.email,''),'@',1),''), 'earn', g.e, 'gem', w.gem) order by g.e desc), '[]'::jsonb) from (
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
  select data->>'n' into nm from docs where path = 'arena/' || u::text;
  insert into market(seller, seller_name, item, price) values (u, coalesce(nm,'守護員'), it, p_price);
  return jsonb_build_object('ok', true, 'fair', f);
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
create or replace function public.bot_td() returns void language sql security definer set search_path = public as $$
  update bots set td_wk = moe_week(), td_best = case when td_wk <> moe_week() then 0 else td_best end where active and td_wk <> moe_week();
  update bots set td_best = greatest(td_best, floor(8 + power / 900.0 + random() * 10)::int) where active and random() < .08;
$$;
revoke execute on function public.bot_td(), public.td_board(int) from public, anon, authenticated;
grant execute on function public.td_report(int,int), public.td_top(int), public.td_claim() to authenticated;

-- ============ 單一裝置登入 ============
create or replace function public.session_start(p_dev text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); s uuid := gen_random_uuid();
begin if u is null then raise exception 'not signed in'; end if;
  insert into sessions(uid, sid, dev, at, seen) values (u, s, left(coalesce(p_dev,''),60), now(), now())
    on conflict (uid) do update set sid = excluded.sid, dev = excluded.dev, at = now(), seen = now();
  return jsonb_build_object('sid', s); end $$;
create or replace function public.session_ping(p_sid uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); S sessions;
begin if u is null then return jsonb_build_object('ok', true); end if;
  select * into S from sessions where uid = u;
  if S.uid is null then return jsonb_build_object('ok', true); end if;
  if S.sid <> p_sid then return jsonb_build_object('ok', false, 'dev', S.dev); end if;
  update sessions set seen = now() where uid = u; return jsonb_build_object('ok', true); end $$;
grant execute on function public.session_start(text), public.session_ping(uuid) to authenticated;
-- 被擠掉的裝置不能再寫入存檔
drop policy if exists docs_sess on public.docs;
create policy docs_sess on public.docs as restrictive for all to authenticated using (moe_sess_ok()) with check (moe_sess_ok());
