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
create table if not exists public.gem_log(id bigserial primary key, uid uuid not null, delta int not null, reason text, at timestamptz not null default now());
create table if not exists public.pay_first(uid uuid, pkg text, primary key(uid,pkg));
alter table public.wallet enable row level security;
alter table public.gem_log enable row level security;
alter table public.pay_first enable row level security;
drop policy if exists wallet_read on public.wallet;
create policy wallet_read on public.wallet for select to authenticated using (uid = auth.uid());
drop policy if exists gem_log_read on public.gem_log;
create policy gem_log_read on public.gem_log for select to authenticated using (uid = auth.uid());

create or replace function public.moe_uid() returns uuid language plpgsql stable as $$
begin if auth.uid() is null then raise exception 'not signed in'; end if; return auth.uid(); end $$;
create or replace function public.moe_today() returns date language sql stable as $$ select (now() at time zone 'Asia/Taipei')::date $$;
create or replace function public.moe_vip(p_topup int) returns int language sql immutable as $$
  select coalesce((select max(i) from unnest(array[0,60,330,980,1980,3280,6480,9800,19800,32800,64800]) with ordinality t(v,i) where p_topup >= v),1)::int - 1 $$;

-- 第一次連線:建立錢包(新玩家 160 鑽石)
create or replace function public.wallet_init(p_local int) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); w wallet;
begin
  insert into wallet(uid) values (u) on conflict (uid) do nothing;
  select * into w from wallet where uid = u;
  return jsonb_build_object('gem',w.gem,'topup',w.topup,'pity',w.pity,'dpity',w.dpity,'bank',w.bank);
end $$;

-- 同步:遊戲中賺到的鑽石(每天最多入帳 1000,超過的先存著,之後每天陸續入帳)與花掉的鑽石
create or replace function public.gem_sync(p_earn int, p_spend int) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); w wallet; e int; s int;
begin
  select * into w from wallet where uid = u for update;
  if not found then insert into wallet(uid) values (u) returning * into w; end if;
  if w.earn_day is distinct from moe_today() then w.earn_day := moe_today(); w.earn_today := 0; end if;
  w.bank := least(w.bank + greatest(coalesce(p_earn,0),0), 20000);
  e := least(w.bank, greatest(1000 - w.earn_today, 0));
  w.bank := w.bank - e;
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
create or replace function public.summon(p_n int, p_wish text default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); w wallet; cost int; res jsonb := '[]'::jsonb; i int; r float; q int; k text; tot float; acc float;
  ks text[] := array['fox','otter','penguin','pango','ferret','whale','bear','dragon','bunny','mouse','mole','puffer','owl','lizard','deer','moth','armad','seal','marten','phoenix'];
  ws float[] := array[1,1,1,1,1,1,.5,.08,1,1,1,1,1,1,1,1,.5,.5,.5,.08];
  epic text[] := array['bear','armad','seal','marten']; anyhi boolean := false;
begin
  if p_n not in (1,10) then raise exception 'bad n'; end if;
  cost := case when p_n = 10 then 1440 else 160 end;
  select * into w from wallet where uid = u for update;
  if not found or w.gem < cost then raise exception 'not enough gem'; end if;
  w.gem := w.gem - cost;
  select sum(x) into tot from unnest(ws) x;
  for i in 1..p_n loop
    w.pity := w.pity + 1; w.dpity := w.dpity + 1; r := random();
    q := case when r < .015 then 3 when r < .1 then 2 when r < .4 then 1 else 0 end;
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
  insert into gem_log(uid,delta,reason) values (u, -cost, 'summon'||p_n);
  return jsonb_build_object('gem',w.gem,'pity',w.pity,'dpity',w.dpity,'res',res);
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
create or replace function public.ladder_report(p_win boolean, p_opp_pts int, p_opp_pw int, p_my_pw int, p_secs real) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); L ladder := ladder_row(); v int; extra int; g int; ok boolean := true;
begin
  select moe_vip(topup) into v from wallet where uid = u; v := coalesce(v,0); extra := (v>=1)::int + (v>=7)::int;
  if L.used >= 5 + extra + L.bought then raise exception 'no tickets'; end if;
  if L.last_at is not null and now() - L.last_at < interval '8 seconds' then raise exception 'too fast'; end if;
  p_opp_pts := least(greatest(coalesce(p_opp_pts, L.pts), 0), L.pts + 400);
  if p_win and (coalesce(p_secs,0) < 4 or coalesce(p_my_pw,0) * 2.5 < coalesce(p_opp_pw,0)) then ok := false; L.flags := L.flags + 1; end if;
  if p_win and ok then
    g := round(least(greatest(25 + (p_opp_pts - L.pts) / 10.0, 12), 40));
    if L.ls >= 3 then g := round(g * 1.5); end if;
    L.pts := L.pts + g; L.w := L.w + 1; L.ls := 0;
  else
    g := round(least(greatest(15 + (L.pts - p_opp_pts) / 12.0, 6), 25));
    L.pts := greatest(0, L.pts - g); L.l := L.l + 1; L.ls := L.ls + 1; g := -g;
  end if;
  L.best := greatest(L.best, L.pts); L.used := L.used + 1;
  update ladder set pts=L.pts, best=L.best, w=L.w, l=L.l, ls=L.ls, used=L.used, flags=L.flags, last_at=now(), updated_at=now() where uid = u;
  return ladder_json(L, extra) || jsonb_build_object('delta', g, 'ok', ok);
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
  where l.ss = moe_season() and (l.w + l.l) > 0 order by l.pts desc limit least(greatest(p_limit,1),100) $$;

