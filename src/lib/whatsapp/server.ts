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

export async function buildInvoicePdf(input: {sale:any;customer:any;settings:Record<string,string>}) {
  const {sale,customer,settings}=input;
  const pdf=await PDFDocument.create();
  const regular=await pdf.embedFont(StandardFonts.Helvetica),bold=await pdf.embedFont(StandardFonts.HelveticaBold);
  const width=595.28,height=841.89,margin=40,right=width-margin;
  let page=pdf.addPage([width,height]),y=height-margin;
  const text=(value:unknown,x:number,atY:number,size=9,strong=false)=>page.drawText(safe(value),{x,y:atY,size,font:strong?bold:regular,color:rgb(.08,.08,.08)});
  const rule=(atY:number)=>page.drawLine({start:{x:margin,y:atY},end:{x:right,y:atY},thickness:.6,color:rgb(.7,.7,.7)});
  const wrap=(value:unknown,maxWidth:number,size=9)=>{
    const result:string[]=[];
    for(const paragraph of safe(value).split(/\r?\n/)){
      let line='';
      for(const word of paragraph.split(/\s+/).filter(Boolean)){
        if(line&&regular.widthOfTextAtSize(line+' '+word,size)>maxWidth){result.push(line);line='';}
        let rest=word;
        while(regular.widthOfTextAtSize(rest,size)>maxWidth){let cut=1;while(cut<rest.length&&regular.widthOfTextAtSize(rest.slice(0,cut+1),size)<=maxWidth)cut++;if(line){result.push(line);line='';}result.push(rest.slice(0,cut));rest=rest.slice(cut);}
        line=line?line+' '+rest:rest;
      }
      result.push(line);
    }
    return result.length?result:[''];
  };
  const rightText=(value:string,end:number,atY:number,maxWidth:number,strong=false)=>{const font=strong?bold:regular;let size=9;while(font.widthOfTextAtSize(value,size)>maxWidth&&size>5)size-=.25;text(value,end-font.widthOfTextAtSize(value,size),atY,size,strong);};
  const newPage=()=>{page=pdf.addPage([width,height]);y=height-margin;text(`Invoice ${safe(sale.bill_no||sale.id)} - continued`,margin,y,10,true);y-=24;};
  const ensure=(space:number)=>{if(y-space<55)newPage();};
  const block=(value:unknown,size=9,strong=false)=>{for(const line of wrap(value,right-margin,size)){ensure(size+6);text(line,margin,y,size,strong);y-=size+5;}};
  const shop=settings.shop_name||'e-Zone Computers';
  block(shop,18,true);block('SALE INVOICE',12,true);
  if(settings.shop_address)block(settings.shop_address);
  if(settings.shop_phone)block(`Phone: ${settings.shop_phone}`);
  if(settings.shop_email)block(`Email: ${settings.shop_email}`);
  if(settings.shop_gstin)block(`GSTIN: ${settings.shop_gstin}`);
  if(settings.shop_state||settings.shop_state_code)block([settings.shop_state,settings.shop_state_code?`State Code: ${settings.shop_state_code}`:''].filter(Boolean).join(' | '));
  y-=5;block(`Invoice: ${safe(sale.bill_no||sale.id)}     Date: ${safe(sale.date)}`,10,true);rule(y);y-=20;
  block('Bill To',10,true);block(sale.buyer_name||customer?.name||'Customer',10,true);
  if(customer?.address)block(customer.address);
  if(customer?.phone)block(`Phone: ${customer.phone}`);
  if(customer?.gstin)block(`GSTIN: ${customer.gstin}`);
  block(`Payment Mode: ${safe(sale.payment_mode)}`);y-=10;
  const cols=[margin,margin+24,margin+310,margin+350,margin+435,right];
  const tableHeader=()=>{ensure(30);rule(y);['#','Description','Qty','Rate','Amount'].forEach((label,i)=>text(label,cols[i]+4,y-15,8,true));y-=23;rule(y);};
  tableHeader();
  const lines=Array.isArray(sale.line_items)&&sale.line_items.length?sale.line_items:[{stock_label:sale.stock_label||'Item',quantity:sale.quantity||1,unit_price:sale.unit_price??sale.sale_price??0,serial_numbers:sale.serial_numbers||[]}];
  const invoiceRows=lines.map((line:any,index:number)=>({number:String(index+1),description:safe(line.stock_label),serials:Array.isArray(line.serial_numbers)?line.serial_numbers.filter(Boolean):[],quantity:Number(line.quantity||1),rate:Number(line.unit_price||0),amount:Math.round(Number(line.unit_price||0)*100)*Number(line.quantity||1)/100}));
  if(Number(sale.service_charge||0)>0)invoiceRows.push({number:'',description:'Service Charge',serials:[],quantity:1,rate:Number(sale.service_charge),amount:Number(sale.service_charge)});
  for(const row of invoiceRows){
    const description=wrap(row.description,cols[2]-cols[1]-8,9).map(value=>({value,size:9,height:13}));
    const serialText=row.serials.length?`S/N - ${row.serials.join(', ')}`:'';
    const serials=serialText?wrap(serialText,cols[2]-cols[1]-8,6.3).map(value=>({value,size:6.3,height:9})):[];
    const segments=[...description,...serials];let offset=0,first=true;
    while(offset<segments.length){
      if(y-28<55){newPage();tableHeader();}
      const available=y-65;let take=0,contentHeight=0;
      while(offset+take<segments.length&&contentHeight+segments[offset+take].height<=available){contentHeight+=segments[offset+take].height;take++;}
      if(take===0){newPage();tableHeader();continue;}
      const top=y,rowHeight=contentHeight+10;let lineY=top-15;
      for(let n=0;n<take;n++){const segment=segments[offset+n];text(segment.value,cols[1]+4,lineY,segment.size);lineY-=segment.height;}
      if(first){text(row.number,cols[0]+4,top-15,8);rightText(String(row.quantity),cols[3]-4,top-15,cols[3]-cols[2]-8);rightText(money(row.rate).replace('INR ',''),cols[4]-4,top-15,cols[4]-cols[3]-8);rightText(money(row.amount).replace('INR ',''),cols[5]-4,top-15,cols[5]-cols[4]-8);first=false;}
      y-=rowHeight;rule(y);for(const x of cols)page.drawLine({start:{x,y:top},end:{x,y},thickness:.4,color:rgb(.8,.8,.8)});
      offset+=take;if(offset<segments.length){newPage();tableHeader();}
    }
  }
  ensure(110);y-=24;
  for(const [label,value] of [['Total',sale.sale_price],['Received',sale.amount_received],['Balance Due',sale.due]] as [string,number][]){text(label,right-220,y,10,true);rightText(money(Number(value||0)),right,y,125,true);y-=19;}
  y-=15;
  if(settings.invoice_terms){block('Terms:',9,true);block(settings.invoice_terms,8);}
  ensure(65);y-=25;text('Authorized Signatory',right-130,y,9);y-=15;for(const line of wrap(shop,160,8)){ensure(15);text(line,right-160,y,8);y-=12;}
  const pages=pdf.getPages();pages.forEach((p,index)=>p.drawText(`Page ${index+1} of ${pages.length}`,{x:margin,y:25,size:8,font:regular,color:rgb(.4,.4,.4)}));
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
