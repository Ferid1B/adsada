-- Run this SQL in Supabase SQL Editor before enabling online-config.js.
create table if not exists public.player_saves (
  user_id uuid primary key references auth.users(id) on delete cascade,
  hero_name text not null,
  level integer not null default 1,
  depth integer not null default 1,
  state jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.player_saves enable row level security;
drop policy if exists "players read own save" on public.player_saves;
drop policy if exists "players insert own save" on public.player_saves;
drop policy if exists "players update own save" on public.player_saves;
create policy "players read own save" on public.player_saves for select using (auth.uid() = user_id);
create policy "players insert own save" on public.player_saves for insert with check (auth.uid() = user_id);
create policy "players update own save" on public.player_saves for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
