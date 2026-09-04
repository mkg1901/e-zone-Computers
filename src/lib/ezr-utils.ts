import type { Cache, Stock, Sale, Ledger } from '@/types/ezr';
export const pad=(n:number,len:number)=>String(n).padStart(len,'0');
export const inr=(n:unknown)=>'₹'+Number(n||0).toLocaleString('en-IN');
export const todayISO=()=>{ const d=new Date(); const y=d.getFullYear(); const m=String(d.getMonth()+1).padStart(2,'0'); const day=String(d.getDate()).padStart(2,'0'); return `${y}-${m}-${day}`; };
export const fmtDate=(iso?:string)=>{if(!iso)return '—';const d=new Date(`${iso}T00:00:00`);return Number.isNaN(d.valueOf())?iso:d.toLocaleDateString('en-GB',{day:'2-digit',month:'short',year:'numeric'});};
export const monthLabel=(ym:string)=>{if(!ym)return '—';const [y,m]=ym.split('-').map(Number);return new Date(y,m-1,1).toLocaleDateString('en-GB',{month:'long',year:'numeric'});};
export const quarterOfMonth=(m:number)=>Math.floor((m-1)/3)+1;
export const ymToQuarterKey=(ym:string)=>{const[y,m]=ym.split('-').map(Number);return `${y}-Q${quarterOfMonth(m)}`};
export const quarterLabel=(qKey:string)=>{const[y,q]=qKey.split('-Q');const r:Record<string,string>={1:'Jan–Mar',2:'Apr–Jun',3:'Jul–Sep',4:'Oct–Dec'};return `${r[q]} ${y} (Q${q})`;};
export const stockTotalCost=(s?:Stock)=>!s?0:Number(s.purchasePrice||0)+(s.modifications||[]).reduce((sum,m)=>sum+(m.type==='Removed'?-Number(m.cost||0):Number(m.cost||0)),0);
export const saleGrossProfit=(sale:Sale,cache:Cache)=>{if(sale.lineItems?.length)return sale.salePrice-sale.lineItems.reduce((sum,line)=>sum+line.purchasePrice*line.quantity,0);if(sale.stockSource==='new'&&sale.newProductId){const p=cache.newStock.find(x=>x.id===sale.newProductId);return p?Number(sale.salePrice||0)-Number(p.purchasePrice||0)*Number(sale.quantity||1):null}const st=cache.stock.find(x=>x.id===sale.stockId);return st?Number(sale.salePrice||0)-stockTotalCost(st):null};
export const cashOpening=(c:Cache)=>Number(c.settings.cash_opening||0);
export const cashBalance=(c:Cache)=>cashOpening(c)+c.ledger.filter(l=>l.mode==='Cash').reduce((s,l)=>s+Number(l.amount),0);
export const bankBalance=(id:string,c:Cache)=>{const b=c.banks.find(x=>x.id===id);return b?Number(b.openingBalance||0)+c.ledger.filter(l=>l.mode==='Bank'&&l.bankId===id).reduce((s,l)=>s+Number(l.amount),0):0};
export const totalBankBalance=(c:Cache)=>c.banks.reduce((s,b)=>s+bankBalance(b.id,c),0);
export const totalCustomerDue=(c:Cache)=>c.sales.reduce((s,x)=>s+Number(x.due||0),0);
export const totalSellerDue=(c:Cache)=>c.purchases.reduce((s,x)=>s+Number(x.due||0),0);

// Check the projected ledger before any related stock/accounting writes.
export function assertLedgerChange(c:Cache, amount:number, mode:string, bankId?:string|null, refType?:string, refId?:string){
 if(!Number.isFinite(amount))throw Error('Enter a valid amount.');
 if(mode!=='Cash'&&mode!=='Online'&&mode!=='Bank')throw Error('Select Cash or Online.');
 const bank=mode!=='Cash';
 if(bank&&!c.banks.some(b=>b.id===bankId))throw Error('Select a bank account.');
 const ledger=c.ledger.filter(l=>!(refType&&refId&&l.refType===refType&&l.refId===refId));
 const next={...c,ledger:[...ledger,{id:'preview',date:'',type:'',mode:bank?'Bank':'Cash',bankId:bank?bankId:null,amount}]};
 if(Math.round(cashBalance(next)*100)<0)throw Error('Insufficient cash balance.');
 for(const account of c.banks)if(Math.round(bankBalance(account.id,next)*100)<0)throw Error('Insufficient balance in '+account.name+'.');
}

export type LedgerDisplayRow=Ledger & {transferAmount?:number};
// Collapse only a complete, matching transfer pair for display. Never change the accounting cache.
export function ledgerDisplayRows(entries:Ledger[]):LedgerDisplayRow[]{
 const groups=new Map<string,Ledger[]>();
 for(const row of entries){
  if(row.refType==='manual'&&row.refId){
   const group=groups.get(row.refId)||[];group.push(row);groups.set(row.refId,group);
  }
 }
 const combined=new Map<string,LedgerDisplayRow>();
 for(const [ref,group] of groups){
  if(group.length!==2)continue;
  const cash=group.find(r=>r.mode==='Cash'),bank=group.find(r=>r.mode==='Bank');
  if(!cash||!bank||!bank.bankId||cash.bankId||cash.date!==bank.date||cash.note!==bank.note||cash.createdByName!==bank.createdByName)continue;
  if(!Number.isFinite(cash.amount)||!Number.isFinite(bank.amount)||cash.amount===0||cash.amount!==-bank.amount)continue;
  const toBank=cash.amount<0;
  if(!(cash.note||'').startsWith(toBank?'Cash to bank transfer - ':'Bank to cash transfer - '))continue;
  if((toBank?cash:bank).type!=='Payment'||(toBank?bank:cash).type!=='Payment Received')continue;
  const newest=String(cash.id).localeCompare(String(bank.id),undefined,{numeric:true})>0?cash:bank;
  combined.set(ref,{...newest,type:'Transfer',mode:toBank?'Cash → Bank':'Bank → Cash',bankId:bank.bankId,refType:'transfer',amount:0,transferAmount:Math.abs(cash.amount)});
 }
 const emitted=new Set<string>();const rows:LedgerDisplayRow[]=[];
 for(const row of entries){const transfer=row.refType==='manual'&&row.refId?combined.get(row.refId):undefined;if(transfer){if(!emitted.has(row.refId!)){rows.push(transfer);emitted.add(row.refId!);}}else rows.push(row);}
 return rows.sort((a,b)=>b.date.localeCompare(a.date)||String(b.id).localeCompare(String(a.id),undefined,{numeric:true}));
}

export function saleInvoiceLines(sale:Sale){
 return sale.lineItems?.length?sale.lineItems.map(line=>({description:line.stockLabel,serials:line.serialNumbers,quantity:line.quantity,rate:line.unitPrice,amount:Math.round(line.unitPrice*100)*line.quantity/100})):[{description:sale.stockLabel||'Item',serials:sale.serialNumbers||[],quantity:sale.quantity||1,rate:sale.unitPrice??sale.salePrice,amount:sale.salePrice-(sale.serviceCharge||0)}];
}
