\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
-- Ký quỹ tháng theo ngày tham gia (chạy sau 30_join_recovery.sql)
update settings set allow_self_join = true, monthly_fee = 0;
update test_clock set t = '2026-12-01 08:00';
select process_penalties();
select t_eq((select count(*) from dues)::int, 0, 'K0 ký quỹ = 0 → không yêu cầu');
update members set locked = true where name = 'Em Hoàng';
select id as an from members where name = 'Anh An' \gset
select wallet_balance(:'an') as anbal \gset
select coalesce(sum(amount),0) as fund0 from fund_tx \gset
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000a0a0';
select admin_update_settings('{"monthly_fee": 260000, "treasurer": "Anh An", "pay_bank": "vcb", "pay_account": "0123 456 789", "pay_name": "Nguyen Van An"}') is null;
reset request.jwt.claim.sub;
reset role;
select process_penalties();
select t_eq(month_mandatory_days('2026-12-01'), 27, 'K1 Tháng 12/2026: 27 ngày bắt buộc');
select t_eq((select required from dues where member_id = :'an'), 260000, 'K2 vào từ đầu tháng: ký quỹ yêu cầu đủ 260.000đ');
select t_eq((select amount from dues where member_id = :'an'), greatest(260000 - greatest(:anbal, 0), 0), 'K3 số dư cũ được trừ vào phần phải nạp');
select t_eq(wallet_balance(:'an'), :anbal, 'K4 ký quỹ KHÔNG trừ tiền khỏi ví');
select t_eq((select coalesce(sum(amount),0) from fund_tx)::int, :fund0, 'K5 ký quỹ KHÔNG chuyển vào quỹ nhóm');
select t_eq((select count(*) from dues d join members m on m.id = d.member_id where m.name = 'Em Hoàng')::int, 0, 'K6 tài khoản khóa không yêu cầu ký quỹ');
select t_eq((select pay_account from settings), '0123456789', 'K7 lưu thông tin nhận tiền (chuẩn hóa số TK)');
update members set locked = false where name = 'Em Hoàng';

-- Người mới vào 15/12
update test_clock set t = '2026-12-15 10:00';
set role anon;
select member_join('GYM2026', 'Em Lan', '1212') as lan \gset
reset role;
select process_penalties();
select id as lanid from members where name = 'Em Lan' \gset
select t_eq((select required from dues where member_id = :'lanid'), 144000, 'K8 vào 15/12 → ký quỹ 260.000 × 15/27 = 144.000đ');
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000a0a0';
select admin_wallet_entry(:'lanid', 'deposit', 100000, 'Tiền mặt') is null;
reset request.jwt.claim.sub;
reset role;
select t_eq(wallet_balance(:'lanid'), 100000, 'K9 tiền nạp nằm trong ví của thành viên');
select t_eq((select paid from dues where member_id = :'lanid'), 100000, 'K10 tính vào ký quỹ đã nạp');
set role anon;
select t_eq((select (x->>'outstanding')::int from jsonb_array_elements(app_state(:'lan'::jsonb->>'token')->'members') x where x->>'id' = :'lanid'), 44000, 'K11 còn thiếu 44.000đ ký quỹ');
-- Đã tập thì không đổi sang báo vắng
select member_checkin(:'lan'::jsonb->>'token') is not null;
select t_err(format($$select public.member_register_absence(%L, 'work', null)$$, :'lan'::jsonb->>'token'), 'ALREADY_TRAINED', 'K12 đã tập thì không báo vắng được');
reset role;
-- Vắng không lý do 16/12 → trừ 50k từ ký quỹ sang quỹ
select coalesce(sum(amount),0) as fund1 from fund_tx \gset
update test_clock set t = '2026-12-17 09:00';
select process_penalties();
select t_eq(wallet_balance(:'lanid'), 50000, 'K13 phạm luật: trừ 50.000đ từ ký quỹ');
select t_eq((select coalesce(sum(amount),0) from fund_tx where type = 'penalty_income' and member_id = :'lanid')::int, 50000, 'K14 tiền phạt vào quỹ nhóm');
-- Sang tháng mới: số dư còn lại được tính, chỉ nạp phần thiếu
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000a0a0';
select admin_wallet_entry(:'lanid', 'deposit', 1000000, 'CK') is null;
reset request.jwt.claim.sub;
reset role;
update test_clock set t = '2027-01-01 08:00';
select process_penalties();
select t_eq((select required from dues where member_id = :'lanid' and month = '2027-01-01'), 260000, 'K15 tháng 1/2027 làm lại: ký quỹ đủ tháng 260.000đ');
select t_eq((select amount from dues where member_id = :'lanid' and month = '2027-01-01'), greatest(260000 - wallet_balance(:'lanid'), 0), 'K16 số dư tháng trước được chuyển sang, chỉ nạp phần thiếu');
select t_eq((select status from dues where member_id = :'lanid' and month = '2026-12-01'), 'active', 'K17 tháng 12 vẫn lưu lịch sử');
-- Miễn ký quỹ
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000a0a0';
select admin_void_due(:'lanid', '2027-01-01', 'miễn test') is null;
reset request.jwt.claim.sub;
reset role;
select t_eq((select status from dues where member_id = :'lanid' and month = '2027-01-01'), 'voided', 'K18 Admin miễn ký quỹ tháng');
select t_eq(((select sum(amount) from wallet_tx where status='confirmed') + (select sum(amount) from fund_tx))::int,
  ((select sum(amount) from wallet_tx where status='confirmed' and type in ('deposit','adjustment')))::int, 'K19 cân đối: ví + quỹ = tiền thật đã nộp');
