-- =====================================================================
-- GYM CHALLENGE — 007: hoàn trả / trừ tiền ví thì giảm "ký quỹ đã nạp" của tháng
--  Lỗi cũ: nạp tiền cộng vào dues.paid, nhưng hoàn trả (adjustment âm) không trừ lại
--  → thành viên đã được hoàn hết tiền vẫn hiện "Ký quỹ · đủ".
-- An toàn khi chạy lại.
-- =====================================================================

-- Tiền rút khỏi ví → giảm phần ký quỹ đã nạp của tháng hiện tại (không âm)
create or replace function public._unapply_withdrawal(p_member uuid, p_amount int) returns void
language sql security definer set search_path = public as $$
  update dues set paid = greatest(paid - greatest(p_amount, 0), 0)
  where member_id = p_member and month = date_trunc('month', vn_today())::date and status = 'active'
$$;

create or replace function public.admin_wallet_entry(p_member uuid, p_type text, p_amount int, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare a text := require_admin();
begin
  if p_type not in ('deposit','adjustment') then raise exception 'TYPE_INVALID'; end if;
  if p_amount is null or p_amount = 0 or (p_type = 'deposit' and p_amount < 0) then raise exception 'AMOUNT_INVALID'; end if;
  if length(trim(coalesce(p_note,''))) = 0 then raise exception 'NOTE_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtext('wallet:' || p_member::text));
  if p_amount < 0 and wallet_balance(p_member) + p_amount < 0 then raise exception 'WALLET_INSUFFICIENT'; end if;
  insert into wallet_tx(member_id, type, amount, status, note, created_by, decided_by, decided_at)
    values (p_member, p_type, p_amount, 'confirmed', p_note, a, a, now());
  insert into audit_log(actor, action, details) values (a, 'wallet_entry', jsonb_build_object('member_id', p_member, 'type', p_type, 'amount', p_amount, 'note', p_note));
  if p_type = 'deposit' then perform _charge_dues(); perform _apply_deposit(p_member, p_amount); end if;
  if p_amount < 0 then perform _unapply_withdrawal(p_member, -p_amount); end if;
  if p_amount > 0 then perform _settle_outstanding(p_member); end if;
end $$;

revoke execute on function public._unapply_withdrawal(uuid, int) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on function public._unapply_withdrawal(uuid, int) from anon, authenticated;
    grant execute on function public.admin_wallet_entry(uuid, text, int, text) to authenticated;
  end if;
end $$;

-- Sửa dữ liệu tháng hiện tại: ai đã bị trừ/hoàn tiền trong tháng thì tính lại
-- ký quỹ đã nạp = tiền nạp − tiền hoàn trong tháng (chạy lại cho cùng kết quả)
with m as (select date_trunc('month', vn_today())::date as m0),
moves as (
  select w.member_id,
         sum(w.amount) filter (where w.type = 'deposit' or (w.type = 'adjustment' and w.amount < 0)) as net,
         bool_or(w.type = 'adjustment' and w.amount < 0) as has_out
  from wallet_tx w, m
  where w.status = 'confirmed'
    and (coalesce(w.decided_at, w.created_at) at time zone 'Asia/Ho_Chi_Minh')::date >= m.m0
  group by w.member_id
)
update dues d set paid = least(d.amount, greatest(coalesce(mv.net, 0), 0))
from moves mv, m
where d.member_id = mv.member_id and mv.has_out and d.month = m.m0 and d.status = 'active';

select 'OK 007' as ket_qua;
