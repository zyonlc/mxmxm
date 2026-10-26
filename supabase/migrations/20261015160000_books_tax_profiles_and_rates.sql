alter table public.books_organizations
  add column if not exists tax_country_code char(2),
  add column if not exists tax_entity_type text,
  add column if not exists income_tax_regime_confirmed_at timestamptz;

update public.books_organizations
   set tax_country_code = upper(country_code::text)
 where tax_country_code is null;

alter table public.books_organizations
  drop constraint if exists books_organizations_tax_entity_type_check;
alter table public.books_organizations
  add constraint books_organizations_tax_entity_type_check
  check (tax_entity_type is null or tax_entity_type in ('individual', 'sole_proprietor', 'company', 'partnership', 'trust', 'ngo', 'other'));

alter table public.user_profiles
  add column if not exists tax_entity_type text;
alter table public.user_profiles
  drop constraint if exists user_profiles_tax_entity_type_check;
alter table public.user_profiles
  add constraint user_profiles_tax_entity_type_check
  check (tax_entity_type is null or tax_entity_type in ('individual', 'sole_proprietor', 'company', 'partnership', 'trust', 'ngo', 'other'));

create or replace function public.initialize_books_tax_entity_type()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.tax_country_code is null then
    new.tax_country_code := upper(new.country_code::text);
  end if;
  if new.tax_entity_type is null then
    select profile.tax_entity_type into new.tax_entity_type
      from public.user_profiles as profile
     where profile.user_id = new.owner_id;
  end if;
  return new;
end;
$$;

drop trigger if exists initialize_books_tax_entity_type on public.books_organizations;
create trigger initialize_books_tax_entity_type
before insert on public.books_organizations
for each row execute function public.initialize_books_tax_entity_type();
revoke all on function public.initialize_books_tax_entity_type() from public, anon, authenticated;

alter table public.books_tax_rates
  add column if not exists confirmed_at timestamptz;

insert into public.books_tax_rates (
  organization_id, country_code, name, rate_percentage, effective_from, is_active, confirmed_at
)
select organization.id, 'UG', 'URA VAT · suggested default', 18, current_date, true, null
  from public.books_organizations as organization
 where organization.country_code = 'UG'
   and not exists (
     select 1 from public.books_tax_rates as rate
      where rate.organization_id = organization.id
        and rate.country_code = 'UG'
        and rate.name ilike '%VAT%'
        and rate.is_active
        and rate.effective_from <= current_date
        and (rate.effective_to is null or rate.effective_to >= current_date)
   );

create table if not exists public.books_income_tax_rates (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.books_organizations(id) on delete cascade,
  country_code char(2) not null,
  tax_entity_type text not null check (tax_entity_type in ('company', 'individual', 'sole_proprietor', 'partnership', 'trust', 'ngo', 'other')),
  name text not null,
  rate_method text not null check (rate_method in ('flat', 'progressive')),
  rate_schedule jsonb not null check (jsonb_typeof(rate_schedule) = 'array'),
  effective_from date not null,
  effective_to date,
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from),
  unique (organization_id, tax_entity_type, effective_from)
);

alter table public.books_income_tax_rates enable row level security;
drop policy if exists books_income_tax_rates_member_select on public.books_income_tax_rates;
create policy books_income_tax_rates_member_select
  on public.books_income_tax_rates for select to authenticated
  using (organization_id in (select public.user_books_organization_ids()));
grant select on public.books_income_tax_rates to authenticated;

create or replace function public.update_books_tax_profile(
  target_organization_id uuid,
  target_country_code text,
  target_tax_entity_type text
)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if target_country_code is null or target_country_code !~ '^[A-Z]{2}$'
     or (target_tax_entity_type is not null and target_tax_entity_type not in ('individual', 'sole_proprietor', 'company', 'partnership', 'trust', 'ngo', 'other')) then
    raise exception 'Select a valid tax jurisdiction and entity type';
  end if;
  if not exists (
    select 1 from public.books_memberships as membership
     where membership.organization_id = target_organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin')
  ) then
    raise exception 'Only a Books owner or administrator can change the tax profile';
  end if;
  update public.books_organizations
     set tax_country_code = target_country_code,
         tax_entity_type = target_tax_entity_type,
         income_tax_regime_confirmed_at = null
   where id = target_organization_id;
