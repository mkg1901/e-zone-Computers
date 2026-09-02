import { createClient } from '@supabase/supabase-js';
import { PDFDocument, StandardFonts, rgb } from 'pdf-lib';

export type WhatsAppConfig = {
  graphVersion: string;
  phoneNumberId: string;
  accessToken: string;
  templateName: string;
  templateLanguage: string;
};

export function getWhatsAppConfig(): WhatsAppConfig {
  const graphVersion = process.env.WHATSAPP_GRAPH_API_VERSION?.trim();
  const phoneNumberId = process.env.WHATSAPP_PHONE_NUMBER_ID?.trim();
  const accessToken = process.env.WHATSAPP_ACCESS_TOKEN?.trim();
  const templateName = process.env.WHATSAPP_INVOICE_TEMPLATE_NAME?.trim();
  const templateLanguage = process.env.WHATSAPP_INVOICE_TEMPLATE_LANGUAGE?.trim() || 'en';
  const missing = [
    ['WHATSAPP_GRAPH_API_VERSION', graphVersion],
    ['WHATSAPP_PHONE_NUMBER_ID', phoneNumberId],
    ['WHATSAPP_ACCESS_TOKEN', accessToken],
    ['WHATSAPP_INVOICE_TEMPLATE_NAME', templateName],
  ].filter(([, value]) => !value).map(([key]) => key);
  if (missing.length) throw new Error(`WhatsApp is not configured. Missing: ${missing.join(', ')}`);
  return { graphVersion: graphVersion!, phoneNumberId: phoneNumberId!, accessToken: accessToken!, templateName: templateName!, templateLanguage };
}

