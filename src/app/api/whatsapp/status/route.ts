import { NextRequest, NextResponse } from 'next/server';
import { getUserSupabase } from '@/lib/whatsapp/server';

export async function GET(req: NextRequest) {
  try {
    const { sb, token } = getUserSupabase(req.headers.get('authorization'));
    const { data: userData, error: userError } = await sb.auth.getUser(token);
    if (userError || !userData.user) return NextResponse.json({ error: 'Your login session has expired.' }, { status: 401 });
    const { data: profile } = await sb.from('profiles').select('role').eq('id', userData.user.id).single();
    if (profile?.role !== 'Admin') return NextResponse.json({ error: 'Admin access is required.' }, { status: 403 });
    const fields = {
      graphVersion: Boolean(process.env.WHATSAPP_GRAPH_API_VERSION?.trim()),
      phoneNumberId: Boolean(process.env.WHATSAPP_PHONE_NUMBER_ID?.trim()),
      accessToken: Boolean(process.env.WHATSAPP_ACCESS_TOKEN?.trim()),
      templateName: Boolean(process.env.WHATSAPP_INVOICE_TEMPLATE_NAME?.trim()),
      templateLanguage: process.env.WHATSAPP_INVOICE_TEMPLATE_LANGUAGE?.trim() || 'en',
    };
    return NextResponse.json({ configured: fields.graphVersion && fields.phoneNumberId && fields.accessToken && fields.templateName, fields });
  } catch (error: any) {
    return NextResponse.json({ error: error?.message || 'Could not check WhatsApp configuration.' }, { status: 400 });
  }
}