end;
$$;
revoke all on function public.update_books_tax_profile(uuid, text, text) from public, anon;
grant execute on function public.update_books_tax_profile(uuid, text, text) to authenticated;

create or replace function public.save_books_vat_rate(
  target_organization_id uuid,
  target_name text,
  target_rate_percentage numeric,
  target_effective_from date,
  target_country_code text default 'UG'
)
returns uuid language plpgsql security definer set search_path = public
as $$
declare rate_id uuid;
begin
  if not exists (
    select 1 from public.books_memberships as membership
     where membership.organization_id = target_organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin')
  ) then
    raise exception 'Only a Books owner or administrator can change tax rates';
  end if;
  if not exists (select 1 from public.books_organizations as organization where organization.id = target_organization_id and organization.tax_country_code = target_country_code) then
    raise exception 'VAT rate jurisdiction must match the saved Books tax profile';
  end if;
  if nullif(trim(target_name), '') is null or target_rate_percentage is null or target_rate_percentage < 0 or target_rate_percentage > 100
     or target_effective_from is null or target_country_code is null or target_country_code !~ '^[A-Z]{2}$' then
    raise exception 'Enter a valid tax name, country code, and rate';
  end if;
  if target_effective_from < current_date then
    raise exception 'New rates cannot be entered with a past effective date';
  end if;
  if exists (
    select 1 from public.books_tax_rates as future_rate
     where future_rate.organization_id = target_organization_id
       and future_rate.country_code = target_country_code
       and future_rate.effective_from > target_effective_from
       and future_rate.is_active
  ) then
    raise exception 'Add new rates after the latest scheduled rate date';
  end if;
  update public.books_tax_rates
     set effective_to = target_effective_from - 1
   where organization_id = target_organization_id
     and country_code = target_country_code
     and is_active
     and effective_from < target_effective_from
     and (effective_to is null or effective_to >= target_effective_from);
  insert into public.books_tax_rates (
    organization_id, country_code, name, rate_percentage, effective_from,
    effective_to, is_active, confirmed_at
  ) values (
    target_organization_id, target_country_code, trim(target_name), target_rate_percentage,
    target_effective_from, null, true, now()
  ) on conflict (organization_id, name, effective_from) do update set
    rate_percentage = excluded.rate_percentage,
    effective_to = null,
    is_active = true,
    confirmed_at = excluded.confirmed_at
  returning id into rate_id;
  return rate_id;
end;
$$;
revoke all on function public.save_books_vat_rate(uuid, text, numeric, date, text) from public, anon;
grant execute on function public.save_books_vat_rate(uuid, text, numeric, date, text) to authenticated;