export function getUserSupabase(authorization: string | null) {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anon = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  const token = authorization?.startsWith('Bearer ') ? authorization.slice(7).trim() : '';
  if (!url || !anon) throw new Error('Missing Supabase environment variables.');
  if (!token) throw new Error('You are not signed in.');
  const sb = createClient(url, anon, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return { sb, token };
}

export function normalizeWhatsAppPhone(input: string) {
  let digits = String(input || '').replace(/\D/g, '');
  if (!digits) throw new Error('Customer does not have a mobile number.');
  // EZR is primarily used in India. Ten-digit local numbers are normalized to +91.
  if (digits.length === 10) digits = `91${digits}`;
  else if (digits.length === 11 && digits.startsWith('0')) digits = `91${digits.slice(1)}`;
  if (digits.length < 11 || digits.length > 15) throw new Error('Customer mobile number is not valid for WhatsApp.');
  return digits;
}

function money(value: number) {
  return `INR ${Number(value || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

function safe(value: unknown) {
  return String(value ?? '').trim();
}

function wrapText(text: string, maxChars: number) {
  const words = safe(text).split(/\s+/).filter(Boolean);
  const lines: string[] = [];
  let line = '';
  for (const word of words) {
    const test = line ? `${line} ${word}` : word;
    if (test.length > maxChars && line) { lines.push(line); line = word; }
    else line = test;
  }
  if (line) lines.push(line);
  return lines.length ? lines : [''];
}

export async function buildInvoicePdf(input: {
  sale: any;
  customer: any;
  settings: Record<string, string>;
}) {
  const { sale, customer, settings } = input;
  const pdf = await PDFDocument.create();
  const page = pdf.addPage([595.28, 841.89]);
  const regular = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const { width, height } = page.getSize();
  const margin = 45;
  let y = height - margin;
  const draw = (text: string, x: number, size = 10, isBold = false) => {
    page.drawText(safe(text), { x, y, size, font: isBold ? bold : regular, color: rgb(0.08, 0.08, 0.08) });
  };
  const line = (fromX: number, toX: number, atY: number, thickness = 1) => page.drawLine({ start: { x: fromX, y: atY }, end: { x: toX, y: atY }, thickness, color: rgb(0.35, 0.35, 0.35) });

  const shopName = settings.shop_name || 'e-Zone Computers';
  draw(shopName, margin, 20, true);
  page.drawText('SALE INVOICE', { x: width - margin - 120, y, size: 15, font: bold });
  y -= 22;
  for (const addressLine of wrapText(settings.shop_address || '', 62).slice(0, 3)) { draw(addressLine, margin, 9); y -= 12; }
  if (settings.shop_phone) { draw(`Phone: ${settings.shop_phone}`, margin, 9); y -= 12; }
  if (settings.shop_email) { draw(`Email: ${settings.shop_email}`, margin, 9); y -= 12; }
  if (settings.shop_gstin) { draw(`GSTIN: ${settings.shop_gstin}`, margin, 9); y -= 12; }
  const stateLine = [settings.shop_state, settings.shop_state_code ? `State Code: ${settings.shop_state_code}` : ''].filter(Boolean).join(' | ');
  if (stateLine) { draw(stateLine, margin, 9); y -= 12; }

  page.drawText(`Invoice: ${safe(sale.bill_no || sale.id)}`, { x: width - margin - 170, y: height - margin - 28, size: 10, font: bold });
  page.drawText(`Date: ${safe(sale.date)}`, { x: width - margin - 170, y: height - margin - 44, size: 10, font: regular });
  line(margin, width - margin, y - 2, 1.4);
  y -= 24;

  draw('Bill To', margin, 11, true); y -= 16;
  draw(safe(sale.buyer_name || customer?.name || 'Customer'), margin, 10, true); y -= 14;
  for (const addr of wrapText(customer?.address || '', 70).slice(0, 3)) { if (addr) { draw(addr, margin, 9); y -= 12; } }
  if (customer?.phone) { draw(`Phone: ${customer.phone}`, margin, 9); y -= 12; }
  if (customer?.gstin) { draw(`GSTIN: ${customer.gstin}`, margin, 9); y -= 12; }
  y -= 8;

  const cols = [margin, margin + 30, margin + 260, margin + 360, margin + 405, width - margin];
  const rowTop = y;
  line(margin, width - margin, rowTop, 1);
  page.drawText('#', { x: cols[0] + 5, y: y - 16, size: 9, font: bold });
  page.drawText('Description', { x: cols[1] + 5, y: y - 16, size: 9, font: bold });
  page.drawText('Serial No.', { x: cols[2] + 5, y: y - 16, size: 9, font: bold });
  page.drawText('Qty', { x: cols[3] + 5, y: y - 16, size: 9, font: bold });
  page.drawText('Rate', { x: cols[4] + 5, y: y - 16, size: 9, font: bold });
  y -= 26;
  line(margin, width - margin, y, 0.8);
  page.drawText('1', { x: cols[0] + 5, y: y - 18, size: 9, font: regular });
  const desc = safe(sale.stock_label || 'Item').slice(0, 38);
  page.drawText(desc, { x: cols[1] + 5, y: y - 18, size: 9, font: regular });
  const serials = Array.isArray(sale.serial_numbers) && sale.serial_numbers.length ? sale.serial_numbers.join(', ') : '-';
  page.drawText(serials.slice(0, 20), { x: cols[2] + 5, y: y - 18, size: 8, font: regular });
  page.drawText(String(sale.quantity || 1), { x: cols[3] + 8, y: y - 18, size: 9, font: regular });
  page.drawText(money(Number(sale.unit_price || sale.sale_price || 0)).replace('INR ', ''), { x: cols[4] + 5, y: y - 18, size: 8, font: regular });
  y -= 30;
  line(margin, width - margin, y, 1);
  for (const x of cols) page.drawLine({ start: { x, y: rowTop }, end: { x, y }, thickness: 0.6, color: rgb(0.55, 0.55, 0.55) });

  y -= 30;
  const totalX = width - margin - 210;
  page.drawText('Total', { x: totalX, y, size: 10, font: bold });
  page.drawText(money(Number(sale.sale_price || 0)), { x: totalX + 95, y, size: 10, font: bold }); y -= 17;
  page.drawText('Received', { x: totalX, y, size: 9, font: regular });
  page.drawText(money(Number(sale.amount_received || 0)), { x: totalX + 95, y, size: 9, font: regular }); y -= 17;
  page.drawText('Balance Due', { x: totalX, y, size: 10, font: bold });
  page.drawText(money(Number(sale.due || 0)), { x: totalX + 95, y, size: 10, font: bold });

  y -= 55;
  if (settings.invoice_terms) {
    draw('Terms:', margin, 9, true); y -= 13;
    for (const termLine of wrapText(settings.invoice_terms, 88).slice(0, 5)) { draw(termLine, margin, 8); y -= 11; }
  }
  page.drawText('Authorized Signatory', { x: width - margin - 120, y: 90, size: 9, font: regular });
  page.drawText(shopName.slice(0, 36), { x: width - margin - 120, y: 74, size: 9, font: bold });
  return pdf.save();
}

async function graphJson(url: string, options: RequestInit) {
  const response = await fetch(url, options);
  const text = await response.text();
  let data: any = {};
  try { data = text ? JSON.parse(text) : {}; } catch { data = { raw: text }; }
  if (!response.ok) throw new Error(data?.error?.message || `WhatsApp API request failed (${response.status}).`);
  return data;
}

export async function sendInvoiceTemplate(input: {
  phone: string;
  filename: string;
  pdfBytes: Uint8Array;
  customerName: string;
  invoiceNumber: string;
  amountText: string;
}) {
  const config = getWhatsAppConfig();
  const base = `https://graph.facebook.com/${encodeURIComponent(config.graphVersion)}`;
  const form = new FormData();
  form.append('messaging_product', 'whatsapp');
  form.append('type', 'application/pdf');
  form.append('file', new Blob([Buffer.from(input.pdfBytes)], { type: 'application/pdf' }), input.filename);
  const uploaded = await graphJson(`${base}/${encodeURIComponent(config.phoneNumberId)}/media`, {
    method: 'POST', headers: { Authorization: `Bearer ${config.accessToken}` }, body: form,
  });
  if (!uploaded?.id) throw new Error('WhatsApp media upload did not return a media ID.');

  const sent = await graphJson(`${base}/${encodeURIComponent(config.phoneNumberId)}/messages`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${config.accessToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      messaging_product: 'whatsapp',
      recipient_type: 'individual',
      to: input.phone,
      type: 'template',
      template: {
        name: config.templateName,
        language: { code: config.templateLanguage },
        components: [
          { type: 'header', parameters: [{ type: 'document', document: { id: uploaded.id, filename: input.filename } }] },
          { type: 'body', parameters: [
            { type: 'text', text: input.customerName || 'Customer' },
            { type: 'text', text: input.invoiceNumber },
            { type: 'text', text: input.amountText },
          ] },
        ],
      },
    }),
  });
  const messageId = sent?.messages?.[0]?.id;
  if (!messageId) throw new Error('WhatsApp accepted the request but did not return a message ID.');
  return { messageId, mediaId: uploaded.id };
}
