begin;

alter table public.email_jobs add column if not exists provider_message_id text unique;
alter table public.email_logs drop constraint if exists email_logs_provider_message_id_key;
alter table public.email_logs add column if not exists webhook_event_id text unique;
create index if not exists email_logs_provider_message_idx on public.email_logs(provider_message_id, occurred_at desc);
create unique index if not exists notification_event_once on public.notifications(recipient_id, notification_type, related_record_type, related_record_id) where related_record_id is not null;

create or replace function public.claim_email_jobs(batch_size integer default 20)
returns setof public.email_jobs language plpgsql security definer set search_path = public as $$
begin
  if current_setting('request.jwt.claim.role', true) <> 'service_role' then raise exception 'Service role required'; end if;
  return query
  with claimed as (
    select id from public.email_jobs
    where state = 'Queued' and scheduled_for <= now() and attempts < 5
    order by scheduled_for, created_at
    for update skip locked limit greatest(1, least(batch_size, 100))
  )
  update public.email_jobs j set state = 'Processing', attempts = attempts + 1
  from claimed where j.id = claimed.id returning j.*;
end $$;

create or replace function public.post_payment(
  target_trainee uuid,
  target_amount_centavos bigint,
  target_method text,
  target_receiving_account text,
  target_reference text,
  target_received_at timestamptz,
  target_proof uuid,
  target_allocations jsonb,
  target_remarks text default null
) returns public.payments language plpgsql security definer set search_path = public as $$
declare result public.payments; item jsonb; allocated bigint := 0; duplicate_found boolean := false;
begin
  if not public.has_any_role(array['admin','cashier','accounting']) then raise exception 'Not authorized'; end if;
  if target_amount_centavos <= 0 then raise exception 'Payment amount must be positive'; end if;
  if jsonb_typeof(target_allocations) <> 'array' or jsonb_array_length(target_allocations) = 0 then raise exception 'At least one allocation is required'; end if;
  for item in select value from jsonb_array_elements(target_allocations) loop
    if (item->>'amount_centavos')::bigint <= 0 then raise exception 'Allocation amounts must be positive'; end if;
    if not exists(select 1 from public.enrollments where id = (item->>'enrollment_id')::uuid and trainee_id = target_trainee) then raise exception 'Allocation does not belong to trainee'; end if;
    allocated := allocated + (item->>'amount_centavos')::bigint;
  end loop;
  if allocated <> target_amount_centavos then raise exception 'Allocations must equal payment amount'; end if;
  if nullif(trim(target_reference), '') is not null then
    select exists(select 1 from public.payments where lower(reference_number) = lower(trim(target_reference)) and valid) into duplicate_found;
  end if;
  insert into public.payments(payment_number, trainee_id, amount_centavos, method, receiving_account, reference_number, received_at, proof_id, verification_state, cashier_id, remarks)
  values(public.next_reference('PAY'), target_trainee, target_amount_centavos, target_method, target_receiving_account, nullif(trim(target_reference), ''), target_received_at, target_proof, case when duplicate_found then 'Duplicate Review' else 'Verified' end, auth.uid(), target_remarks)
  returning * into result;
  for item in select value from jsonb_array_elements(target_allocations) loop
    insert into public.payment_allocations(payment_id, enrollment_id, amount_centavos) values(result.id, (item->>'enrollment_id')::uuid, (item->>'amount_centavos')::bigint);
  end loop;
  insert into public.audit_logs(actor_id, actor_role, action, record_type, record_id, new_values)
  values(auth.uid(), 'cashier', 'payment.posted', 'payment', result.id::text, to_jsonb(result));
  return result;
end $$;

create or replace function public.reverse_payment(target_payment uuid, target_amount_centavos bigint, target_reason text, approved_request uuid)
returns public.refunds_and_reversals language plpgsql security definer set search_path = public as $$
declare payment_row public.payments; prior_reversed bigint; result public.refunds_and_reversals;
begin
  if not public.has_any_role(array['admin','accounting']) then raise exception 'Not authorized'; end if;
  select * into payment_row from public.payments where id = target_payment and valid for update;
  if payment_row.id is null then raise exception 'Payment not found'; end if;
  if not exists(select 1 from public.enrollment_requests where id = approved_request and status = 'Approved') then raise exception 'Approved request required'; end if;
  select coalesce(sum(amount_centavos),0) into prior_reversed from public.refunds_and_reversals where payment_id = target_payment and event_type in ('refund','reversal');
  if target_amount_centavos <= 0 or prior_reversed + target_amount_centavos > payment_row.amount_centavos then raise exception 'Invalid reversal amount'; end if;
  insert into public.refunds_and_reversals(payment_id,event_type,amount_centavos,reason,approved_request_id,created_by)
  values(target_payment,'reversal',target_amount_centavos,target_reason,approved_request,auth.uid()) returning * into result;
  insert into public.audit_logs(actor_id,actor_role,action,record_type,record_id,new_values,reason)
  values(auth.uid(),'accounting','payment.reversed','payment',target_payment::text,to_jsonb(result),target_reason);
  return result;
