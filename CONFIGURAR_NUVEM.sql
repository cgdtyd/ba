-- SQL extraído do DASHBOARD_DE_CONTROLE.html
-- Cole no Supabase: SQL Editor -> New query -> Run

-- dashboard de controle - configuração Supabase
-- Execute este script uma única vez no SQL Editor do seu projeto.
-- A aplicação usa somente a chave anon/publishable. Nunca use service_role no HTML.

create extension if not exists pgcrypto;

create table if not exists public.erp_companies (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  invite_code text not null unique default upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)),
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.erp_company_members (
  company_id uuid not null references public.erp_companies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'operator' check (role in ('owner','admin','operator','viewer')),
  created_at timestamptz not null default now(),
  primary key (company_id,user_id)
);

create table if not exists public.erp_snapshots (
  company_id uuid primary key references public.erp_companies(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  revision bigint not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.erp_companies enable row level security;
alter table public.erp_company_members enable row level security;
alter table public.erp_snapshots enable row level security;

-- O navegador só precisa ler as tabelas. Todas as gravações passam pelas RPCs abaixo.
revoke all on table public.erp_companies from anon;
revoke all on table public.erp_company_members from anon;
revoke all on table public.erp_snapshots from anon;
revoke all on table public.erp_companies from authenticated;
revoke all on table public.erp_company_members from authenticated;
revoke all on table public.erp_snapshots from authenticated;
grant select on table public.erp_companies to authenticated;
grant select on table public.erp_company_members to authenticated;
grant select on table public.erp_snapshots to authenticated;

-- Função pequena, SECURITY DEFINER, usada pelas políticas para não criar
-- recursão de RLS ao consultar erp_company_members dentro das próprias regras.
create or replace function public.is_erp_member(p_company_id uuid)
returns boolean
language sql stable security definer set search_path=public as $$
  select exists(
    select 1
    from public.erp_company_members m
    where m.company_id=p_company_id and m.user_id=auth.uid()
  );
$$;

revoke all on function public.is_erp_member(uuid) from public;
grant execute on function public.is_erp_member(uuid) to authenticated;

drop policy if exists erp_companies_read_members on public.erp_companies;
create policy erp_companies_read_members
on public.erp_companies for select to authenticated
using (public.is_erp_member(id));

drop policy if exists erp_members_read_members on public.erp_company_members;
create policy erp_members_read_members
on public.erp_company_members for select to authenticated
using (public.is_erp_member(company_id));

drop policy if exists erp_snapshots_read_members on public.erp_snapshots;
create policy erp_snapshots_read_members
on public.erp_snapshots for select to authenticated
using (public.is_erp_member(company_id));

-- Cria a primeira empresa do usuário ou entra em uma empresa existente por convite.
create or replace function public.bootstrap_erp_workspace(
  p_company_name text default null,
  p_invite_code text default null
)
returns table(company_id uuid, company_name text, role text, invite_code text)
language plpgsql security definer set search_path=public as $$
declare
  v_uid uuid:=auth.uid();
  v_company uuid;
  v_role text;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select m.company_id,m.role
    into v_company,v_role
  from public.erp_company_members m
  where m.user_id=v_uid
  order by m.created_at
  limit 1;

  if v_company is null and nullif(trim(coalesce(p_invite_code,'')),'') is not null then
    select c.id into v_company
    from public.erp_companies c
    where upper(c.invite_code)=upper(trim(p_invite_code))
    limit 1;

    if v_company is null then raise exception 'invalid_invite_code'; end if;

    v_role:='operator';
    insert into public.erp_company_members(company_id,user_id,role)
    values(v_company,v_uid,v_role)
    on conflict do nothing;
  end if;

  if v_company is null then
    insert into public.erp_companies(name,created_by)
    values(coalesce(nullif(trim(p_company_name),''),'Minha empresa'),v_uid)
    returning id into v_company;

    v_role:='owner';
    insert into public.erp_company_members(company_id,user_id,role)
    values(v_company,v_uid,v_role);

    insert into public.erp_snapshots(company_id)
    values(v_company)
    on conflict do nothing;
  end if;

  insert into public.erp_snapshots(company_id)
  values(v_company)
  on conflict do nothing;

  return query
  select c.id,c.name,m.role,c.invite_code
  from public.erp_companies c
  join public.erp_company_members m
    on m.company_id=c.id and m.user_id=v_uid
  where c.id=v_company;
end $$;

-- Salva um snapshot com revisão. Se outro computador já salvou antes,
-- a função gera sync_conflict em vez de sobrescrever os dados silenciosamente.
create or replace function public.save_erp_snapshot(
  p_company_id uuid,
  p_data jsonb,
  p_base_revision bigint default null,
  p_force boolean default false
)
returns table(revision bigint,updated_at timestamptz)
language plpgsql security definer set search_path=public as $$
declare
  v_uid uuid:=auth.uid();
  v_role text;
  v_current bigint;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select m.role into v_role
  from public.erp_company_members m
  where m.company_id=p_company_id and m.user_id=v_uid;

  if v_role is null then raise exception 'not_authorized'; end if;
  if v_role='viewer' then raise exception 'read_only_user'; end if;

  select s.revision into v_current
  from public.erp_snapshots s
  where s.company_id=p_company_id
  for update;

  if v_current is null then
    insert into public.erp_snapshots(company_id,data,revision,updated_at)
    values(p_company_id,p_data,1,now());
  else
    if not p_force and p_base_revision is not null and v_current<>p_base_revision then
      raise exception 'sync_conflict';
    end if;

    update public.erp_snapshots s
    set data=p_data,
        revision=v_current+1,
        updated_at=now()
    where s.company_id=p_company_id;
  end if;

  return query
  select s.revision,s.updated_at
  from public.erp_snapshots s
  where s.company_id=p_company_id;
end $$;

-- Proprietário/administrador pode invalidar o código antigo e gerar outro.
create or replace function public.rotate_erp_invite(p_company_id uuid)
returns text
language plpgsql security definer set search_path=public as $$
declare
  v_uid uuid:=auth.uid();
  v_role text;
  v_code text;
begin
  select m.role into v_role
  from public.erp_company_members m
  where m.company_id=p_company_id and m.user_id=v_uid;

  if v_role is null or v_role not in ('owner','admin') then
    raise exception 'not_authorized';
  end if;

  v_code:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
  update public.erp_companies set invite_code=v_code where id=p_company_id;
  return v_code;
end $$;

revoke all on function public.bootstrap_erp_workspace(text,text) from public;
revoke all on function public.save_erp_snapshot(uuid,jsonb,bigint,boolean) from public;
revoke all on function public.rotate_erp_invite(uuid) from public;

grant execute on function public.bootstrap_erp_workspace(text,text) to authenticated;
grant execute on function public.save_erp_snapshot(uuid,jsonb,bigint,boolean) to authenticated;
grant execute on function public.rotate_erp_invite(uuid) to authenticated;