create or replace function public.confirm_books_vat_rate(target_organization_id uuid, target_rate_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare selected_rate public.books_tax_rates%rowtype;
begin
  if not exists (
    select 1 from public.books_memberships as membership
     where membership.organization_id = target_organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin')
  ) then
    raise exception 'Only a Books owner or administrator can confirm tax rates';
  end if;
  select * into selected_rate from public.books_tax_rates
   where id = target_rate_id and organization_id = target_organization_id and is_active
     and country_code = (select organization.tax_country_code from public.books_organizations as organization where organization.id = target_organization_id)
     and effective_from <= current_date
     and (effective_to is null or effective_to >= current_date);
  if not found then raise exception 'An active rate for today was not found'; end if;
  update public.books_tax_rates
     set confirmed_at = now()
   where id = target_rate_id;
end;
$$;
revoke all on function public.confirm_books_vat_rate(uuid, uuid) from public, anon;
grant execute on function public.confirm_books_vat_rate(uuid, uuid) to authenticated;

create or replace function public.save_books_income_tax_schedule(
  target_organization_id uuid,
  target_name text,
  target_tax_entity_type text,
  target_rate_method text,
  target_effective_from date,
  target_rate_schedule jsonb
)
returns uuid language plpgsql security definer set search_path = public
as $$
declare
  rate_id uuid;
  country text;
  bracket jsonb;
  bracket_count integer := 0;
  lower_bound numeric;
  upper_bound numeric;
  rate_percentage numeric;
  base_tax numeric;
  previous_upper numeric;
  previous_rate numeric;
  previous_base numeric;
  final_upper numeric;
begin
  if not exists (
    select 1 from public.books_memberships as membership
     where membership.organization_id = target_organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin')
  ) then
    raise exception 'Only a Books owner or administrator can change income-tax rates';
  end if;
  if target_tax_entity_type is null
     or target_tax_entity_type not in ('company', 'individual', 'sole_proprietor', 'partnership', 'trust', 'ngo', 'other')
     or target_rate_method is null or target_rate_method not in ('flat', 'progressive')
     or nullif(trim(target_name), '') is null or target_effective_from is null
     or target_rate_schedule is null or jsonb_typeof(target_rate_schedule) <> 'array' then
    raise exception 'Enter a valid income-tax schedule';
  end if;
  select tax_country_code into strict country
    from public.books_organizations
   where id = target_organization_id and tax_entity_type = target_tax_entity_type;

  if target_effective_from < current_date then
    raise exception 'New income-tax schedules cannot have a past effective date';
  end if;
  if exists (
    select 1 from public.books_income_tax_rates as future_rate
     where future_rate.organization_id = target_organization_id
       and future_rate.tax_entity_type = target_tax_entity_type
       and future_rate.effective_from > target_effective_from
  ) then
    raise exception 'Add schedules after the latest scheduled date for this entity';
  end if;

  for bracket in select value from jsonb_array_elements(target_rate_schedule) loop
    bracket_count := bracket_count + 1;
    lower_bound := nullif(bracket ->> 'lower_bound', '')::numeric;
    upper_bound := nullif(bracket ->> 'upper_bound', 'null')::numeric;
    rate_percentage := nullif(bracket ->> 'rate_percentage', '')::numeric;
    base_tax := nullif(bracket ->> 'base_tax', '')::numeric;
    if lower_bound is null or rate_percentage is null or base_tax is null
       or lower_bound < 0
       or (upper_bound is not null and upper_bound <= lower_bound)
       or base_tax < 0
       or rate_percentage < 0 or rate_percentage > 100
       or (bracket_count = 1 and (lower_bound <> 0 or base_tax <> 0))
       or (bracket_count > 1 and (previous_upper is distinct from lower_bound or abs(base_tax - (previous_base + (lower_bound - previous_upper) * previous_rate / 100)) > 0.01)) then
      raise exception 'Income-tax brackets must be valid, ordered, contiguous, and mathematically consistent';
    end if;
    previous_upper := upper_bound;
    previous_rate := rate_percentage;
    previous_base := base_tax;
    final_upper := upper_bound;
  end loop;
  if bracket_count = 0 or final_upper is not null
     or (target_rate_method = 'flat' and bracket_count <> 1) then
    raise exception 'The income-tax schedule must cover all income and match its calculation method';
  end if;

  update public.books_income_tax_rates
     set effective_to = target_effective_from - 1
   where organization_id = target_organization_id
     and tax_entity_type = target_tax_entity_type
     and effective_from < target_effective_from
     and (effective_to is null or effective_to >= target_effective_from);
  insert into public.books_income_tax_rates (
    organization_id, country_code, tax_entity_type, name, rate_method,
    rate_schedule, effective_from, confirmed_at
  ) values (
    target_organization_id, country, target_tax_entity_type, trim(target_name),
    target_rate_method, target_rate_schedule, target_effective_from, now()
  ) on conflict (organization_id, tax_entity_type, effective_from) do update set
    name = excluded.name, rate_method = excluded.rate_method,
    rate_schedule = excluded.rate_schedule, effective_to = null,
    confirmed_at = excluded.confirmed_at
  returning id into rate_id;
  update public.books_organizations set income_tax_regime_confirmed_at = now()
   where id = target_organization_id;
  return rate_id;
end;
$$;
revoke all on function public.save_books_income_tax_schedule(uuid, text, text, text, date, jsonb) from public, anon;
grant execute on function public.save_books_income_tax_schedule(uuid, text, text, text, date, jsonb) to authenticated;
