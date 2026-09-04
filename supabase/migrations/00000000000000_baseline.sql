-- OpenComms baseline schema, captured from live project tbgcinfhgskcjoevfkea
-- on 2026-09-04 and checked in so a rebuild cannot lose it. Everything here
-- was already applied by hand; this file exists to make that reproducible.
--
-- The shape of the security model matters more than any single line: RLS is
-- ON for every table and there are NO policies at all, so the anon key can
-- reach nothing directly. Every path into the data is a SECURITY DEFINER
-- function, which is what lets the server enforce a rule instead of merely
-- suggesting one. Do not "fix" the missing policies by adding some.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- tables

create table if not exists public.squads (
    id             uuid primary key default gen_random_uuid(),
    name           text        not null default 'Squad',
    -- Three digits, chosen by the person, never generated. A code you picked
    -- is one you can say across a gym floor and the other person can type
    -- without looking. The client keypad is fixed at three to match.
    join_code      text        not null check (join_code ~ '^[0-9]{3}$'),
    creator_device text,
    max_members    integer     not null default 8,
    created_at     timestamptz not null default now(),
    expires_at     timestamptz not null default (now() + interval '12 hours'),
    ended_at       timestamptz
);

-- A code is only reserved while its line is live. Ending a line frees the
-- code immediately rather than holding it for twelve hours after everyone
-- walked away — with a three digit space there are only a thousand of them.
create unique index if not exists squads_live_code
    on public.squads (join_code) where ended_at is null;
create index if not exists squads_expiry
    on public.squads (expires_at) where ended_at is null;

create table if not exists public.squad_members (
    squad_id     uuid        not null references public.squads(id) on delete cascade,
    device_id    text        not null,
    display_name text        not null default 'Someone',
    joined_at    timestamptz not null default now(),
    last_seen_at timestamptz not null default now(),
    primary key (squad_id, device_id)
);
create index if not exists squad_members_device on public.squad_members (device_id);
create index if not exists squad_members_seen   on public.squad_members (last_seen_at desc);

create table if not exists public.devices (
    device_id           text primary key,
    display_name        text        not null default 'Someone',
    livekit_identity    text,
    -- Only ever a hash. The server cannot recover a number from one and
    -- cannot be used to enumerate anybody, because you can only ask about
    -- hashes you already hold.
    phone_hash          text,
    latitude            double precision,
    longitude           double precision,
    location_updated_at timestamptz,
    is_ghost_mode       boolean     not null default false,
    last_seen_at        timestamptz not null default now(),
    created_at          timestamptz not null default now()
);
create index if not exists devices_last_seen on public.devices (last_seen_at desc);
create index if not exists devices_phone_hash on public.devices (phone_hash) where phone_hash is not null;

create table if not exists public.blocks (
    blocker_device text        not null,
    blocked_device text        not null,
    display_name   text        not null default 'Someone',
    blocked_at     timestamptz not null default now(),
    primary key (blocker_device, blocked_device)
);

create table if not exists public.reports (
    id              bigserial primary key,
    reporter_device text        not null,
    reported_device text        not null,
    squad_id        uuid,
    reason          text        not null,
    detail          text,
    reported_at     timestamptz not null default now(),
    reviewed_at     timestamptz
);
create index if not exists reports_unreviewed
    on public.reports (reported_at desc) where reviewed_at is null;

-- Failed joins are the only evidence a sweep is happening, so they are
-- recorded whether or not anybody is watching.
create table if not exists public.join_attempts (
    id           bigserial primary key,
    code         text        not null,
    device_id    text,
    client_ip    inet,
    succeeded    boolean     not null,
    attempted_at timestamptz not null default now()
);
create index if not exists join_attempts_device_time on public.join_attempts (device_id, attempted_at desc);
create index if not exists join_attempts_ip_time     on public.join_attempts (client_ip, attempted_at desc);

-- ---------------------------------------------------------------- rls

alter table public.squads        enable row level security;
alter table public.squad_members enable row level security;
alter table public.devices       enable row level security;
alter table public.blocks        enable row level security;
alter table public.reports       enable row level security;
alter table public.join_attempts enable row level security;
