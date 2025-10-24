CREATE TABLE IF NOT EXISTS channel (
    link text primary key not null unique,
    title text not null,
    description text not null
);
CREATE TABLE IF NOT EXISTS post (
    title text not null,
    pubdate integer not null,
    link text primary key not null unique,
    description text not null,
    read boolean not null,
    channel integer,
    foreign key(channel) references channel(rowid)
);
