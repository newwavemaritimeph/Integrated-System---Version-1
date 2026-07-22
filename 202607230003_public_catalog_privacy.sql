begin;

-- Public and trainee sessions can read course descriptions needed by the website,
-- but cannot select price or approval metadata directly from the catalog table.
revoke select on public.courses from anon, authenticated;
grant select (id, code, name, category_id, delivery_type, duration_label, duration_days, training_mode, requirements_text, default_capacity, public_visible, active) on public.courses to anon, authenticated;

create or replace function public.staff_course_financial_catalog()
returns table (
  course_id uuid,
  course_code text,
  course_name text,
  standard_price_centavos bigint,
  offer_id uuid,
  center_name text,
  training_fee_centavos bigint,
  rebate_centavos bigint,
  partner_payable_centavos bigint,
  duration_label text,
  offer_active boolean
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_staff_role() then raise exception 'Not authorized'; end if;
  return query
  select c.id, c.code, c.name, c.standard_price_centavos, o.id, pc.name,
    o.training_fee_centavos, o.rebate_centavos, o.partner_payable_centavos,
    coalesce(o.duration_label, c.duration_label), coalesce(o.active, c.active)
  from public.courses c
  left join public.partner_course_offers o on o.course_id = c.id
  left join public.partner_centers pc on pc.id = o.partner_center_id
  where c.active
  order by c.name, pc.name;
end $$;

revoke all on function public.staff_course_financial_catalog() from public, anon;
grant execute on function public.staff_course_financial_catalog() to authenticated;

commit;
