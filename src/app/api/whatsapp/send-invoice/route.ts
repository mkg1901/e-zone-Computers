import { NextRequest, NextResponse } from 'next/server';
import { buildInvoicePdf, getUserSupabase, normalizeWhatsAppPhone, sendInvoiceTemplate } from '@/lib/whatsapp/server';

export const runtime = 'nodejs';

export async function POST(req: NextRequest) {
  let sb: ReturnType<typeof getUserSupabase>['sb'] | null = null;
  let saleId = '';
  let phone = '';
  let customerId: string | null = null;
  let userId: string | null = null;
  try {
    const body = await req.json().catch(() => ({}));
    saleId = String(body?.saleId || '').trim();
    if (!saleId) return NextResponse.json({ error: 'Sale ID is required.' }, { status: 400 });

    const auth = getUserSupabase(req.headers.get('authorization'));
    sb = auth.sb;
    const { data: userData, error: userError } = await sb.auth.getUser(auth.token);
    if (userError || !userData.user) return NextResponse.json({ error: 'Your login session has expired.' }, { status: 401 });
    userId = userData.user.id;

    const { data: sale, error: saleError } = await sb.from('sales').select('*').eq('id', saleId).single();
    if (saleError || !sale) throw new Error('Sale was not found or you do not have access to it.');
    customerId = sale.buyer_id || null;
    if (!customerId) throw new Error('This sale is not linked to a customer.');

    const [{ data: customer, error: customerError }, { data: settingsRows, error: settingsError }, { data: profile }] = await Promise.all([
      sb.from('customers').select('*').eq('id', customerId).single(),
      sb.from('settings').select('key,value'),
      sb.from('profiles').select('full_name').eq('id', userId).single(),
    ]);
    if (customerError || !customer) throw new Error('Customer record could not be loaded.');
    if (settingsError) throw new Error(settingsError.message);
    phone = normalizeWhatsAppPhone(customer.phone || '');
    const settings = Object.fromEntries((settingsRows || []).map((r: any) => [r.key, String(r.value ?? '')]));
    const pdfBytes = await buildInvoicePdf({ sale, customer, settings });
    const invoiceNumber = String(sale.bill_no || sale.id);
    const amountText = `INR ${Number(sale.sale_price || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

    const { data: attempt, error: attemptError } = await sb.from('invoice_whatsapp_deliveries').insert({
      sale_id: saleId,
      customer_id: customerId,
      phone,
      status: 'pending',
      created_by: userId,
      created_by_name: profile?.full_name || '',
    }).select('id').single();
    if (attemptError) throw new Error(`Could not create WhatsApp delivery record: ${attemptError.message}`);

    try {
      const sent = await sendInvoiceTemplate({
        phone,
        filename: `Invoice-${invoiceNumber}.pdf`,
        pdfBytes,
        customerName: String(customer.name || sale.buyer_name || 'Customer'),
        invoiceNumber,
        amountText,
      });
      await sb.from('invoice_whatsapp_deliveries').update({
        status: 'sent', whatsapp_message_id: sent.messageId, whatsapp_media_id: sent.mediaId, sent_at: new Date().toISOString(), error_message: '',
      }).eq('id', attempt.id);
      return NextResponse.json({ ok: true, messageId: sent.messageId, phone });
    } catch (sendError: any) {
      await sb.from('invoice_whatsapp_deliveries').update({ status: 'failed', error_message: sendError?.message || String(sendError) }).eq('id', attempt.id);
      throw sendError;
    }
  } catch (error: any) {
    // If an error occurs before the pending attempt is created, preserve a failure audit row when possible.
    if (sb && saleId && userId) {
      const { data: existing } = await sb.from('invoice_whatsapp_deliveries').select('id').eq('sale_id', saleId).order('created_at', { ascending: false }).limit(1).maybeSingle();
      if (!existing) await sb.from('invoice_whatsapp_deliveries').insert({ sale_id: saleId, customer_id: customerId, phone, status: 'failed', error_message: error?.message || String(error), created_by: userId });
    }
    return NextResponse.json({ error: error?.message || 'WhatsApp invoice sending failed.' }, { status: 400 });
  }
}
