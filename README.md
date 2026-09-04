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

## 2026-09-03 — New-stock purchase foreign-key fix

Run `supabase/migrations/20260903_new_stock_purchase_link.sql` in Supabase SQL Editor before adding New Item Stock with this version.

The migration preserves the existing `purchases.stock_id` foreign key and adds `purchases.new_product_id` for quantity-stock batches. New-stock purchases use a null legacy stock reference. The `create_new_stock_purchase` RPC saves the batch, optional serials, purchase and ledger in one transaction under the signed-in user's existing RLS permissions. If any insert fails, all of that attempt's inserts roll back.

The migration does not delete records or change balances. An earlier failed attempt may already have saved a batch without its purchase and ledger; inspect those records before retrying or repairing them. No automatic historical repair is included.

## Payment Management — non-negative balances and Cash to Bank

Apply `supabase/migrations/20260903_payment_balances.sql` in Supabase SQL Editor after the earlier migrations. The file adds database enforcement for non-negative current cash/bank balances, atomic ledger replacement for payment edits, and `transfer_cash_to_bank` for Staff and Admin. It preserves the existing bank/settings write policies and uses the caller's RLS permissions for transfer ledger writes. Two narrowly scoped trigger functions serialize balance changes and read all ledger entries for validation; they are not callable by app users.

- Payment Management → Total Balance → **Transfer Cash to Bank** decreases cash and increases the chosen bank by the same amount. Transfers are internal movements, not sales, purchases or expenses.
- A transfer request ID prevents repeated submission of the same form from creating another pair of entries.
- Spending, receipt deletion and opening-balance changes that would leave a negative current balance are rejected. This is a current-balance rule, not a historical day-by-day balance reconstruction.
- Section action buttons appear on the left and section titles on the right.
- The Purchases page no longer has a New Purchase button; stock-entry flows still create purchases.

No existing negative balances are silently reset. If old records already leave an account negative or a bank ledger entry without a bank, reconcile those records before further changes. The migration does not repair them. The older multi-request client workflows remain non-atomic as a whole; database balance guards prevent a negative ledger balance, but another part of a workflow may already have saved before a later concurrent-accounting error. New-stock creation and Cash to Bank transfers are atomic.

Validation: production build and isolated PostgreSQL tests for both roles, insufficient-funds rollback, zero balances, transfer retry deduplication, opening-balance protection and receipt edit/delete protection. Live Supabase policies and constraints must still be verified after application.

## Bank to Cash transfers

After applying `20260903_payment_balances.sql`, apply `supabase/migrations/20260903_payment_transfers_both_directions.sql` in Supabase SQL Editor. Payment Management now offers **Cash → Bank** and **Bank → Cash** to Staff and Admin. The selected source must have sufficient funds; the combined balance stays unchanged. Existing transfers default to the Cash to Bank direction. Both APIs share atomic writes and request deduplication, including protection against reusing a request ID in the opposite direction.

## Sale and due-payment amount limits

Apply `supabase/migrations/20260903_payment_amount_limits.sql` after the prior payment migrations. New sales cap Amount Received at the sale total (unit price × quantity for new stock). Due forms reject amounts above the outstanding balance instead of silently reducing them. `pay_outstanding_due` locks the current sale/purchase, checks its latest outstanding amount, and saves the payment and ledger together under existing RLS permissions. Existing invalid sale rows are not rewritten; the new check applies to future inserts and updates. Live Supabase migration application is still required.

## Multi-item New Stock bills and service charges

Apply `supabase/migrations/20260903_multi_item_sales.sql` after the earlier migrations. In New Sale, select **New Stock**, use **+ Add Item** for each product, and enter its quantity, unit selling price and optional serials. Use one line per batch; increase its quantity for multiple units. **Service Charge** is optional and defaults to zero. Amount Received is capped at the combined bill total.

Each bill is one sale/invoice with item snapshots (`sales.line_items`) and a separate `service_charge`. The database validates current stock/serials and computes totals, then saves all items and the receipt atomically. Dues and sales totals use the combined amount; profit deducts each item's saved purchase cost. Admin deletion restores all item quantities/serials and reverses the sale ledger atomically, subject to balance protection. New-stock bill editing remains disabled; corrections use delete/re-enter as before.

Browser print and WhatsApp PDFs show every item and service charge separately; long PDFs paginate with repeated column headers. Old Stock and earlier single-item invoices retain their existing behavior. Existing records are not converted. Tested with fictional PostgreSQL records and rendered one/two-page PDFs; live Supabase application and live WhatsApp delivery remain unverified.


### Searchable new stock and billing / required serials

