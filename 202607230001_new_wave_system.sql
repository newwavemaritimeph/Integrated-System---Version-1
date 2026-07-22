begin;

create extension if not exists pgcrypto;

create or replace function public.set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

create table public.roles (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null unique,
  is_staff boolean not null default true,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  complete_name text,
  mobile text,
  account_state text not null default 'Active' check (account_state in ('Invited','Active','Suspended','Deactivated')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.user_roles (
  user_id uuid not null references public.profiles(id) on delete cascade,
  role_id uuid not null references public.roles(id),
  assigned_by uuid references public.profiles(id),
  assigned_at timestamptz not null default now(),
  primary key (user_id, role_id)
);

create or replace function public.has_staff_role() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.user_roles ur join public.roles r on r.id = ur.role_id
    where ur.user_id = auth.uid() and r.is_staff and r.active
  );
$$;

create or replace function public.has_any_role(role_codes text[]) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.user_roles ur join public.roles r on r.id = ur.role_id
    where ur.user_id = auth.uid() and r.code = any(role_codes) and r.active
  );
$$;

create table public.organization_settings (
  id boolean primary key default true check (id),
  legal_name text not null default 'New Wave Maritime Training and Assessment Center, Inc.',
  address text,
  mobile text,
  telephone text,
  public_email text,
  privacy_email text,
  office_hours text,
  privacy_notice text,
  terms_and_conditions text,
  sending_domain text,
  certificate_issuance_enabled boolean not null default false,
  launch_approved_at timestamptz,
  launch_approved_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

create table public.id_sequences (
  code text not null,
  sequence_year integer not null,
  last_value bigint not null default 0,
  primary key (code, sequence_year)
);

create or replace function public.next_reference(prefix text, requested_year integer default extract(year from now())::integer)
returns text language plpgsql security definer set search_path = public as $$
declare next_value bigint;
begin
  insert into public.id_sequences(code, sequence_year, last_value) values (upper(prefix), requested_year, 1)
  on conflict (code, sequence_year) do update set last_value = public.id_sequences.last_value + 1
  returning last_value into next_value;
  return upper(prefix) || '-' || requested_year || '-' || lpad(next_value::text, 6, '0');
end $$;

create table public.trainees (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid unique references public.profiles(id),
  trainee_number text not null unique,
  legal_first_name text not null,
  legal_middle_name text,
  legal_last_name text not null,
  birthdate date not null,
  sex text,
  nationality text,
  address text,
  mobile text not null,
  email text not null,
  srn text,
  emergency_contact jsonb not null default '{}'::jsonb,
  profile_photo_path text,
  account_state text not null default 'Active' check (account_state in ('Pending','Active','Suspended','Deactivated')),
  duplicate_reviewed_at timestamptz,
  duplicate_reviewed_by uuid references public.profiles(id),
  duplicate_review_reason text,
  registered_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index trainees_name_birthdate_idx on public.trainees(lower(legal_last_name), lower(legal_first_name), birthdate);
create index trainees_email_idx on public.trainees(lower(email));
create index trainees_mobile_idx on public.trainees(mobile);
create unique index trainees_srn_unique on public.trainees(srn) where srn is not null and srn <> '';

create table public.course_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  public_visible boolean not null default true,
  sort_order integer not null default 0,
  active boolean not null default true
);

create table public.courses (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  name text not null,
  category_id uuid references public.course_categories(id),
  delivery_type text not null check (delivery_type in ('In-House','Partner or Endorsed')),
  duration_label text not null,
  duration_days numeric(5,2),
  training_mode text,
  standard_price_centavos bigint not null check (standard_price_centavos >= 0),
  requirements_text text,
  default_capacity integer not null default 24 check (default_capacity > 0),
  google_classroom_link text,
  public_visible boolean not null default false,
  active boolean not null default true,
  source_document text,
  source_label text,
  created_by uuid references public.profiles(id),
  approved_by uuid references public.profiles(id),
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(code, delivery_type)
);
create index courses_public_idx on public.courses(public_visible, active);

create table public.course_requirements (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.courses(id) on delete cascade,
  requirement text not null,
  sort_order integer not null default 0
);

create table public.partner_centers (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  contact_details jsonb not null default '{}'::jsonb,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.partner_course_offers (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.courses(id),
  partner_center_id uuid not null references public.partner_centers(id),
  duration_label text not null,
  training_fee_centavos bigint not null check (training_fee_centavos >= 0),
  rebate_centavos bigint not null check (rebate_centavos >= 0 and rebate_centavos <= training_fee_centavos),
  partner_payable_centavos bigint generated always as (training_fee_centavos - rebate_centavos) stored,
  source_document text not null,
  source_row integer not null,
  source_label text not null,
  effective_from date not null default current_date,
  effective_to date,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(partner_center_id, course_id, effective_from)
);
create index partner_offers_center_idx on public.partner_course_offers(partner_center_id, active);

create table public.employees (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid unique references public.profiles(id),
  employee_number text not null unique,
  complete_name text not null,
  position text not null,
  employment_status text not null default 'Active',
  date_hired date not null,
  pay_type text not null check (pay_type in ('Monthly','Weekly','Daily')),
  base_rate_centavos bigint not null default 0,
  instructor_daily_rate_centavos bigint,
  government_ids jsonb not null default '{}'::jsonb,
  payroll_account jsonb not null default '{}'::jsonb,
  emergency_contact jsonb not null default '{}'::jsonb,
  leave_balances jsonb not null default '{}'::jsonb,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.classrooms (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  venue text not null,
  capacity integer not null check (capacity > 0),
  active boolean not null default true
);

create table public.instructor_qualifications (
  instructor_id uuid not null references public.employees(id) on delete cascade,
  course_id uuid not null references public.courses(id) on delete cascade,
  valid_from date not null,
  valid_until date,
  verified_by uuid references public.profiles(id),
  primary key (instructor_id, course_id, valid_from)
);

create table public.schedule_patterns (
  id uuid primary key default gen_random_uuid(),
  course_id uuid references public.courses(id) on delete cascade,
  name text not null,
  duration_days numeric(5,2) not null,
  weekdays smallint[] not null,
  default_capacity integer not null default 24,
  active boolean not null default true
);

create table public.batches (
  id uuid primary key default gen_random_uuid(),
  batch_number text not null unique,
  course_id uuid not null references public.courses(id),
  partner_offer_id uuid references public.partner_course_offers(id),
  starts_on date not null,
  ends_on date not null,
  daily_start time,
  daily_end time,
  mode text not null,
  venue text,
  classroom_id uuid references public.classrooms(id),
  capacity integer not null default 24 check (capacity > 0),
  confirmed_count integer not null default 0 check (confirmed_count >= 0 and confirmed_count <= capacity),
  enrollment_deadline timestamptz not null,
  status text not null default 'Open' check (status in ('Open','Full','Cancelled','Ongoing')),
  published_at timestamptz,
  active boolean not null default true,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_on >= starts_on)
);
create index batches_availability_idx on public.batches(status, starts_on, enrollment_deadline);

create table public.batch_training_dates (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.batches(id) on delete cascade,
  training_date date not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  unique(batch_id, training_date, starts_at)
);

create table public.resource_assignments (
  id uuid primary key default gen_random_uuid(),
  batch_training_date_id uuid not null references public.batch_training_dates(id) on delete cascade,
  instructor_id uuid not null references public.employees(id),
  classroom_id uuid references public.classrooms(id),
  assignment_state text not null default 'Assigned',
  created_at timestamptz not null default now(),
  unique(batch_training_date_id, instructor_id),
  unique(batch_training_date_id, classroom_id)
);

create table public.enrollments (
  id uuid primary key default gen_random_uuid(),
  enrollment_number text not null unique,
  trainee_id uuid not null references public.trainees(id),
  course_id uuid not null references public.courses(id),
  partner_offer_id uuid references public.partner_course_offers(id),
  batch_id uuid references public.batches(id),
  enrollment_status text not null default 'Pending' check (enrollment_status in ('Pending','Open Schedule','Enrolled','Cancelled')),
  source text,
  selling_price_centavos bigint not null check (selling_price_centavos >= 0),
  rebate_centavos bigint not null default 0 check (rebate_centavos >= 0),
  partner_payable_centavos bigint not null default 0 check (partner_payable_centavos >= 0),
  rate_snapshot jsonb not null,
  instructions_status text not null default 'Pending' check (instructions_status in ('Pending','Acknowledged')),
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  cancelled_at timestamptz
);
create index enrollments_trainee_idx on public.enrollments(trainee_id, created_at desc);
create index enrollments_batch_idx on public.enrollments(batch_id, enrollment_status);

create or replace function public.confirm_enrollment(target_enrollment uuid, target_batch uuid)
returns public.enrollments language plpgsql security definer set search_path = public as $$
declare locked_batch public.batches; result public.enrollments;
begin
  if not public.has_any_role(array['admin','registration','training_operations']) then raise exception 'Not authorized'; end if;
  select * into locked_batch from public.batches where id = target_batch for update;
  if locked_batch.id is null or locked_batch.status <> 'Open' or locked_batch.starts_on <= current_date or locked_batch.enrollment_deadline <= now() then raise exception 'Batch is not available'; end if;
  if locked_batch.confirmed_count >= locked_batch.capacity then raise exception 'Batch is full'; end if;
  update public.enrollments set batch_id = target_batch, enrollment_status = 'Enrolled', updated_at = now() where id = target_enrollment and enrollment_status in ('Pending','Open Schedule') returning * into result;
  if result.id is null then raise exception 'Enrollment cannot be confirmed'; end if;
  update public.batches set confirmed_count = confirmed_count + 1, status = case when confirmed_count + 1 >= capacity then 'Full' else status end, updated_at = now() where id = target_batch;
  return result;
end $$;

create table public.enrollment_requests (
  id uuid primary key default gen_random_uuid(), request_number text not null unique, trainee_id uuid not null references public.trainees(id), enrollment_id uuid references public.enrollments(id),
  request_type text not null, existing_values jsonb not null default '{}'::jsonb, requested_values jsonb not null default '{}'::jsonb, reason text not null,
  requester_id uuid not null references public.profiles(id), assigned_approver_id uuid references public.profiles(id), status text not null default 'Pending' check (status in ('Pending','Approved','Rejected','Returned for Clarification')),
  decision_remarks text, decided_at timestamptz, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.request_events (id uuid primary key default gen_random_uuid(), request_id uuid not null references public.enrollment_requests(id) on delete cascade, actor_id uuid not null references public.profiles(id), event_type text not null, prior_values jsonb, new_values jsonb, remarks text, created_at timestamptz not null default now());

create table public.charge_catalog (id uuid primary key default gen_random_uuid(), name text not null unique, default_amount_centavos bigint not null default 0, active boolean not null default true, used_count integer not null default 0);
create table public.enrollment_charges (id uuid primary key default gen_random_uuid(), enrollment_id uuid not null references public.enrollments(id), charge_catalog_id uuid references public.charge_catalog(id), description text not null, amount_centavos bigint not null check (amount_centavos >= 0), event_type text not null default 'charge', valid boolean not null default true, created_by uuid references public.profiles(id), created_at timestamptz not null default now());
create table public.payment_proofs (id uuid primary key default gen_random_uuid(), storage_path text not null unique, original_filename text not null, content_type text not null, extracted_reference text, verified_reference text, verified_by uuid references public.profiles(id), verified_at timestamptz, created_at timestamptz not null default now());
create table public.payments (id uuid primary key default gen_random_uuid(), payment_number text not null unique, trainee_id uuid not null references public.trainees(id), amount_centavos bigint not null check (amount_centavos > 0), method text not null, receiving_account text not null, reference_number text, received_at timestamptz not null, proof_id uuid references public.payment_proofs(id), verification_state text not null default 'Pending', event_type text not null default 'payment', valid boolean not null default true, cashier_id uuid not null references public.profiles(id), remarks text, created_at timestamptz not null default now());
create index payments_reference_idx on public.payments(reference_number) where reference_number is not null;
create table public.payment_allocations (id uuid primary key default gen_random_uuid(), payment_id uuid not null references public.payments(id), enrollment_id uuid not null references public.enrollments(id), amount_centavos bigint not null check (amount_centavos > 0), unique(payment_id, enrollment_id));
create table public.refunds_and_reversals (id uuid primary key default gen_random_uuid(), payment_id uuid references public.payments(id), enrollment_id uuid references public.enrollments(id), event_type text not null check (event_type in ('refund','reversal','adjustment')), amount_centavos bigint not null check (amount_centavos > 0), reason text not null, approved_request_id uuid references public.enrollment_requests(id), created_by uuid references public.profiles(id), created_at timestamptz not null default now());
create table public.receipts (id uuid primary key default gen_random_uuid(), receipt_number text not null unique, payment_id uuid not null references public.payments(id), snapshot jsonb not null, document_path text, issued_by uuid references public.profiles(id), issued_at timestamptz not null default now());
create table public.invoices (id uuid primary key default gen_random_uuid(), invoice_number text not null unique, enrollment_id uuid not null references public.enrollments(id), snapshot jsonb not null, revision integer not null default 1, document_path text, issued_at timestamptz not null default now(), unique(enrollment_id, revision));
create table public.cashier_closings (id uuid primary key default gen_random_uuid(), cashier_id uuid not null references public.profiles(id), closing_date date not null, opening_cash_centavos bigint not null, cash_collections_centavos bigint not null, online_collections_centavos bigint not null, refunds_centavos bigint not null, expenses_centavos bigint not null, expected_cash_centavos bigint not null, actual_cash_centavos bigint, variance_centavos bigint, remarks text, status text not null default 'Pending', submitted_at timestamptz, reviewed_by uuid references public.profiles(id), reviewed_at timestamptz, unique(cashier_id, closing_date));

create table public.expenses (id uuid primary key default gen_random_uuid(), expense_number text not null unique, payee text not null, category text not null, amount_centavos bigint not null check(amount_centavos > 0), purpose text not null, status text not null default 'Pending' check(status in ('Pending','Approved','Rejected','Paid')), requested_by uuid not null references public.profiles(id), approved_by uuid references public.profiles(id), paid_at timestamptz, created_at timestamptz not null default now());
create table public.expense_vouchers (id uuid primary key default gen_random_uuid(), voucher_number text not null unique, expense_id uuid not null unique references public.expenses(id), snapshot jsonb not null, document_path text, created_at timestamptz not null default now());
create table public.payables (id uuid primary key default gen_random_uuid(), partner_center_id uuid references public.partner_centers(id), enrollment_id uuid references public.enrollments(id), description text not null, amount_centavos bigint not null, due_on date, status text not null default 'Pending', paid_at timestamptz, created_at timestamptz not null default now());
create table public.account_reconciliation_items (id uuid primary key default gen_random_uuid(), account_name text not null, transaction_date date not null, reference text, amount_centavos bigint not null, matched_payment_id uuid references public.payments(id), status text not null default 'Unreconciled', reviewed_by uuid references public.profiles(id), created_at timestamptz not null default now());
create table public.accounting_periods (id uuid primary key default gen_random_uuid(), starts_on date not null, ends_on date not null, status text not null default 'Open', locked_by uuid references public.profiles(id), locked_at timestamptz, unique(starts_on, ends_on));

create table public.training_instruction_templates (id uuid primary key default gen_random_uuid(), course_id uuid not null references public.courses(id), version integer not null, subject text not null, body jsonb not null, approved_by uuid references public.profiles(id), approved_at timestamptz, active boolean not null default false, unique(course_id, version));
create table public.training_instructions (id uuid primary key default gen_random_uuid(), enrollment_id uuid not null references public.enrollments(id), template_id uuid not null references public.training_instruction_templates(id), snapshot jsonb not null, status text not null default 'Pending' check(status in ('Pending','Acknowledged')), sent_at timestamptz, sent_by uuid references public.profiles(id), unique(enrollment_id, template_id));
create table public.instruction_acknowledgments (id uuid primary key default gen_random_uuid(), instruction_id uuid not null unique references public.training_instructions(id), trainee_id uuid not null references public.trainees(id), acknowledged_at timestamptz not null default now(), ip_hash text);

create table public.attendance_tokens (id uuid primary key default gen_random_uuid(), enrollment_id uuid not null references public.enrollments(id), token_hash text not null unique, active boolean not null default true, expires_at timestamptz, revoked_at timestamptz, created_at timestamptz not null default now());
create unique index attendance_token_active_unique on public.attendance_tokens(enrollment_id) where active and revoked_at is null;
create table public.attendance_sessions (id uuid primary key default gen_random_uuid(), batch_training_date_id uuid not null references public.batch_training_dates(id), session_name text not null, starts_at timestamptz not null, ends_at timestamptz not null, check_in_opens_at timestamptz not null, check_in_closes_at timestamptz not null, late_threshold_minutes integer not null default 15, minimum_required_minutes integer not null, state text not null default 'Planned', started_by uuid references public.profiles(id), submitted_at timestamptz, verified_by uuid references public.profiles(id), verified_at timestamptz, unique(batch_training_date_id, session_name));
create table public.attendance_records (id uuid primary key default gen_random_uuid(), session_id uuid not null references public.attendance_sessions(id), enrollment_id uuid not null references public.enrollments(id), checked_in_at timestamptz, checked_out_at timestamptz, attended_minutes integer, status text not null check(status in ('Present','Late','Absent','Incomplete','Make-Up Required','Make-Up Completed')), method text not null check(method in ('QR','Manual','Online Import')), manual_reason text, remarks text, locked_at timestamptz, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(session_id, enrollment_id), check(method <> 'Manual' or manual_reason is not null));
create table public.attendance_events (id uuid primary key default gen_random_uuid(), attendance_record_id uuid not null references public.attendance_records(id), idempotency_key text not null unique, event_type text not null, actor_id uuid not null references public.profiles(id), event_at timestamptz not null default now(), server_payload jsonb not null, previous_status text, new_status text);
create table public.make_up_assignments (id uuid primary key default gen_random_uuid(), original_attendance_record_id uuid not null references public.attendance_records(id), enrollment_id uuid not null references public.enrollments(id), make_up_session_id uuid references public.attendance_sessions(id), charge_id uuid references public.enrollment_charges(id), status text not null default 'Pending', assigned_by uuid references public.profiles(id), completed_at timestamptz, unique(original_attendance_record_id, make_up_session_id));

create table public.certificate_templates (id uuid primary key default gen_random_uuid(), course_id uuid not null references public.courses(id), version integer not null, storage_path text not null, approved_by uuid references public.profiles(id), approved_at timestamptz, active boolean not null default false, created_at timestamptz not null default now(), unique(course_id, version));
create table public.certificate_number_pool (id uuid primary key default gen_random_uuid(), certificate_number text not null unique, course_id uuid references public.courses(id), state text not null default 'Available', assigned_at timestamptz, voided_at timestamptz);
create table public.certificates (id uuid primary key default gen_random_uuid(), enrollment_id uuid not null unique references public.enrollments(id), template_id uuid references public.certificate_templates(id), number_pool_id uuid unique references public.certificate_number_pool(id), status text not null default 'Pending Attendance' check(status in ('Pending Attendance','Ready to Print','Printed','Released','Cancelled')), snapshot jsonb, printed_by uuid references public.profiles(id), printed_at timestamptz, reprint_count integer not null default 0, ready_notified_at timestamptz, created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table public.certificate_release_events (id uuid primary key default gen_random_uuid(), certificate_id uuid not null references public.certificates(id), event_type text not null, recipient_name text, recipient_id_type text, released_by uuid references public.profiles(id), reason text, created_at timestamptz not null default now());

create table public.employee_attendance (id uuid primary key default gen_random_uuid(), employee_id uuid not null references public.employees(id), attendance_date date not null, checked_in_at timestamptz, checked_out_at timestamptz, minutes_late integer not null default 0, minutes_undertime integer not null default 0, status text not null, remarks text, unique(employee_id, attendance_date));
create table public.leave_requests (id uuid primary key default gen_random_uuid(), employee_id uuid not null references public.employees(id), leave_type text not null, starts_on date not null, ends_on date not null, reason text not null, status text not null default 'Pending', approved_by uuid references public.profiles(id), created_at timestamptz not null default now());
create table public.employee_charges (id uuid primary key default gen_random_uuid(), employee_id uuid not null references public.employees(id), description text not null, amount_centavos bigint not null, effective_on date not null, status text not null default 'Active');
create table public.cash_advances (id uuid primary key default gen_random_uuid(), employee_id uuid not null references public.employees(id), amount_centavos bigint not null, requested_on date not null, balance_centavos bigint not null, status text not null default 'Pending', approved_by uuid references public.profiles(id));
create table public.payroll_components (id uuid primary key default gen_random_uuid(), code text not null unique, name text not null, component_type text not null check(component_type in ('Earning','Deduction')), calculation_method text not null, configuration jsonb not null default '{}'::jsonb, effective_from date not null, effective_to date, active boolean not null default true);
create table public.payroll_periods (id uuid primary key default gen_random_uuid(), period_number text not null unique, starts_on date not null, ends_on date not null, pay_date date not null, status text not null default 'Draft', reviewed_by uuid references public.profiles(id), finalized_by uuid references public.profiles(id), finalized_at timestamptz);
create table public.payroll_items (id uuid primary key default gen_random_uuid(), payroll_period_id uuid not null references public.payroll_periods(id), employee_id uuid not null references public.employees(id), gross_centavos bigint not null, deduction_centavos bigint not null, net_centavos bigint not null, breakdown jsonb not null, unique(payroll_period_id, employee_id));
create table public.payslips (id uuid primary key default gen_random_uuid(), payroll_item_id uuid not null unique references public.payroll_items(id), snapshot jsonb not null, document_path text, published_at timestamptz);
create table public.benefit_records (id uuid primary key default gen_random_uuid(), employee_id uuid not null references public.employees(id), benefit_type text not null, reference text, amount_centavos bigint, effective_from date, effective_to date);
create table public.coe_requests (id uuid primary key default gen_random_uuid(), employee_id uuid not null references public.employees(id), purpose text not null, status text not null default 'Pending', requested_at timestamptz not null default now(), completed_at timestamptz, document_path text);

create table public.notifications (id uuid primary key default gen_random_uuid(), recipient_id uuid not null references public.profiles(id), notification_type text not null, title text not null, body text not null, related_record_type text, related_record_id uuid, deep_link text, read_at timestamptz, created_at timestamptz not null default now());
create index notifications_unread_idx on public.notifications(recipient_id, created_at desc) where read_at is null;
create table public.email_templates (id uuid primary key default gen_random_uuid(), template_code text not null, version integer not null, subject text not null, body_html text not null, body_text text not null, active boolean not null default false, created_at timestamptz not null default now(), unique(template_code, version));
create table public.email_jobs (id uuid primary key default gen_random_uuid(), idempotency_key text not null unique, template_code text not null, recipient text not null, variables jsonb not null, scheduled_for timestamptz not null default now(), state text not null default 'Queued', attempts integer not null default 0, last_error text, sent_at timestamptz, created_at timestamptz not null default now());
create index email_jobs_queue_idx on public.email_jobs(state, scheduled_for);
create table public.email_logs (id uuid primary key default gen_random_uuid(), email_job_id uuid references public.email_jobs(id), provider_message_id text unique, event_type text not null, provider_payload jsonb not null, occurred_at timestamptz not null, created_at timestamptz not null default now());
create table public.announcements (id uuid primary key default gen_random_uuid(), title text not null, body text not null, audience_roles text[] not null, published_at timestamptz, expires_at timestamptz, created_by uuid references public.profiles(id));
create table public.file_attachments (id uuid primary key default gen_random_uuid(), record_type text not null, record_id uuid not null, storage_bucket text not null, storage_path text not null, original_filename text not null, content_type text not null, uploaded_by uuid references public.profiles(id), created_at timestamptz not null default now(), unique(storage_bucket, storage_path));
create table public.document_versions (id uuid primary key default gen_random_uuid(), document_type text not null, record_type text not null, record_id uuid not null, revision integer not null, snapshot jsonb not null, storage_path text, generated_by uuid references public.profiles(id), generated_at timestamptz not null default now(), unique(document_type, record_id, revision));
create table public.incidents (id uuid primary key default gen_random_uuid(), batch_id uuid references public.batches(id), reported_by uuid not null references public.profiles(id), category text not null, description text not null, severity text not null, resolution text, created_at timestamptz not null default now(), resolved_at timestamptz);
create table public.contact_messages (id uuid primary key default gen_random_uuid(), complete_name text not null, email text not null, mobile text, message text not null, ip_hash text, created_at timestamptz not null default now(), resolved_at timestamptz);
create table public.rate_limits (key_hash text not null, action text not null, window_started_at timestamptz not null, request_count integer not null default 1, primary key(key_hash, action, window_started_at));
create table public.audit_logs (id uuid primary key default gen_random_uuid(), actor_id uuid references public.profiles(id), actor_role text, action text not null, record_type text not null, record_id text not null, prior_values jsonb, new_values jsonb, reason text, correlation_id uuid not null default gen_random_uuid(), request_ip_hash text, created_at timestamptz not null default now());
create index audit_record_idx on public.audit_logs(record_type, record_id, created_at desc);

create or replace function public.prevent_immutable_change() returns trigger language plpgsql as $$ begin raise exception 'Immutable records cannot be changed or deleted'; end $$;
create trigger audit_logs_immutable before update or delete on public.audit_logs for each row execute function public.prevent_immutable_change();
create trigger attendance_events_immutable before update or delete on public.attendance_events for each row execute function public.prevent_immutable_change();
create trigger email_logs_immutable before update or delete on public.email_logs for each row execute function public.prevent_immutable_change();

do $$ declare table_name text; begin
  foreach table_name in array array['profiles','trainees','courses','partner_course_offers','employees','batches','enrollments','enrollment_requests','attendance_records','certificates'] loop
    execute format('create trigger %I_set_updated_at before update on public.%I for each row execute function public.set_updated_at()', table_name, table_name);
  end loop;
end $$;

-- All application tables use RLS. Service-role server functions bypass these policies.
do $$ declare table_name text; begin
  foreach table_name in array array[
    'roles','profiles','user_roles','organization_settings','id_sequences','trainees','course_categories','courses','course_requirements','partner_centers','partner_course_offers','employees','classrooms','instructor_qualifications','schedule_patterns','batches','batch_training_dates','resource_assignments','enrollments','enrollment_requests','request_events','charge_catalog','enrollment_charges','payment_proofs','payments','payment_allocations','refunds_and_reversals','receipts','invoices','cashier_closings','expenses','expense_vouchers','payables','account_reconciliation_items','accounting_periods','training_instruction_templates','training_instructions','instruction_acknowledgments','attendance_tokens','attendance_sessions','attendance_records','attendance_events','make_up_assignments','certificate_templates','certificate_number_pool','certificates','certificate_release_events','employee_attendance','leave_requests','employee_charges','cash_advances','payroll_components','payroll_periods','payroll_items','payslips','benefit_records','coe_requests','notifications','email_templates','email_jobs','email_logs','announcements','file_attachments','document_versions','incidents','contact_messages','rate_limits','audit_logs'
  ] loop execute format('alter table public.%I enable row level security', table_name); end loop;
end $$;

create policy profiles_self_or_staff_read on public.profiles for select to authenticated using (id = auth.uid() or public.has_staff_role());
create policy profiles_self_update on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy roles_staff_read on public.roles for select to authenticated using (public.has_staff_role());
create policy user_roles_self_or_admin_read on public.user_roles for select to authenticated using (user_id = auth.uid() or public.has_any_role(array['admin','hr']));
create policy trainees_self_or_staff_read on public.trainees for select to authenticated using (profile_id = auth.uid() or public.has_staff_role());
create policy trainees_registration_write on public.trainees for all to authenticated using (public.has_any_role(array['admin','registration'])) with check (public.has_any_role(array['admin','registration']));
create policy public_courses_read on public.courses for select to anon, authenticated using (public_visible and active or public.has_staff_role());
create policy public_categories_read on public.course_categories for select to anon, authenticated using (public_visible and active or public.has_staff_role());
create policy public_batches_read on public.batches for select to anon, authenticated using ((published_at is not null and status = 'Open' and starts_on > current_date and enrollment_deadline > now()) or public.has_staff_role());
create policy staff_partner_centers_read on public.partner_centers for select to authenticated using (public.has_staff_role());
create policy staff_partner_offers_read on public.partner_course_offers for select to authenticated using (public.has_staff_role());
create policy finance_partner_offers_write on public.partner_course_offers for all to authenticated using (public.has_any_role(array['admin','accounting'])) with check (public.has_any_role(array['admin','accounting']));
create policy enrollment_owner_or_staff_read on public.enrollments for select to authenticated using (public.has_staff_role() or exists(select 1 from public.trainees t where t.id = trainee_id and t.profile_id = auth.uid()));
create policy enrollment_staff_write on public.enrollments for all to authenticated using (public.has_any_role(array['admin','registration','training_operations'])) with check (public.has_any_role(array['admin','registration','training_operations']));
create policy notification_owner_read on public.notifications for select to authenticated using (recipient_id = auth.uid());
create policy notification_owner_update on public.notifications for update to authenticated using (recipient_id = auth.uid()) with check (recipient_id = auth.uid());
create policy audit_authorized_read on public.audit_logs for select to authenticated using (public.has_any_role(array['admin','accounting']));

-- Broad staff read access supports cross-functional operations; write access remains server-command controlled.
do $$ declare table_name text; begin
  foreach table_name in array array['course_requirements','employees','classrooms','instructor_qualifications','schedule_patterns','batch_training_dates','resource_assignments','enrollment_requests','request_events','charge_catalog','enrollment_charges','payment_proofs','payments','payment_allocations','refunds_and_reversals','receipts','invoices','cashier_closings','expenses','expense_vouchers','payables','account_reconciliation_items','accounting_periods','training_instruction_templates','training_instructions','attendance_sessions','attendance_records','attendance_events','make_up_assignments','certificate_templates','certificate_number_pool','certificates','certificate_release_events','employee_attendance','leave_requests','employee_charges','cash_advances','payroll_components','payroll_periods','payroll_items','payslips','benefit_records','coe_requests','announcements','file_attachments','document_versions','incidents'] loop
    execute format('create policy %I_staff_read on public.%I for select to authenticated using (public.has_staff_role())', table_name, table_name);
  end loop;
end $$;

insert into public.roles(code,name,is_staff) values
('admin','Admin',true),('registration','Registration Officer',true),('cashier','Cashier',true),('accounting','Accounting Manager',true),('training_operations','Training Operations Officer',true),('hr','HR Officer',true),('instructor','Instructor',true),('trainee','Trainee',false)
on conflict(code) do nothing;

insert into public.organization_settings(id, legal_name, address, mobile, telephone, public_email, certificate_issuance_enabled) values
(true, 'New Wave Maritime Training and Assessment Center, Inc.', '103 Bel Air Apartments, 1020 Roxas Boulevard, Ermita, Manila 1000', '+63 948 847 6530', '8553 0310', 'newwavemaritime@gmail.com', false)
on conflict(id) do nothing;

insert into public.course_categories(name,public_visible,sort_order) values
('Upcoming MARINA STCW',true,10),('MARINA Domestic',true,20),('Maritime In-House',true,30),('Catering (ILO / MLC 2006)',true,40),('Partner or Endorsed',true,50)
on conflict(name) do nothing;

insert into public.charge_catalog(name,default_amount_centavos) values
('Rescheduling Fee',0),('Cancellation Fee',0),('Uniform',0),('Make-Up Class Fee',0),('Certificate Reprinting',0),('Courier or Delivery Fee',0)
on conflict(name) do nothing;

commit;
