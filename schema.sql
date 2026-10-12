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

-- Expose only public game stats; never expose account IDs, email addresses, or save JSON.
create table if not exists public.ranked_progress (
  user_id uuid primary key references auth.users(id) on delete cascade,
  hero_name text not null,
  level integer not null default 1 check (level >= 1),
  xp integer not null default 0 check (xp >= 0),
  depth integer not null default 1 check (depth >= 1),
  kills integer not null default 0 check (kills >= 0),
  wins integer not null default 0 check (wins >= 0),
  battles_since_guardian integer not null default 0 check (battles_since_guardian between 0 and 3),
  hero_hp integer not null default 100 check (hero_hp >= 1),
  max_hp integer not null default 100 check (max_hp >= 1),
  attributes jsonb not null default '{"strength":5,"agility":5,"endurance":5,"intellect":5,"luck":3,"will":4}'::jsonb,
  stat_points integer not null default 0 check (stat_points >= 0),
  pvp_rating integer not null default 1000 check (pvp_rating >= 0),
  pvp_wins integer not null default 0 check (pvp_wins >= 0),
  pvp_losses integer not null default 0 check (pvp_losses >= 0),
  potions integer not null default 3 check (potions >= 0),
  gold integer not null default 250 check (gold >= 0),
  bag jsonb not null default '{"blade":1,"coat":1}'::jsonb,
  equipment jsonb not null default '{"weapon":"blade","armor":"coat","charm":null}'::jsonb,
  claimed_quests text[] not null default '{}',
  hunger integer not null default 100 check (hunger between 0 and 100),
  last_work_at timestamptz,
  exploration_index integer not null default 0 check (exploration_index between 0 and 5),
  run_gold integer not null default 0 check (run_gold >= 0),
  battle jsonb,
  updated_at timestamptz not null default now()
);

alter table public.ranked_progress
  add column if not exists bag jsonb not null default '{"blade":1,"coat":1}'::jsonb,
  add column if not exists equipment jsonb not null default '{"weapon":"blade","armor":"coat","charm":null}'::jsonb,
  add column if not exists claimed_quests text[] not null default '{}',
  add column if not exists hunger integer not null default 100 check (hunger between 0 and 100),
  add column if not exists last_work_at timestamptz,
  add column if not exists exploration_index integer not null default 0 check (exploration_index between 0 and 5),
  add column if not exists run_gold integer not null default 0 check (run_gold >= 0),
  add column if not exists max_hp integer not null default 100 check (max_hp >= 1),
  add column if not exists attributes jsonb not null default '{"strength":5,"agility":5,"endurance":5,"intellect":5,"luck":3,"will":4}'::jsonb,
  add column if not exists stat_points integer not null default 0 check (stat_points >= 0),
  add column if not exists pvp_rating integer not null default 1000 check (pvp_rating >= 0),
  add column if not exists pvp_wins integer not null default 0 check (pvp_wins >= 0),
  add column if not exists pvp_losses integer not null default 0 check (pvp_losses >= 0);
alter table public.ranked_progress drop constraint if exists ranked_progress_hero_hp_check;
alter table public.ranked_progress drop constraint if exists ranked_progress_hero_hp_max_check;
alter table public.ranked_progress add constraint ranked_progress_hero_hp_max_check check (hero_hp <= max_hp);

alter table public.ranked_progress enable row level security;
drop policy if exists "players read own ranked progress" on public.ranked_progress;
create policy "players read own ranked progress" on public.ranked_progress for select using (auth.uid() = user_id);
revoke insert, update, delete, truncate, references, trigger on public.ranked_progress from anon, authenticated;
grant select on public.ranked_progress to authenticated;

create or replace function public.ranked_profile_json(p public.ranked_progress)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'hero_name', p.hero_name,
    'level', p.level,
    'xp', p.xp,
    'depth', p.depth,
    'kills', p.kills,
    'wins', p.wins,
    'hero_hp', p.hero_hp,
    'max_hp', p.max_hp,
    'attributes', p.attributes,
    'stat_points', p.stat_points,
    'pvp_rating', p.pvp_rating,
    'pvp_wins', p.pvp_wins,
    'pvp_losses', p.pvp_losses,
    'potions', p.potions,
    'gold', p.gold,
    'battles_since_guardian', p.battles_since_guardian,
    'bag', p.bag,
    'equipment', p.equipment,
    'claimed', to_jsonb(p.claimed_quests),
    'hunger', p.hunger,
    'exploration_index', p.exploration_index,
    'run_gold', p.run_gold
  );
$$;