select t_eq((select (x->>'fee')::int from jsonb_array_elements(month_report('2026-12-01')->'members') x where x->>'id' = :'lanid'), 144000, 'K20 báo cáo tháng hiện ký quỹ yêu cầu');
-- 006: chặn chi vượt quỹ, hoàn vượt ví
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000a0a0';
select t_err($$select public.admin_fund_entry('expense', 999999999, 'liên hoan')$$, 'FUND_INSUFFICIENT', 'G1 không chi vượt số dư quỹ');
select t_err(format($$select public.admin_wallet_entry(%L, 'adjustment', -999999999, 'hoàn trả')$$, :'lanid'), 'WALLET_INSUFFICIENT', 'G2 không hoàn vượt số dư ví');
reset request.jwt.claim.sub;
reset role;
select coalesce(sum(amount),0) as fundnow from fund_tx \gset
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000a0a0';
select admin_fund_entry('expense', :fundnow, 'Liên hoan cuối tháng') is null;
reset request.jwt.claim.sub;
reset role;
select t_eq((select sum(amount) from fund_tx)::int, 0, 'G3 chi đúng bằng số dư quỹ → quỹ về 0');
select t_eq(((select sum(amount) from wallet_tx where status='confirmed') + (select sum(amount) from fund_tx))::int,
  ((select sum(amount) from wallet_tx where status='confirmed' and type in ('deposit','adjustment')) - (select coalesce(-sum(amount),0) from fund_tx where type = 'expense'))::int, 'G4 cân đối sau chi: ví + quỹ = tiền nộp − tiền đã chi');
-- 007: hoàn trả tiền thì giảm ký quỹ đã nạp
update test_clock set t = '2027-02-01 08:00';
select process_penalties();
select id as anid from members where name = 'Anh An' \gset
select amount as an_due from dues where member_id = :'anid' and month = '2027-02-01' \gset
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000a0a0';
select admin_wallet_entry(:'anid', 'deposit', :an_due + 20000000, 'CK đủ ký quỹ') is null;
reset request.jwt.claim.sub;
reset role;
select t_eq((select paid from dues where member_id = :'anid' and month = '2027-02-01'), :an_due, 'W1 nạp đủ → ký quỹ đủ');
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000a0a0';
reset request.jwt.claim.sub;
reset role;
select wallet_balance(:'anid') as an_bal \gset
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000a0a0';
select admin_wallet_entry(:'anid', 'adjustment', -(:an_bal), 'Hoàn trả tiền: test') is null;
reset request.jwt.claim.sub;
reset role;
select t_eq((select paid from dues where member_id = :'anid' and month = '2027-02-01'), greatest(:an_due - :an_bal, 0), 'W2 hoàn trả → ký quỹ đã nạp giảm đúng số tiền hoàn');
select t_eq((select paid < amount from dues where member_id = :'anid' and month = '2027-02-01')::text, (:an_bal > 0)::text, 'W3 đã hoàn tiền thì không còn báo "đủ"');
-- 008: bắt đầu thử thách giữa tháng → ký quỹ tính theo ngày còn lại của cả tháng
update test_clock set t = '2027-03-01 08:00';
select process_penalties();
select t_eq((select required from dues where member_id = :'lanid' and month = '2027-03-01'), 260000, 'S1 tháng 3 bắt đầu từ đầu tháng: đủ 260.000đ');
select (select count(*) from generate_series('2027-03-15'::date, '2027-03-31'::date, interval '1 day') g(d) where extract(isodow from g.d)::int = any(s.workdays) and not (g.d::date = any(s.off_dates)))::int as left_days, month_fee_days('2027-03-01') as all_days from settings s where id = 1 \gset
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000a0a0';
select admin_update_settings('{"challenge_start": "2027-03-15"}') is null;
reset request.jwt.claim.sub;
reset role;
select t_eq((select required from dues where member_id = :'lanid' and month = '2027-03-01'), (round(260000.0 * :left_days / :all_days / 1000) * 1000)::int, 'S2 đổi ngày bắt đầu 15/3 → ký quỹ = 260.000 × ngày còn lại ÷ ngày cả tháng');
select t_eq((select member_days || '/' || month_days from dues where member_id = :'lanid' and month = '2027-03-01'), :left_days || '/' || :all_days, 'S3 lưu số ngày mới để hiển thị');
select t_eq((select amount <= required and paid <= amount from dues where member_id = :'lanid' and month = '2027-03-01')::text, 'true', 'S4 số phải nạp và đã nạp không vượt ký quỹ mới');
