-- 萌獸星球 雲端資料庫設定(在 Supabase 的 SQL Editor 貼上整段後按 Run)
-- 所有遊戲資料都存在 docs 這張表:arena/(公開的玩家資料)、data/users/<id>/(私人存檔)

create table if not exists public.docs(
  path text primary key,
  coll text not null,
  owner uuid not null default auth.uid(),
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
create index if not exists docs_coll_idx on public.docs(coll);
alter table public.docs enable row level security;

drop policy if exists docs_read on public.docs;
drop policy if exists docs_insert on public.docs;
drop policy if exists docs_update on public.docs;
drop policy if exists docs_delete on public.docs;
-- 讀取:公開資料(arena)大家都能讀;私人存檔只有自己能讀
create policy docs_read on public.docs for select to authenticated
  using (coll = 'arena' or owner = auth.uid());
-- 寫入:只能寫自己的 arena 資料、自己的私人存檔
create policy docs_insert on public.docs for insert to authenticated
  with check (owner = auth.uid() and (path = 'arena/' || auth.uid()::text or path like 'data/users/' || auth.uid()::text || '/%'));
create policy docs_update on public.docs for update to authenticated
  using (owner = auth.uid())
  with check (owner = auth.uid() and (path = 'arena/' || auth.uid()::text or path like 'data/users/' || auth.uid()::text || '/%'));
create policy docs_delete on public.docs for delete to authenticated using (owner = auth.uid());

-- 查詢:遊戲的排行榜、天梯、好友、聊天都用這個函式(會套用上面的權限)
create or replace function public.query_docs(p_coll text, p_filters jsonb default '[]'::jsonb, p_order text default null, p_desc boolean default false, p_limit int default 100)
returns table(path text, data jsonb) language plpgsql stable security invoker set search_path = public as $$
declare q text := 'select d.path, d.data from public.docs d where d.coll = ' || quote_literal(p_coll);
  f jsonb; fld text; op text; v text;
begin
  for f in select * from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) loop
    fld := f->>0; op := f->>1; v := (f->2)::text;
    if fld !~ '^[A-Za-z0-9_]+$' then raise exception 'bad field'; end if;
    if op = '==' then q := q || format(' and d.data->%L = %L::jsonb', fld, v);
    elsif op = '!=' then q := q || format(' and d.data->%L <> %L::jsonb', fld, v);
    elsif op in ('<','<=','>','>=') then q := q || format(' and d.data->%L %s %L::jsonb', fld, op, v);
    elsif op = 'array-contains' then q := q || format(' and d.data->%L @> jsonb_build_array(%L::jsonb)', fld, v);
    elsif op = 'in' then q := q || format(' and d.data->%L in (select jsonb_array_elements(%L::jsonb))', fld, v);
    else raise exception 'bad op'; end if;
  end loop;
  if p_order is not null then
    if p_order !~ '^[A-Za-z0-9_]+$' then raise exception 'bad order'; end if;
    q := q || format(' order by d.data->%L %s nulls last', p_order, case when p_desc then 'desc' else 'asc' end);
  end if;
  q := q || ' limit ' || least(greatest(coalesce(p_limit, 100), 1), 500);
  return query execute q;
end $$;

-- 部分更新(聊天、愛心用)
create or replace function public.doc_merge(p_path text, p_patch jsonb)
returns void language plpgsql security invoker set search_path = public as $$
begin
  update public.docs set data = data || p_patch, updated_at = now() where path = p_path;
  if not found then raise exception 'not found'; end if;
end $$;

grant select, insert, update, delete on public.docs to authenticated;
grant execute on function public.query_docs(text, jsonb, text, boolean, int) to authenticated;
grant execute on function public.doc_merge(text, jsonb) to authenticated;