end $$;

create or replace function public.apply_approved_request(target_request uuid, target_decision text, target_remarks text default null)
returns public.enrollment_requests language plpgsql security definer set search_path = public as $$
declare req public.enrollment_requests; result public.enrollment_requests;
begin
  if not public.has_any_role(array['admin','accounting','registration','training_operations','hr']) then raise exception 'Not authorized'; end if;
  if target_decision not in ('Approved','Rejected','Returned for Clarification') then raise exception 'Invalid decision'; end if;
  select * into req from public.enrollment_requests where id = target_request for update;
  if req.id is null or req.status <> 'Pending' then raise exception 'Request is not pending'; end if;
  if target_decision = 'Approved' then
    if req.request_type = 'Enrollment Cancellation' then
      update public.enrollments set enrollment_status='Cancelled', cancelled_at=now() where id=req.enrollment_id;
    elsif req.request_type = 'Schedule Change' then
      update public.enrollments set batch_id=(req.requested_values->>'batch_id')::uuid, enrollment_status='Enrolled' where id=req.enrollment_id;
    elsif req.request_type not in ('Attendance Correction','Payment Reversal','Offer Rate Change','Employee Request') then
      raise exception 'Unsupported approved request type';
    end if;
  end if;
  update public.enrollment_requests set status=target_decision, decision_remarks=target_remarks, decided_at=now(), assigned_approver_id=auth.uid(), updated_at=now()
  where id=target_request returning * into result;
  insert into public.request_events(request_id,actor_id,event_type,prior_values,new_values,remarks)
  values(target_request,auth.uid(),target_decision,to_jsonb(req),to_jsonb(result),target_remarks);
  return result;
end $$;

create or replace function public.correct_attendance(target_record uuid, target_status text, target_reason text, target_request uuid, target_idempotency_key text)
returns public.attendance_records language plpgsql security definer set search_path = public as $$
declare existing public.attendance_records; result public.attendance_records;
begin
  if not public.has_any_role(array['admin','training_operations']) then raise exception 'Not authorized'; end if;
  if target_status not in ('Present','Late','Absent','Incomplete','Make-Up Required','Make-Up Completed') then raise exception 'Invalid attendance status'; end if;
  if exists(select 1 from public.attendance_events where idempotency_key=target_idempotency_key) then
    return (select ar from public.attendance_records ar join public.attendance_events ae on ae.attendance_record_id=ar.id where ae.idempotency_key=target_idempotency_key);
  end if;
  select * into existing from public.attendance_records where id=target_record for update;
  if existing.id is null then raise exception 'Attendance record not found'; end if;
  if existing.locked_at is not null and not exists(select 1 from public.enrollment_requests where id=target_request and request_type='Attendance Correction' and status='Approved') then raise exception 'Approved correction request required'; end if;
  update public.attendance_records set status=target_status, remarks=target_reason, updated_at=now() where id=target_record returning * into result;
  insert into public.attendance_events(attendance_record_id,idempotency_key,event_type,actor_id,server_payload,previous_status,new_status)
  values(target_record,target_idempotency_key,'Correction',auth.uid(),jsonb_build_object('reason',target_reason,'request_id',target_request),existing.status,target_status);
  return result;
end $$;

create or replace function public.refresh_certificate_eligibility(target_enrollment uuid)
returns public.certificates language plpgsql security definer set search_path = public as $$
declare enrollment_row public.enrollments; cert public.certificates; eligible boolean;
begin
  if not public.has_any_role(array['admin','training_operations']) then raise exception 'Not authorized'; end if;
  select * into enrollment_row from public.enrollments where id=target_enrollment;
  if enrollment_row.id is null then raise exception 'Enrollment not found'; end if;
  select exists(select 1 from public.attendance_records where enrollment_id=target_enrollment)
    and not exists(select 1 from public.attendance_records where enrollment_id=target_enrollment and status not in ('Present','Late','Make-Up Completed'))
    into eligible;
  insert into public.certificates(enrollment_id,status,snapshot)
  values(target_enrollment,case when eligible then 'Ready to Print' else 'Pending Attendance' end,jsonb_build_object('evaluated_at',now(),'eligible',eligible))
  on conflict(enrollment_id) do update set status=excluded.status,snapshot=excluded.snapshot,updated_at=now()
  returning * into cert;
  if eligible and cert.ready_notified_at is null then
    update public.certificates set ready_notified_at=now() where id=cert.id returning * into cert;
    insert into public.notifications(recipient_id,notification_type,title,body,related_record_type,related_record_id,deep_link)
    select ur.user_id,'certificate.ready','Certificate ready to print','An enrollment passed certificate eligibility checks.','certificate',cert.id,'/portal?module=Certificates'
    from public.user_roles ur join public.roles r on r.id=ur.role_id where r.code in ('admin','training_operations')
    on conflict do nothing;
  end if;
  return cert;
