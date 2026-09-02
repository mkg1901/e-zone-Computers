# EZR Modern — Next.js + TypeScript

This project is a behavior-preserving migration of the supplied `index (17).html` EZR application to a modern Next.js/React/TypeScript structure with a white/light UI.

## What was migrated

- Supabase email/password authentication and profile-role lookup
- Admin-only navigation for Payment Management, Reports and Admin Panel
- Dashboard with monthly totals and live balances
- Transactions and ledger
- Stock management, including sold/blocked/in-stock states
- Add Parts / Remove Parts and accessory blocking/restoration
- Sales, edit/delete, stock sale state and ledger effects
- Purchases, edit/delete, auto-created stock and ledger effects
- Customer and seller dues with part-payment handling
- Customers and suppliers management
- Cash/bank opening balances and bank management
- Expenses with edit/delete and ledger reversal/rebuild
- Call Lodge with Open/Closed states and mandatory service note on closure
- Reports and CSV export / browser print-to-PDF
- Admin-managed accessory types
- Global search
- Supabase Realtime refresh
- Future-date blocking

## Structure

- `src/app/` — Next.js App Router shell and global light theme
- `src/components/ezr/EzrApp.tsx` — React application and feature views
- `src/lib/ezr-data.ts` — Supabase data access / mapping
- `src/lib/ezr-utils.ts` — accounting/date/inventory helpers
- `src/lib/supabase/client.ts` — environment-based Supabase client
- `src/types/ezr.ts` — TypeScript domain types
- `public/original-ezr.html` — untouched source supplied for migration reference

## Setup

1. Install Node.js 20+ (Node 22 LTS is recommended).
2. Run `npm install`.
3. Copy `.env.example` to `.env.local` and enter the Supabase project URL and anon/publishable key. A local `.env.local` matching the supplied app is included in this handoff and is ignored by Git.
4. Run `npm run dev`.
5. Open `http://localhost:3000`.

The migration intentionally keeps the existing Supabase table names and `generate_id` RPC so it can operate against the current database schema and RLS policies.

## Important deployment note

The browser uses a Supabase anon/publishable key, which is expected to be public. Database security must continue to be enforced by Supabase Row Level Security. Never replace the browser key with a Supabase service-role key.

## Verification note

The source tree was syntax-checked locally with TypeScript parsing. Package installation/build could not be completed in the handoff environment because registry installation timed out, so run `npm install && npm run build` on a machine with normal npm connectivity before production deployment.

## 2026-09-01 — Invoice + New Item Stock upgrade

This build adds two new capabilities while preserving the existing stock workflow.

### Sale invoice

- Every sale row now has an **Invoice** button.
- The invoice opens in a print-friendly window and can be printed or saved as PDF from the browser.
- Admin Panel now contains **Shop / Invoice Settings** for Shop Name, Address, Phone, Email, GSTIN, State, State Code and Invoice Terms.
- Existing invoice IDs continue to come from the existing `invoice_seq` / `generate_id()` flow.
- This version prints the shop GSTIN but does **not** calculate GST tax components automatically. Product tax rates can be added later without changing the invoice numbering model.

### New Item Stock

Stock now has a third tab named **New Item Stock**. This inventory is quantity-based and separate from the existing individually-tracked Laptop/Desktop/Accessory records.

New Item Stock entry captures Accessory Type, Brand, Model No., Quantity, optional serial numbers, per-unit purchase price, date, seller and payment source. Brand and model values already used in New Item Stock are offered as browser suggestions on future entries. Serial numbers are optional; when supplied, each is tracked individually.

Sales can now use either **Existing / Used Stock** or **New Item Stock**. Selling New Item Stock reduces the available quantity and optionally marks selected serial numbers as sold. Deleting that sale as Admin restores the quantity and serial numbers. New Item Stock purchase records flow into Purchases, Ledger, Dashboard totals, Dues and Reports.

### Required Supabase migration

Before opening this upgraded build against the live database, run this file once in **Supabase Dashboard → SQL Editor**:

`supabase/migrations/20260901_invoice_new_stock.sql`

The migration is incremental. It creates the new quantity-stock tables and adds new sale columns; it does not delete or replace existing stock, sales or purchase rows.

After running the migration, restart the development server:

```powershell
npm.cmd run dev
```

Recommended first test: add one New Item Stock batch with quantity 2 and two serial numbers, sell one unit, print its invoice, then confirm the remaining quantity is 1 and the selected serial is no longer available for another sale.

## v3 — Fully automatic WhatsApp invoice delivery

After running `supabase/migrations/20260902_whatsapp_invoice_delivery.sql` and configuring the server-only `WHATSAPP_*` environment variables, Sales includes a **Send WhatsApp** button. It generates the PDF on the server, uploads it through the WhatsApp Business Platform, sends the approved invoice template, and records every attempt in `invoice_whatsapp_deliveries`.

See `WHATSAPP_SETUP.md` for the required template shape and setup steps.


## v4 — Payment Management balance visibility + Cash/Bank UX fix

- Payment Management is now visible to both Admin and Staff.
- Added a **Total Balance** tab showing Cash Balance, Total Bank Balance, Total Available Balance, and a bank-wise read-only breakdown.
- Staff can view Total Balance only. Bank account management and opening-balance editing remain Admin-only.
- Fixed payment forms so the **Bank** selector is hidden whenever Payment Mode is **Cash** and appears only when **Online** is selected.
- The Cash/Online fix applies to transactions, sales, purchases, due payments, expenses, existing stock purchases, and new-item stock purchases.
