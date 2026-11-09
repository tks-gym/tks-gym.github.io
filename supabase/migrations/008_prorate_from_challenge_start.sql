-- =====================================================================
-- GYM CHALLENGE — 008: ký quỹ tháng đầu tính theo số ngày còn lại của CẢ THÁNG
--  Trước: mẫu số = số ngày bắt buộc kể từ ngày bắt đầu thử thách → bắt đầu giữa tháng
--         vẫn là 19/19 ngày = đủ phí.
--  Nay:   mẫu số = số ngày bắt buộc của cả tháng (bỏ qua ngày bắt đầu),
--         tử số = số ngày bắt buộc kể từ max(ngày tham gia, ngày bắt đầu thử thách).
--  Đổi ngày bắt đầu / mức ký quỹ / ngày tập trong Cài đặt → tự tính lại ký quỹ tháng hiện tại.
-- An toàn khi chạy lại.
-- =====================================================================

-- Số ngày bắt buộc của cả tháng, không phụ thuộc ngày bắt đầu thử thách
create or replace function public.month_fee_days(p_month date) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from settings s,
    generate_series(date_trunc('month', p_month)::date, (date_trunc('month', p_month) + interval '1 month - 1 day')::date, interval '1 day') g(d)
  where s.id = 1 and extract(isodow from g.d)::int = any(s.workdays) and not (g.d::date = any(s.off_dates))
$$;

create or replace function public.fee_for(p_member uuid, p_month date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare fee int; md int; td int;
begin
  select monthly_fee into fee from settings where id = 1;
  td := month_fee_days(p_month);
  md := member_month_days(p_member, p_month);   -- đã tính từ max(ngày tham gia, ngày bắt đầu)
  return jsonb_build_object('fee_full', fee, 'member_days', md, 'month_days', td,
    'amount', case when td = 0 or fee = 0 then 0 else (round(fee::numeric * md / td / 1000) * 1000)::int end);
end $$;

-- Tính lại ký quỹ tháng hiện tại theo cài đặt mới.
-- Giữ nguyên phần số dư tháng trước đã được trừ (required − amount), không âm.
create or replace function public._recompute_dues() returns int
language plpgsql security definer set search_path = public as $$
declare m0 date := date_trunc('month', vn_today())::date; r record; f jsonb; rq int; n int := 0;
begin
  for r in select * from dues where month = m0 and status = 'active' for update loop
    f := fee_for(r.member_id, m0);
    rq := (f->>'amount')::int;
    if rq <> r.required or (f->>'member_days')::int <> r.member_days or (f->>'month_days')::int <> r.month_days then
      update dues set required    = rq,
                      amount      = greatest(rq - greatest(r.required - r.amount, 0), 0),
                      paid        = least(paid, greatest(rq - greatest(r.required - r.amount, 0), 0)),
                      member_days = (f->>'member_days')::int,
                      month_days  = (f->>'month_days')::int
      where id = r.id;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

create or replace function public.admin_update_settings(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare a text := require_admin(); old jsonb;
begin
  select to_jsonb(s) into old from settings s where id = 1;
  if p ? 'join_code' and length(_norm_code(p->>'join_code')) < 4 then raise exception 'JOIN_CODE_SHORT'; end if;
  update settings set
    penalty_amount  = coalesce((p->>'penalty_amount')::int, penalty_amount),
    monthly_fee     = coalesce((p->>'monthly_fee')::int, monthly_fee),
    workdays        = coalesce((select array_agg(x::int order by x::int) from jsonb_array_elements_text(p->'workdays') x), workdays),
    off_dates       = case when p ? 'off_dates' then coalesce((select array_agg(x::date order by x::date) from jsonb_array_elements_text(p->'off_dates') x), '{}') else off_dates end,
    checkin_start   = coalesce((p->>'checkin_start')::time, checkin_start),
    checkin_end     = coalesce((p->>'checkin_end')::time, checkin_end),
    challenge_start = coalesce((p->>'challenge_start')::date, challenge_start),
    allow_self_join = coalesce((p->>'allow_self_join')::boolean, allow_self_join),
    join_code       = coalesce(nullif(_norm_code(p->>'join_code'), ''), join_code),
    treasurer       = coalesce(left(trim(p->>'treasurer'), 60), treasurer),
    pay_bank        = coalesce(left(upper(trim(p->>'pay_bank')), 20), pay_bank),
    pay_account     = coalesce(left(regexp_replace(p->>'pay_account', '[^0-9]', '', 'g'), 30), pay_account),
    pay_name        = coalesce(left(upper(trim(p->>'pay_name')), 60), pay_name),
    updated_at      = now()
  where id = 1;
  insert into audit_log(actor, action, details) values (a, 'settings_update', jsonb_build_object('old', old - 'join_code', 'new', p - 'join_code'));
  perform _charge_dues();
  perform _recompute_dues();
end $$;


revoke execute on function public._recompute_dues() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on function public._recompute_dues() from anon, authenticated;
    grant execute on function public.admin_update_settings(jsonb) to authenticated;
  end if;
end $$;

-- Áp dụng ngay cho tháng hiện tại
select _recompute_dues();

select 'OK 008' as ket_qua;