end $$;

create or replace function public.allocate_certificate_number(target_certificate uuid)
returns public.certificates language plpgsql security definer set search_path = public as $$
declare cert public.certificates; number_row public.certificate_number_pool; template_row public.certificate_templates;
begin
  if not public.has_any_role(array['admin','training_operations']) then raise exception 'Not authorized'; end if;
  if coalesce(current_setting('app.certificate_issuance_enabled',true),'false') <> 'true'
     or not exists(select 1 from public.organization_settings where id and certificate_issuance_enabled) then raise exception 'Certificate issuance is disabled'; end if;
  select * into cert from public.certificates where id=target_certificate and status='Ready to Print' for update;
  if cert.id is null then raise exception 'Certificate is not ready'; end if;
  select ct.* into template_row from public.certificate_templates ct join public.enrollments e on e.id=cert.enrollment_id
    where ct.course_id=e.course_id and ct.active and ct.approved_at is not null order by ct.version desc limit 1;
  if template_row.id is null then raise exception 'No approved active template'; end if;
  select p.* into number_row from public.certificate_number_pool p join public.enrollments e on e.id=cert.enrollment_id
    where p.state='Available' and (p.course_id is null or p.course_id=e.course_id) order by p.certificate_number for update skip locked limit 1;
  if number_row.id is null then raise exception 'Certificate number pool is empty'; end if;
  update public.certificate_number_pool set state='Assigned',assigned_at=now() where id=number_row.id;
  update public.certificates set template_id=template_row.id,number_pool_id=number_row.id,snapshot=jsonb_build_object('certificate_number',number_row.certificate_number,'template_version',template_row.version,'allocated_at',now()),updated_at=now()
  where id=cert.id returning * into cert;
  return cert;
end $$;

create or replace function public.lock_accounting_period(target_period uuid)
returns public.accounting_periods language plpgsql security definer set search_path = public as $$
declare result public.accounting_periods;
begin
  if not public.has_any_role(array['admin','accounting']) then raise exception 'Not authorized'; end if;
  update public.accounting_periods set status='Locked',locked_by=auth.uid(),locked_at=now() where id=target_period and status='Open' returning * into result;
  if result.id is null then raise exception 'Accounting period is not open'; end if;
  return result;
end $$;

create or replace function public.finalize_payroll(target_period uuid)
returns public.payroll_periods language plpgsql security definer set search_path = public as $$
declare result public.payroll_periods;
begin
  if not public.has_any_role(array['admin','hr']) then raise exception 'Not authorized'; end if;
  update public.payroll_periods set status='Finalized',finalized_by=auth.uid(),finalized_at=now()
  where id=target_period and status='Reviewed' and reviewed_by is not null and exists(select 1 from public.payroll_items where payroll_period_id=target_period)
  returning * into result;
  if result.id is null then raise exception 'Payroll must be reviewed and contain payroll items'; end if;
  return result;
end $$;

create trigger payments_immutable before update or delete on public.payments for each row execute function public.prevent_immutable_change();
create trigger payment_allocations_immutable before update or delete on public.payment_allocations for each row execute function public.prevent_immutable_change();
create trigger reversals_immutable before update or delete on public.refunds_and_reversals for each row execute function public.prevent_immutable_change();

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values
('payment-proofs','payment-proofs',false,10485760,array['image/png','image/jpeg','image/webp']),
('financial-documents','financial-documents',false,52428800,array['application/pdf','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet']),
('certificate-templates','certificate-templates',false,52428800,array['application/pdf','image/png','image/jpeg']),
('hr-files','hr-files',false,52428800,null),
('generated-documents','generated-documents',false,52428800,array['application/pdf','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'])
on conflict(id) do nothing;

create policy private_staff_storage_read on storage.objects for select to authenticated using (bucket_id in ('payment-proofs','financial-documents','certificate-templates','hr-files','generated-documents') and public.has_staff_role());

commit;
