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
  hero_hp integer not null default 100 check (hero_hp between 1 and 100),
  potions integer not null default 3 check (potions >= 0),
  gold integer not null default 250 check (gold >= 0),
  battle jsonb,
  updated_at timestamptz not null default now()
);

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
    'potions', p.potions,
    'gold', p.gold,
    'battles_since_guardian', p.battles_since_guardian
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
  if v_profile.gold < 20 then raise exception 'Not enough ranked gold'; end if;
  update public.ranked_progress
  set gold = gold - 20, hero_hp = 100, updated_at = now()
  where user_id = v_user_id returning * into v_profile;
  return public.ranked_profile_json(v_profile);
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

  if p_action = 'flee' then
    if v_guardian then raise exception 'Cannot flee from a guardian'; end if;
    if random() < 0.65 then
      update public.ranked_progress set battle = null, updated_at = now()
      where user_id = v_user_id returning * into v_profile;
      return jsonb_build_object('outcome', 'fled', 'message', 'Вы скрылись от преследования.', 'profile', public.ranked_profile_json(v_profile));
    end if;
    v_message := 'Побег не удался.';
  elsif p_action = 'attack' then
    v_hit := random() < 0.84;
    if v_hit then
      v_damage := 13 + floor(random() * 14)::integer;
      v_enemy_hp := greatest(0, v_enemy_hp - v_damage);
      v_message := 'Удар: ' || v_damage || ' урона.';
    else
      v_message := 'Вы промахнулись.';
    end if;
  elsif p_action = 'skill' then
    if (v_battle->>'skillCooldown')::integer > 0 then raise exception 'Skill is on cooldown'; end if;
    v_damage := 26 + floor(random() * 7)::integer;
    v_enemy_hp := greatest(0, v_enemy_hp - v_damage);
    v_battle := jsonb_set(v_battle, '{skillCooldown}', '3'::jsonb);
    v_message := 'Точный удар наносит ' || v_damage || ' урона.';
  elsif p_action = 'potion' then
    if v_profile.potions <= 0 or v_hero_hp >= 100 then raise exception 'No usable potion'; end if;
    v_damage := least(35, 100 - v_hero_hp);
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
      battle = null, updated_at = now()
    where user_id = v_user_id returning * into v_profile;
    return jsonb_build_object('outcome', 'victory', 'message', v_message || ' Победа! +' || v_reward_xp || ' опыта и ' || v_reward_gold || ' золота.', 'profile', public.ranked_profile_json(v_profile));
  end if;

  v_battle := jsonb_set(v_battle, '{hp}', to_jsonb(v_enemy_hp));
  if (v_battle->>'skillCooldown')::integer > 0 then
    v_battle := jsonb_set(v_battle, '{skillCooldown}', to_jsonb(greatest(0, (v_battle->>'skillCooldown')::integer - 1)));
  end if;

  if random() >= 0.10 then
    v_damage := greatest(1, (v_battle->>'attack')::integer + floor(random() * 6)::integer - 2 - 1);
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
    v_profile.battle := null;
  else
    v_profile.battle := v_battle;
  end if;
  v_profile.hero_hp := v_hero_hp;
  update public.ranked_progress set
    hero_hp = v_profile.hero_hp, potions = v_profile.potions,
    battles_since_guardian = v_profile.battles_since_guardian,
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

revoke all on function public.ranked_profile_json(public.ranked_progress) from public, anon, authenticated;
revoke all on function public.ranked_start_profile(text) from public, anon, authenticated;
revoke all on function public.ranked_rest() from public, anon, authenticated;
revoke all on function public.ranked_start_battle() from public, anon, authenticated;
revoke all on function public.ranked_battle_action(text) from public, anon, authenticated;
grant execute on function public.ranked_start_profile(text) to authenticated;
grant execute on function public.ranked_rest() to authenticated;
grant execute on function public.ranked_start_battle() to authenticated;
grant execute on function public.ranked_battle_action(text) to authenticated;

drop view if exists public.player_leaderboard;
create view public.player_leaderboard
with (security_invoker = false)
as
select hero_name, level, depth
from public.ranked_progress
where nullif(btrim(hero_name), '') is not null;
grant select on public.player_leaderboard to anon, authenticated;
