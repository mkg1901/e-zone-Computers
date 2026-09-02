# EZR — Fully Automatic WhatsApp Invoice Setup

This version sends the invoice PDF directly from the EZR server through the WhatsApp Business Platform. The browser does not open WhatsApp and the access token is never exposed to client-side JavaScript.

## Required WhatsApp template

Create and obtain approval for a utility template with:

- Template name: `ezr_sale_invoice` (or set your approved name in `.env.local`)
- Header: **Document**
- Body with exactly three text variables, in this order:
  1. Customer name
  2. Invoice number
  3. Invoice amount

Suggested body wording:

`Hello {{1}}, thank you for shopping with E-Zone Computers. Your invoice {{2}} for {{3}} is attached.`

Use the exact approved template name and language code in the environment variables.

## Environment variables

Copy your existing Supabase variables from the previous EZR project and add:

```env
WHATSAPP_GRAPH_API_VERSION=YOUR_GRAPH_API_VERSION
WHATSAPP_PHONE_NUMBER_ID=YOUR_PHONE_NUMBER_ID
WHATSAPP_ACCESS_TOKEN=YOUR_ACCESS_TOKEN
WHATSAPP_INVOICE_TEMPLATE_NAME=ezr_sale_invoice
WHATSAPP_INVOICE_TEMPLATE_LANGUAGE=en
```

Do not prefix the access token with `NEXT_PUBLIC_`. It must remain server-side only.

## Database migration

Run `supabase/migrations/20260902_whatsapp_invoice_delivery.sql` in the Supabase SQL Editor after the earlier invoice/new-stock migration.

## User flow

Sales now have separate **Invoice** and **Send WhatsApp** actions. Reprinting an invoice does not resend it. Pressing **Send WhatsApp** asks for confirmation, generates the PDF on the Next.js server, uploads it to WhatsApp, sends the approved template with the PDF document, and records the attempt in `invoice_whatsapp_deliveries` as Pending, Sent, or Failed.