create or replace function public.ranked_start_profile(p_hero_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_profile public.ranked_progress;
begin
  if v_user_id is null then
    raise exception 'Sign in is required';
  end if;
  if p_hero_name is null or length(btrim(p_hero_name)) < 2 or length(btrim(p_hero_name)) > 20 then
    raise exception 'Hero name must be between 2 and 20 characters';
  end if;

  insert into public.ranked_progress (user_id, hero_name)
  values (v_user_id, btrim(p_hero_name))
  on conflict (user_id) do nothing;

  select * into strict v_profile
  from public.ranked_progress
  where user_id = v_user_id;

  return jsonb_build_object(
    'profile', public.ranked_profile_json(v_profile),
    'battle', v_profile.battle
  );
end;
$$;

create or replace function public.ranked_rest()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_profile public.ranked_progress;
begin
  if v_user_id is null then raise exception 'Sign in is required'; end if;
  select * into v_profile from public.ranked_progress where user_id = v_user_id for update;
  if not found then raise exception 'Create a ranked profile first'; end if;
  if v_profile.battle is not null then raise exception 'Finish the active battle first'; end if;
  if exists (select 1 from public.ranked_pvp_matches where (player_one = v_user_id or player_two = v_user_id) and status = 'active') then raise exception 'Finish the active PvP match first'; end if;
  if v_profile.gold < 20 then raise exception 'Not enough ranked gold'; end if;
  update public.ranked_progress
  set gold = gold - 20, hero_hp = max_hp, updated_at = now()
  where user_id = v_user_id returning * into v_profile;
  return public.ranked_profile_json(v_profile);
end;
$$;

create or replace function public.ranked_allocate_stat(p_stat text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_profile public.ranked_progress;
  v_stat_value integer;
begin
  if v_user_id is null then raise exception 'Sign in is required'; end if;
  if p_stat is null or p_stat not in ('strength', 'agility', 'endurance', 'intellect', 'luck', 'will') then
    raise exception 'Unknown character attribute';
  end if;
  select * into v_profile from public.ranked_progress where user_id = v_user_id for update;
  if not found then raise exception 'Create a ranked profile first'; end if;
  if v_profile.battle is not null then raise exception 'Finish the active battle first'; end if;
  if exists (select 1 from public.ranked_pvp_matches where (player_one = v_user_id or player_two = v_user_id) and status = 'active') then raise exception 'Finish the active PvP match first'; end if;
  if v_profile.stat_points < 1 then raise exception 'No character points available'; end if;
  v_stat_value := coalesce((v_profile.attributes->>p_stat)::integer, 0);
  if v_stat_value >= 100 then raise exception 'Attribute limit reached'; end if;

  v_profile.attributes := jsonb_set(v_profile.attributes, array[p_stat], to_jsonb(v_stat_value + 1), true);
  v_profile.stat_points := v_profile.stat_points - 1;
  if p_stat = 'endurance' then
    v_profile.max_hp := v_profile.max_hp + 8;
    v_profile.hero_hp := least(v_profile.max_hp, v_profile.hero_hp + 8);
  end if;

  update public.ranked_progress
  set attributes = v_profile.attributes,
      stat_points = v_profile.stat_points,
      max_hp = v_profile.max_hp,
      hero_hp = v_profile.hero_hp,
      updated_at = now()
  where user_id = v_user_id
  returning * into v_profile;
  return public.ranked_profile_json(v_profile);
end;
$$;

create table if not exists public.ranked_pvp_matches (
  id uuid primary key default gen_random_uuid(),
  player_one uuid not null references auth.users(id) on delete cascade,
  player_two uuid references auth.users(id) on delete cascade,
  player_one_name text not null,
  player_two_name text,
  status text not null default 'waiting' check (status in ('waiting', 'active', 'finished')),
  turn_player uuid references auth.users(id) on delete set null,
  winner uuid references auth.users(id) on delete set null,
  player_one_hp integer not null,
  player_two_hp integer,
  player_one_max_hp integer not null,
  player_two_max_hp integer,
  player_one_attack integer not null,
  player_two_attack integer,
  player_one_armor integer not null,
  player_two_armor integer,
  player_one_agility integer not null,
  player_two_agility integer,
  player_one_intellect integer not null,
  player_two_intellect integer,
  player_one_guard boolean not null default false,
  player_two_guard boolean not null default false,
  player_one_cooldown integer not null default 0,
  player_two_cooldown integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (player_one <> player_two),
  check (
    (status = 'waiting' and player_two is null and turn_player is null)
    or (status = 'active' and player_two is not null and turn_player is not null)
    or (status = 'finished' and player_two is not null and winner is not null and turn_player is null)
  )
);
create unique index if not exists ranked_pvp_waiting_player_idx
  on public.ranked_pvp_matches (player_one) where status = 'waiting';
create index if not exists ranked_pvp_player_status_idx
  on public.ranked_pvp_matches (player_one, player_two, status);
alter table public.ranked_pvp_matches enable row level security;
revoke all on public.ranked_pvp_matches from public, anon, authenticated;

create or replace function public.ranked_pvp_match_json(p_match public.ranked_pvp_matches, p_user_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_match.id,
    'status', p_match.status,
    'opponent_name', case when p_user_id = p_match.player_one then p_match.player_two_name else p_match.player_one_name end,
    'your_turn', p_match.turn_player = p_user_id,
    'your_hp', case when p_user_id = p_match.player_one then p_match.player_one_hp else p_match.player_two_hp end,
    'your_max_hp', case when p_user_id = p_match.player_one then p_match.player_one_max_hp else p_match.player_two_max_hp end,
    'opponent_hp', case when p_user_id = p_match.player_one then p_match.player_two_hp else p_match.player_one_hp end,
    'opponent_max_hp', case when p_user_id = p_match.player_one then p_match.player_two_max_hp else p_match.player_one_max_hp end,
    'winner', case when p_match.winner = p_user_id then 'you' when p_match.winner is not null then 'opponent' else null end
  );
$$;

create or replace function public.ranked_pvp_find_match()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_profile public.ranked_progress;
  v_opponent public.ranked_progress;
  v_match public.ranked_pvp_matches;
begin
  if v_user_id is null then raise exception 'Sign in is required'; end if;
  perform pg_advisory_xact_lock(918273645);
  select * into v_profile from public.ranked_progress where user_id = v_user_id for update;
  if not found then raise exception 'Create a ranked profile first'; end if;
  if v_profile.battle is not null or v_profile.exploration_index <> 0 or v_profile.run_gold <> 0 then
    raise exception 'Return to town and finish the active battle before PvP';
  end if;
  select * into v_match from public.ranked_pvp_matches
  where (player_one = v_user_id or player_two = v_user_id) and status in ('waiting', 'active')
  order by created_at desc limit 1 for update;
  if found then return jsonb_build_object('match', public.ranked_pvp_match_json(v_match, v_user_id)); end if;

  select * into v_match from public.ranked_pvp_matches
  where status = 'waiting' and player_one <> v_user_id
    and exists (
      select 1 from public.ranked_progress candidate
      where candidate.user_id = player_one and candidate.battle is null
        and candidate.exploration_index = 0 and candidate.run_gold = 0
    )
  order by created_at limit 1 for update skip locked;
  if found then
    select * into strict v_opponent from public.ranked_progress where user_id = v_match.player_one;
    v_match.player_two := v_user_id;
    v_match.player_two_name := v_profile.hero_name;
    v_match.status := 'active';
    v_match.turn_player := case when random() < 0.5 then v_match.player_one else v_user_id end;
    v_match.player_one_hp := v_opponent.hero_hp;
    v_match.player_two_hp := v_profile.hero_hp;
    v_match.player_one_max_hp := v_opponent.max_hp;
    v_match.player_two_max_hp := v_profile.max_hp;
    v_match.player_one_attack := 6 + coalesce((v_opponent.attributes->>'strength')::integer, 5) * 2
      + case when v_opponent.equipment->>'weapon' = 'blade' then 4 when v_opponent.equipment->>'weapon' = 'saber' then 8 when v_opponent.equipment->>'weapon' = 'sword' then 14 else 0 end
      + case when v_opponent.equipment->>'charm' = 'charm' then 3 else 0 end;
    v_match.player_two_attack := 6 + coalesce((v_profile.attributes->>'strength')::integer, 5) * 2
      + case when v_profile.equipment->>'weapon' = 'blade' then 4 when v_profile.equipment->>'weapon' = 'saber' then 8 when v_profile.equipment->>'weapon' = 'sword' then 14 else 0 end
      + case when v_profile.equipment->>'charm' = 'charm' then 3 else 0 end;
    v_match.player_one_armor := case when v_opponent.equipment->>'armor' = 'coat' then 2 when v_opponent.equipment->>'armor' = 'armor' then 7 when v_opponent.equipment->>'armor' = 'plate' then 13 else 0 end + case when v_opponent.equipment->>'charm' = 'charm' then 2 else 0 end;
    v_match.player_two_armor := case when v_profile.equipment->>'armor' = 'coat' then 2 when v_profile.equipment->>'armor' = 'armor' then 7 when v_profile.equipment->>'armor' = 'plate' then 13 else 0 end + case when v_profile.equipment->>'charm' = 'charm' then 2 else 0 end;
    v_match.player_one_agility := coalesce((v_opponent.attributes->>'agility')::integer, 5);
    v_match.player_two_agility := coalesce((v_profile.attributes->>'agility')::integer, 5);
    v_match.player_one_intellect := coalesce((v_opponent.attributes->>'intellect')::integer, 5);
    v_match.player_two_intellect := coalesce((v_profile.attributes->>'intellect')::integer, 5);
    v_match.player_one_attack := 6 + coalesce((v_opponent.attributes->>'strength')::integer, 5) * 2
      + case when v_opponent.equipment->>'weapon' = 'blade' then 4 when v_opponent.equipment->>'weapon' = 'saber' then 8 when v_opponent.equipment->>'weapon' = 'sword' then 14 else 0 end
      + case when v_opponent.equipment->>'charm' = 'charm' then 3 else 0 end;
    v_match.player_one_armor := case when v_opponent.equipment->>'armor' = 'coat' then 2 when v_opponent.equipment->>'armor' = 'armor' then 7 when v_opponent.equipment->>'armor' = 'plate' then 13 else 0 end + case when v_opponent.equipment->>'charm' = 'charm' then 2 else 0 end;
    update public.ranked_pvp_matches set
      player_two = v_match.player_two, player_two_name = v_match.player_two_name, status = v_match.status,
      turn_player = v_match.turn_player, player_one_hp = v_match.player_one_hp, player_two_hp = v_match.player_two_hp,
      player_one_max_hp = v_match.player_one_max_hp, player_two_max_hp = v_match.player_two_max_hp,
      player_one_attack = v_match.player_one_attack, player_two_attack = v_match.player_two_attack,
      player_one_armor = v_match.player_one_armor, player_two_armor = v_match.player_two_armor,
      player_one_agility = v_match.player_one_agility, player_two_agility = v_match.player_two_agility,
      player_one_intellect = v_match.player_one_intellect, player_two_intellect = v_match.player_two_intellect,
      updated_at = now()
    where id = v_match.id returning * into v_match;
  else
    insert into public.ranked_pvp_matches (player_one, player_one_name, player_one_hp, player_one_max_hp, player_one_attack, player_one_armor, player_one_agility, player_one_intellect)
    values (
      v_user_id, v_profile.hero_name, v_profile.hero_hp, v_profile.max_hp,
      6 + coalesce((v_profile.attributes->>'strength')::integer, 5) * 2
        + case when v_profile.equipment->>'weapon' = 'blade' then 4 when v_profile.equipment->>'weapon' = 'saber' then 8 when v_profile.equipment->>'weapon' = 'sword' then 14 else 0 end
        + case when v_profile.equipment->>'charm' = 'charm' then 3 else 0 end,
      case when v_profile.equipment->>'armor' = 'coat' then 2 when v_profile.equipment->>'armor' = 'armor' then 7 when v_profile.equipment->>'armor' = 'plate' then 13 else 0 end + case when v_profile.equipment->>'charm' = 'charm' then 2 else 0 end,
      coalesce((v_profile.attributes->>'agility')::integer, 5),
      coalesce((v_profile.attributes->>'intellect')::integer, 5)
    ) returning * into v_match;
  end if;
  return jsonb_build_object('match', public.ranked_pvp_match_json(v_match, v_user_id));
end;
$$;

create or replace function public.ranked_pvp_current()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_match public.ranked_pvp_matches;
begin
  if v_user_id is null then raise exception 'Sign in is required'; end if;
  select * into v_match from public.ranked_pvp_matches
  where player_one = v_user_id or player_two = v_user_id
  order by created_at desc limit 1;
  if not found then return jsonb_build_object('match', null); end if;
  return jsonb_build_object('match', public.ranked_pvp_match_json(v_match, v_user_id));
end;
$$;

create or replace function public.ranked_pvp_cancel_search()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_match_id uuid;
begin
  if v_user_id is null then raise exception 'Sign in is required'; end if;
  perform pg_advisory_xact_lock(918273645);
  delete from public.ranked_pvp_matches
  where player_one = v_user_id and status = 'waiting'
  returning id into v_match_id;
  if v_match_id is null then raise exception 'There is no waiting PvP search to cancel'; end if;
  return jsonb_build_object('match', null, 'cancelled', true);
end;
$$;

create or replace function public.ranked_pvp_action(p_match_id uuid, p_action text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_match public.ranked_pvp_matches;
  v_profile public.ranked_progress;
  v_is_one boolean;
  v_my_hp integer;
  v_enemy_hp integer;
  v_my_max integer;
  v_enemy_max integer;
  v_my_attack integer;
  v_enemy_armor integer;
  v_my_agility integer;
  v_enemy_agility integer;
  v_my_intellect integer;
  v_my_guard boolean;
  v_enemy_guard boolean;
  v_my_cooldown integer;
  v_damage integer := 0;
  v_winner uuid;
begin
  if v_user_id is null then raise exception 'Sign in is required'; end if;
  if p_action is null or p_action not in ('attack', 'defend', 'special', 'potion', 'surrender') then raise exception 'Unknown PvP action'; end if;
  perform pg_advisory_xact_lock(918273645);
  select * into v_match from public.ranked_pvp_matches where id = p_match_id for update;
  if not found or (v_match.player_one <> v_user_id and v_match.player_two <> v_user_id) then raise exception 'PvP match not found'; end if;
  if v_match.status <> 'active' then raise exception 'This PvP match is not active'; end if;
  if v_match.turn_player <> v_user_id then raise exception 'Wait for your turn'; end if;
  v_is_one := v_match.player_one = v_user_id;
  v_my_hp := case when v_is_one then v_match.player_one_hp else v_match.player_two_hp end;
  v_enemy_hp := case when v_is_one then v_match.player_two_hp else v_match.player_one_hp end;
  v_my_max := case when v_is_one then v_match.player_one_max_hp else v_match.player_two_max_hp end;
  v_enemy_max := case when v_is_one then v_match.player_two_max_hp else v_match.player_one_max_hp end;
  v_my_attack := case when v_is_one then v_match.player_one_attack else v_match.player_two_attack end;
  v_enemy_armor := case when v_is_one then v_match.player_two_armor else v_match.player_one_armor end;
  v_my_agility := case when v_is_one then v_match.player_one_agility else v_match.player_two_agility end;
  v_enemy_agility := case when v_is_one then v_match.player_two_agility else v_match.player_one_agility end;
  v_my_intellect := case when v_is_one then v_match.player_one_intellect else v_match.player_two_intellect end;
  v_my_guard := case when v_is_one then v_match.player_one_guard else v_match.player_two_guard end;
  v_enemy_guard := case when v_is_one then v_match.player_two_guard else v_match.player_one_guard end;
  v_my_cooldown := case when v_is_one then v_match.player_one_cooldown else v_match.player_two_cooldown end;

  if p_action = 'surrender' then
    v_winner := case when v_is_one then v_match.player_two else v_match.player_one end;
  else
    if p_action = 'potion' then
      select * into v_profile from public.ranked_progress where user_id = v_user_id for update;
      if v_profile.potions < 1 then raise exception 'No healing potions'; end if;
      if v_my_hp >= v_my_max then raise exception 'Health is already full'; end if;
      v_profile.potions := v_profile.potions - 1;
      v_my_hp := least(v_my_max, v_my_hp + 35);
      update public.ranked_progress set potions = v_profile.potions, updated_at = now() where user_id = v_user_id;
    elsif p_action = 'defend' then
      v_my_guard := true;
    else
      if p_action = 'special' and v_my_cooldown > 0 then raise exception 'Special attack is recharging'; end if;
      if random() <= greatest(0.55, least(0.95, 0.75 + (v_my_agility - v_enemy_agility) * 0.02)) then
        v_damage := greatest(1, v_my_attack + floor(random() * 7)::integer
          + case when p_action = 'special' then v_my_intellect * 2 else 0 end
          - floor(v_enemy_armor * 0.45)::integer);
        if v_enemy_guard then v_damage := greatest(1, floor(v_damage * 0.55)::integer); end if;
        v_enemy_hp := greatest(0, v_enemy_hp - v_damage);
      end if;
      if p_action = 'special' then v_my_cooldown := 2; elsif v_my_cooldown > 0 then v_my_cooldown := v_my_cooldown - 1; end if;
      v_enemy_guard := false;
    end if;
    if v_enemy_hp <= 0 then v_winner := v_user_id; end if;
  end if;

  if v_winner is not null then
    update public.ranked_pvp_matches set
      player_one_hp = case when v_is_one then v_my_hp else v_enemy_hp end,
      player_two_hp = case when v_is_one then v_enemy_hp else v_my_hp end,
      status = 'finished', winner = v_winner, turn_player = null, updated_at = now()
    where id = v_match.id returning * into v_match;
    update public.ranked_progress set pvp_wins = pvp_wins + 1, pvp_rating = pvp_rating + 25, updated_at = now() where user_id = v_winner;
    update public.ranked_progress set pvp_losses = pvp_losses + 1, pvp_rating = greatest(0, pvp_rating - 20), updated_at = now() where user_id = case when v_winner = v_match.player_one then v_match.player_two else v_match.player_one end;
  else
    update public.ranked_pvp_matches set
      player_one_hp = case when v_is_one then v_my_hp else v_enemy_hp end,
      player_two_hp = case when v_is_one then v_enemy_hp else v_my_hp end,
      player_one_guard = case when v_is_one then v_my_guard else v_enemy_guard end,
      player_two_guard = case when v_is_one then v_enemy_guard else v_my_guard end,
      player_one_cooldown = case when v_is_one then v_my_cooldown else player_one_cooldown end,
      player_two_cooldown = case when v_is_one then player_two_cooldown else v_my_cooldown end,
      turn_player = case when v_is_one then v_match.player_two else v_match.player_one end,
      updated_at = now()
    where id = v_match.id returning * into v_match;
  end if;
  select * into v_profile from public.ranked_progress where user_id = v_user_id;
  return jsonb_build_object(
    'match', public.ranked_pvp_match_json(v_match, v_user_id),
    'profile', public.ranked_profile_json(v_profile),
    'message', case when v_winner = v_user_id then 'Победа! Рейтинг повышен.' when v_winner is not null then 'Поражение. Матч завершён.' when p_action = 'surrender' then 'Вы сдались.' else 'Ход отправлен.' end
  );
end;
$$;

create or replace function public.ranked_start_battle()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_profile public.ranked_progress;
  v_guardian boolean;
  v_enemy_name text;
  v_icon text;
  v_max_hp integer;
  v_attack integer;
begin
  if v_user_id is null then raise exception 'Sign in is required'; end if;
  select * into v_profile from public.ranked_progress where user_id = v_user_id for update;
  if not found then raise exception 'Create a ranked profile first'; end if;
  if v_profile.battle is not null then
    return jsonb_build_object(
      'battle', v_profile.battle,
      'hero_hp', v_profile.hero_hp,
      'profile', public.ranked_profile_json(v_profile)
    );
  end if;
  if exists (select 1 from public.ranked_pvp_matches where (player_one = v_user_id or player_two = v_user_id) and status = 'active') then raise exception 'Finish the active PvP match first'; end if;
  if v_profile.hunger < 4 then raise exception 'Not enough hunger to enter the dungeon'; end if;
  v_profile.hunger := v_profile.hunger - 4;

  v_guardian := v_profile.battles_since_guardian >= 3;
  if v_guardian then
    v_enemy_name := 'Хранитель прохода';
    v_icon := '👹';
    v_max_hp := 65 + v_profile.depth * 23 + floor(random() * 9)::integer;
    v_attack := 8 + v_profile.depth * 3 + floor(random() * 4)::integer;
  else
    case floor(random() * 4)::integer
      when 0 then v_enemy_name := 'Пещерный зверь'; v_icon := '🐺';
      when 1 then v_enemy_name := 'Костяной дозорный'; v_icon := '💀';
      when 2 then v_enemy_name := 'Голодный ползун'; v_icon := '🕷';
      else v_enemy_name := 'Крысолов'; v_icon := '🐀';
    end case;
    v_max_hp := 32 + v_profile.depth * 12 + floor(random() * 9)::integer;
    v_attack := 5 + v_profile.depth * 2 + floor(random() * 4)::integer;
  end if;

  update public.ranked_progress
  set battle = jsonb_build_object(
        'name', v_enemy_name,
        'icon', v_icon,
        'guardian', v_guardian,
        'hp', v_max_hp,
        'maxHp', v_max_hp,
        'attack', v_attack,
        'skillCooldown', 0
      ),
      hunger = v_profile.hunger,
      updated_at = now()
  where user_id = v_user_id
  returning * into v_profile;

  return jsonb_build_object(
    'battle', v_profile.battle,
    'hero_hp', v_profile.hero_hp,
    'profile', public.ranked_profile_json(v_profile)
  );
end;
$$;

create or replace function public.ranked_battle_action(p_action text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_profile public.ranked_progress;
  v_battle jsonb;
  v_guardian boolean;
  v_hero_hp integer;
  v_enemy_hp integer;
  v_damage integer;
  v_defended boolean := false;
  v_hit boolean;
  v_message text;
  v_outcome text := 'turn';
  v_reward_xp integer;
  v_reward_gold integer;
  v_enemy_name text;
  v_weapon_attack integer;
  v_armor_value integer;
  v_strength integer;
  v_agility integer;
  v_endurance integer;
  v_intellect integer;
  v_dodge_chance numeric;
begin
  if v_user_id is null then raise exception 'Sign in is required'; end if;
  if p_action not in ('attack', 'defend', 'skill', 'potion', 'flee') then
    raise exception 'Invalid battle action';
  end if;

  select * into v_profile from public.ranked_progress where user_id = v_user_id for update;
  if not found or v_profile.battle is null then raise exception 'No active battle'; end if;
  v_battle := v_profile.battle;
  v_guardian := (v_battle->>'guardian')::boolean;
  v_hero_hp := v_profile.hero_hp;
  v_enemy_hp := (v_battle->>'hp')::integer;
  v_enemy_name := v_battle->>'name';
  v_strength := coalesce((v_profile.attributes->>'strength')::integer, 5);
  v_agility := coalesce((v_profile.attributes->>'agility')::integer, 5);
  v_endurance := coalesce((v_profile.attributes->>'endurance')::integer, 5);
  v_intellect := coalesce((v_profile.attributes->>'intellect')::integer, 5);
  v_dodge_chance := least(0.35, 0.06 + v_agility * 0.012);
  v_weapon_attack := case v_profile.equipment->>'weapon'
    when 'blade' then 4 when 'saber' then 8 when 'sword' then 14 else 0 end
    + case when v_profile.equipment->>'charm' = 'charm' then 3 else 0 end;
  v_armor_value := case v_profile.equipment->>'armor'
    when 'coat' then 2 when 'armor' then 7 when 'plate' then 13 else 0 end
    + case when v_profile.equipment->>'charm' = 'charm' then 2 else 0 end;

  if p_action = 'flee' then
    if v_guardian then raise exception 'Cannot flee from a guardian'; end if;
    if random() < 0.65 then
      update public.ranked_progress set battle = null, updated_at = now()
      where user_id = v_user_id returning * into v_profile;
      return jsonb_build_object('outcome', 'fled', 'message', 'Вы скрылись от преследования.', 'profile', public.ranked_profile_json(v_profile));
    end if;
    v_message := 'Побег не удался.';
  elsif p_action = 'attack' then
    v_hit := random() < least(0.95, 0.78 + v_agility * 0.012);
    if v_hit then
      v_damage := 13 + floor(random() * 14)::integer + v_weapon_attack + greatest(0, v_strength - 5) * 2;
      v_enemy_hp := greatest(0, v_enemy_hp - v_damage);
      v_message := 'Удар: ' || v_damage || ' урона.';
    else
      v_message := 'Вы промахнулись.';
    end if;
  elsif p_action = 'skill' then
    if (v_battle->>'skillCooldown')::integer > 0 then raise exception 'Skill is on cooldown'; end if;
    v_damage := 26 + floor(random() * 7)::integer + v_weapon_attack
      + greatest(0, v_intellect - 5) * 2 + greatest(0, v_agility - 5);
    v_enemy_hp := greatest(0, v_enemy_hp - v_damage);
    v_battle := jsonb_set(v_battle, '{skillCooldown}', '3'::jsonb);
    v_message := 'Точный удар наносит ' || v_damage || ' урона.';
  elsif p_action = 'potion' then
    if v_profile.potions <= 0 or v_hero_hp >= v_profile.max_hp then raise exception 'No usable potion'; end if;
    v_damage := least(35, v_profile.max_hp - v_hero_hp);
    v_hero_hp := v_hero_hp + v_damage;
    v_profile.potions := v_profile.potions - 1;
    v_message := 'Зелье восстановило ' || v_damage || ' HP.';
  else
    v_defended := true;
    v_message := 'Вы подняли щит.';
  end if;

  if v_enemy_hp = 0 then
    v_reward_xp := case when v_guardian then 70 else 28 end + v_profile.depth * 12;
    v_reward_gold := 18 + v_profile.depth * 8 + floor(random() * 16)::integer;
    v_profile.xp := v_profile.xp + v_reward_xp;
    while v_profile.xp >= v_profile.level * 100 loop
      v_profile.xp := v_profile.xp - v_profile.level * 100;
      v_profile.level := v_profile.level + 1;
      v_profile.stat_points := v_profile.stat_points + 2;
      v_profile.hero_hp := least(v_profile.max_hp, v_profile.hero_hp + 15);
    end loop;
    v_profile.kills := v_profile.kills + 1;
    v_profile.gold := v_profile.gold + v_reward_gold;
    if v_guardian then
      v_profile.wins := v_profile.wins + 1;
      v_profile.depth := v_profile.depth + 1;
      v_profile.battles_since_guardian := 0;
    else
      v_profile.battles_since_guardian := v_profile.battles_since_guardian + 1;
    end if;
    v_profile.hero_hp := greatest(1, v_hero_hp);
    v_profile.potions := least(3, v_profile.potions + 1);
    v_profile.battle := null;
    update public.ranked_progress set
      level = v_profile.level, xp = v_profile.xp, depth = v_profile.depth,
      kills = v_profile.kills, wins = v_profile.wins,
      gold = v_profile.gold,
      battles_since_guardian = v_profile.battles_since_guardian,
      hero_hp = v_profile.hero_hp, potions = v_profile.potions,
      stat_points = v_profile.stat_points,
      battle = null, updated_at = now()
    where user_id = v_user_id returning * into v_profile;
    return jsonb_build_object('outcome', 'victory', 'message', v_message || ' Победа! +' || v_reward_xp || ' опыта и ' || v_reward_gold || ' золота.', 'profile', public.ranked_profile_json(v_profile));
  end if;

  v_battle := jsonb_set(v_battle, '{hp}', to_jsonb(v_enemy_hp));
  if (v_battle->>'skillCooldown')::integer > 0 then
    v_battle := jsonb_set(v_battle, '{skillCooldown}', to_jsonb(greatest(0, (v_battle->>'skillCooldown')::integer - 1)));
  end if;

  if random() >= v_dodge_chance then
    v_damage := greatest(1, (v_battle->>'attack')::integer + floor(random() * 6)::integer - 2 - 1
      - floor((v_armor_value + greatest(0, v_endurance - 5)) * 0.5)::integer);
    if v_defended then v_damage := greatest(1, floor(v_damage * 0.4)::integer); end if;
    v_hero_hp := greatest(0, v_hero_hp - v_damage);
    v_message := v_message || ' ' || v_enemy_name || ' наносит ' || v_damage || ' урона.';
  else
    v_message := v_message || ' Вы уклонились от удара.';
  end if;

  if v_hero_hp = 0 then
    v_outcome := 'defeat';
    v_message := v_message || ' Вы потерпели поражение.';
    v_hero_hp := 1;
    v_profile.battles_since_guardian := 0;
    v_profile.potions := least(3, v_profile.potions + 1);
    v_profile.run_gold := 0;
    v_profile.hero_hp := 1;
    v_profile.battle := null;
  else
    v_profile.battle := v_battle;
  end if;
  v_profile.hero_hp := v_hero_hp;
  update public.ranked_progress set
    hero_hp = v_profile.hero_hp, potions = v_profile.potions,
    battles_since_guardian = v_profile.battles_since_guardian,
    run_gold = v_profile.run_gold,
    battle = v_profile.battle, updated_at = now()
  where user_id = v_user_id returning * into v_profile;
  return jsonb_build_object(
    'outcome', v_outcome,
    'message', v_message,
    'battle', v_profile.battle,
    'hero_hp', v_profile.hero_hp,
    'profile', public.ranked_profile_json(v_profile)
  );
end;
$$;

create or replace function public.ranked_economy_action(
  p_action text,
  p_item text default null,
  p_quest text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_profile public.ranked_progress;
  v_price integer;
  v_value integer;
  v_slot text;
  v_count integer;
  v_reward integer;
  v_requirement boolean;
  v_quest_id text;
begin
  if v_user_id is null then raise exception 'Sign in is required'; end if;
  if p_action not in ('buy_item', 'sell_item', 'equip_item', 'buy_potion', 'eat', 'work', 'claim_quest') then
    raise exception 'Invalid economy action';
  end if;
  select * into v_profile
  from public.ranked_progress
  where user_id = v_user_id
  for update;
  if not found then raise exception 'Create a ranked profile first'; end if;
  if v_profile.battle is not null then raise exception 'Finish the active battle first'; end if;
  if exists (select 1 from public.ranked_pvp_matches where (player_one = v_user_id or player_two = v_user_id) and status = 'active') then raise exception 'Finish the active PvP match first'; end if;

  if p_action = 'buy_item' then
    v_price := case p_item when 'saber' then 85 when 'armor' then 95 when 'sword' then 190 when 'plate' then 225 when 'charm' then 140 else null end;
    if v_price is null then raise exception 'This item cannot be purchased'; end if;
    if v_profile.gold < v_price then raise exception 'Not enough ranked gold'; end if;
    v_profile.gold := v_profile.gold - v_price;
    v_profile.bag := jsonb_set(v_profile.bag, array[p_item], to_jsonb(coalesce((v_profile.bag->>p_item)::integer, 0) + 1), true);
  elsif p_action = 'sell_item' then
    v_value := case p_item when 'blade' then 8 when 'coat' then 8 when 'saber' then 85 when 'sword' then 190 when 'armor' then 95 when 'plate' then 225 when 'charm' then 140 else null end;
    if v_value is null then raise exception 'This item cannot be sold'; end if;
    v_count := coalesce((v_profile.bag->>p_item)::integer, 0);
    if v_count < 1 then raise exception 'Item is not in inventory'; end if;
    if v_profile.equipment->>'weapon' = p_item or v_profile.equipment->>'armor' = p_item or v_profile.equipment->>'charm' = p_item then
      if v_count <= 1 then raise exception 'Unequip the item before selling it'; end if;
    end if;
    v_profile.bag := jsonb_set(v_profile.bag, array[p_item], to_jsonb(v_count - 1), true);
    v_profile.gold := v_profile.gold + v_value;
  elsif p_action = 'equip_item' then
    v_slot := case
      when p_item in ('blade', 'saber', 'sword') then 'weapon'
      when p_item in ('coat', 'armor', 'plate') then 'armor'
      when p_item = 'charm' then 'charm'
      else null
    end;
    if v_slot is null then raise exception 'This item cannot be equipped'; end if;
    if coalesce((v_profile.bag->>p_item)::integer, 0) < 1 then raise exception 'Item is not in inventory'; end if;
    v_profile.equipment := jsonb_set(v_profile.equipment, array[v_slot], to_jsonb(p_item), true);
  elsif p_action = 'buy_potion' then
    if v_profile.potions >= 3 then raise exception 'Potion capacity reached'; end if;
    if v_profile.gold < 35 then raise exception 'Not enough ranked gold'; end if;
    v_profile.gold := v_profile.gold - 35;
    v_profile.potions := v_profile.potions + 1;
  elsif p_action = 'eat' then
    if v_profile.hunger >= 100 then raise exception 'You are not hungry'; end if;
    if v_profile.gold < 15 then raise exception 'Not enough ranked gold'; end if;
    v_profile.gold := v_profile.gold - 15;
    v_profile.hunger := least(100, v_profile.hunger + 45);
  elsif p_action = 'work' then
    if v_profile.hunger < 8 then raise exception 'Not enough hunger to work'; end if;
    if v_profile.last_work_at is not null and v_profile.last_work_at > now() - interval '30 minutes' then
      raise exception 'Work is available again after 30 minutes';
    end if;
    v_profile.gold := v_profile.gold + 18;
    v_profile.hunger := v_profile.hunger - 8;
    v_profile.last_work_at := now();
  elsif p_action = 'claim_quest' then
    v_quest_id := p_quest;
    v_reward := case v_quest_id when 'first' then 45 when 'hunter' then 120 when 'guardian' then 160 when 'veteran' then 220 else null end;
    if v_reward is null then raise exception 'Unknown quest'; end if;
    if v_quest_id = any(v_profile.claimed_quests) then raise exception 'Quest reward already claimed'; end if;
    v_requirement := case v_quest_id
      when 'first' then v_profile.kills >= 1
      when 'hunter' then v_profile.kills >= 5
      when 'guardian' then v_profile.depth >= 2
      when 'veteran' then v_profile.level >= 5
      else false end;
    if not v_requirement then raise exception 'Quest is not complete'; end if;
    v_profile.gold := v_profile.gold + v_reward;
    v_profile.claimed_quests := array_append(v_profile.claimed_quests, v_quest_id);
  end if;

  update public.ranked_progress
  set gold = v_profile.gold,
      bag = v_profile.bag,
      equipment = v_profile.equipment,
      claimed_quests = v_profile.claimed_quests,
      potions = v_profile.potions,
      hunger = v_profile.hunger,
      last_work_at = v_profile.last_work_at,
      updated_at = now()
  where user_id = v_user_id
  returning * into v_profile;
  return jsonb_build_object('profile', public.ranked_profile_json(v_profile));
end;
$$;

create or replace function public.ranked_explore_action(p_choice integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_profile public.ranked_progress;
  v_next_event integer;
  v_action text;
  v_message text;
  v_reward integer := 0;
  v_xp integer := 0;
  v_damage integer := 0;
  v_heal integer := 0;
  v_item text;
  v_battle jsonb;
  v_old_hp integer;
  v_guardian boolean;
  v_enemy_name text;
  v_icon text;
  v_max_hp integer;
  v_attack integer;
  v_outcome text := 'event';
begin
  if v_user_id is null then raise exception 'Sign in is required'; end if;
  if p_choice is null or p_choice not in (-1, 0, 1) then raise exception 'Invalid exploration choice'; end if;
  select * into v_profile
  from public.ranked_progress
  where user_id = v_user_id
  for update;
  if not found then raise exception 'Create a ranked profile first'; end if;
  if v_profile.battle is not null then raise exception 'Finish the active battle first'; end if;
  if exists (select 1 from public.ranked_pvp_matches where (player_one = v_user_id or player_two = v_user_id) and status = 'active') then raise exception 'Finish the active PvP match first'; end if;

  if p_choice = -1 then
    v_profile.gold := v_profile.gold + v_profile.run_gold;
    v_profile.run_gold := 0;
    update public.ranked_progress
    set gold = v_profile.gold, run_gold = 0, updated_at = now()
    where user_id = v_user_id returning * into v_profile;
    return jsonb_build_object(
      'outcome', 'left',
      'message', 'Поход завершён. Добыча доставлена в город.',
      'profile', public.ranked_profile_json(v_profile)
    );
  end if;
  if v_profile.hunger < 4 then raise exception 'Not enough hunger to explore'; end if;

  v_next_event := (v_profile.exploration_index + 1) % 6;
  case v_profile.exploration_index
    when 0 then v_action := case p_choice when 0 then 'fight' else 'loot' end;
    when 1 then v_action := case p_choice when 0 then 'treasure' else 'fight' end;
    when 2 then v_action := case p_choice when 0 then 'trap' else 'loot' end;
    when 3 then v_action := case p_choice when 0 then 'spring' else 'treasure' end;
    when 4 then v_action := case p_choice when 0 then 'loot' else 'fight' end;
    when 5 then v_action := case p_choice when 0 then 'runes' else 'fight' end;
    else raise exception 'Invalid exploration state';
  end case;

  v_profile.hunger := v_profile.hunger - 4;
  v_profile.exploration_index := v_next_event;
  if v_action = 'fight' then
    v_guardian := v_profile.battles_since_guardian >= 3;
    if v_guardian then
      v_enemy_name := 'Хранитель прохода';
      v_icon := '👹';
      v_max_hp := 65 + v_profile.depth * 23 + floor(random() * 9)::integer;
      v_attack := 8 + v_profile.depth * 3 + floor(random() * 4)::integer;
    else
      case floor(random() * 4)::integer
        when 0 then v_enemy_name := 'Пещерный зверь'; v_icon := '🐺';
        when 1 then v_enemy_name := 'Костяной дозорный'; v_icon := '💀';
        when 2 then v_enemy_name := 'Голодный ползун'; v_icon := '🕷';
        else v_enemy_name := 'Крысолов'; v_icon := '🐀';
      end case;
      v_max_hp := 32 + v_profile.depth * 12 + floor(random() * 9)::integer;
      v_attack := 5 + v_profile.depth * 2 + floor(random() * 4)::integer;
    end if;
    v_battle := jsonb_build_object(
      'name', v_enemy_name,
      'icon', v_icon,
      'guardian', v_guardian,
      'hp', v_max_hp,
      'maxHp', v_max_hp,
      'attack', v_attack,
      'skillCooldown', 0
    );
    v_profile.battle := v_battle;
    v_message := v_enemy_name || ' преграждает путь. Бой рассчитывается сервером.';
    v_outcome := 'battle';
  elsif v_action = 'loot' then
    v_reward := 18 + floor(random() * 19)::integer + v_profile.depth * 5;
    v_profile.run_gold := v_profile.run_gold + v_reward;
    v_profile.xp := v_profile.xp + 12;
    v_message := 'Вы нашли ' || v_reward || ' золота. Оно в походной сумке. +12 опыта.';
  elsif v_action = 'treasure' then
    v_reward := 28 + floor(random() * 28)::integer + v_profile.depth * 5;
    v_profile.run_gold := v_profile.run_gold + v_reward;
    v_profile.xp := v_profile.xp + 16;
    if random() < 0.33 then
      v_item := 'saber';
      v_profile.bag := jsonb_set(v_profile.bag, '{saber}', to_jsonb(coalesce((v_profile.bag->>'saber')::integer, 0) + 1), true);
      v_message := 'В сундуке: ' || v_reward || ' золота и Шахтёрская сабля. +16 опыта.';
    else
      v_message := 'В сундуке лежит ' || v_reward || ' золота. +16 опыта.';
    end if;
  elsif v_action = 'trap' then
    v_damage := 8 + floor(random() * 9)::integer + v_profile.depth * 2;
    v_old_hp := v_profile.hero_hp;
    v_profile.hero_hp := greatest(1, v_old_hp - v_damage);
    if v_damage >= v_old_hp then
      v_outcome := 'defeat';
      v_profile.run_gold := 0;
      v_profile.battles_since_guardian := 0;
      v_message := 'Ловушка нанесла ' || v_damage || ' урона. Вы потерпели поражение; походная добыча потеряна.';
    else
      v_message := 'Ловушка нанесла ' || v_damage || ' урона.';
    end if;
  elsif v_action = 'spring' then
    v_heal := least(24, v_profile.max_hp - v_profile.hero_hp);
    v_profile.hero_hp := v_profile.hero_hp + v_heal;
    v_profile.xp := v_profile.xp + 10;
    v_message := 'Источник восстановил ' || v_heal || ' HP. +10 опыта.';
  elsif v_action = 'runes' then
    v_profile.xp := v_profile.xp + 22;
    v_message := 'Вы прочли руны: лестницу вниз охраняет хранитель. +22 опыта.';
  end if;

  while v_profile.xp >= v_profile.level * 100 loop
    v_profile.xp := v_profile.xp - v_profile.level * 100;
    v_profile.level := v_profile.level + 1;
    v_profile.stat_points := v_profile.stat_points + 2;
    v_profile.hero_hp := least(v_profile.max_hp, v_profile.hero_hp + 15);
  end loop;

  update public.ranked_progress
  set level = v_profile.level,
      xp = v_profile.xp,
      stat_points = v_profile.stat_points,
      hero_hp = v_profile.hero_hp,
      bag = v_profile.bag,
      hunger = v_profile.hunger,
      exploration_index = v_profile.exploration_index,
      run_gold = v_profile.run_gold,
      battles_since_guardian = v_profile.battles_since_guardian,
      battle = v_profile.battle,
      updated_at = now()
  where user_id = v_user_id
  returning * into v_profile;

  return jsonb_build_object(
    'outcome', v_outcome,
    'message', v_message,
    'battle', v_profile.battle,
    'profile', public.ranked_profile_json(v_profile)
  );
end;
$$;

revoke all on function public.ranked_explore_action(integer) from public, anon, authenticated;
grant execute on function public.ranked_explore_action(integer) to authenticated;

revoke all on function public.ranked_economy_action(text, text, text) from public, anon, authenticated;
grant execute on function public.ranked_economy_action(text, text, text) to authenticated;

revoke all on function public.ranked_profile_json(public.ranked_progress) from public, anon, authenticated;
revoke all on function public.ranked_start_profile(text) from public, anon, authenticated;
revoke all on function public.ranked_allocate_stat(text) from public, anon, authenticated;
revoke all on function public.ranked_pvp_match_json(public.ranked_pvp_matches, uuid) from public, anon, authenticated;
revoke all on function public.ranked_pvp_find_match() from public, anon, authenticated;
revoke all on function public.ranked_pvp_current() from public, anon, authenticated;
revoke all on function public.ranked_pvp_cancel_search() from public, anon, authenticated;
revoke all on function public.ranked_pvp_action(uuid, text) from public, anon, authenticated;
revoke all on function public.ranked_rest() from public, anon, authenticated;
revoke all on function public.ranked_start_battle() from public, anon, authenticated;
revoke all on function public.ranked_battle_action(text) from public, anon, authenticated;
revoke all on function public.ranked_explore_action(integer) from public, anon, authenticated;
grant execute on function public.ranked_start_profile(text) to authenticated;
grant execute on function public.ranked_allocate_stat(text) to authenticated;
grant execute on function public.ranked_pvp_find_match() to authenticated;
grant execute on function public.ranked_pvp_current() to authenticated;
grant execute on function public.ranked_pvp_cancel_search() to authenticated;
grant execute on function public.ranked_pvp_action(uuid, text) to authenticated;
grant execute on function public.ranked_rest() to authenticated;
grant execute on function public.ranked_battle_action(text) to authenticated;
grant execute on function public.ranked_explore_action(integer) to authenticated;

drop view if exists public.player_leaderboard;
create view public.player_leaderboard
with (security_invoker = false)
as
select hero_name, level, depth, pvp_rating, pvp_wins, pvp_losses
from public.ranked_progress
where nullif(btrim(hero_name), '') is not null;
grant select on public.player_leaderboard to anon, authenticated;
