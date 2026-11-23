-- 088 — Resale / rental listings (عرض عقار) — additive, one transaction, safe to re-run. Needs 087.
--
--  • brokerage_listings: a property any salesperson / employee offers for resale or rent — its name / type, address, area,
--    price, finishing and description, who listed it, and whether it is still available. Optional owner name / phone
--    (shown to the administration only).
--  • brokerage_listing_photos: its photos (base64, up to 8 live per listing). A removed photo is only marked removed —
--    the runtime role deletes nothing here.
--  • brokerage_deals.listing_id: a sale / rent of a listing. Anyone can sell it: the seller records the client (name,
--    phone), the final price and the commission amount; the deal is created as proposed (contributor = the lister,
--    closer = the seller) and the administrative officer is told. He receives the commission and sets its split
--    (seller / lister when different / sales manager, by amount or %, the rest to the office).
--  • A listing sale's commission is a fixed amount (arrangement 'fixed', no rate) — the 1 %–2.5 % rule stays for a
--    resale registered without a listing.

CREATE TABLE IF NOT EXISTS brokerage_listings (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind          text NOT NULL CHECK (kind IN ('resale', 'rental')),
  status        text NOT NULL DEFAULT 'available' CHECK (status IN ('available', 'pending', 'sold', 'withdrawn')),
  title         text NOT NULL CHECK (length(trim(title)) BETWEEN 2 AND 160),   -- name / type: محل، شقة، فيلا…
  address       text NOT NULL CHECK (length(trim(address)) BETWEEN 2 AND 300),
  area_m2       numeric(10,2) NOT NULL CHECK (area_m2 > 0),
  price_egp     numeric(16,2) NOT NULL CHECK (price_egp > 0),                    -- asking price / monthly rent
  finishing     text NOT NULL CHECK (finishing IN ('none', 'semi', 'full', 'super_lux', 'ultra_super_lux')),
  description   text NOT NULL DEFAULT '' CHECK (length(description) <= 3000),
  owner_name    text NOT NULL DEFAULT '' CHECK (length(owner_name) <= 120),
  owner_phone   text NOT NULL DEFAULT '' CHECK (length(owner_phone) <= 30),
  listed_by     uuid NOT NULL REFERENCES employees(id),
  client_ref    uuid UNIQUE,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS brokerage_listings_kind ON brokerage_listings (kind, status, created_at DESC);

CREATE TABLE IF NOT EXISTS brokerage_listing_photos (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id  uuid NOT NULL REFERENCES brokerage_listings(id),
  mime        text NOT NULL CHECK (mime IN ('image/jpeg', 'image/png', 'image/webp')),
  data        text NOT NULL,
  position    int NOT NULL DEFAULT 0,
  removed     boolean NOT NULL DEFAULT false,
  added_by    uuid NOT NULL REFERENCES employees(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS brokerage_listing_photos_listing ON brokerage_listing_photos (listing_id, position) WHERE NOT removed;

ALTER TABLE brokerage_deals ADD COLUMN IF NOT EXISTS listing_id uuid REFERENCES brokerage_listings(id);
CREATE INDEX IF NOT EXISTS brokerage_deals_listing ON brokerage_deals (listing_id) WHERE listing_id IS NOT NULL;

-- the resale rule of 087 (rate 1–2.5 %, arrangement 'percent') — a listing sale may carry a fixed commission instead
DO $$
DECLARE c text;
BEGIN
  FOR c IN SELECT conname FROM pg_constraint
            WHERE conrelid = 'brokerage_deals'::regclass AND contype = 'c'
              AND pg_get_constraintdef(oid) LIKE '%resale%' AND pg_get_constraintdef(oid) LIKE '%percent%'
              AND conname <> 'brokerage_deals_resale_terms'
  LOOP
    EXECUTE format('ALTER TABLE brokerage_deals DROP CONSTRAINT %I', c);
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'brokerage_deals_resale_terms') THEN
    ALTER TABLE brokerage_deals ADD CONSTRAINT brokerage_deals_resale_terms CHECK (
      kind <> 'resale'
      OR (rate_pct IS NOT NULL AND arrangement = 'percent')
      OR (listing_id IS NOT NULL AND rate_pct IS NULL AND arrangement = 'fixed'));
  END IF;
END $$;
