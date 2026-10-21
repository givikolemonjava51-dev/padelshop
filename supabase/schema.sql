-- Padelbade shop: stock, orders and staff access.
-- Run once in Supabase → SQL Editor. Safe to re-run: it never overwrites stock or orders.

-- ---------- tables ----------
create table if not exists public.products (
  id         text primary key,            -- same id as in index.html (r1, b1x, g2 …)
  cat        text not null,
  name       text not null,
  price      numeric(10,2),               -- null = price given at the club
  stock      integer not null default 0 check (stock >= 0),
  updated_at timestamptz not null default now(),
  updated_by text
);

create table if not exists public.orders (
  id         bigint generated always as identity primary key,
  no         text not null unique,
  created_at timestamptz not null default now(),
  name       text not null,
  phone      text not null,
  address    text,
  pay        text not null check (pay in ('cash','bank')),
  items      jsonb not null,              -- [{id,name,price,qty}]
  total      numeric(10,2) not null,
  status     text not null default 'new' check (status in ('new','confirmed','done','cancelled')),
  note       text,
  updated_at timestamptz not null default now(),
  updated_by text
);
create index if not exists orders_created_at_idx on public.orders (created_at desc);

-- Stock is taken off when staff confirm an order, not when the customer sends it.
-- Orders stored before this column existed already took their stock (unless cancelled).
alter table public.orders add column if not exists stock_taken boolean;
update public.orders set stock_taken = (status <> 'cancelled') where stock_taken is null;
alter table public.orders alter column stock_taken set default false;
alter table public.orders alter column stock_taken set not null;

-- Staff who may open /admin. Add a row per person (lower-case e-mail).
create table if not exists public.staff (
  email      text primary key check (email = lower(email)),
  name       text,
  created_at timestamptz not null default now()
);

-- ---------- helpers ----------
create or replace function public.is_staff()
returns boolean
language sql stable security definer set search_path = public, auth
as $$
  select exists (
    select 1 from auth.users u
    join public.staff s on s.email = lower(u.email)
    where u.id = auth.uid() and u.email_confirmed_at is not null
  );
$$;

create or replace function public.staff_email()
returns text language sql stable as $$ select lower(auth.jwt() ->> 'email') $$;

-- ---------- row level security ----------
alter table public.products enable row level security;
alter table public.orders   enable row level security;
alter table public.staff    enable row level security;

drop policy if exists products_read   on public.products;
drop policy if exists products_update on public.products;
drop policy if exists orders_read     on public.orders;
drop policy if exists staff_read      on public.staff;

-- the shop page reads stock with the public key
create policy products_read   on public.products for select using (true);
create policy products_update on public.products for update using (public.is_staff()) with check (public.is_staff());
create policy orders_read     on public.orders   for select using (public.is_staff());
create policy staff_read      on public.staff    for select using (public.is_staff());

-- nobody writes orders or stock directly from the browser except through the functions below
revoke insert, update, delete on public.orders from anon, authenticated;
revoke insert, delete on public.products from anon, authenticated;
revoke update on public.products from anon;
grant select on public.products to anon, authenticated;
grant update (stock) on public.products to authenticated;
grant select on public.orders, public.staff to authenticated;

create or replace function public.products_touch()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  new.updated_by := coalesce(public.staff_email(), new.updated_by);
  return new;
end $$;
drop trigger if exists products_touch on public.products;
create trigger products_touch before update on public.products
  for each row execute function public.products_touch();

