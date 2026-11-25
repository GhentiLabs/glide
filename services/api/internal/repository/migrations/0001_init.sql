-- Server order of record changes; the listRecords cursor.
CREATE SEQUENCE record_seq;

-- Sealed dictation records, one row per (user, record). Tombstones keep their row with sealed NULL.
CREATE TABLE records (
  sub         text        NOT NULL,
  id          uuid        NOT NULL,
  kid         integer     NOT NULL,
  revision    integer     NOT NULL,
  seq         bigint      NOT NULL DEFAULT nextval('record_seq'),
  deleted     boolean     NOT NULL DEFAULT false,
  sealed      bytea,
  has_audio   boolean     NOT NULL DEFAULT false,
  audio_bytes bigint      NOT NULL DEFAULT 0,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (sub, id)
);
CREATE UNIQUE INDEX records_sub_seq ON records (sub, seq);

CREATE TABLE training_consent (
  sub     text    PRIMARY KEY,
  enabled boolean NOT NULL,
  since   timestamptz
);

-- One row per shared item; the sealed bytes live in object storage at training/<sub>/<id>.
CREATE TABLE training_items (
  sub         text        NOT NULL,
  id          uuid        NOT NULL,
  key_version integer     NOT NULL,
  bytes       bigint      NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (sub, id)
);
