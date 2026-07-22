# New Wave Maritime Integrated Management System

A responsive public website and role-based operations portal for New Wave Maritime Training and Assessment Center, Inc. The application uses Next.js/Vinext for Sites hosting and Supabase for Postgres, authentication, private storage, and Row Level Security.

## Included catalogs

- 148 New Wave courses from the 2025 course list, including price, duration, category, and modality
- 96 endorsed partner-center offers from the July 2026 endorsements list
- Partner training fee, New Wave rebate, and partner payable snapshots for staff accounting

Public users see a simplified, price-free list grouped into STCW Courses, In-House Courses, and Endorsed Trainings. Center, price, rebate, and payable values remain available only to authorized staff workflows.

## Local setup

1. Copy `.env.example` to `.env.local` and add the Supabase, Resend, and scheduled-job credentials.
2. Apply `supabase/migrations` to a clean Supabase project.
3. Run `npm run db:seed` to load both catalogs.
4. Run `npm run dev`.

Useful checks:

```bash
npm test
npx tsc --noEmit
npm run lint
npm run build
```

## Production gate

The Admin launch checklist must be complete before publishing: legal/privacy content, terms, sending domain, authorized staff accounts, receiving accounts, payroll settings, and approved templates. Certificate issuance is disabled by default and remains blocked until an approved active certificate template is uploaded.

Required variables are documented in `.env.example`. Service-role, scheduled-job, webhook, and Resend secrets are server-only and must never be exposed to browser bundles.