-- ---------- place an order (called by the shop page) ----------
-- Refuses items that are already sold out and stores the order as "new".
-- Stock is not taken here: staff check it and confirm the order in /admin.
create or replace function public.place_order(p_name text, p_phone text, p_address text, p_pay text, p_items jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  it      jsonb;
  pr      public.products%rowtype;
  qty     integer;
  lines   jsonb := '[]'::jsonb;
  sum_    numeric := 0;
  short   jsonb := '[]'::jsonb;
  ord_no  text;
begin
  p_name := btrim(coalesce(p_name,''));
  p_phone := btrim(coalesce(p_phone,''));
  if length(p_name) < 1 or length(p_name) > 100 then raise exception 'bad_name'; end if;
  if length(regexp_replace(p_phone,'\D','','g')) < 9 or length(p_phone) > 30 then raise exception 'bad_phone'; end if;
  if p_pay not in ('cash','bank') then raise exception 'bad_pay'; end if;
  if p_pay = 'bank' and length(btrim(coalesce(p_address,''))) < 5 then raise exception 'bad_address'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 50 then
    raise exception 'empty_cart';
  end if;

  for it in select * from jsonb_array_elements(p_items) order by value->>'id' loop
    qty := (it->>'qty')::integer;
    if qty is null or qty < 1 or qty > 999 then raise exception 'bad_qty'; end if;
    select * into pr from public.products where id = it->>'id';
    if not found or pr.price is null then raise exception 'unknown_item'; end if;
    if pr.stock < qty then
      short := short || jsonb_build_object('id', pr.id, 'stock', pr.stock);
      continue;
    end if;
    lines := lines || jsonb_build_object('id', pr.id, 'name', pr.name, 'price', pr.price, 'qty', qty);
    sum_ := sum_ + pr.price * qty;
  end loop;

  if jsonb_array_length(short) > 0 then
    return jsonb_build_object('ok', false, 'error', 'out_of_stock', 'short', short);
  end if;

  loop
    ord_no := 'PB-' || lpad((floor(random() * 100000))::int::text, 5, '0');
    exit when not exists (select 1 from public.orders where no = ord_no);
  end loop;

  insert into public.orders (no, name, phone, address, pay, items, total, stock_taken)
  values (ord_no, p_name, p_phone, nullif(btrim(coalesce(p_address,'')), ''), p_pay, lines, sum_, false);

  return jsonb_build_object('ok', true, 'no', ord_no, 'total', sum_,
    'stock', (select jsonb_object_agg(id, stock) from public.products));
end $$;

revoke all on function public.place_order(text,text,text,text,jsonb) from public;
grant execute on function public.place_order(text,text,text,text,jsonb) to anon, authenticated;

-- ---------- change an order's status (dashboard) ----------
-- Confirming (or marking done) takes the items out of stock and fails with out_of_stock
-- if there is not enough; moving back to "new" or cancelling puts them back.
create or replace function public.set_order_status(p_id bigint, p_status text, p_note text default null)
returns public.orders
language plpgsql security definer set search_path = public
as $$
declare
  o  public.orders%rowtype;
  it jsonb;
  sign_ integer := 0;
  take boolean;
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  if p_status not in ('new','confirmed','done','cancelled') then raise exception 'bad_status'; end if;
  select * into o from public.orders where id = p_id for update;
  if not found then raise exception 'not_found'; end if;

  -- saving a note keeps the status and leaves stock alone
  take := case when p_status = o.status then o.stock_taken else p_status in ('confirmed','done') end;
  if take and not o.stock_taken then sign_ := -1; end if;
  if not take and o.stock_taken then sign_ := 1; end if;

  if sign_ <> 0 then
    for it in select * from jsonb_array_elements(o.items) order by value->>'id' loop
      update public.products set stock = stock + sign_ * (it->>'qty')::integer
        where id = it->>'id';
    end loop;
  end if;

  update public.orders set status = p_status, note = coalesce(p_note, note), stock_taken = take,
    updated_at = now(), updated_by = public.staff_email()
    where id = p_id returning * into o;
  return o;
exception when check_violation then
  raise exception 'out_of_stock';
end $$;

revoke all on function public.set_order_status(bigint,text,text) from public;
grant execute on function public.set_order_status(bigint,text,text) to authenticated;

-- ---------- starting catalog (only inserts ids that are missing) ----------
insert into public.products (id, cat, name, price, stock) values
  ('r1', 'racket', 'Babolat Stima Vita', 300, 1),
  ('r2', 'racket', 'Babolat Air Viper', 1000, 1),
  ('r3', 'racket', 'Head Coello Vibe 2026', 480, 1),
  ('r4', 'racket', 'Head Vibe 2026', 320, 1),
  ('r5', 'racket', 'Nox Equation Hard Advanced', 420, 1),
  ('r6', 'racket', 'Bullpadel Hack Advance', 400, 1),
  ('r7', 'racket', 'Bullpadel Ionic Light 26', 480, 1),
  ('r8', 'racket', 'Bullpadel Ionic Power 26', 600, 1),
  ('r9', 'racket', 'Lok Be Hype Gen 2', 400, 1),
  ('r10', 'racket', 'Bullpadel XPLO 27', 1200, 1),
  ('r11', 'racket', 'Siux Diablo Elite 4', 500, 1),
  ('r12', 'racket', 'Bullpadel Vertex 05 Geo 2027', 1200, 1),
  ('r13', 'racket', 'Bullpadel Hack 05 Hybrid 2027', 1200, 1),
  ('r14', 'racket', 'Bullpadel Neuron 02 2027', 1200, 1),
  ('b1', 'ball', 'Wilson Rush 100', 30, 99),
  ('b1x', 'ball', 'Wilson Rush 100 · ყუთი', 650, 99),
  ('b2', 'ball', 'Tecnifibre Padel Team', 30, 99),
  ('b2x', 'ball', 'Tecnifibre Padel Team · ყუთი', 650, 99),
  ('b3', 'ball', 'Bullpadel Tournament Pro', 30, 99),
  ('b3x', 'ball', 'Bullpadel Tournament Pro · ყუთი', 650, 99),
  ('b4', 'ball', 'Bullpadel FIP Next', 30, 99),
  ('b4x', 'ball', 'Bullpadel FIP Next · ყუთი', 650, 99),
  ('g1', 'bag', 'Bullpadel Ionic ჩანთა', 200, 2),
  ('g2', 'bag', 'Bullpadel APA ჩანთა', 200, 3)
on conflict (id) do nothing;

-- ---------- staff ----------
-- Add each person who may use /admin, then create their login in
-- Authentication → Users → "Add user" (tick "Auto Confirm User").
-- insert into public.staff (email, name) values ('you@example.com', 'Giviko');