Apply `supabase/migrations/20260903_new_stock_serial_tracking.sql` after `20260903_new_stock_purchase_link.sql` and `20260903_multi_item_sales.sql` and their prerequisites. This replaces the earlier optional-serial entry workflow. New Stock inventory searches item details, seller and serials; entry has searchable item history, type, seller and bank. Select whether each incoming batch has serial numbers. Serialized batches require one unique serial per unit; quantity-only batches need none. Existing batches retain their previous serial policy; no historical classification is inferred or records rewritten.

New Stock bills use searchable available items and a bill grid. Search by type, brand, model, stock ID or serial; arrow keys and Enter add a result. Scanning an exact available serial adds its item and selects that serial. Enter each selling rate explicitly. Serialized items require one selected serial per unit, checked both in the form and the atomic sale RPC. Multiple items, service charges, receipt limits, invoice printing and deletion/restoration are retained. Old Stock billing is unchanged. Apply the migration before using the new entry workflow; no live migration is applied by a build.


### Partial new-stock purchase payments and searchable contacts

Apply `supabase/migrations/20260903_new_stock_partial_payment.sql` after the serial-tracking migration. New-item purchases default Amount Paid to the full total; enter a smaller amount (including zero) to create seller dues automatically. Only Amount Paid leaves cash/bank. The atomic purchase function validates the payment range and calculates the outstanding amount; later payments use the existing Pay Seller workflow. Existing purchase records are preserved.

Buyer and seller fields support searching names, phone numbers and locations. Use Add new buyer/seller inside the entry form to save and select a contact without discarding the draft. Name, phone and Location / Address are required for new contacts, including entries in Customers & Suppliers. Location uses the existing address column. Saving a contact adds it to the contact list immediately, even if the bill is later cancelled.


### New Stock bill item selection

Search and select a product to open its item panel. The panel shows available quantity beside purchase price per unit. Enter quantity and selling price, select available serials when applicable, then click Add to Bill. Selecting a result alone does not add it. After adding, search is cleared and focused for the next product. Bill rows support Edit and Remove. Selecting an existing bill product edits its row rather than duplicating it; Cancel leaves the bill unchanged. Existing billing totals, service charges, payment limits and Old Stock behavior are preserved. This interface change needs no new SQL migration.


### Person-based dues

Dues now lists one row per buyer or seller who has an outstanding balance. The row total is the sum of that person's open transactions. **View Transactions** opens the person's full sales or purchase history, including paid transactions, in newest-first order. Payment actions remain attached to the individual outstanding invoice or purchase so existing atomic payment validation and accounting remain unchanged. This display change requires no new SQL migration.


### Person account ledger and account-level payments

Apply `supabase/migrations/20260903_person_due_payments.sql` after `20260903_payment_amount_limits.sql`. Inside a buyer or seller, transactions appear as an account ledger with Date, Particulars, Reference, Debit, Credit and running Balance. The single Receive Payment or Pay Seller action is positioned beside the phone summary and is capped by the person's current total outstanding amount.

A partial account payment is allocated to the oldest outstanding invoices or purchases first. The allocation and one cash/bank ledger entry are saved atomically. Retrying the same request does not duplicate the payment. Transaction rows no longer contain separate payment buttons. Existing individual due payments remain visible in the account ledger and no historical records are rewritten.


### New Stock hierarchy and invoice serial layout

New Stock inventory is grouped as Item Type → Brand → Model. Expanding a model shows its purchase batches, quantities, serial tracking, purchase price and seller. Search filters the hierarchy and expands matching levels automatically. No stock records or identifiers are changed.

Browser and WhatsApp PDF invoices no longer use a separate Serial No. column. When an item has serial numbers, they print directly below its description as `S/N - XXXXX, XXXXX, XXXXX` at 70% of the description font size. This presentation change requires no SQL migration.


### Password reset using email OTP

The login page now includes **Reset password with email OTP** for existing staff/admin accounts. Staff verify the recovery code sent to their registered email (including Gmail) and set a new password. No new account is created, and the recovery session does not replace the normal login session. See `supabase/PASSWORD_RESET_SETUP.md` and `supabase/templates/reset-password-otp.html` for the required Supabase email-template and SMTP configuration. This is Auth configuration, not a SQL migration. Live delivery has not been verified.

### Grouped New Stock and FIFO

Matching item type, brand and model (ignoring case and outer spaces) display as one product. Quantities are summed, purchase prices shown as a range, and sellers separated by commas. Original purchase batches remain for costs, dues and deletion. New-stock billing splits quantities across original batches, oldest purchase date first; same-date ties use creation time then ID. Available serial choices use the same batch order, then serial creation time and ID. Apply `supabase/migrations/20260904_new_stock_fifo.sql` after the serial-tracking migration to enforce non-serial FIFO in the database. This migration does not merge or rewrite existing records.
