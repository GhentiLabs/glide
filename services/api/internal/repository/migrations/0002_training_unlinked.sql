-- Training items are stored at training/<id>, with no account in the path; this table is the
-- only link back to the account, kept so turning sharing off can delete them. An id has one owner.
ALTER TABLE training_items DROP CONSTRAINT training_items_pkey;
ALTER TABLE training_items ADD PRIMARY KEY (id);
CREATE INDEX training_items_sub ON training_items (sub);