-- ============ 玩家交易所 ============
create table if not exists public.market(
  id bigserial primary key, seller uuid not null default auth.uid(), seller_name text, item jsonb not null, price int not null check (price > 0),
  status text not null default 'open', created timestamptz not null default now(), buyer uuid, sold_at timestamptz, ck timestamptz not null default now());
alter table public.market add column if not exists ck timestamptz not null default now();
create index if not exists market_open_idx on public.market(status, created);
create table if not exists public.inbox(id bigserial primary key, uid uuid not null, item jsonb, gem int not null default 0, note text, created timestamptz not null default now(), claimed boolean not null default false);
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
  select greatest(5, round(
    (case when it ? 'uq' and coalesce(it->>'uq','') <> '' then 7000 else (array[12,40,220,2500,10000])[(it->>'rar')::int + 1] end)
    * (1 + .06 * coalesce((it->>'lv')::int,0))
    * (1 + coalesce((select sum((s->>1)::numeric) from jsonb_array_elements(coalesce(it->'subs','[]'::jsonb)) s),0) / 60)
    * (case when it->>'type' = 'bell' then 1.1 else 1 end)))::int $$;

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
  if (select count(*) from market where seller = u and status = 'open' and created > now() - interval '48 hours') >= 5 then raise exception '最多同時上架 5 件'; end if;
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
  insert into inbox(uid, item, note) values (u, m.item, '交易所購買');
  insert into inbox(uid, gem, note) values (m.seller, g, '交易所賣出(已扣 10% 手續費)');
  insert into gem_log(uid,delta,reason) values (u, -m.price, 'market_buy:'||p_id), (m.seller, g, 'market_sell:'||p_id);
  return jsonb_build_object('gem', (select gem from wallet where uid = u), 'item', m.item);
end $$;

create or replace function public.market_cancel(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); m market;
begin
  select * into m from market where id = p_id and seller = u for update;
  if not found or m.status <> 'open' then raise exception '這件已經賣掉或下架了'; end if;
  update market set status = 'cancelled' where id = p_id;
  insert into inbox(uid, item, note) values (u, m.item, '交易所下架退回');
  return jsonb_build_object('ok', true);
end $$;

-- 電腦玩家也會買上架的裝備:定價越接近參考價越容易賣出(在伺服器上計算)
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
      insert into inbox(uid, gem, note) values (u, g, '交易所賣出(電腦玩家購買,已扣 10% 手續費)');
      insert into gem_log(uid,delta,reason) values (u, g, 'market_sell_bot:'||m.id);
    end if;
  end loop;
end $$;
revoke execute on function public.market_tick(uuid) from public, anon, authenticated;

-- 領取信箱(買到的裝備、下架或過期退回的裝備;賣出的鑽石已直接入帳)
create or replace function public.inbox_claim() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := moe_uid(); out jsonb;
begin
  perform market_tick(u);
  insert into inbox(uid, item, note) select seller, item, '交易所上架 48 小時未售出,退回' from market where seller = u and status = 'open' and created < now() - interval '48 hours';
  update market set status = 'expired' where seller = u and status = 'open' and created < now() - interval '48 hours';
  with c as (update inbox set claimed = true where uid = u and not claimed returning item, gem, note)
  select coalesce(jsonb_agg(jsonb_build_object('item', item, 'gem', gem, 'note', note)), '[]'::jsonb) into out from c;
  return jsonb_build_object('items', out, 'gem', (select gem from wallet where uid = u));
end $$;

grant execute on function public.wallet_init(int), public.gem_sync(int,int), public.summon(int,text), public.topup_test(text),
  public.ladder_me(), public.ladder_report(boolean,int,int,int,real), public.ladder_buy(), public.ladder_top(int),
  public.market_list(jsonb,int), public.market_browse(), public.market_mine(), public.market_buy(bigint), public.market_cancel(bigint), public.inbox_claim() to authenticated;
revoke execute on function public.ladder_row(), public.ladder_json(ladder,int) from public, anon, authenticated;
grant select on public.wallet, public.gem_log, public.ladder, public.market, public.inbox to authenticated;
