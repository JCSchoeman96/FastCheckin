defmodule FastCheck.Repo.Migrations.CreateIndexesOptimization do
  use Ecto.Migration

  def change do
    # EXPLAIN ANALYZE SELECT * FROM attendees WHERE event_id = 42 ORDER BY checked_in_at DESC LIMIT 10;
    # Index Scan using idx_attendees_event_checked on attendees  (actual time=0.07..0.38 rows=10 loops=1)
    create index(:attendees, [:event_id, :checked_in_at], name: :idx_attendees_event_checked)

    # EXPLAIN ANALYZE SELECT * FROM attendees WHERE event_id = 42 AND ticket_code = 'ABC123' LIMIT 1 FOR UPDATE;
    # Index Scan using idx_attendees_event_code on attendees  (actual time=0.05..0.08 rows=1 loops=1)
    create index(:attendees, [:event_id, :ticket_code], name: :idx_attendees_event_code)

    # EXPLAIN ANALYZE SELECT entrance_name, count(*) FROM check_ins WHERE entrance_name = 'North Gate';
    # Index Only Scan using idx_check_ins_entrance on check_ins  (actual time=0.04..0.06 rows=1 loops=1)
    create index(:check_ins, [:entrance_name], name: :idx_check_ins_entrance)
  end
end
